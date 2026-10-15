import AppKit
import Testing
@testable import UsageBar

private actor MenuProvider: UsageProvider {
    nonisolated let id = "claude"
    nonisolated let displayName = "Claude"
    nonisolated let glyph = "claude"
    private(set) var replacements: [String?] = []
    private(set) var signOuts = 0
    var accountIDs: [String] { ["test@example.com"] }
    func fetch() async -> [AccountSnapshot] { [] }
    func signIn(replacing accountID: String?, showing: @Sendable @escaping (String, URL) -> Void) async throws {
        replacements.append(accountID)
    }
    func signOut(accountID: String) async { signOuts += 1 }
}

private func account(id: String = "test@example.com", error: String? = nil) -> AccountSnapshot {
    AccountSnapshot(providerID: "claude", glyph: "claude", accountID: id, accountLabel: id,
                    windows: [], error: error, fetchedAt: Date())
}

@MainActor
struct ReconnectMenuTests {
    @Test func savedAccountHasReconnectInBothMenusEvenWhenFetchFails() throws {
        let provider = MenuProvider()
        let controller = StatusItemController(providers: [provider])
        let saved = account(error: ProviderError.sessionExpired.localizedDescription)
        for menu in [controller.menu(for: saved), controller.mergedMenu([saved])] {
            let reconnect = try #require(menu.items.first { $0.title.trimmingCharacters(in: .whitespaces) == "Reconnect Claude…" })
            #expect(reconnect.representedObject as? AccountSnapshot == saved)
            #expect(reconnect.target as? StatusItemController === controller)
            #expect(reconnect.action.map(NSStringFromSelector) == "reconnect:")
            #expect(menu.items.contains { $0.title.contains("Sign in another Claude account…") })
            #expect(menu.items.contains { $0.title == "Refresh usage" })
        }
    }

    @Test func signedOutAccountOffersSignInNotReconnect() {
        let controller = StatusItemController(providers: [MenuProvider()])
        let saved = account(id: "-", error: "Not signed in")
        for menu in [controller.menu(for: saved), controller.mergedMenu([saved])] {
            #expect(!menu.items.contains { $0.title.contains("Reconnect") })
            #expect(menu.items.contains { $0.title.contains("Sign in to Claude…") })
        }
    }
}

struct ReconnectTests {
    @Test func reconnectTargetsExistingAccountWithoutSigningOut() async throws {
        let provider = MenuProvider()
        try await provider.reconnect(accountID: "test@example.com") { _, _ in }
        try await provider.signIn { _, _ in }
        #expect(await provider.replacements == ["test@example.com", nil])
        #expect(await provider.signOuts == 0)
    }

    @Test func replacementPreservesExistingKeyAndRejectsDifferentAccount() throws {
        #expect(try AccountIdentity.storageID(authenticated: "TEST@example.com", replacing: "test@example.com") == "test@example.com")
        #expect(try AccountIdentity.storageID(authenticated: "new@example.com", replacing: nil) == "new@example.com")
        #expect(throws: ProviderError.self) {
            try AccountIdentity.storageID(authenticated: "other@example.com", replacing: "test@example.com")
        }
    }

    @Test func claudeReconnectUpdatesCredentialsWithoutAddingOrRemovingAccounts() async throws {
        let store = TokenStore(loadVault: { [:] }, writeVault: { _ in })
        let provider = ClaudeProvider(store: store, send: { _ in throw CancellationError() })
        let original = authorization(email: "test@example.com", access: "old", refresh: "old-refresh")
        try await provider.storeAuthorization(original, replacing: nil)
        try await provider.storeAuthorization(authorization(email: "other@example.com", access: "other", refresh: "other-refresh"), replacing: nil)
        try await provider.storeAuthorization(authorization(email: "TEST@example.com", access: "new", refresh: "new-refresh"), replacing: "test@example.com")
        #expect(await provider.accountIDs == ["other@example.com", "test@example.com"])
        let saved = try #require(await store.load(SavedToken.self, key: "claude.test@example.com"))
        #expect(saved.accessToken == "new")
        #expect(saved.refreshToken == "new-refresh")
        #expect(await store.load(SavedToken.self, key: "claude.other@example.com")?.accessToken == "other")
    }

    @Test func wrongAccountOrFailedAuthorizationLeavesOriginalCredentialsIntact() async throws {
        let store = TokenStore(loadVault: { [:] }, writeVault: { _ in })
        let provider = ClaudeProvider(store: store, send: { _ in throw CancellationError() })
        try await provider.storeAuthorization(authorization(email: "test@example.com", access: "old", refresh: "old-refresh"), replacing: nil)
        await #expect(throws: ProviderError.self) {
            try await provider.storeAuthorization(authorization(email: "other@example.com", access: "wrong", refresh: "wrong-refresh"), replacing: "test@example.com")
        }
        await #expect(throws: ProviderError.self) {
            try await provider.storeAuthorization([:], replacing: "test@example.com")
        }
        #expect(await provider.accountIDs == ["test@example.com"])
        #expect(await store.load(SavedToken.self, key: "claude.test@example.com")?.accessToken == "old")
    }
}

private struct SavedToken: Decodable {
    let accessToken: String
    let refreshToken: String?
}

private func authorization(email: String, access: String, refresh: String) -> [String: Any] {
    ["access_token": access, "refresh_token": refresh, "expires_in": 28800,
     "account": ["email_address": email]]
}
