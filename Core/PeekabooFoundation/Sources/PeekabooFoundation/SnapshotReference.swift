import Foundation

/// Producer-bound opaque reference for one UI snapshot.
///
/// The `ps1_` prefix versions the reference format. The 128-bit random suffix makes references
/// globally unique across independent local and Bridge hosts, so ownership is established by the
/// producer that created the reference instead of by probing collision-prone timestamp names.
public struct SnapshotReference: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public static let prefix = "ps1_"
    public static let randomByteCount = 16
    public static let encodedLength = prefix.count + randomByteCount * 2

    public let rawValue: String

    public var description: String {
        self.rawValue
    }

    public init?(rawValue: String) {
        guard rawValue.count == Self.encodedLength,
              rawValue.hasPrefix(Self.prefix)
        else { return nil }

        let suffix = rawValue.utf8.dropFirst(Self.prefix.utf8.count)
        guard suffix.allSatisfy({ byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) ||
                (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        })
        else { return nil }
        self.rawValue = rawValue
    }

    public init?(_ description: String) {
        self.init(rawValue: description)
    }

    public static func generate() -> Self {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<Self.randomByteCount).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        let suffix = bytes.map { String(format: "%02x", $0) }.joined()
        return Self(rawValue: Self.prefix + suffix)!
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let reference = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Snapshot reference must use ps1_ followed by 32 lowercase hexadecimal digits")
        }
        self = reference
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self.rawValue)
    }
}
