import Foundation

/// Canonical validation for immutable source-revision receipts embedded at build time.
public enum SourceProvenance {
    public static let unknownCommit = "unknown"

    /// Returns a canonical full Git object name only when the stamp is exactly 40 lowercase hex characters.
    public static func exactCommit(_ value: String?) -> String? {
        guard let value else { return nil }
        let bytes = value.utf8
        guard bytes.count == 40,
              bytes.allSatisfy({ byte in
                  (48...57).contains(byte) || (97...102).contains(byte)
              })
        else { return nil }
        return value
    }

    public static func normalizedCommit(_ value: String?) -> String {
        self.exactCommit(value) ?? self.unknownCommit
    }
}
