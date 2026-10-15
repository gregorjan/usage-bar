import Foundation

actor TokenStore {
    static let shared = TokenStore()

    private let vaultAccount = "vault"
    private let loadVault: @Sendable () -> [String: Data]?
    private let writeVault: @Sendable ([String: Data]) throws -> Void
    private var cache: [String: Data]?
    private var pendingWrite = false

    init(loadVault: @escaping @Sendable () -> [String: Data]? = {
        Keychain.loadJSON([String: Data].self, account: "vault")
    }, writeVault: @escaping @Sendable ([String: Data]) throws -> Void = {
        try Keychain.saveJSON($0, account: "vault")
    }) {
        self.loadVault = loadVault
        self.writeVault = writeVault
    }

    private func vault() -> [String: Data] {
        if let cache {
            if pendingWrite {
                do {
                    try writeVault(cache)
                    pendingWrite = false
                } catch {
                    Log.write("credential save retry failed: \(error.localizedDescription)")
                }
            }
            return cache
        }
        let loaded = loadVault() ?? migrate()
        cache = loaded
        return loaded
    }

    private func migrate() -> [String: Data] {
        var merged: [String: Data] = [:]
        for legacy in Keychain.accounts(prefix: "") where legacy != vaultAccount {
            if let data = Keychain.load(account: legacy) { merged[legacy] = data }
        }
        if !merged.isEmpty {
            do {
                try writeVault(merged)
                merged.keys.forEach { Keychain.delete(account: $0) }
                Log.write("migrated \(merged.count) keychain items into vault")
            } catch {
                Log.write("vault migration failed: \(error.localizedDescription)")
            }
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

    func save(_ value: some Encodable, key: String) throws {
        let data = try JSONEncoder().encode(value)
        var current = vault()
        current[key] = data
        // A rotated refresh token must survive in memory even if Keychain is locked.
        cache = current
        pendingWrite = true
        try writeVault(current)
        pendingWrite = false
    }

    func delete(key: String) {
        var current = vault()
        current[key] = nil
        do {
            try writeVault(current)
            cache = current
            pendingWrite = false
        } catch {
            Log.write("credential deletion failed: \(error.localizedDescription)")
        }
    }
}
