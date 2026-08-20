import Foundation

public enum PeekabooBridgeCertificationProducerAttestationKind: String, Codable, CaseIterable, Sendable {
    case crashInventoryPair = "crash_inventory_pair"
    case monitorSeal = "monitor_seal"
    case observerSemantic = "observer_semantic"

    var expectedSigningIdentifier: String {
        switch self {
        case .crashInventoryPair, .observerSemantic:
            "boo.peekaboo.peekaboo-certification-controller"
        case .monitorSeal:
            "boo.peekaboo.background-computer-use-probe"
        }
    }
}

public struct PeekabooBridgeCertificationProducerExpectation: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64
    public let codeSignatureHash: String

    public init(
        processIdentifier: Int32,
        processStartIdentity: UInt64,
        codeSignatureHash: String)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processIdentifier
        case processStartIdentity
        case codeSignatureHash
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification producer expectation")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        guard let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Certification producer start identity is not canonical")
        }
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
        try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
    }

    func validate() throws {
        guard self.processIdentifier > 0,
              self.processStartIdentity > 0,
              PeekabooBridgeCertificationValidation.isLowerHex(self.codeSignatureHash, count: 40)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Certification producer identity is invalid")
        }
    }
}

public struct PeekabooBridgeCertificationProducerAttestationRequest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: PeekabooBridgeCertificationProducerAttestationKind
    public let executionNonce: String
    public let monitorInstanceID: UUID
    public let producerSocketPath: String
    public let expectedProducer: PeekabooBridgeCertificationProducerExpectation
    public let timeoutMilliseconds: Int
    public let maximumResponseBytes: Int

    public init(
        schemaVersion: Int = 1,
        kind: PeekabooBridgeCertificationProducerAttestationKind,
        executionNonce: String,
        monitorInstanceID: UUID,
        producerSocketPath: String,
        expectedProducer: PeekabooBridgeCertificationProducerExpectation,
        timeoutMilliseconds: Int,
        maximumResponseBytes: Int)
    {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.producerSocketPath = producerSocketPath
        self.expectedProducer = expectedProducer
        self.timeoutMilliseconds = timeoutMilliseconds
        self.maximumResponseBytes = maximumResponseBytes
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case executionNonce
        case monitorInstanceID
        case producerSocketPath
        case expectedProducer
        case timeoutMilliseconds
        case maximumResponseBytes
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification producer attestation request")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.kind = try container.decode(
            PeekabooBridgeCertificationProducerAttestationKind.self,
            forKey: .kind)
        self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
        self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
        self.producerSocketPath = try container.decode(String.self, forKey: .producerSocketPath)
        self.expectedProducer = try container.decode(
            PeekabooBridgeCertificationProducerExpectation.self,
            forKey: .expectedProducer)
        self.timeoutMilliseconds = try container.decode(Int.self, forKey: .timeoutMilliseconds)
        self.maximumResponseBytes = try container.decode(Int.self, forKey: .maximumResponseBytes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.executionNonce, forKey: .executionNonce)
        try container.encode(self.monitorInstanceID, forKey: .monitorInstanceID)
        try container.encode(self.producerSocketPath, forKey: .producerSocketPath)
        try container.encode(self.expectedProducer, forKey: .expectedProducer)
        try container.encode(self.timeoutMilliseconds, forKey: .timeoutMilliseconds)
        try container.encode(self.maximumResponseBytes, forKey: .maximumResponseBytes)
    }

    func validate() throws {
        guard self.schemaVersion == 1,
              PeekabooBridgeCertificationValidation.isLowerHex(self.executionNonce, count: 64),
              PeekabooBridgeCertificationValidation.isVersion4(self.monitorInstanceID),
              PeekabooBridgeCertificationValidation.isAbsolutePath(self.producerSocketPath),
              self.producerSocketPath.utf8.count < 104,
              (100...30000).contains(self.timeoutMilliseconds),
              (1024...1024 * 1024).contains(self.maximumResponseBytes)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Certification producer request is outside its closed transport bounds")
        }
        try self.expectedProducer.validate()
    }
}

public struct PeekabooBridgeCertificationProducerChallenge: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: PeekabooBridgeCertificationProducerAttestationKind
    public let executionNonce: String
    public let monitorInstanceID: UUID
    public let challenge: String
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String

    public init(
        schemaVersion: Int = 1,
        kind: PeekabooBridgeCertificationProducerAttestationKind,
        executionNonce: String,
        monitorInstanceID: UUID,
        challenge: String,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String)
    {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.challenge = challenge
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case executionNonce
        case monitorInstanceID
        case challenge
        case listenerInstanceID
        case listenerPublicKeySHA256
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification producer challenge")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.kind = try container.decode(
            PeekabooBridgeCertificationProducerAttestationKind.self,
            forKey: .kind)
        self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
        self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
        self.challenge = try container.decode(String.self, forKey: .challenge)
        self.listenerInstanceID = try container.decode(UUID.self, forKey: .listenerInstanceID)
        self.listenerPublicKeySHA256 = try container.decode(String.self, forKey: .listenerPublicKeySHA256)
    }
}

public struct PeekabooBridgeCertificationProducerAuthorization: Codable, Equatable, Sendable {
    public let processIdentifier: Int32
    public let processIdentifierVersion: Int32
    public let processStartIdentity: UInt64
    public let codeSignatureHash: String
    public let signingIdentifier: String
    public let teamIdentifier: String
    public let sourceCommit: String
    public let executableSHA256: String

    public init(
        processIdentifier: Int32,
        processIdentifierVersion: Int32,
        processStartIdentity: UInt64,
        codeSignatureHash: String,
        signingIdentifier: String,
        teamIdentifier: String,
        sourceCommit: String,
        executableSHA256: String)
    {
        self.processIdentifier = processIdentifier
        self.processIdentifierVersion = processIdentifierVersion
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
        self.signingIdentifier = signingIdentifier
        self.teamIdentifier = teamIdentifier
        self.sourceCommit = sourceCommit
        self.executableSHA256 = executableSHA256
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case processIdentifier
        case processIdentifierVersion
        case processStartIdentity
        case codeSignatureHash
        case signingIdentifier
        case teamIdentifier
        case sourceCommit
        case executableSHA256
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification producer authorization")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        self.processIdentifierVersion = try container.decode(Int32.self, forKey: .processIdentifierVersion)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        guard let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Certification producer authorization generation is not canonical")
        }
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
        self.signingIdentifier = try container.decode(String.self, forKey: .signingIdentifier)
        self.teamIdentifier = try container.decode(String.self, forKey: .teamIdentifier)
        self.sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
        self.executableSHA256 = try container.decode(String.self, forKey: .executableSHA256)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(self.processIdentifierVersion, forKey: .processIdentifierVersion)
        try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
        try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
        try container.encode(self.signingIdentifier, forKey: .signingIdentifier)
        try container.encode(self.teamIdentifier, forKey: .teamIdentifier)
        try container.encode(self.sourceCommit, forKey: .sourceCommit)
        try container.encode(self.executableSHA256, forKey: .executableSHA256)
    }
}

public enum PeekabooBridgeCertificationProducerPayload: Codable, Equatable, Sendable {
    case crashInventoryPair(PeekabooBridgeCertificationCrashInventoryPairPayload)
    case monitorSeal(PeekabooBridgeCertificationMonitorSealPayload)
    case observerSemantic(PeekabooBridgeCertificationObserverSemanticPayload)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case crashInventoryPair
        case monitorSeal
        case observerSemantic
    }

    public init(from decoder: any Decoder) throws {
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let probe = try decoder.container(keyedBy: CodingKeys.self)
        guard probe.allKeys.count == 1, let key = probe.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Certification producer payload must contain exactly one typed case"))
        }
        try PeekabooBridgeClosedPayload.requireExactKeys(
            [key.stringValue],
            from: decoder,
            description: "Certification producer payload")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        precondition(knownKeys.contains(key.stringValue))
        switch key {
        case .crashInventoryPair:
            self = try .crashInventoryPair(container.decode(
                PeekabooBridgeCertificationCrashInventoryPairPayload.self,
                forKey: key))
        case .monitorSeal:
            self = try .monitorSeal(container.decode(
                PeekabooBridgeCertificationMonitorSealPayload.self,
                forKey: key))
        case .observerSemantic:
            self = try .observerSemantic(container.decode(
                PeekabooBridgeCertificationObserverSemanticPayload.self,
                forKey: key))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .crashInventoryPair(value):
            try container.encode(value, forKey: .crashInventoryPair)
        case let .monitorSeal(value):
            try container.encode(value, forKey: .monitorSeal)
        case let .observerSemantic(value):
            try container.encode(value, forKey: .observerSemantic)
        }
    }

    var kind: PeekabooBridgeCertificationProducerAttestationKind {
        switch self {
        case .crashInventoryPair: .crashInventoryPair
        case .monitorSeal: .monitorSeal
        case .observerSemantic: .observerSemantic
        }
    }
}

public struct PeekabooBridgeCertificationProducerWireResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: PeekabooBridgeCertificationProducerAttestationKind
    public let executionNonce: String
    public let monitorInstanceID: UUID
    public let challenge: String
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let payload: PeekabooBridgeCertificationProducerPayload

    public init(
        schemaVersion: Int = 1,
        kind: PeekabooBridgeCertificationProducerAttestationKind,
        executionNonce: String,
        monitorInstanceID: UUID,
        challenge: String,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        payload: PeekabooBridgeCertificationProducerPayload)
    {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.challenge = challenge
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case executionNonce
        case monitorInstanceID
        case challenge
        case listenerInstanceID
        case listenerPublicKeySHA256
        case payload
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification producer response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.kind = try container.decode(
            PeekabooBridgeCertificationProducerAttestationKind.self,
            forKey: .kind)
        self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
        self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
        self.challenge = try container.decode(String.self, forKey: .challenge)
        self.listenerInstanceID = try container.decode(UUID.self, forKey: .listenerInstanceID)
        self.listenerPublicKeySHA256 = try container.decode(String.self, forKey: .listenerPublicKeySHA256)
        self.payload = try container.decode(PeekabooBridgeCertificationProducerPayload.self, forKey: .payload)
    }
}

public struct PeekabooBridgeCertificationProducerAttestationResponse: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let kind: PeekabooBridgeCertificationProducerAttestationKind
    public let executionNonce: String
    public let monitorInstanceID: UUID
    public let challenge: String
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let producer: PeekabooBridgeCertificationProducerAuthorization
    public let payload: PeekabooBridgeCertificationProducerPayload
    public let observedAtUnixMilliseconds: Int64

    public init(
        schemaVersion: Int = 1,
        kind: PeekabooBridgeCertificationProducerAttestationKind,
        executionNonce: String,
        monitorInstanceID: UUID,
        challenge: String,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        producer: PeekabooBridgeCertificationProducerAuthorization,
        payload: PeekabooBridgeCertificationProducerPayload,
        observedAtUnixMilliseconds: Int64)
    {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.challenge = challenge
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.producer = producer
        self.payload = payload
        self.observedAtUnixMilliseconds = observedAtUnixMilliseconds
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case executionNonce
        case monitorInstanceID
        case challenge
        case listenerInstanceID
        case listenerPublicKeySHA256
        case producer
        case payload
        case observedAtUnixMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification producer attestation response")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.kind = try container.decode(PeekabooBridgeCertificationProducerAttestationKind.self, forKey: .kind)
        self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
        self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
        self.challenge = try container.decode(String.self, forKey: .challenge)
        self.listenerInstanceID = try container.decode(UUID.self, forKey: .listenerInstanceID)
        self.listenerPublicKeySHA256 = try container.decode(String.self, forKey: .listenerPublicKeySHA256)
        self.producer = try container.decode(
            PeekabooBridgeCertificationProducerAuthorization.self,
            forKey: .producer)
        self.payload = try container.decode(PeekabooBridgeCertificationProducerPayload.self, forKey: .payload)
        self.observedAtUnixMilliseconds = try container.decode(Int64.self, forKey: .observedAtUnixMilliseconds)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.schemaVersion, forKey: .schemaVersion)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.executionNonce, forKey: .executionNonce)
        try container.encode(self.monitorInstanceID, forKey: .monitorInstanceID)
        try container.encode(self.challenge, forKey: .challenge)
        try container.encode(self.listenerInstanceID, forKey: .listenerInstanceID)
        try container.encode(self.listenerPublicKeySHA256, forKey: .listenerPublicKeySHA256)
        try container.encode(self.producer, forKey: .producer)
        try container.encode(self.payload, forKey: .payload)
        try container.encode(self.observedAtUnixMilliseconds, forKey: .observedAtUnixMilliseconds)
    }

    func validate(
        request: PeekabooBridgeCertificationProducerAttestationRequest,
        listenerAttestation: PeekabooBridgeListenerAttestation) throws
    {
        try self.validateEnvelope(request: request)
        try listenerAttestation.validateSignature()
        guard self.listenerInstanceID == listenerAttestation.listenerInstanceID,
              self.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  listenerAttestation.publicKey)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "certification producer response identity")
        }
        try self.payload.validate(context: .init(
            request: request,
            producer: self.producer,
            listenerAttestation: listenerAttestation))
    }

    func validateEnvelope(request: PeekabooBridgeCertificationProducerAttestationRequest) throws {
        try request.validate()
        try self.producer.validate(expected: request.expectedProducer, kind: request.kind)
        guard self.schemaVersion == 1,
              self.kind == request.kind,
              self.payload.kind == request.kind,
              self.executionNonce == request.executionNonce,
              self.monitorInstanceID == request.monitorInstanceID,
              PeekabooBridgeCertificationValidation.isLowerHex(self.challenge, count: 64),
              PeekabooBridgeCertificationValidation.isVersion4(self.listenerInstanceID),
              PeekabooBridgeCertificationValidation.isLowerHex(self.listenerPublicKeySHA256, count: 64),
              PeekabooBridgeCertificationValidation.isPositiveSafeInteger(
                  self.observedAtUnixMilliseconds)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "certification producer response envelope")
        }
    }
}

extension PeekabooBridgeCertificationProducerAuthorization {
    func validate(
        expected: PeekabooBridgeCertificationProducerExpectation,
        kind: PeekabooBridgeCertificationProducerAttestationKind) throws
    {
        guard self.processIdentifier == expected.processIdentifier,
              self.processIdentifierVersion > 0,
              self.processStartIdentity == expected.processStartIdentity,
              self.codeSignatureHash == expected.codeSignatureHash,
              PeekabooBridgeCertificationValidation.isLowerHex(self.codeSignatureHash, count: 40),
              self.signingIdentifier == kind.expectedSigningIdentifier,
              self.teamIdentifier == PeekabooBridgeCertificationValidation.foundationTeamIdentifier,
              PeekabooBridgeCertificationValidation.isLowerHex(self.sourceCommit, count: 40),
              PeekabooBridgeCertificationValidation.isLowerHex(self.executableSHA256, count: 64)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "certification producer authorization")
        }
    }
}

struct PeekabooBridgeCertificationPayloadValidationContext {
    let request: PeekabooBridgeCertificationProducerAttestationRequest
    let producer: PeekabooBridgeCertificationProducerAuthorization
    let listenerAttestation: PeekabooBridgeListenerAttestation
}

enum PeekabooBridgeCertificationValidation {
    static let foundationTeamIdentifier = "FWJYW4S8P8"
    static let maximumSafeInteger: Int64 = 9_007_199_254_740_991

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func isVersion4(_ value: UUID) -> Bool {
        let string = value.uuidString.lowercased()
        return string[string.index(string.startIndex, offsetBy: 14)] == "4" &&
            "89ab".contains(string[string.index(string.startIndex, offsetBy: 19)])
    }

    static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    static func isSafeIdentifier(_ value: String, maximumBytes: Int = 256) -> Bool {
        let bytes = value.utf8
        return !bytes.isEmpty && bytes.count <= maximumBytes && !value.contains("\0")
    }

    static func isPositiveSafeInteger(_ value: Int64) -> Bool {
        value > 0 && value <= self.maximumSafeInteger
    }

    static func isNonnegativeSafeInteger(_ value: Int64) -> Bool {
        value >= 0 && value <= self.maximumSafeInteger
    }
}
