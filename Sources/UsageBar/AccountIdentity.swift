import Foundation

enum AccountIdentity {
    /// Reconnection must update the existing key, never create or replace a different account.
    static func storageID(authenticated: String, replacing existing: String?) throws -> String {
        guard let existing else { return authenticated }
        guard authenticated.caseInsensitiveCompare(existing) == .orderedSame else {
            throw ProviderError.accountMismatch(expected: existing, actual: authenticated)
        }
        return existing
    }
}
