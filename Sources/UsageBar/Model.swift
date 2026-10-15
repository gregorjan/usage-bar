import Foundation

struct UsageWindow: Codable, Sendable, Equatable {
    let label: String
    let percentUsed: Double?
    let resetsAt: Date?
}

struct AccountSnapshot: Codable, Sendable, Equatable {
    let providerID: String
    let glyph: String
    let accountID: String
    let accountLabel: String
    let windows: [UsageWindow]
    let error: String?
    let fetchedAt: Date

    var itemKey: String { "\(providerID):\(accountID)" }
}

enum ProviderError: LocalizedError {
    case notAuthenticated
    case sessionExpired
    case http(Int, String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: "Not signed in"
        case .sessionExpired: "Claude rejected the saved refresh token. Session authorization has expired."
        case let .http(code, body): "HTTP \(code)\(body.isEmpty ? "" : ": \(body)")"
        case let .malformed(what): "Unexpected response: \(what)"
        }
    }
}

protocol UsageProvider: Actor {
    nonisolated var id: String { get }
    nonisolated var displayName: String { get }
    nonisolated var glyph: String { get }
    func fetch() async -> [AccountSnapshot]
    func signIn(showing: @Sendable @escaping (String, URL) -> Void) async throws
    func signOut(accountID: String) async
    var accountIDs: [String] { get async }
}
