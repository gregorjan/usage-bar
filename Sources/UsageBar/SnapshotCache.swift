import Foundation

/// Stores usage only, never credentials. A failed fetch must not erase a good reading.
struct SnapshotCache {
    private let defaults: UserDefaults
    private let key = "lastSuccessfulUsage"
    private var saved: [String: AccountSnapshot]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        saved = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: AccountSnapshot].self, from: $0) } ?? [:]
    }

    func restored(providerID: String) -> [AccountSnapshot] {
        saved.values.filter { $0.providerID == providerID }
            .sorted { $0.accountID < $1.accountID }
            .map { Self.stale($0, error: "Refreshing saved usage…") }
    }

    mutating func apply(_ fresh: [AccountSnapshot], providerID: String) -> [AccountSnapshot] {
        let live = Set(fresh.map(\.itemKey))
        saved = saved.filter { $0.value.providerID != providerID || live.contains($0.key) }
        let result = fresh.map { snapshot in
            if snapshot.error == nil, !snapshot.windows.isEmpty {
                saved[snapshot.itemKey] = snapshot
                return snapshot
            }
            guard let previous = saved[snapshot.itemKey] else { return snapshot }
            return Self.stale(previous, error: snapshot.error ?? "No usage in response")
        }
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
        return result
    }

    private static func stale(_ previous: AccountSnapshot, error: String) -> AccountSnapshot {
        AccountSnapshot(providerID: previous.providerID, glyph: previous.glyph,
                        accountID: previous.accountID, accountLabel: previous.accountLabel,
                        windows: previous.windows, error: error, fetchedAt: previous.fetchedAt)
    }
}
