import Foundation
import Testing
@testable import UsageBar

private func snapshot(error: String? = nil, windows: [UsageWindow]? = nil, account: String = "test") -> AccountSnapshot {
    AccountSnapshot(providerID: "claude", glyph: "claude", accountID: account, accountLabel: account,
                    windows: windows ?? [UsageWindow(label: "5h", percentUsed: 95,
                                                     resetsAt: Date(timeIntervalSince1970: 2_000_000_000))],
                    error: error, fetchedAt: Date(timeIntervalSince1970: 1_900_000_000))
}

struct SnapshotCacheTests {
    @Test func failuresRetainUsageAndOriginalTimestampAcrossRestarts() throws {
        let suite = "UsageBarTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var cache = SnapshotCache(defaults: defaults)
        let good = snapshot()
        #expect(cache.apply([good], providerID: "claude") == [good])
        let failed = snapshot(error: "Offline", windows: [])
        let stale = try #require(cache.apply([failed], providerID: "claude").first)
        #expect(stale.windows == good.windows)
        #expect(stale.fetchedAt == good.fetchedAt)
        #expect(stale.error == "Offline")
        #expect(Format.barText(stale) == "5h 95% ⚠︎")
        #expect(Format.compact(stale) == "95⚠︎")
        let restored = try #require(SnapshotCache(defaults: defaults).restored(providerID: "claude").first)
        #expect(restored.windows == good.windows)
        #expect(restored.fetchedAt == good.fetchedAt)
        #expect(restored.error != nil)
        #expect(cache.apply([good], providerID: "claude").first?.error == nil)
    }

    @Test func signedOutAccountsAreRemovedAndNeverResurrected() throws {
        let suite = "UsageBarTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var cache = SnapshotCache(defaults: defaults)
        _ = cache.apply([snapshot()], providerID: "claude")
        let signedOut = snapshot(error: "Not signed in", windows: [], account: "-")
        #expect(cache.apply([signedOut], providerID: "claude") == [signedOut])
        #expect(SnapshotCache(defaults: defaults).restored(providerID: "claude").isEmpty)
    }

    @Test func noReadingShowsWarningNotDashAndStaleLimitsDoNotClaimReset() {
        #expect(Format.barText(snapshot(error: "Offline", windows: [])) == "⚠︎")
        #expect(Format.compact(snapshot(error: "Offline", windows: [])) == "⚠︎")
        #expect(Format.compact(snapshot(error: "Loading…", windows: [])) == "…")
        let stale = snapshot(error: "Offline", windows: [UsageWindow(label: "5h", percentUsed: 100,
                                                                    resetsAt: .distantPast)])
        #expect(Format.compact(stale) == "100⚠︎")
        #expect(!Format.barText(stale).contains("↻"))
        #expect(!Format.barText(snapshot()).contains("⚠︎"))
    }
}

private struct TestToken: Codable, Sendable {
    var accessToken = "old"
    var refreshToken: String? = "refresh-old"
    var expiresAt: Date? = .distantPast
    var label = "test"
}

private actor ClaudeServer {
    enum Mode: Sendable { case normal, unauthorized, invalidGrant, malformed }
    let mode: Mode
    private(set) var renewals = 0
    private(set) var usageRequests = 0

    init(_ mode: Mode = .normal) { self.mode = mode }

    func send(_ request: URLRequest) async throws -> Data {
        if request.url?.path == "/v1/oauth/token" {
            renewals += 1
            try await Task.sleep(for: .milliseconds(50))
            switch mode {
            case .invalidGrant:
                throw ProviderError.http(400, #"{"error":"invalid_grant","error_description":"Refresh token expired"}"#)
            case .malformed:
                return Data(#"{"expires_in":28800}"#.utf8)
            default:
                return Data(#"{"access_token":"new","refresh_token":"refresh-new","expires_in":28800}"#.utf8)
            }
        }
        usageRequests += 1
        if mode == .unauthorized, request.value(forHTTPHeaderField: "Authorization") == "Bearer old" {
            throw ProviderError.http(401, "expired access token")
        }
        return Data(#"{"five_hour":{"utilization":23,"resets_at":"2026-10-16T12:00:00Z"}}"#.utf8)
    }
}

private func memoryStore(token: TestToken = TestToken()) async throws -> TokenStore {
    let store = TokenStore(loadVault: { [:] }, writeVault: { _ in })
    try await store.save(token, key: "claude.test")
    return store
}

struct ClaudeTests {
    @Test func concurrentExpiredRequestsShareOneRenewalAndSaveRotatedToken() async throws {
        let store = try await memoryStore()
        let server = ClaudeServer()
        let provider = ClaudeProvider(store: store, send: { try await server.send($0) })
        await withTaskGroup(of: [AccountSnapshot].self) { group in
            for _ in 0..<20 { group.addTask { await provider.fetch() } }
            for await result in group {
                #expect(result.first?.error == nil)
                #expect(result.first?.windows.first?.percentUsed == 23)
            }
        }
        #expect(await server.renewals == 1)
        let saved = try #require(await store.load(TestToken.self, key: "claude.test"))
        #expect(saved.accessToken == "new")
        #expect(saved.refreshToken == "refresh-new")
        #expect(try #require(saved.expiresAt) > Date())
    }

    @Test func unauthorizedAccessRenewsDespiteFutureExpiryAndRetriesUsage() async throws {
        let store = try await memoryStore(token: TestToken(expiresAt: .distantFuture))
        let server = ClaudeServer(.unauthorized)
        let provider = ClaudeProvider(store: store, send: { try await server.send($0) })
        let result = await provider.fetch()
        #expect(result.first?.error == nil)
        #expect(await server.renewals == 1)
        #expect(await server.usageRequests == 2)
    }

    @Test func signOutDuringRenewalCannotResurrectAccount() async throws {
        let store = try await memoryStore()
        let server = ClaudeServer()
        let provider = ClaudeProvider(store: store, send: { try await server.send($0) })
        let fetching = Task { await provider.fetch() }
        while await server.renewals == 0 { await Task.yield() }
        await provider.signOut(accountID: "test")
        _ = await fetching.value
        #expect(await provider.accountIDs.isEmpty)
        #expect(await store.load(TestToken.self, key: "claude.test") == nil)
    }

    @Test func missingExpiryRenewsRatherThanUsingUnknownToken() async throws {
        let store = try await memoryStore(token: TestToken(expiresAt: nil))
        let server = ClaudeServer()
        let provider = ClaudeProvider(store: store, send: { try await server.send($0) })
        #expect(await provider.fetch().first?.error == nil)
        #expect(await server.renewals == 1)
    }

    @Test func rejectedRefreshIsExplicitAndDoesNotDeleteAccount() async throws {
        let store = try await memoryStore()
        let server = ClaudeServer(.invalidGrant)
        let provider = ClaudeProvider(store: store, send: { try await server.send($0) })
        let result = await provider.fetch()
        #expect(result.first?.error == ProviderError.sessionExpired.localizedDescription)
        #expect(await provider.accountIDs == ["test"])
        #expect(await server.usageRequests == 0)
        #expect(await store.load(TestToken.self, key: "claude.test")?.refreshToken == "refresh-old")
    }

    @Test func malformedRenewalDoesNotSilentlyReuseExpiredAccess() async throws {
        let store = try await memoryStore()
        let server = ClaudeServer(.malformed)
        let provider = ClaudeProvider(store: store, send: { try await server.send($0) })
        #expect(await provider.fetch().first?.error?.contains("no access_token") == true)
        #expect(await server.usageRequests == 0)
        #expect(await store.load(TestToken.self, key: "claude.test")?.accessToken == "old")
    }
}

private final class TestVault: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = false
    private var stored: [String: Data] = [:]
    struct Locked: Error {}

    func fail(_ value: Bool) { lock.withLock { failing = value } }
    func save(_ value: [String: Data]) throws {
        try lock.withLock {
            if failing { throw Locked() }
            stored = value
        }
    }
    func load() -> [String: Data] { lock.withLock { stored } }
}

struct TokenStoreTests {
    @Test func failedPersistenceKeepsRotatedTokenInMemoryAndRetriesSaving() async throws {
        let vault = TestVault()
        let store = TokenStore(loadVault: { vault.load() }, writeVault: { try vault.save($0) })
        try await store.save(TestToken(), key: "claude.test")
        vault.fail(true)
        let rotated = TestToken(accessToken: "new", refreshToken: "refresh-new", expiresAt: .distantFuture)
        await #expect(throws: TestVault.Locked.self) { try await store.save(rotated, key: "claude.test") }
        #expect(await store.load(TestToken.self, key: "claude.test")?.refreshToken == "refresh-new")
        let oldDisk = try #require(vault.load()["claude.test"])
        #expect(try JSONDecoder().decode(TestToken.self, from: oldDisk).refreshToken == "refresh-old")
        vault.fail(false)
        _ = await store.load(TestToken.self, key: "claude.test")
        let newDisk = try #require(vault.load()["claude.test"])
        #expect(try JSONDecoder().decode(TestToken.self, from: newDisk).refreshToken == "refresh-new")
    }
}
