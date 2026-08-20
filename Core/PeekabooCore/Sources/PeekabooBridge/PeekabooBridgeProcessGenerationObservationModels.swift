import Foundation

public struct PeekabooBridgeProcessGenerationIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64

    public init(processIdentifier: Int32, processStartIdentity: UInt64) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processIdentifier
        case processStartIdentity
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        guard let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Process start identity must be a canonical positive decimal string")
        }
        self.processStartIdentity = processStartIdentity
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
    }

    func validate() throws {
        guard self.processIdentifier > 0, self.processStartIdentity > 0 else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Process-generation observation requires a positive PID and start identity")
        }
    }
}

public struct PeekabooBridgeProcessGenerationObservationRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let expected: PeekabooBridgeProcessGenerationIdentity

    public init(
        schemaVersion: Int = 1,
        expected: PeekabooBridgeProcessGenerationIdentity)
    {
        self.schemaVersion = schemaVersion
        self.expected = expected
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case expected
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.expected = try container.decode(PeekabooBridgeProcessGenerationIdentity.self, forKey: .expected)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.expected, forKey: .expected)
    }

    func validate() throws {
        guard self.schemaVersion == 1 else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unsupported process-generation observation schema")
        }
        try self.expected.validate()
    }
}

public enum PeekabooBridgeProcessGenerationDisposition: String, Codable, Equatable, Sendable {
    case sameGenerationAlive
    case exactGenerationAbsent
    case pidReused
}

public struct PeekabooBridgeProcessGenerationObservationResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let expected: PeekabooBridgeProcessGenerationIdentity
    public let disposition: PeekabooBridgeProcessGenerationDisposition
    public let observed: PeekabooBridgeProcessGenerationIdentity?
    public let observationStartedAtUnixMilliseconds: Int64
    public let observationCompletedAtUnixMilliseconds: Int64

    public init(
        schemaVersion: Int = 1,
        expected: PeekabooBridgeProcessGenerationIdentity,
        disposition: PeekabooBridgeProcessGenerationDisposition,
        observed: PeekabooBridgeProcessGenerationIdentity?,
        observationStartedAtUnixMilliseconds: Int64,
        observationCompletedAtUnixMilliseconds: Int64)
    {
        self.schemaVersion = schemaVersion
        self.expected = expected
        self.disposition = disposition
        self.observed = observed
        self.observationStartedAtUnixMilliseconds = observationStartedAtUnixMilliseconds
        self.observationCompletedAtUnixMilliseconds = observationCompletedAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case expected
        case disposition
        case observed
        case observationStartedAtUnixMilliseconds
        case observationCompletedAtUnixMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(CodingKeys.self, from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.expected = try container.decode(PeekabooBridgeProcessGenerationIdentity.self, forKey: .expected)
        self.disposition = try container.decode(
            PeekabooBridgeProcessGenerationDisposition.self,
            forKey: .disposition)
        self.observed = try container.decodeIfPresent(
            PeekabooBridgeProcessGenerationIdentity.self,
            forKey: .observed)
        self.observationStartedAtUnixMilliseconds = try container.decode(
            Int64.self,
            forKey: .observationStartedAtUnixMilliseconds)
        self.observationCompletedAtUnixMilliseconds = try container.decode(
            Int64.self,
            forKey: .observationCompletedAtUnixMilliseconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.expected, forKey: .expected)
        try container.encode(self.disposition, forKey: .disposition)
        try container.encode(self.observed, forKey: .observed)
        try container.encode(
            self.observationStartedAtUnixMilliseconds,
            forKey: .observationStartedAtUnixMilliseconds)
        try container.encode(
            self.observationCompletedAtUnixMilliseconds,
            forKey: .observationCompletedAtUnixMilliseconds)
    }

    func validate(request: PeekabooBridgeProcessGenerationObservationRequest) throws {
        do {
            try request.validate()
            try self.observed?.validate()
        } catch {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "process-generation observation identity")
        }
        guard self.schemaVersion == 1,
              self.expected == request.expected,
              self.observationStartedAtUnixMilliseconds > 0,
              self.observationCompletedAtUnixMilliseconds >= self.observationStartedAtUnixMilliseconds
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "process-generation observation request and timing")
        }

        switch self.disposition {
        case .sameGenerationAlive:
            guard self.observed == self.expected else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "same-generation observation identity")
            }
        case .exactGenerationAbsent:
            guard self.observed == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "absent process-generation observation identity")
            }
        case .pidReused:
            guard let observed = self.observed,
                  observed.processIdentifier == self.expected.processIdentifier,
                  observed.processStartIdentity > 0,
                  observed.processStartIdentity != self.expected.processStartIdentity
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "reused process-generation observation identity")
            }
        }
    }
}

enum PeekabooBridgeClosedPayload {
    private struct AnyKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            self.intValue = nil
        }

        init?(intValue: Int) {
            self.stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    static func requireExactKeys<Keys: CodingKey & CaseIterable>(
        _ keys: Keys.Type,
        from decoder: any Decoder,
        description: String = "Bridge payload") throws
    where Keys.AllCases: Collection {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        let expected = Set(keys.allCases.map(\.stringValue))
        guard actual == expected else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(description) keys are not closed"))
        }
    }

    static func requireExactKeys(
        _ expected: Set<String>,
        from decoder: any Decoder,
        description: String) throws
    {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == expected else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "\(description) keys are not closed"))
        }
    }
}
