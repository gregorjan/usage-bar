import Foundation

actor TokenStore {
    static let shared = TokenStore()

    private let vaultAccount = "vault"
    private var cache: [String: Data]?

    private func vault() -> [String: Data] {
        if let cache { return cache }
        let loaded = Keychain.loadJSON([String: Data].self, account: vaultAccount) ?? migrate()
        cache = loaded
        return loaded
    }

    private func migrate() -> [String: Data] {
        var merged: [String: Data] = [:]
        for legacy in Keychain.accounts(prefix: "") where legacy != vaultAccount {
            if let data = Keychain.load(account: legacy) { merged[legacy] = data }
        }
        if !merged.isEmpty {
            Keychain.saveJSON(merged, account: vaultAccount)
            merged.keys.forEach { Keychain.delete(account: $0) }
            Log.write("migrated \(merged.count) keychain items into vault")
        }
        return merged
    }

    func keys(prefix: String) -> [String] {
        vault().keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = vault()[key] else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func save(_ value: some Encodable, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        var current = vault()
        current[key] = data
        cache = current
        Keychain.saveJSON(current, account: vaultAccount)
    }

    func delete(key: String) {
        var current = vault()
        current[key] = nil
        cache = current
        Keychain.saveJSON(current, account: vaultAccount)
    }
}
