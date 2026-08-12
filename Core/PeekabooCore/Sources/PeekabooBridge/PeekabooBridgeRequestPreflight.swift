import Foundation

enum PeekabooBridgeRequestPreflight {
    static let maximumJSONNestingDepth = 128
    private static let projectedActionKeyBytes = Array("projectedAction".utf8)

    /// Rejects recursive projection carriage before `JSONDecoder` constructs its payload.
    ///
    /// The projected enum case has one stable synthesized-Codable path: the outer case key is at
    /// depth one and the nested legacy request case key is at depth four. Arbitrary operation
    /// payload keys live below that boundary, so they remain untouched.
    static func validate(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var index = 0
            var depth = 0
            var outerProjectionSeen = false

            while index < bytes.count {
                switch bytes[index] {
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                    guard depth <= Self.maximumJSONNestingDepth else {
                        throw PeekabooBridgeErrorEnvelope(
                            code: .invalidRequest,
                            message: "Bridge request JSON exceeds the maximum nesting depth")
                    }
                    index += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth = max(0, depth - 1)
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

                    guard Self.isProjectedActionKey(
                        bytes,
                        stringStart: stringStart,
                        stringEnd: stringEnd)
                    else { continue }

                    if depth == 1 {
                        outerProjectionSeen = true
                    } else if outerProjectionSeen, depth == 4 {
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
        let keyData = Data(bytes[stringStart...stringEnd])
        return (try? JSONDecoder().decode(String.self, from: keyData)) == "projectedAction"
    }
}
