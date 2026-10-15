import AppKit
import Foundation

private struct CodexToken: Codable {
    var accessToken: String
    var refreshToken: String
    var accountID: String?
    var expiresAt: Date?
    var label: String
}

actor CodexProvider: UsageProvider {
    nonisolated let id = "codex"
    nonisolated let displayName = "Codex"
    nonisolated let glyph = "openai"

    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let port: UInt16 = 1455
    private let callbackPath = "/auth/callback"
    private let keyPrefix = "codex."

    private var redirect: String { "http://localhost:\(port)\(callbackPath)" }

    var accountIDs: [String] {
        get async {
            await TokenStore.shared.keys(prefix: keyPrefix).map { String($0.dropFirst(keyPrefix.count)) }
        }
    }

    func signOut(accountID: String) async {
        await TokenStore.shared.delete(key: keyPrefix + accountID)
    }

    func signIn(showing _: @Sendable @escaping (String, URL) -> Void) async throws {
        let pkce = PKCE()
        var components = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "state", value: pkce.verifier),
        ]
        if await !accountIDs.isEmpty { components.queryItems?.append(.init(name: "prompt", value: "login")) }

        let loopback = Loopback()
        async let callback = loopback.waitForCode(port: port, path: callbackPath)
        await PasteFlow.open(components.url!)
        let params = try await callback
        guard let code = params["code"] else { throw ProviderError.malformed("no code in callback") }

        let body = try await Net.json(Net.form(
            URL(string: "https://auth.openai.com/oauth/token")!,
            [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect,
                "client_id": clientID,
                "code_verifier": pkce.verifier,
            ]))
        guard let access = body["access_token"] as? String,
              let refresh = body["refresh_token"] as? String
        else { throw ProviderError.malformed("no tokens in response") }

        let claims = Self.claims(body["id_token"] as? String)
        let label = (claims["email"] as? String) ?? "codex"
        let accountID = ((claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String)
        try await TokenStore.shared.save(CodexToken(accessToken: access, refreshToken: refresh, accountID: accountID,
                       expiresAt: (body["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
                       label: label),
            key: keyPrefix + label)
    }

    private static func claims(_ idToken: String?) -> [String: Any] {
        guard let segment = idToken?.split(separator: ".").dropFirst().first else { return [:] }
        var base64 = String(segment).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    func fetch() async -> [AccountSnapshot] {
        let ids = await accountIDs
        guard !ids.isEmpty else {
            return [AccountSnapshot(providerID: id, glyph: glyph, accountID: "-", accountLabel: displayName,
                                    windows: [], error: ProviderError.notAuthenticated.localizedDescription,
                                    fetchedAt: Date())]
        }
        var out: [AccountSnapshot] = []
        for accountID in ids { out.append(await snapshot(accountID: accountID)) }
        return out
    }

    private func snapshot(accountID: String) async -> AccountSnapshot {
        do {
            let stored = try await validToken(accountID: accountID)
            var headers = ["chatgpt-account-id": stored.accountID ?? ""]
            headers = headers.filter { !$0.value.isEmpty }
            let body = try await Net.json(Net.get(
                URL(string: "https://chatgpt.com/backend-api/codex/usage")!,
                bearer: stored.accessToken, headers: headers))
            let windows = Self.windows(from: body)
            return AccountSnapshot(providerID: id, glyph: glyph, accountID: accountID, accountLabel: accountID,
                                   windows: windows, error: windows.isEmpty ? "No usage in response" : nil,
                                   fetchedAt: Date())
        } catch {
            return AccountSnapshot(providerID: id, glyph: glyph, accountID: accountID, accountLabel: accountID,
                                   windows: [], error: error.localizedDescription, fetchedAt: Date())
        }
    }

    private static func windows(from body: [String: Any]) -> [UsageWindow] {
        guard let limits = body["rate_limit"] as? [String: Any] else { return [] }
        return ["primary_window", "secondary_window"].compactMap { key in
            guard let raw = limits[key] as? [String: Any] else { return nil }
            let seconds = (raw["limit_window_seconds"] as? Double) ?? 0
            let label = switch seconds {
            case 604800: "W"
            case 18000: "5h"
            case 86400...: "\(Int(seconds / 86400))d"
            default: "\(Int(seconds / 3600))h"
            }
            let reset = (raw["reset_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
                ?? (raw["reset_after_seconds"] as? Double).map { Date().addingTimeInterval($0) }
            return UsageWindow(label: label, percentUsed: raw["used_percent"] as? Double, resetsAt: reset)
        }
    }

    private func validToken(accountID: String) async throws -> CodexToken {
        guard var stored = await TokenStore.shared.load(CodexToken.self, key: keyPrefix + accountID) else {
            throw ProviderError.notAuthenticated
        }
        if let expiry = stored.expiresAt, expiry.timeIntervalSinceNow < 120 {
            let body = try await Net.json(Net.form(
                URL(string: "https://auth.openai.com/oauth/token")!,
                ["grant_type": "refresh_token", "refresh_token": stored.refreshToken, "client_id": clientID]))
            if let access = body["access_token"] as? String {
                stored.accessToken = access
                stored.refreshToken = (body["refresh_token"] as? String) ?? stored.refreshToken
                stored.expiresAt = (body["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
                try await TokenStore.shared.save(stored, key: keyPrefix + accountID)
            }
        }
        return stored
    }
}
