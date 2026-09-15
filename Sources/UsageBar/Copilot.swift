import Foundation

private struct CopilotToken: Codable {
    var accessToken: String
    var login: String
}

actor CopilotProvider: UsageProvider {
    nonisolated let id = "copilot"
    nonisolated let displayName = "Copilot"
    nonisolated let glyph = "githubcopilot"

    private let clientID = "Iv1.b507a08c87ecfe98"
    private let keyPrefix = "copilot."

    var accountIDs: [String] {
        get async {
            await TokenStore.shared.keys(prefix: keyPrefix).map { String($0.dropFirst(keyPrefix.count)) }
        }
    }

    func signOut(accountID: String) async {
        await TokenStore.shared.delete(key: keyPrefix + accountID)
    }

    func signIn(showing: @Sendable @escaping (String, URL) -> Void) async throws {
        let start = try await Net.json(Net.form(
            URL(string: "https://github.com/login/device/code")!,
            ["client_id": clientID, "scope": "read:user"]
        ))
        guard let deviceCode = start["device_code"] as? String,
              let userCode = start["user_code"] as? String,
              let verification = (start["verification_uri"] as? String).flatMap(URL.init(string:))
        else { throw ProviderError.malformed("device code response") }

        showing(userCode, verification)

        let interval = (start["interval"] as? Int) ?? 5
        let deadline = Date().addingTimeInterval(TimeInterval((start["expires_in"] as? Int) ?? 900))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(interval))
            let poll = try await Net.json(Net.form(
                URL(string: "https://github.com/login/oauth/access_token")!,
                [
                    "client_id": clientID,
                    "device_code": deviceCode,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                ]
            ))
            if let token = poll["access_token"] as? String {
                let login = try await self.login(for: token)
                await TokenStore.shared.save(CopilotToken(accessToken: token, login: login), key: keyPrefix + login)
                return
            }
            if let error = poll["error"] as? String, error != "authorization_pending" {
                if error == "slow_down" { continue }
                throw ProviderError.malformed(error)
            }
        }
        throw ProviderError.malformed("device code expired")
    }

    private func login(for token: String) async throws -> String {
        let user = try await Net.json(Net.get(URL(string: "https://api.github.com/user")!, token: token))
        return (user["login"] as? String) ?? "github"
    }

    func fetch() async -> [AccountSnapshot] {
        let ids = await accountIDs
        guard !ids.isEmpty else {
            return [AccountSnapshot(providerID: id, glyph: glyph, accountID: "-", accountLabel: displayName,
                                    windows: [], error: ProviderError.notAuthenticated.localizedDescription,
                                    fetchedAt: Date())]
        }
        var out: [AccountSnapshot] = []
        for accountID in ids {
            out.append(await snapshot(accountID: accountID))
        }
        return out
    }

    private func snapshot(accountID: String) async -> AccountSnapshot {
        guard let stored = await TokenStore.shared.load(CopilotToken.self, key: keyPrefix + accountID) else {
            return AccountSnapshot(providerID: id, glyph: glyph, accountID: accountID, accountLabel: accountID,
                                   windows: [], error: ProviderError.notAuthenticated.localizedDescription,
                                   fetchedAt: Date())
        }
        do {
            let body = try await Net.json(Net.get(
                URL(string: "https://api.github.com/copilot_internal/user")!, token: stored.accessToken))
            let reset = (body["quota_reset_date_utc"] as? String).flatMap(Dates.internetDate)
                ?? (body["quota_reset_date"] as? String).flatMap(Dates.day)
            var windows: [UsageWindow] = []
            if let snapshots = body["quota_snapshots"] as? [String: Any],
               let premium = snapshots["premium_interactions"] as? [String: Any],
               let remaining = premium["percent_remaining"] as? Double {
                windows.append(UsageWindow(label: "", percentUsed: 100 - remaining, resetsAt: reset))
            }
            let label = (body["login"] as? String) ?? accountID
            return AccountSnapshot(providerID: id, glyph: glyph, accountID: accountID, accountLabel: label,
                                   windows: windows, error: windows.isEmpty ? "No quota in response" : nil,
                                   fetchedAt: Date())
        } catch {
            return AccountSnapshot(providerID: id, glyph: glyph, accountID: accountID, accountLabel: accountID,
                                   windows: [], error: error.localizedDescription, fetchedAt: Date())
        }
    }
}

enum Dates {
    static func internetDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func day(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.date(from: value)
    }
}
