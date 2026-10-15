/// Shares one in-flight operation per account, including failures.
/// Actors alone do not prevent duplicate work across suspension points.
actor SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var pending: [Key: Task<Value, Error>] = [:]

    func run(key: Key, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let task = pending[key] { return try await task.value }
        let task = Task { try await operation() }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }
}
