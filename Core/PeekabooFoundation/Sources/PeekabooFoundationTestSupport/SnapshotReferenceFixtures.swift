import Foundation
import PeekabooFoundation

public enum SnapshotReferenceFixtures {
    public static let first = Self.reference(1)
    public static let second = Self.reference(2)
    public static let third = Self.reference(3)

    public static func reference(_ value: UInt64) -> SnapshotReference {
        let suffix = String(format: "%016llx%016llx", 0, value)
        return SnapshotReference(rawValue: SnapshotReference.prefix + suffix)!
    }

    public static func id(_ value: UInt64 = 1) -> String {
        self.reference(value).rawValue
    }
}
