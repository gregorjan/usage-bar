import Foundation

private struct OAuthToken: Codable, Sendable {
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
    private let tokenRequests = SingleFlight<String, OAuthToken>()
    private let store: TokenStore
    private let send: @Sendable (URLRequest) async throws -> Data
    private var credentialGeneration: [String: UInt64] = [:]

    init(store: TokenStore = .shared,
         send: @escaping @Sendable (URLRequest) async throws -> Data = Net.data) {
        self.store = store
        self.send = send
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        try Net.decodeJSON(await send(request))
    }

    var accountIDs: [String] {
        get async {
            await store.keys(prefix: keyPrefix).map { String($0.dropFirst(keyPrefix.count)) }
        }
    }

    func signOut(accountID: String) async {
        credentialGeneration[accountID, default: 0] &+= 1
        await store.delete(key: keyPrefix + accountID)
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

        let body = try await json(Net.form(
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
        credentialGeneration[label, default: 0] &+= 1
        try await store.save(OAuthToken(accessToken: access, refreshToken: body["refresh_token"] as? String,
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
            let body: [String: Any]
            do {
                body = try await usage(token: token)
            } catch ProviderError.http(401, _) {
                // Expiry metadata can be wrong, or the access token revoked early.
                let renewed = try await validToken(accountID: accountID, rejectedToken: token)
                body = try await usage(token: renewed)
            }
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

    private func usage(token: String) async throws -> [String: Any] {
        try await json(Net.get(URL(string: "https://api.anthropic.com/api/oauth/usage")!,
                               bearer: token, headers: ["anthropic-beta": "oauth-2025-04-20"]))
    }

    private func validToken(accountID: String, rejectedToken: String? = nil) async throws -> String {
        if let current = await store.load(OAuthToken.self, key: keyPrefix + accountID),
           current.accessToken != rejectedToken,
           let expiry = current.expiresAt, expiry.timeIntervalSinceNow >= 120 {
            return current.accessToken
        }
        let stored = try await tokenRequests.run(key: accountID) {
            try await self.loadOrRefresh(accountID: accountID, rejectedToken: rejectedToken)
        }
        return stored.accessToken
    }

    private func loadOrRefresh(accountID: String, rejectedToken: String?) async throws -> OAuthToken {
        let generation = credentialGeneration[accountID, default: 0]
        guard var stored = await store.load(OAuthToken.self, key: keyPrefix + accountID) else {
            throw ProviderError.notAuthenticated
        }
        let rejected = rejectedToken == stored.accessToken
        let expiring = stored.expiresAt.map { $0.timeIntervalSinceNow < 120 } ?? true
        guard rejected || expiring else { return stored }
        guard let refresh = stored.refreshToken, !refresh.isEmpty else { throw ProviderError.sessionExpired }
        let body: [String: Any]
        do {
            body = try await json(Net.form(
                URL(string: "https://console.anthropic.com/v1/oauth/token")!,
                ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID]))
        } catch ProviderError.http(400, let response) {
            let data = Data(response.utf8)
            if let error = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               error["error"] as? String == "invalid_grant" {
                throw ProviderError.sessionExpired
            }
            throw ProviderError.http(400, response)
        }
        guard let access = body["access_token"] as? String, !access.isEmpty else {
            throw ProviderError.malformed("no access_token in token refresh")
        }
        guard credentialGeneration[accountID, default: 0] == generation else {
            throw ProviderError.notAuthenticated
        }
        stored.accessToken = access
        stored.refreshToken = (body["refresh_token"] as? String) ?? stored.refreshToken
        stored.expiresAt = (body["expires_in"] as? Double).map { Date().addingTimeInterval($0) }
        try await store.save(stored, key: keyPrefix + accountID)
        Log.write("claude token renewed and saved")
        return stored
    }
}
