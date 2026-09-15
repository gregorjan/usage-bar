import Foundation

private struct OAuthToken: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var label: String
}

actor ClaudeProvider: UsageProvider {
    nonisolated let id = "claude"
    nonisolated let displayName = "Claude"
    nonisolated let glyph = "claude"

    private let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let redirect = "https://console.anthropic.com/oauth/code/callback"
    private let scope = "org:create_api_key user:profile user:inference"
    private let keyPrefix = "claude."

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
        var components = URLComponents(string: "https://claude.ai/oauth/authorize")!
        components.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.verifier),
        ]
        let pasted = try await PasteFlow.run(url: components.url!, provider: displayName)
        let parts = pasted.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { throw ProviderError.malformed("empty code") }

        let body = try await Net.json(Net.form(
            URL(string: "https://console.anthropic.com/v1/oauth/token")!,
            [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect,
                "client_id": clientID,
                "code_verifier": pkce.verifier,
                "state": parts.count > 1 ? parts[1] : pkce.verifier,
            ]
        ))
        guard let access = body["access_token"] as? String else { throw ProviderError.malformed("no access_token") }
        let label = ((body["account"] as? [String: Any])?["email_address"] as? String) ?? "claude"
        let expires = (body["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        await TokenStore.shared.save(OAuthToken(accessToken: access, refreshToken: body["refresh_token"] as? String,
                       expiresAt: expires, label: label),
            key: keyPrefix + label)
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
            let token = try await validToken(accountID: accountID)
            let request = Net.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                                  bearer: token,
                                  headers: ["anthropic-beta": "oauth-2025-04-20"])
            let body = try await Net.json(request)
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
        let mapping = [("five_hour", "5h"), ("seven_day", "W"), ("seven_day_opus", "Opus")]
        return mapping.compactMap { key, label in
            guard let raw = body[key] as? [String: Any] else { return nil }
            let used = (raw["utilization"] as? Double) ?? (raw["percent_used"] as? Double)
            let reset = (raw["resets_at"] as? String).flatMap(Dates.internetDate)
            guard used != nil || reset != nil else { return nil }
            return UsageWindow(label: label, percentUsed: used, resetsAt: reset)
        }
    }

    private func validToken(accountID: String) async throws -> String {
        guard var stored = await TokenStore.shared.load(OAuthToken.self, key: keyPrefix + accountID) else {
            throw ProviderError.notAuthenticated
        }
        if let expiry = stored.expiresAt, expiry.timeIntervalSinceNow < 120, let refresh = stored.refreshToken {
            let body = try await Net.json(Net.form(
                URL(string: "https://console.anthropic.com/v1/oauth/token")!,
                ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]))
            if let access = body["access_token"] as? String {
                stored.accessToken = access
                stored.refreshToken = (body["refresh_token"] as? String) ?? stored.refreshToken
                stored.expiresAt = (body["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
                await TokenStore.shared.save(stored, key: keyPrefix + accountID)
            }
        }
        return stored.accessToken
    }
}
