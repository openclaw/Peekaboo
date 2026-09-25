import Foundation

/// The comparison selected from the resolved native element, not inferred from a caller's text.
public enum ElementValueKind: String, Codable, Equatable, Sendable {
    case bool
    case int
    case double
    case string
}

/// A tagged native scalar. Unlike an untagged JSON number, this preserves integer versus floating readback.
public enum ElementValueReadback: Equatable, Sendable, Codable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    public var kind: ElementValueKind {
        switch self {
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        }
    }

    public var displayString: String {
        switch self {
        case let .bool(value): String(value)
        case let .int(value): String(value)
        case let .double(value):
            // The display must remain stable when signed JSON canonicalizes integral numbers and negative zero.
            Int(exactly: value).map(String.init) ?? String(value)
        case let .string(value): value
        }
    }

    var swiftScalarPresentation: String {
        if case let .double(value) = self {
            return String(value)
        }
        return self.displayString
    }

    var isFinite: Bool {
        if case let .double(value) = self {
            return value.isFinite
        }
        return true
    }

    init?(nativeValue: Any?) {
        guard let nativeValue else { return nil }
        if let string = nativeValue as? String {
            self = .string(string)
        } else if let number = nativeValue as? NSNumber {
            let encoding = String(cString: number.objCType)
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if ["f", "d", "D"].contains(encoding) {
                self = .double(number.doubleValue)
            } else {
                guard !["C", "S", "I", "L", "Q"].contains(encoding) || number.uint64Value <= UInt64(Int.max) else {
                    return nil
                }
                self = .int(number.intValue)
            }
        } else {
            return nil
        }
    }

    var number: NSNumber? {
        switch self {
        case let .bool(value): NSNumber(value: value)
        case let .int(value): NSNumber(value: value)
        case let .double(value): NSNumber(value: value)
        case .string: nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(ElementValueKind.self, forKey: .kind) {
        case .bool: self = try .bool(container.decode(Bool.self, forKey: .value))
        case .int: self = try .int(container.decode(Int.self, forKey: .value))
        case .double:
            let value = try container.decode(Double.self, forKey: .value)
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    forKey: .value, in: container, debugDescription: "Native readback must be finite")
            }
            self = .double(value == 0 ? 0 : value)
        case .string: self = try .string(container.decode(String.self, forKey: .value))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self {
        case let .bool(value): try container.encode(value, forKey: .value)
        case let .int(value): try container.encode(value, forKey: .value)
        case let .double(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(value, .init(
                    codingPath: encoder.codingPath, debugDescription: "Native readback must be finite"))
            }
            try container.encode(value == 0 ? 0.0 : value, forKey: .value)
        case let .string(value): try container.encode(value, forKey: .value)
        }
    }
}

/// Host-produced evidence of the native coercion and the exact scalar used to verify a value mutation.
public struct ElementValueVerification: Codable, Equatable, Sendable {
    public enum Attribute: String, Codable, Equatable, Sendable {
        case value
        case selected

        var actionName: String {
            self == .value ? "AXSetValue" : "AXSelected"
        }
    }

    public let attribute: Attribute
    public let resolvedKind: ElementValueKind
    public let readback: ElementValueReadback
    public let legacyPresentation: String

    public init(
        attribute: Attribute,
        resolvedKind: ElementValueKind,
        readback: ElementValueReadback,
        legacyPresentation: String? = nil)
    {
        self.attribute = attribute
        self.resolvedKind = resolvedKind
        self.readback = readback
        self.legacyPresentation = legacyPresentation ?? readback.swiftScalarPresentation
    }

    public var displayString: String {
        self.readback.displayString
    }

    public func matches(requested: UIElementValue, newValue: String?, actionName: String?) -> Bool {
        guard actionName == self.attribute.actionName,
              newValue == self.displayString,
              self.readback.isFinite,
              NativeElementValuePresentation.accepts(self.legacyPresentation, for: self.readback)
        else { return false }
        if self.attribute == .selected {
            guard self.resolvedKind == .bool, case .bool = self.readback else { return false }
        }
        guard let expected = try? ElementValueMutationSemantics.coerce(requested, to: self.resolvedKind) else {
            return false
        }
        return ElementValueMutationSemantics.matches(self.readback, expected: expected)
    }
}

/// Preserve the historical presentation of the raw observation before numeric bridging erases its source shape.
enum NativeElementValuePresentation {
    static func accepts(_ presentation: String, for readback: ElementValueReadback) -> Bool {
        guard readback.isFinite else { return false }
        if presentation == readback.swiftScalarPresentation {
            return true
        }
        switch readback {
        case .bool, .string:
            return false
        case .int, .double:
            if let number = readback.number, presentation == self.describe(number) {
                return true
            }
            guard case let .double(value) = readback else { return false }
            // JSON loses numeric negative zero, while the separately signed historical spelling must survive.
            if value == 0, presentation == "-0.0" || presentation == "0.0" {
                return true
            }
            let float = Float(value)
            return Double(float) == value && presentation == String(float)
        }
    }

    static func describe(_ value: Any?) -> String? {
        switch value {
        case let value as String: value
        case let value as Bool: String(value)
        case let value as Int: String(value)
        case let value as Double: String(value)
        case let value as Float: String(value)
        case let value?: String(describing: value)
        case nil: nil
        }
    }
}

extension UIElementValue {
    var comparisonKind: ElementValueKind {
        switch self {
        case .bool: .bool
        case .int: .int
        case .double: .double
        case .string: .string
        }
    }
}

/// Shared scalar policy for native verification and signed result binding.
enum ElementValueMutationSemantics {
    static func coerce(
        _ value: UIElementValue,
        to kind: ElementValueKind,
        role: String? = nil) throws -> UIElementValue
    {
        switch kind {
        case .string: .string(value.displayString)
        case .bool: try .bool(self.booleanValue(value, role: role))
        case .int: try .int(self.integerValue(value))
        case .double: try .double(self.doubleValue(value))
        }
    }

    static func booleanValue(_ value: UIElementValue, role: String?) throws -> Bool {
        switch value {
        case let .bool(value): return value
        case let .int(value) where value == 0 || value == 1: return value == 1
        case let .double(value) where value == 0 || value == 1: return value == 1
        case let .string(value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on": return true
            case "false", "0", "no", "off": return false
            default: break
            }
        default: break
        }
        let target = role.map { " for \($0)" } ?? ""
        throw ActionInputError.failed("Expected a boolean value\(target)")
    }

    private static func integerValue(_ value: UIElementValue) throws -> Int {
        switch value {
        case let .int(value): return value
        case let .double(value) where value.isFinite:
            if let integer = Int(exactly: value) {
                return integer
            }
        case let .string(value):
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if let integer = Int(value) {
                return integer
            }
            if let integer = self.exactDecimalInteger(value) {
                return integer
            }
        case let .bool(value): return value ? 1 : 0
        default: break
        }
        throw ActionInputError.failed("Expected an integer value")
    }

    private static func exactDecimalInteger(_ value: String) -> Int? {
        let exponentParts = value.split(maxSplits: 2, omittingEmptySubsequences: false) { $0 == "e" || $0 == "E" }
        guard exponentParts.count <= 2, var mantissa = exponentParts.first else { return nil }
        let negative = mantissa.first == "-"
        if negative || mantissa.first == "+" {
            mantissa.removeFirst()
        }
        let exponent = exponentParts.count == 2 ? exponentParts[1] : Substring("0")
        var exponentDigits = exponent
        if exponentDigits.first == "-" || exponentDigits.first == "+" {
            exponentDigits.removeFirst()
        }
        guard self.isASCIIDigits(exponentDigits) else { return nil }
        let parts = mantissa.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let rawDigits = parts.joined()
        guard self.isASCIIDigits(rawDigits) else { return nil }
        var digits = rawDigits.drop(while: { $0 == "0" })
        if digits.isEmpty {
            return 0
        }
        guard let parsedExponent = Int(exponent) else { return nil }
        let fractionalCount = parts.count == 2 ? parts[1].count : 0
        let adjusted = parsedExponent.subtractingReportingOverflow(fractionalCount)
        guard !adjusted.overflow else { return nil }
        let scale = adjusted.partialValue
        let maximumDigits = String(Int.max).count
        var zeroSuffix = ""
        if scale < 0 {
            guard scale >= -digits.count else { return nil }
            let removedCount = -scale
            guard digits.suffix(removedCount).allSatisfy({ $0 == "0" }) else { return nil }
            digits = digits.dropLast(removedCount)
        } else {
            guard digits.count <= maximumDigits, scale <= maximumDigits - digits.count else { return nil }
            zeroSuffix = String(repeating: "0", count: scale)
        }
        guard digits.count <= maximumDigits else { return nil }
        return Int((negative ? "-" : "") + String(digits) + zeroSuffix)
    }

    private static func isASCIIDigits(_ value: some StringProtocol) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    private static func doubleValue(_ value: UIElementValue) throws -> Double {
        let result: Double? = switch value {
        case let .double(value): value
        case let .int(value): Double(value)
        case let .string(value): Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        case let .bool(value): value ? 1 : 0
        }
        guard let result, result.isFinite else { throw ActionInputError.failed("Expected a finite numeric value") }
        return result
    }

    static func matches(_ actual: ElementValueReadback?, expected: UIElementValue) -> Bool {
        guard let actual else { return false }
        switch expected {
        case let .bool(expected):
            if case let .bool(value) = actual {
                return value == expected
            }
            return actual.number?.doubleValue == (expected ? 1.0 : 0.0)
        case let .int(expected):
            guard actual.kind != .double, let number = actual.number else { return false }
            return number.intValue == expected
        case let .double(expected):
            guard let number = actual.number else { return false }
            let value = number.doubleValue
            let tolerance = max(1e-9, abs(expected) * 1e-9)
            return value.isFinite && abs(value - expected) <= tolerance
        case let .string(expected):
            guard case let .string(value) = actual else { return false }
            return value == expected
        }
    }
}
