import Foundation

enum PeekabooBridgeRequestPreflight {
    struct ValidationMetrics: Equatable {
        fileprivate(set) var objectStorageCount = 0
        fileprivate(set) var objectKeyCount = 0
        fileprivate(set) var keyInsertionAttemptCount = 0
        fileprivate(set) var maximumKeysInObject = 0
    }

    private final class JSONObjectKeyStorage {
        var keys: Set<String> = []
    }

    private enum JSONContainer {
        case object(JSONObjectKeyStorage?)
        case array
    }

    static let maximumJSONNestingDepth = 128
    // Bound duplicate-detection memory independently of the transport's message-size limit.
    static let maximumJSONTotalObjectKeyCount = 65536
    private static let projectedActionKeyBytes = Array("projectedAction".utf8)

    /// Rejects recursive projection carriage before `JSONDecoder` constructs its payload.
    ///
    /// The projected enum case has one stable synthesized-Codable path: the outer case key is at
    /// depth one and the nested legacy request case key is at depth four. Arbitrary operation
    /// payload keys live below that boundary, so they remain untouched.
    static func validate(_ data: Data) throws {
        var metrics: ValidationMetrics?
        try self.validate(data, metrics: &metrics)
    }

    static func collectValidationMetrics(_ data: Data) throws -> ValidationMetrics {
        var metrics: ValidationMetrics? = .init()
        try self.validate(data, metrics: &metrics)
        return metrics ?? .init()
    }

    private static func validate(_ data: Data, metrics: inout ValidationMetrics?) throws {
        try self.validateUTF8Carriage(data)
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            var containers: [JSONContainer] = []
            var outerProjectionSeen = false
            var objectKeyCount = 0

            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "{"):
                    containers.append(.object(nil))
                    guard containers.count <= Self.maximumJSONNestingDepth else {
                        throw PeekabooBridgeErrorEnvelope(
                            code: .invalidRequest,
                            message: "Bridge request JSON exceeds the maximum nesting depth")
                    }
                    index += 1
                case UInt8(ascii: "["):
                    containers.append(.array)
                    guard containers.count <= Self.maximumJSONNestingDepth else {
                        throw PeekabooBridgeErrorEnvelope(
                            code: .invalidRequest,
                            message: "Bridge request JSON exceeds the maximum nesting depth")
                    }
                    index += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    if !containers.isEmpty {
                        containers.removeLast()
                    }
                    index += 1
                case UInt8(ascii: "\""):
                    let stringStart = index
                    index += 1
                    var escaped = false
                    while index < bytes.count {
                        let byte = bytes[index]
                        if escaped {
                            escaped = false
                        } else if byte == UInt8(ascii: "\\") {
                            escaped = true
                        } else if byte == UInt8(ascii: "\"") {
                            break
                        }
                        index += 1
                    }
                    guard index < bytes.count else { return }
                    let stringEnd = index
                    index += 1
                    var lookahead = index
                    while lookahead < bytes.count, Self.isJSONWhitespace(bytes[lookahead]) {
                        lookahead += 1
                    }
                    guard lookahead < bytes.count,
                          bytes[lookahead] == UInt8(ascii: ":")
                    else { continue }

                    if let containerIndex = containers.indices.last,
                       let keyStorage = Self.objectKeyStorage(
                           for: &containers[containerIndex],
                           metrics: &metrics)
                    {
                        try Self.recordObjectKey(
                            bytes,
                            stringRange: stringStart...stringEnd,
                            keyStorage: keyStorage,
                            objectKeyCount: &objectKeyCount,
                            metrics: &metrics)
                    }

                    guard Self.isProjectedActionKey(
                        bytes,
                        stringStart: stringStart,
                        stringEnd: stringEnd)
                    else { continue }

                    if containers.count == 1 {
                        outerProjectionSeen = true
                    } else if outerProjectionSeen, containers.count == 4 {
                        throw PeekabooBridgeErrorEnvelope(
                            code: .invalidRequest,
                            message: "Projected Bridge action requests cannot be nested")
                    }
                default:
                    index += 1
                }
            }
        }
    }

    private static func validateUTF8Carriage(_ data: Data) throws {
        let hasUTF8ByteOrderMark = data.starts(with: [0xEF, 0xBB, 0xBF])
        guard !hasUTF8ByteOrderMark,
              !data.contains(0),
              String(data: data, encoding: .utf8) != nil
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Bridge request JSON must use UTF-8 without a byte-order mark")
        }
    }

    private static func objectKeyStorage(
        for container: inout JSONContainer,
        metrics: inout ValidationMetrics?) -> JSONObjectKeyStorage?
    {
        guard case let .object(existingKeyStorage) = container else { return nil }
        if let existingKeyStorage {
            return existingKeyStorage
        }

        let keyStorage = JSONObjectKeyStorage()
        container = .object(keyStorage)
        metrics?.objectStorageCount += 1
        return keyStorage
    }

    private static func recordObjectKey(
        _ bytes: UnsafeBufferPointer<UInt8>,
        stringRange: ClosedRange<Int>,
        keyStorage: JSONObjectKeyStorage,
        objectKeyCount: inout Int,
        metrics: inout ValidationMetrics?) throws
    {
        objectKeyCount += 1
        metrics?.objectKeyCount = objectKeyCount
        guard objectKeyCount <= self.maximumJSONTotalObjectKeyCount else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Bridge request JSON exceeds the maximum object-key count")
        }

        guard let key = decodedJSONString(
            bytes,
            stringStart: stringRange.lowerBound,
            stringEnd: stringRange.upperBound)
        else { return }

        metrics?.keyInsertionAttemptCount += 1
        guard keyStorage.keys.insert(key).inserted else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Bridge request JSON contains a duplicate object key")
        }
        if let maximumKeysInObject = metrics?.maximumKeysInObject {
            metrics?.maximumKeysInObject = max(maximumKeysInObject, keyStorage.keys.count)
        }
    }

    private static func decodedJSONString(
        _ bytes: UnsafeBufferPointer<UInt8>,
        stringStart: Int,
        stringEnd: Int) -> String?
    {
        let contentStart = stringStart + 1
        let content = bytes[contentStart..<stringEnd]
        guard content.contains(UInt8(ascii: "\\")) else {
            return String(bytes: content, encoding: .utf8)
        }
        return try? JSONDecoder().decode(String.self, from: Data(bytes[stringStart...stringEnd]))
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") ||
            byte == UInt8(ascii: "\t") ||
            byte == UInt8(ascii: "\n") ||
            byte == UInt8(ascii: "\r")
    }

    private static func isProjectedActionKey(
        _ bytes: UnsafeBufferPointer<UInt8>,
        stringStart: Int,
        stringEnd: Int) -> Bool
    {
        let contentStart = stringStart + 1
        let contentCount = stringEnd - contentStart
        if contentCount == Self.projectedActionKeyBytes.count {
            var matchesPlainKey = true
            for offset in Self.projectedActionKeyBytes.indices
                where bytes[contentStart + offset] != Self.projectedActionKeyBytes[offset]
            {
                matchesPlainKey = false
                break
            }
            if matchesPlainKey {
                return true
            }
        }

        guard contentCount <= Self.projectedActionKeyBytes.count * 6,
              bytes[contentStart..<stringEnd].contains(UInt8(ascii: "\\"))
        else { return false }
        return self.decodedJSONString(
            bytes,
            stringStart: stringStart,
            stringEnd: stringEnd) == "projectedAction"
    }
}
