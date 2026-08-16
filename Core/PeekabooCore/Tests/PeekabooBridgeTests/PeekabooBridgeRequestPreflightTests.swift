import Foundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeRequestPreflightTests {
    @Test
    func `flat objects use one mutable key storage and linear insertion work`() throws {
        let keyCount = 12000
        let metrics = try PeekabooBridgeRequestPreflight.collectValidationMetrics(
            Self.flatObject(keyCount: keyCount))

        #expect(metrics.objectStorageCount == 1)
        #expect(metrics.objectKeyCount == keyCount)
        #expect(metrics.keyInsertionAttemptCount == keyCount)
        #expect(metrics.maximumKeysInObject == keyCount)
    }

    @Test
    func `keyless objects do not allocate duplicate detection storage`() throws {
        let emptyObjectCount = 12000
        let data = Data(("[" + Array(repeating: "{}", count: emptyObjectCount).joined(separator: ",") + "]").utf8)
        let metrics = try PeekabooBridgeRequestPreflight.collectValidationMetrics(data)

        #expect(metrics.objectStorageCount == 0)
        #expect(metrics.objectKeyCount == 0)
        #expect(metrics.keyInsertionAttemptCount == 0)
        #expect(metrics.maximumKeysInObject == 0)
    }

    @Test
    func `total object key count is bounded across nested objects`() throws {
        let maximumKeyCount = PeekabooBridgeRequestPreflight.maximumJSONTotalObjectKeyCount
        let keysPerNestedObject = (maximumKeyCount - 2) / 2
        let left = Self.flatObjectJSON(keyCount: keysPerNestedObject)
        let right = Self.flatObjectJSON(keyCount: keysPerNestedObject)
        let atLimit = Data((#"{"left":"# + left + #", "right":"# + right + "}").utf8)
        try PeekabooBridgeRequestPreflight.validate(atLimit)

        let overLimitRight = Self.flatObjectJSON(keyCount: keysPerNestedObject + 1)
        let data = Data((#"{"left":"# + left + #", "right":"# + overLimitRight + "}").utf8)
        Self.expectInvalid(
            data,
            message: "Bridge request JSON exceeds the maximum object-key count")
    }

    @Test
    func `escaped and nested object keys retain duplicate semantics`() throws {
        Self.expectInvalid(
            Data(#"{"alpha":0,"\u0061lpha":1}"#.utf8),
            message: "Bridge request JSON contains a duplicate object key")
        Self.expectInvalid(
            Data(#"{"outer":{"key":0,"k\u0065y":1}}"#.utf8),
            message: "Bridge request JSON contains a duplicate object key")

        let isolatedKeys = Data(#"{"same":0,"left":{"same":1},"right":{"same":2}}"#.utf8)
        let metrics = try PeekabooBridgeRequestPreflight.collectValidationMetrics(isolatedKeys)
        #expect(metrics.objectStorageCount == 3)
        #expect(metrics.objectKeyCount == 5)
        #expect(metrics.keyInsertionAttemptCount == 5)
        #expect(metrics.maximumKeysInObject == 3)
    }

    @Test
    func `projection depth checks still compare decoded keys`() throws {
        let nestedProjection = Data(
            #"{"projectedAction":{"_0":{"request":{"projected\u0041ction":{"_0":{"request":BROKEN}}}}}}"#
                .utf8)
        Self.expectInvalid(
            nestedProjection,
            message: "Projected Bridge action requests cannot be nested")

        let ordinaryPayloadJSON =
            #"{"projectedAction":{"_0":{"request":{"browserExecute":{"_0":{"arguments":"# +
            #"{"projected\u0041ction":"ordinary"}}}}}}}"#
        let ordinaryPayloadKey = Data(ordinaryPayloadJSON.utf8)
        #expect(throws: Never.self) {
            try PeekabooBridgeRequestPreflight.validate(ordinaryPayloadKey)
        }
    }

    @Test
    func `malformed JSON remains rejected by the single request decode`() throws {
        let malformedInputs = [
            Data(#"{"permissionsStatus":"#.utf8),
            Data(#"{"bad\uZZZZ":1}"#.utf8),
        ]

        for data in malformedInputs {
            #expect(throws: (any Error).self) {
                try PeekabooBridgeRequestPreflight.validate(data)
                _ = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
            }
        }
    }

    @Test
    func `non UTF-8 JSON encodings are rejected before Foundation decoding`() throws {
        let utf8 = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let json = try #require(String(data: utf8, encoding: .utf8))
        let utf16LittleEndian = try #require(json.data(using: .utf16LittleEndian))
        let utf16BigEndian = try #require(json.data(using: .utf16BigEndian))
        let utf32LittleEndian = try #require(json.data(using: .utf32LittleEndian))
        let utf32BigEndian = try #require(json.data(using: .utf32BigEndian))
        let carriages = [
            utf16LittleEndian,
            utf16BigEndian,
            utf32LittleEndian,
            utf32BigEndian,
        ]

        for carriage in carriages {
            _ = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: carriage)
            Self.expectInvalidUTF8Carriage(carriage)
        }
    }

    @Test
    func `byte order marks and malformed UTF-8 are rejected`() throws {
        let utf8 = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let json = try #require(String(data: utf8, encoding: .utf8))
        let utf16LittleEndian = try #require(json.data(using: .utf16LittleEndian))
        let utf16BigEndian = try #require(json.data(using: .utf16BigEndian))
        let utf32LittleEndian = try #require(json.data(using: .utf32LittleEndian))
        let utf32BigEndian = try #require(json.data(using: .utf32BigEndian))
        var carriages: [Data] = []
        carriages.append(Data([0xEF, 0xBB, 0xBF]) + utf8)
        carriages.append(Data([0xFF, 0xFE]) + utf16LittleEndian)
        carriages.append(Data([0xFE, 0xFF]) + utf16BigEndian)
        carriages.append(Data([0xFF, 0xFE, 0x00, 0x00]) + utf32LittleEndian)
        carriages.append(Data([0x00, 0x00, 0xFE, 0xFF]) + utf32BigEndian)
        carriages.append(Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D]))

        for carriage in carriages {
            Self.expectInvalidUTF8Carriage(carriage)
        }
    }

    @Test
    func `alternate encodings cannot bypass duplicate projection or key budget checks`() throws {
        let duplicate = try #require(#"{"same":1,"same":2}"#.data(using: .utf16LittleEndian))
        let nestedProjection = try #require(
            #"{"projectedAction":{"_0":{"request":{"projectedAction":{"_0":{"request":{}}}}}}}"#
                .data(using: .utf16BigEndian))
        let overBudget = try #require(
            Self.flatObjectJSON(keyCount: PeekabooBridgeRequestPreflight.maximumJSONTotalObjectKeyCount + 1)
                .data(using: .utf32LittleEndian))

        for carriage in [duplicate, nestedProjection, overBudget] {
            Self.expectInvalidUTF8Carriage(carriage)
        }
    }

    @Test
    func `valid Unicode UTF-8 request remains accepted`() throws {
        let request = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "検索",
            arguments: ["query": .string("Grüße 👋")]))
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(request)

        try PeekabooBridgeRequestPreflight.validate(data)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
        #expect(decoded.operation == .browserExecute)
    }

    private static func flatObject(keyCount: Int) -> Data {
        Data(self.flatObjectJSON(keyCount: keyCount).utf8)
    }

    private static func flatObjectJSON(keyCount: Int) -> String {
        let fields = (0..<keyCount).map { index in
            #""key\#(index)":\#(index)"#
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    private static func expectInvalid(_ data: Data, message: String) {
        do {
            try PeekabooBridgeRequestPreflight.validate(data)
            Issue.record("Expected request preflight to reject invalid JSON carriage")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .invalidRequest)
            #expect(error.message == message)
        } catch {
            Issue.record("Expected an invalid-request envelope, got \(error)")
        }
    }

    private static func expectInvalidUTF8Carriage(_ data: Data) {
        self.expectInvalid(
            data,
            message: "Bridge request JSON must use UTF-8 without a byte-order mark")
    }
}
