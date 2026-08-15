import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Security

/// Stable process-generation evidence used by protocol 1.29 operation receipts.
public struct PeekabooBridgeOperationProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: pid_t
    public let processStartIdentity: UInt64
    public let codeSignatureHash: String

    public init(processIdentifier: pid_t, processStartIdentity: UInt64, codeSignatureHash: String) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
    }

    private enum CodingKeys: String, CodingKey {
        case processIdentifier
        case processStartIdentity
        case codeSignatureHash
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processIdentifier = try container.decode(pid_t.self, forKey: .processIdentifier)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        let codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
        guard processIdentifier > 0,
              let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal),
              !codeSignatureHash.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Bridge process identity fields are invalid")
        }
        self.init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: codeSignatureHash)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
        try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
    }
}

/// The canonical stable target coalesced from request, response, and execution-owner evidence.
///
/// Leaf services remain responsible for validating their native target immediately before dispatch;
/// the receipt layer rejects incomplete or contradictory attribution rather than widening it.
public enum PeekabooBridgeOperationTargetReceipt: Codable, Equatable, Sendable {
    case global
    case process(ApplicationProcessIdentity)
    case window(WindowMutationIdentity)

    private enum CodingKeys: String, CodingKey {
        case kind
        case processIdentifier
        case processStartIdentity
        case windowID
        case capturedBounds
        case isMinimized
    }

    private enum Kind: String, Codable {
        case global
        case process
        case window
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .global:
            self = .global
        case .process:
            self = try .process(Self.decodeProcessIdentity(from: container))
        case .window:
            let process = try Self.decodeProcessIdentity(from: container)
            let windowID = try container.decode(Int.self, forKey: .windowID)
            let capturedBounds = try container.decode(CGRect.self, forKey: .capturedBounds)
            let isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized)
            guard windowID > 0,
                  UInt32(exactly: windowID) != nil,
                  capturedBounds.width > 0,
                  capturedBounds.height > 0
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .windowID,
                    in: container,
                    debugDescription: "Bridge operation window target fields are invalid")
            }
            self = .window(.init(
                windowID: windowID,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: capturedBounds,
                isMinimized: isMinimized))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case let .process(identity):
            try container.encode(Kind.process, forKey: .kind)
            try Self.encodeProcessIdentity(identity, to: &container)
        case let .window(identity):
            guard let capturedBounds = identity.capturedBounds else {
                throw EncodingError.invalidValue(
                    identity,
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "Exact Bridge operation target requires capture-time bounds"))
            }
            try container.encode(Kind.window, forKey: .kind)
            try Self.encodeProcessIdentity(identity.processIdentity, to: &container)
            try container.encode(identity.windowID, forKey: .windowID)
            try container.encode(capturedBounds, forKey: .capturedBounds)
            try container.encodeIfPresent(identity.isMinimized, forKey: .isMinimized)
        }
    }

    private static func decodeProcessIdentity(
        from container: KeyedDecodingContainer<CodingKeys>) throws -> ApplicationProcessIdentity
    {
        let processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        guard processIdentifier > 0,
              let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Bridge operation target process identity is invalid")
        }
        return .init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    private static func encodeProcessIdentity(
        _ identity: ApplicationProcessIdentity,
        to container: inout KeyedEncodingContainer<CodingKeys>) throws
    {
        try container.encode(identity.processIdentifier, forKey: .processIdentifier)
        try container.encode(String(identity.processStartIdentity), forKey: .processStartIdentity)
    }

    init(targetIdentity: DesktopTargetIdentity) {
        if let exactWindow = targetIdentity.exactWindow {
            self = .window(exactWindow.identity)
        } else {
            self = .process(targetIdentity.processIdentity)
        }
    }
}

/// Lossless signed input to canonical target-attribution coalescing.
public struct PeekabooBridgeOperationTargetEvidence: Codable, Equatable, Sendable {
    public let processIdentifier: Int32?
    public let processIdentity: ApplicationProcessIdentity?
    public let windowID: Int?
    public let windowIdentity: WindowMutationIdentity?
    public let windowBounds: CGRect?
    public let focusedElement: FocusedElementIdentity?

    init(_ evidence: DesktopTargetIdentity.Evidence) {
        self.processIdentifier = evidence.processIdentifier
        self.processIdentity = evidence.processIdentity
        self.windowID = evidence.windowID
        self.windowIdentity = evidence.windowIdentity
        self.windowBounds = evidence.windowBounds
        self.focusedElement = evidence.focusedElement
    }

    var desktopEvidence: DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: self.processIdentifier,
            processIdentity: self.processIdentity,
            windowID: self.windowID,
            windowIdentity: self.windowIdentity,
            windowBounds: self.windowBounds,
            focusedElement: self.focusedElement)
    }

    private enum CodingKeys: String, CodingKey {
        case processIdentifier
        case processIdentityProcessIdentifier
        case processIdentityStartIdentity
        case windowID
        case windowIdentityWindowID
        case windowIdentityOwnerProcessIdentifier
        case windowIdentityOwnerProcessStartIdentity
        case windowIdentityCapturedBounds
        case windowIdentityIsMinimized
        case windowBounds
        case focusedElement
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.processIdentifier = try container.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        self.processIdentity = try Self.decodeProcessIdentity(
            processIdentifierKey: .processIdentityProcessIdentifier,
            processStartIdentityKey: .processIdentityStartIdentity,
            from: container)
        self.windowID = try container.decodeIfPresent(Int.self, forKey: .windowID)
        let identityWindowID = try container.decodeIfPresent(Int.self, forKey: .windowIdentityWindowID)
        let identityProcess = try Self.decodeProcessIdentity(
            processIdentifierKey: .windowIdentityOwnerProcessIdentifier,
            processStartIdentityKey: .windowIdentityOwnerProcessStartIdentity,
            from: container)
        if identityWindowID != nil || identityProcess != nil {
            guard let identityWindowID, let identityProcess else {
                throw DecodingError.dataCorruptedError(
                    forKey: .windowIdentityWindowID,
                    in: container,
                    debugDescription: "Bridge operation window evidence is incomplete")
            }
            self.windowIdentity = try .init(
                windowID: identityWindowID,
                ownerProcessIdentifier: identityProcess.processIdentifier,
                ownerProcessStartIdentity: identityProcess.processStartIdentity,
                capturedBounds: container.decodeIfPresent(
                    CGRect.self,
                    forKey: .windowIdentityCapturedBounds),
                isMinimized: container.decodeIfPresent(Bool.self, forKey: .windowIdentityIsMinimized))
        } else {
            self.windowIdentity = nil
        }
        self.windowBounds = try container.decodeIfPresent(CGRect.self, forKey: .windowBounds)
        self.focusedElement = try container.decodeIfPresent(FocusedElementIdentity.self, forKey: .focusedElement)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.processIdentifier, forKey: .processIdentifier)
        try Self.encodeProcessIdentity(
            self.processIdentity,
            processIdentifierKey: .processIdentityProcessIdentifier,
            processStartIdentityKey: .processIdentityStartIdentity,
            to: &container)
        try container.encodeIfPresent(self.windowID, forKey: .windowID)
        if let windowIdentity = self.windowIdentity {
            try container.encode(windowIdentity.windowID, forKey: .windowIdentityWindowID)
            try Self.encodeProcessIdentity(
                windowIdentity.processIdentity,
                processIdentifierKey: .windowIdentityOwnerProcessIdentifier,
                processStartIdentityKey: .windowIdentityOwnerProcessStartIdentity,
                to: &container)
            try container.encodeIfPresent(
                windowIdentity.capturedBounds,
                forKey: .windowIdentityCapturedBounds)
            try container.encodeIfPresent(windowIdentity.isMinimized, forKey: .windowIdentityIsMinimized)
        }
        try container.encodeIfPresent(self.windowBounds, forKey: .windowBounds)
        try container.encodeIfPresent(self.focusedElement, forKey: .focusedElement)
    }

    private static func decodeProcessIdentity(
        processIdentifierKey: CodingKeys,
        processStartIdentityKey: CodingKeys,
        from container: KeyedDecodingContainer<CodingKeys>) throws -> ApplicationProcessIdentity?
    {
        let processIdentifier = try container.decodeIfPresent(Int32.self, forKey: processIdentifierKey)
        let decimal = try container.decodeIfPresent(String.self, forKey: processStartIdentityKey)
        guard processIdentifier != nil || decimal != nil else { return nil }
        guard let processIdentifier,
              let decimal,
              let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: processStartIdentityKey,
                in: container,
                debugDescription: "Bridge operation process evidence is incomplete or invalid")
        }
        return .init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    private static func encodeProcessIdentity(
        _ identity: ApplicationProcessIdentity?,
        processIdentifierKey: CodingKeys,
        processStartIdentityKey: CodingKeys,
        to container: inout KeyedEncodingContainer<CodingKeys>) throws
    {
        guard let identity else { return }
        try container.encode(identity.processIdentifier, forKey: processIdentifierKey)
        try container.encode(String(identity.processStartIdentity), forKey: processStartIdentityKey)
    }
}

public struct PeekabooBridgeTargetAttributionFailure: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable {
        case preDispatch = "pre_dispatch"
        case postExecution = "post_execution"
    }

    public enum Code: String, Codable, Sendable {
        case invalidProcessIdentifier = "invalid_process_identifier"
        case invalidWindowIdentifier = "invalid_window_identifier"
        case contradictoryProcessIdentifier = "contradictory_process_identifier"
        case contradictoryProcessGeneration = "contradictory_process_generation"
        case contradictoryWindowIdentifier = "contradictory_window_identifier"
        case contradictoryWindowIdentity = "contradictory_window_identity"
        case contradictoryWindowBounds = "contradictory_window_bounds"
        case contradictoryFocusedElement = "contradictory_focused_element"
        case invalidFocusedElement = "invalid_focused_element"
        case missingProcessGeneration = "missing_process_generation"
        case incompleteExactWindow = "incomplete_exact_window"
        case invalidatedSnapshotReceipt = "invalidated_snapshot_receipt"
        case invalidSnapshotIdentifier = "invalid_snapshot_identifier"
        case coordinateReferenceMismatch = "coordinate_reference_mismatch"
        case coordinateWindowMismatch = "coordinate_window_mismatch"
        case coordinateBoundsMismatch = "coordinate_bounds_mismatch"
    }

    public let code: Code
    public let message: String
    public let stage: Stage

    init(_ error: DesktopTargetIdentityError, stage: Stage) {
        self.code = Code(error)
        self.message = error.localizedDescription
        self.stage = stage
    }
}

extension PeekabooBridgeTargetAttributionFailure.Code {
    init(_ error: DesktopTargetIdentityError) {
        self = switch error {
        case .invalidProcessIdentifier: .invalidProcessIdentifier
        case .invalidWindowIdentifier: .invalidWindowIdentifier
        case .contradictoryProcessIdentifier: .contradictoryProcessIdentifier
        case .contradictoryProcessGeneration: .contradictoryProcessGeneration
        case .contradictoryWindowIdentifier: .contradictoryWindowIdentifier
        case .contradictoryWindowIdentity: .contradictoryWindowIdentity
        case .contradictoryWindowBounds: .contradictoryWindowBounds
        case .contradictoryFocusedElement: .contradictoryFocusedElement
        case .invalidFocusedElement: .invalidFocusedElement
        case .missingProcessGeneration: .missingProcessGeneration
        case .incompleteExactWindow: .incompleteExactWindow
        case .invalidatedSnapshotReceipt: .invalidatedSnapshotReceipt
        case .invalidSnapshotIdentifier: .invalidSnapshotIdentifier
        case .coordinateReferenceMismatch: .coordinateReferenceMismatch
        case .coordinateWindowMismatch: .coordinateWindowMismatch
        case .coordinateBoundsMismatch: .coordinateBoundsMismatch
        }
    }
}

/// Self-signed, process-bound identity generated once for one listening socket lifetime.
public struct PeekabooBridgeListenerAttestation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let listenerInstanceID: UUID
    public let publicKey: Data
    public let host: PeekabooBridgeOperationProcessIdentity
    public let createdAtUnixMilliseconds: Int64
    public let receiptArchiveDirectory: String
    public let signature: Data

    init(
        listenerInstanceID: UUID,
        publicKey: Data,
        host: PeekabooBridgeOperationProcessIdentity,
        createdAtUnixMilliseconds: Int64,
        receiptArchiveDirectory: String,
        signature: Data)
    {
        self.schemaVersion = 1
        self.listenerInstanceID = listenerInstanceID
        self.publicKey = publicKey
        self.host = host
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.receiptArchiveDirectory = receiptArchiveDirectory
        self.signature = signature
    }

    public func validateSignature() throws {
        guard self.schemaVersion == 1,
              self.host.processIdentifier > 0,
              self.host.processStartIdentity > 0,
              !self.host.codeSignatureHash.isEmpty,
              !self.receiptArchiveDirectory.isEmpty
        else {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: self.publicKey)
        } catch {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        guard try key.isValidSignature(
            self.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(self.unsignedPayload))
        else {
            throw PeekabooBridgeOperationReceiptError.invalidListenerSignature
        }
    }

    var unsignedPayload: UnsignedPayload {
        UnsignedPayload(
            schemaVersion: self.schemaVersion,
            listenerInstanceID: self.listenerInstanceID,
            publicKey: self.publicKey,
            host: self.host,
            createdAtUnixMilliseconds: self.createdAtUnixMilliseconds,
            receiptArchiveDirectory: self.receiptArchiveDirectory)
    }

    struct UnsignedPayload: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let listenerInstanceID: UUID
        let publicKey: Data
        let host: PeekabooBridgeOperationProcessIdentity
        let createdAtUnixMilliseconds: Int64
        let receiptArchiveDirectory: String
    }
}

/// One unique, listener-bound operation request.
public struct PeekabooBridgeAttestedOperationRequest: Codable, Sendable {
    public let requestID: UUID
    public let expectedListenerInstanceID: UUID
    public let client: PeekabooBridgeOperationProcessIdentity
    public let request: PeekabooBridgeRequest

    public init(
        requestID: UUID,
        expectedListenerInstanceID: UUID,
        client: PeekabooBridgeOperationProcessIdentity,
        request: PeekabooBridgeRequest)
    {
        self.requestID = requestID
        self.expectedListenerInstanceID = expectedListenerInstanceID
        self.client = client
        self.request = request
    }

    func validatedRequest() throws -> PeekabooBridgeRequest {
        try self.request.validateAttestedOperationCarriage()
        return self.request
    }
}

extension PeekabooBridgeRequest {
    fileprivate func validateAttestedOperationCarriage() throws {
        switch self {
        case .attestedOperation:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Attested Bridge operation requests cannot be nested")
        case .handshake:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Bridge handshakes cannot use operation receipt carriage")
        case let .projectedAction(payload):
            let nested = try payload.validatedRequest()
            if case .attestedOperation = nested {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Attested Bridge operation requests cannot be nested inside action carriage")
            }
        case _ where self.mayMutateDesktop:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Mutating attested Bridge operations require action outcome carriage")
        default:
            break
        }
    }
}

/// Canonical facts signed by the serving listener after one operation reaches a terminal response.
public struct PeekabooBridgeOperationReceiptPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let host: PeekabooBridgeOperationProcessIdentity
    public let client: PeekabooBridgeOperationProcessIdentity
    public let operation: PeekabooBridgeOperation
    public let requestSHA256: String
    public let responseSHA256: String
    public let target: PeekabooBridgeOperationTargetReceipt?
    public let focusedElement: FocusedElementIdentity?
    public let targetAttributionFailure: PeekabooBridgeTargetAttributionFailure?
    public let targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]?
    public let outcome: DesktopActionOutcome.Projection?
    public let startedAtUnixMilliseconds: Int64
    public let completedAtUnixMilliseconds: Int64

    public init(
        requestID: UUID,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        host: PeekabooBridgeOperationProcessIdentity,
        client: PeekabooBridgeOperationProcessIdentity,
        operation: PeekabooBridgeOperation,
        requestSHA256: String,
        responseSHA256: String,
        target: PeekabooBridgeOperationTargetReceipt?,
        focusedElement: FocusedElementIdentity? = nil,
        targetAttributionFailure: PeekabooBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]? = nil,
        outcome: DesktopActionOutcome.Projection?,
        startedAtUnixMilliseconds: Int64,
        completedAtUnixMilliseconds: Int64)
    {
        precondition((target == nil) != (targetAttributionFailure == nil))
        precondition((targetAttributionFailure == nil) == (targetAttributionEvidence == nil))
        if focusedElement != nil {
            guard case .window = target else {
                preconditionFailure("Focused operation receipt requires an exact-window target")
            }
        }
        self.schemaVersion = 1
        self.requestID = requestID
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.host = host
        self.client = client
        self.operation = operation
        self.requestSHA256 = requestSHA256
        self.responseSHA256 = responseSHA256
        self.target = target
        self.focusedElement = focusedElement
        self.targetAttributionFailure = targetAttributionFailure
        self.targetAttributionEvidence = targetAttributionEvidence
        self.outcome = outcome
        self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
        self.completedAtUnixMilliseconds = completedAtUnixMilliseconds
    }

    func validateTargetState() throws {
        guard (self.target == nil) != (self.targetAttributionFailure == nil) else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution state")
        }
        guard (self.targetAttributionFailure == nil) == (self.targetAttributionEvidence == nil) else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution evidence state")
        }
        guard let target = self.target else {
            guard self.focusedElement == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("failed target focus")
            }
            return
        }
        let identity = try self.resolvedTargetIdentity()
        if target != .global, identity == nil {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("stable target identity")
        }
    }

    func resolvedTargetIdentity() throws -> DesktopTargetIdentity? {
        guard let target = self.target else { return nil }
        switch target {
        case .global:
            guard self.focusedElement == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("global target focus")
            }
            return nil
        case let .process(process):
            guard self.focusedElement == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("process target focus")
            }
            return try DesktopTargetIdentity(processIdentity: process)
        case let .window(window):
            return try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
                PeekabooBridgeOperationTargetEvidenceAdapter.exactWindow(
                    identity: window,
                    bounds: window.capturedBounds ?? .null,
                    focusedElement: self.focusedElement),
            ])
        }
    }
}

/// Durable proof emitted by one listener. The signature covers every payload field.
public struct PeekabooBridgeOperationReceipt: Codable, Equatable, Sendable {
    public let payload: PeekabooBridgeOperationReceiptPayload
    public let signature: Data

    public init(payload: PeekabooBridgeOperationReceiptPayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public func validateSignature(publicKey: Data) throws {
        try self.payload.validateTargetState()
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        guard try key.isValidSignature(
            self.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(self.payload))
        else {
            throw PeekabooBridgeOperationReceiptError.invalidOperationSignature
        }
    }
}

/// Opt-in audit export that makes both signed digests independently reproducible.
///
/// Unlike the privacy-minimized host archive, this bundle contains the complete canonical request
/// and response bytes. Callers must treat it as sensitive command data.
public struct PeekabooBridgeOperationReceiptBundle: Codable, Equatable, Sendable {
    public let operationAttestation: PeekabooBridgeListenerAttestation
    public let receipt: PeekabooBridgeOperationReceipt
    public let canonicalListenerAttestationPayload: Data
    public let canonicalReceiptPayload: Data
    public let canonicalRequest: Data
    public let canonicalResponse: Data

    public init(
        operationAttestation: PeekabooBridgeListenerAttestation,
        receipt: PeekabooBridgeOperationReceipt,
        canonicalListenerAttestationPayload: Data,
        canonicalReceiptPayload: Data,
        canonicalRequest: Data,
        canonicalResponse: Data)
    {
        self.operationAttestation = operationAttestation
        self.receipt = receipt
        self.canonicalListenerAttestationPayload = canonicalListenerAttestationPayload
        self.canonicalReceiptPayload = canonicalReceiptPayload
        self.canonicalRequest = canonicalRequest
        self.canonicalResponse = canonicalResponse
    }

    public func validate() throws {
        guard try self.canonicalListenerAttestationPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
            self.operationAttestation.unsignedPayload)),
            try self.canonicalReceiptPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
                self.receipt.payload))
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported signature payload bytes")
        }
        try self.operationAttestation.validateSignature()
        try self.receipt.validateSignature(publicKey: self.operationAttestation.publicKey)
        let request: PeekabooBridgeRequest
        let response: PeekabooBridgeResponse
        do {
            request = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self,
                from: self.canonicalRequest)
            response = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: self.canonicalResponse)
            try request.validateAttestedOperationCarriage()
        } catch {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported request or response bytes")
        }
        let payload = self.receipt.payload
        guard try self.canonicalRequest == PeekabooBridgeOperationReceiptCoding.canonicalData(request),
              try self.canonicalResponse == PeekabooBridgeOperationReceiptCoding.canonicalData(response),
              payload.schemaVersion == 1,
              payload.listenerInstanceID == self.operationAttestation.listenerInstanceID,
              self.receipt.payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.operationAttestation.publicKey),
              payload.host == self.operationAttestation.host,
              payload.client.processIdentifier > 0,
              payload.client.processStartIdentity > 0,
              !payload.client.codeSignatureHash.isEmpty,
              payload.operation == request.operation,
              payload.requestSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.canonicalRequest),
              payload.responseSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(self.canonicalResponse),
              payload.outcome == PeekabooBridgeOperationReceiptSemantics.outcome(in: response),
              payload.startedAtUnixMilliseconds > 0,
              payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported verification bundle")
        }
        try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
            payload,
            request: request,
            response: response)
    }
}

public struct PeekabooBridgeAttestedOperationResponse: Codable, Sendable {
    public let response: PeekabooBridgeResponse
    public let receipt: PeekabooBridgeOperationReceipt

    public init(response: PeekabooBridgeResponse, receipt: PeekabooBridgeOperationReceipt) {
        self.response = response
        self.receipt = receipt
    }
}

enum PeekabooBridgeOperationReceiptError: Error, LocalizedError, Equatable {
    case invalidListenerAttestation
    case invalidListenerSignature
    case listenerInstanceMismatch
    case peerIdentityMismatch
    case clientIdentityMismatch
    case replayedRequest
    case invalidOperationSignature
    case receiptMismatch(String)
    case unsafeArchive(String)
    case archiveWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidListenerAttestation:
            "Bridge listener attestation is incomplete or malformed"
        case .invalidListenerSignature:
            "Bridge listener attestation signature is invalid"
        case .listenerInstanceMismatch:
            "Bridge listener instance changed after handshake"
        case .peerIdentityMismatch:
            "Connected Bridge peer does not match the attested process generation"
        case .clientIdentityMismatch:
            "Bridge request client identity does not match the connected peer"
        case .replayedRequest:
            "Bridge operation request ID was already used by this listener"
        case .invalidOperationSignature:
            "Bridge operation receipt signature is invalid"
        case let .receiptMismatch(field):
            "Bridge operation receipt does not match \(field)"
        case let .unsafeArchive(path):
            "Bridge operation receipt archive is unsafe: \(path)"
        case let .archiveWriteFailed(message):
            "Bridge operation receipt archive write failed: \(message)"
        }
    }
}

enum PeekabooBridgeOperationReceiptCoding {
    static func canonicalData(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ value: some Encodable) throws -> String {
        try self.sha256(self.canonicalData(value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func unixMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func uint64(decimal: String) -> UInt64? {
        guard !decimal.isEmpty,
              decimal == "0" || decimal.first != "0",
              decimal.allSatisfy(\.isNumber),
              let value = UInt64(decimal),
              String(value) == decimal
        else { return nil }
        return value
    }
}

enum PeekabooBridgeOperationReceiptSemantics {
    static func outcome(in response: PeekabooBridgeResponse) -> DesktopActionOutcome.Projection? {
        switch response {
        case let .projectedAction(payload): payload.outcome
        case let .error(envelope): envelope.actionOutcome
        default: nil
        }
    }

    static func validateTargetAttribution(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        try payload.validateTargetState()
        try self.validateResponseOutcomeConsistency(response)
        guard let failure = payload.targetAttributionFailure else {
            try self.validateSuccessfulTargetAttribution(
                payload,
                request: request,
                response: response)
            return
        }
        try self.validateFailedTargetAttribution(
            payload,
            failure: failure,
            request: request,
            response: response)
    }

    private static func validateSuccessfulTargetAttribution(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        do {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(request)
        } catch {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "successful request target contract")
        }
        let signedIdentity = try payload.resolvedTargetIdentity()
        let resolvedIdentity: DesktopTargetIdentity?
        do {
            resolvedIdentity = try PeekabooBridgeOperationTargetAttribution.resolve(
                request: request,
                response: response,
                handledTarget: signedIdentity)
        } catch {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "canonical target attribution evidence")
        }
        let resolvedTarget = PeekabooBridgeResolvedOperationTarget(resolvedIdentity)
        guard payload.target == resolvedTarget.target,
              payload.focusedElement == resolvedTarget.focusedElement
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "canonical target attribution")
        }
    }

    private static func validateFailedTargetAttribution(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        failure: PeekabooBridgeTargetAttributionFailure,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        let envelope: PeekabooBridgeErrorEnvelope? = switch response {
        case let .error(envelope): envelope
        case let .projectedAction(projected):
            if case let .error(envelope) = projected.response {
                envelope
            } else {
                nil
            }
        default: nil
        }
        guard envelope?.context == "bridge_target_attribution:\(failure.code.rawValue)" else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution failure response")
        }
        guard let envelope else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution error envelope")
        }
        try self.validateFailureResponseSemantics(
            failure,
            request: request,
            envelope: envelope)
        guard let signedEvidence = payload.targetAttributionEvidence else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution failure evidence")
        }
        let requestEvidence = request.operationTargetEvidence.map(PeekabooBridgeOperationTargetEvidence.init)
        guard Array(signedEvidence.prefix(requestEvidence.count)) == requestEvidence else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution request evidence")
        }
        switch failure.stage {
        case .preDispatch:
            guard signedEvidence == requestEvidence else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("pre-dispatch target evidence")
            }
            do {
                _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(request)
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "claimed pre-dispatch target attribution failure")
            } catch let error as DesktopTargetIdentityError {
                guard PeekabooBridgeTargetAttributionFailure.Code(error) == failure.code else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution failure code")
                }
            }
            return
        case .postExecution:
            do {
                _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(request)
            } catch {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "post-execution request target evidence")
            }
        }
        do {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveEvidence(
                request: request,
                evidence: signedEvidence.map(\.desktopEvidence))
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "claimed target attribution failure")
        } catch let error as DesktopTargetIdentityError {
            guard PeekabooBridgeTargetAttributionFailure.Code(error) == failure.code else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution failure code")
            }
        }
    }

    private static func validateFailureResponseSemantics(
        _ failure: PeekabooBridgeTargetAttributionFailure,
        request: PeekabooBridgeRequest,
        envelope: PeekabooBridgeErrorEnvelope) throws
    {
        guard request.mayMutateDesktop else {
            guard envelope.code == .invalidRequest,
                  envelope.actionOutcome == nil
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "read-only target attribution failure semantics")
            }
            return
        }
        guard let outcome = envelope.actionOutcome?.outcome,
              outcome.route == .bridge
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "mutating target attribution failure outcome")
        }
        if failure.stage == .preDispatch || !outcome.dispatchState.mutationDispatched {
            guard envelope.code == .invalidRequest,
                  outcome.state == .refused,
                  outcome.evidence == .requestRefused,
                  outcome.dispatchState == .none,
                  outcome.retrySafety == .safe,
                  outcome.refusalReason == .invalidRequest
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "retry-safe target attribution refusal")
            }
        } else {
            guard envelope.code == .internalError,
                  outcome.state == .indeterminate,
                  outcome.evidence == .completionUnknown,
                  outcome.dispatchState.mutationDispatched,
                  outcome.retrySafety == .unsafe
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "retry-unsafe target attribution failure")
            }
        }
    }

    private static func validateResponseOutcomeConsistency(
        _ response: PeekabooBridgeResponse) throws
    {
        guard case let .projectedAction(projected) = response,
              case let .error(envelope) = projected.response
        else { return }
        guard projected.outcome == envelope.actionOutcome else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "projected error outcome")
        }
    }
}

/// Ephemeral signer, replay fence, and private durable archive for one listening socket lifetime.
final class PeekabooBridgeOperationReceiptAuthority: @unchecked Sendable {
    let attestation: PeekabooBridgeListenerAttestation

    private let privateKey: Curve25519.Signing.PrivateKey
    private let archiveDirectory: URL
    private let lock = NSLock()
    private var claimedRequestIDs: Set<UUID> = []

    init(socketPath: String) throws {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
              let codeSignatureHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                  processIdentifier: processIdentifier)
        else {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let listenerInstanceID = UUID()
        let archiveRoot = URL(fileURLWithPath: socketPath + ".receipts", isDirectory: true)
        let archiveDirectory = archiveRoot.appendingPathComponent(
            listenerInstanceID.uuidString.lowercased(),
            isDirectory: true)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveRoot)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveDirectory)

        let unsigned = PeekabooBridgeListenerAttestation.UnsignedPayload(
            schemaVersion: 1,
            listenerInstanceID: listenerInstanceID,
            publicKey: publicKey,
            host: .init(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                codeSignatureHash: codeSignatureHash),
            createdAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds(),
            receiptArchiveDirectory: archiveDirectory.path)
        let signature = try privateKey.signature(
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(unsigned))
        let attestation = PeekabooBridgeListenerAttestation(
            listenerInstanceID: unsigned.listenerInstanceID,
            publicKey: unsigned.publicKey,
            host: unsigned.host,
            createdAtUnixMilliseconds: unsigned.createdAtUnixMilliseconds,
            receiptArchiveDirectory: unsigned.receiptArchiveDirectory,
            signature: signature)
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(
            PeekabooBridgeOperationReceiptCoding.canonicalData(attestation),
            to: archiveDirectory.appendingPathComponent("attestation.json"))
        self.privateKey = privateKey
        self.archiveDirectory = archiveDirectory
        self.attestation = attestation
    }

    func claim(
        _ payload: PeekabooBridgeAttestedOperationRequest,
        peer: PeekabooBridgePeer,
        currentProcessStartIdentity: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity) throws
    {
        guard let processIdentifierVersion = peer.auditTokenProcessIdentifierVersion,
              processIdentifierVersion > 0
        else {
            throw PeekabooBridgeOperationReceiptError.peerIdentityMismatch
        }
        guard payload.expectedListenerInstanceID == self.attestation.listenerInstanceID else {
            throw PeekabooBridgeOperationReceiptError.listenerInstanceMismatch
        }
        guard payload.client.processIdentifier == peer.processIdentifier,
              payload.client.processStartIdentity == peer.processStartIdentity,
              payload.client.codeSignatureHash == peer.codeSignatureHash,
              currentProcessStartIdentity(peer.processIdentifier) == payload.client.processStartIdentity
        else {
            throw PeekabooBridgeOperationReceiptError.clientIdentityMismatch
        }

        self.lock.lock()
        let inserted = self.claimedRequestIDs.insert(payload.requestID).inserted
        self.lock.unlock()
        guard inserted else {
            throw PeekabooBridgeOperationReceiptError.replayedRequest
        }
    }

    func signAndArchive(_ payload: PeekabooBridgeOperationReceiptPayload) throws
        -> PeekabooBridgeOperationReceipt
    {
        guard payload.listenerInstanceID == self.attestation.listenerInstanceID else {
            throw PeekabooBridgeOperationReceiptError.listenerInstanceMismatch
        }
        let signature: Data
        self.lock.lock()
        do {
            signature = try self.privateKey.signature(
                for: PeekabooBridgeOperationReceiptCoding.canonicalData(payload))
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        let receipt = PeekabooBridgeOperationReceipt(payload: payload, signature: signature)
        let data = try PeekabooBridgeOperationReceiptCoding.canonicalData(receipt)
        let destination = self.archiveDirectory.appendingPathComponent(
            payload.requestID.uuidString.lowercased() + ".json",
            isDirectory: false)
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(data, to: destination)
        return receipt
    }
}

enum PeekabooBridgeCodeSignatureIdentity {
    static func codeSignatureHash(processIdentifier: pid_t) -> String? {
        self.codeSignatureHash(in: self.signingInformation(attributes: [
            kSecGuestAttributePid: processIdentifier,
        ]))
    }

    static func codeSignatureHash(auditIdentity: PeekabooBridgePeerAuditIdentity) -> String? {
        self.codeSignatureHash(in: self.signingInformation(auditIdentity: auditIdentity))
    }

    static func signingInformation(
        auditIdentity: PeekabooBridgePeerAuditIdentity) -> [String: Any]?
    {
        self.signingInformation(attributes: [
            kSecGuestAttributeAudit: auditIdentity.tokenData,
        ])
    }

    private static func codeSignatureHash(in information: [String: Any]?) -> String? {
        guard let hash = information?[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private static func signingInformation(attributes: NSDictionary) -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any]
        else { return nil }
        return values
    }
}

extension PeekabooBridgeRequest {
    var operationTargetEvidence: [DesktopTargetIdentity.Evidence] {
        switch self {
        case let .projectedAction(payload):
            payload.request.operationTargetEvidence
        case let .attestedOperation(payload):
            payload.request.operationTargetEvidence
        case let .exactWindowTargetedTypeActions(payload):
            [PeekabooBridgeOperationTargetEvidenceAdapter.exactWindow(
                identity: payload.expectedWindowIdentity,
                bounds: payload.expectedWindowBounds,
                focusedElement: payload.expectedFocusedElement)]
        case let .exactWindowTargetedHotkey(payload):
            [PeekabooBridgeOperationTargetEvidenceAdapter.exactWindow(
                identity: payload.expectedWindowIdentity,
                bounds: payload.expectedWindowBounds,
                focusedElement: payload.expectedFocusedElement)]
        case let .targetedTypeActions(payload):
            [.init(
                processIdentifier: payload.targetProcessIdentifier,
                processIdentity: payload.expectedProcessIdentity)]
        case let .targetedHotkey(payload):
            [.init(
                processIdentifier: payload.targetProcessIdentifier,
                processIdentity: payload.expectedProcessIdentity)]
        case let .getFocusedElement(payload):
            [.init(
                processIdentifier: payload.targetProcessIdentifier,
                processIdentity: payload.expectedProcessIdentity)]
        case let .targetedClick(payload):
            [.init(
                processIdentifier: payload.targetProcessIdentifier,
                processIdentity: payload.expectedProcessIdentity,
                windowID: payload.targetWindowID,
                windowIdentity: payload.expectedWindowIdentity,
                windowBounds: payload.expectedWindowBounds)]
        case let .moveWindow(payload):
            [PeekabooBridgeOperationTargetEvidenceAdapter.window(
                target: payload.target,
                identity: payload.expectedIdentity)]
        case let .resizeWindow(payload):
            [PeekabooBridgeOperationTargetEvidenceAdapter.window(
                target: payload.target,
                identity: payload.expectedIdentity)]
        case let .setWindowBounds(payload):
            [PeekabooBridgeOperationTargetEvidenceAdapter.window(
                target: payload.target,
                identity: payload.expectedIdentity)]
        case let .focusWindow(payload),
             let .closeWindow(payload),
             let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            [PeekabooBridgeOperationTargetEvidenceAdapter.window(
                target: payload.target,
                identity: payload.expectedIdentity)]
        case let .quitApplication(payload):
            payload.expectedIdentity.map {
                [.init(processIdentifier: $0.processIdentifier, processIdentity: $0)]
            } ?? []
        case let .activateApplication(payload):
            payload.expectedIdentity.map {
                [.init(processIdentifier: $0.processIdentifier, processIdentity: $0)]
            } ?? []
        case let .exactDialogClickButton(receipt), let .exactDialogDismiss(receipt):
            [.init(target: DesktopTargetIdentity(exactWindow: receipt.target))]
        case let .inspectAccessibilityTree(payload):
            payload.windowContext.map(PeekabooBridgeOperationTargetEvidenceAdapter.windowContext).map { [$0] } ?? []
        default:
            []
        }
    }
}

enum PeekabooBridgeOperationTargetEvidenceAdapter {
    static func exactWindow(
        identity: WindowMutationIdentity,
        bounds: CGRect,
        focusedElement: FocusedElementIdentity? = nil) -> DesktopTargetIdentity.Evidence
    {
        .init(
            processIdentifier: identity.ownerProcessIdentifier,
            processIdentity: identity.processIdentity,
            windowID: identity.windowID,
            windowIdentity: identity,
            windowBounds: bounds,
            focusedElement: focusedElement)
    }

    static func window(
        target: WindowTarget,
        identity: WindowMutationIdentity?) -> DesktopTargetIdentity.Evidence
    {
        let targetWindowID: Int? = if case let .windowId(windowID) = target {
            windowID
        } else {
            nil
        }
        return .init(
            processIdentifier: identity?.ownerProcessIdentifier,
            processIdentity: identity?.processIdentity,
            windowID: targetWindowID ?? identity?.windowID,
            windowIdentity: identity,
            windowBounds: identity?.capturedBounds)
    }

    static func windowContext(_ context: WindowContext) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: context.applicationProcessId,
            processIdentity: context.windowMutationIdentity?.processIdentity,
            windowID: context.windowID,
            windowIdentity: context.windowMutationIdentity,
            windowBounds: context.windowBounds,
            focusedElement: context.focusedElement)
    }
}

struct PeekabooBridgeResolvedOperationTarget: Sendable {
    let target: PeekabooBridgeOperationTargetReceipt
    let focusedElement: FocusedElementIdentity?

    init(_ identity: DesktopTargetIdentity?) {
        guard let identity else {
            self.target = .global
            self.focusedElement = nil
            return
        }
        self.target = .init(targetIdentity: identity)
        self.focusedElement = identity.exactWindow?.focusedElement
    }
}

enum PeekabooBridgeOperationTargetAttribution {
    static func resolveRequest(_ request: PeekabooBridgeRequest) throws -> DesktopTargetIdentity? {
        let identity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(
            request.operationTargetEvidence)
        if request.requiresStableOperationTarget, identity == nil {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        return identity
    }

    static func resolve(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity?) throws -> DesktopTargetIdentity?
    {
        try self.resolveEvidence(
            request: request,
            evidence: self.evidence(
                request: request,
                response: response,
                handledTarget: handledTarget))
    }

    static func resolveEvidence(
        request: PeekabooBridgeRequest,
        evidence: [DesktopTargetIdentity.Evidence]) throws -> DesktopTargetIdentity?
    {
        let identity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(evidence)
        if request.requiresResolvedOperationTarget, identity == nil {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        try request.validateResolvedOperationTarget(identity)
        return identity
    }

    static func evidence(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity?) -> [DesktopTargetIdentity.Evidence]
    {
        var evidence = request.operationTargetEvidence
        if let handledTarget {
            evidence.append(.init(target: handledTarget))
        }
        evidence.append(contentsOf: response.operationTargetEvidence(for: request.operation))
        return evidence
    }

    static func resolveReceipt(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity? = nil) throws -> PeekabooBridgeResolvedOperationTarget
    {
        try PeekabooBridgeResolvedOperationTarget(self.resolve(
            request: request,
            response: response,
            handledTarget: handledTarget))
    }
}

extension PeekabooBridgeRequest {
    fileprivate var requiresStableOperationTarget: Bool {
        switch self {
        case let .attestedOperation(payload): payload.request.requiresStableOperationTarget
        case let .projectedAction(payload): payload.request.requiresStableOperationTarget
        case .focusWindow: true
        default: false
        }
    }

    fileprivate var requiresResolvedOperationTarget: Bool {
        switch self {
        case let .attestedOperation(payload): payload.request.requiresResolvedOperationTarget
        case let .projectedAction(payload): payload.request.requiresResolvedOperationTarget
        case .focusWindow, .targetedScroll, .setValue, .performAction:
            true
        case let .desktopObservation(payload):
            payload.target.requiresExactWindowReceipt
        case let .click(payload):
            payload.target.requiresElementResolution
        case let .type(payload):
            payload.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        default:
            false
        }
    }

    fileprivate func validateResolvedOperationTarget(_ identity: DesktopTargetIdentity?) throws {
        switch self {
        case let .attestedOperation(payload):
            try payload.request.validateResolvedOperationTarget(identity)
        case let .projectedAction(payload):
            try payload.request.validateResolvedOperationTarget(identity)
        case let .desktopObservation(payload):
            guard case let .windowID(expectedWindowID) = payload.target else { return }
            guard let exactWindow = identity?.exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            guard exactWindow.identity.windowID == Int(expectedWindowID) else {
                throw DesktopTargetIdentityError.contradictoryWindowIdentifier
            }
        default:
            return
        }
    }
}

extension DesktopObservationTargetRequest {
    fileprivate var requiresExactWindowReceipt: Bool {
        if case .windowID = self {
            true
        } else {
            false
        }
    }
}

extension ClickTarget {
    fileprivate var requiresElementResolution: Bool {
        switch self {
        case .elementId, .query: true
        case .coordinates: false
        }
    }
}

extension PeekabooBridgeResponse {
    func operationTargetEvidence(
        for operation: PeekabooBridgeOperation) -> [DesktopTargetIdentity.Evidence]
    {
        switch self {
        case let .attestedOperation(payload):
            payload.response.operationTargetEvidence(for: operation)
        case let .projectedAction(payload):
            payload.response.operationTargetEvidence(for: operation)
        case let .desktopObservation(result):
            [
                Self.evidence(result.target.detectionContext),
                Self.evidence(result.target.app),
                Self.evidence(result.target.window),
            ].compactMap(\.self) + Self.evidence(result.capture.metadata)
        case let .capture(result):
            Self.evidence(result.metadata)
        case let .elementDetection(result):
            operation == .inspectAccessibilityTree
                ? [Self.evidence(result.metadata.windowContext)].compactMap(\.self)
                : []
        case let .window(window):
            operation.responseCarriesPostMutationWindowState
                ? []
                : window.map(Self.evidence).map { [$0] } ?? []
        case let .application(application):
            [Self.evidence(application)].compactMap(\.self)
        case let .preparedDialogAction(receipt):
            [.init(target: DesktopTargetIdentity(exactWindow: receipt.target))]
        case let .dialogResult(result):
            Self.evidence(result)
        case .focusedElement:
            []
        case let .error(envelope):
            [Self.evidence(envelope.actionTargetReceipt)].compactMap(\.self)
        default:
            []
        }
    }

    private static func evidence(_ metadata: CaptureMetadata) -> [DesktopTargetIdentity.Evidence] {
        [
            self.evidence(metadata.applicationInfo),
            metadata.windowInfo.map(self.evidence),
        ].compactMap(\.self)
    }

    private static func evidence(_ context: WindowContext?) -> DesktopTargetIdentity.Evidence? {
        guard let context else { return nil }
        return .init(
            processIdentifier: context.applicationProcessId,
            windowID: context.windowID,
            windowIdentity: context.windowMutationIdentity,
            windowBounds: context.windowBounds,
            focusedElement: context.focusedElement)
    }

    private static func evidence(_ window: WindowIdentity?) -> DesktopTargetIdentity.Evidence? {
        guard let window else { return nil }
        return .init(windowID: window.windowID, windowBounds: window.bounds)
    }

    private static func evidence(_ window: ServiceWindowInfo) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: window.mutationIdentity?.ownerProcessIdentifier,
            processIdentity: window.mutationIdentity?.processIdentity,
            windowID: window.windowID,
            windowIdentity: window.mutationIdentity,
            windowBounds: window.bounds)
    }

    private static func evidence(_ identity: WindowMutationIdentity) -> DesktopTargetIdentity.Evidence {
        .init(
            processIdentifier: identity.ownerProcessIdentifier,
            processIdentity: identity.processIdentity,
            windowID: identity.windowID,
            windowIdentity: identity,
            windowBounds: identity.capturedBounds)
    }

    private static func evidence(_ application: ApplicationIdentity?) -> DesktopTargetIdentity.Evidence? {
        guard let application else { return nil }
        return .init(
            processIdentifier: application.processIdentifier,
            processIdentity: application.processStartIdentity.map {
                .init(
                    processIdentifier: application.processIdentifier,
                    processStartIdentity: $0)
            })
    }

    private static func evidence(
        _ application: ServiceApplicationInfo?) -> DesktopTargetIdentity.Evidence?
    {
        guard let application else { return nil }
        return .init(
            processIdentifier: application.processIdentifier,
            processIdentity: application.processStartIdentity.map {
                .init(
                    processIdentifier: application.processIdentifier,
                    processStartIdentity: $0)
            })
    }

    private static func evidence(_ result: DialogActionResult) -> [DesktopTargetIdentity.Evidence] {
        var evidence: [DesktopTargetIdentity.Evidence] = []
        if result.targetWindowIdentity != nil || result.targetWindowBounds != nil || result.focusedElement != nil {
            evidence.append(.init(
                processIdentifier: result.targetWindowIdentity?.ownerProcessIdentifier,
                processIdentity: result.targetWindowIdentity?.processIdentity,
                windowID: result.targetWindowIdentity?.windowID,
                windowIdentity: result.targetWindowIdentity,
                windowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement))
        }
        if let receiptEvidence = self.evidence(result.targetReceipt) {
            evidence.append(receiptEvidence)
        }
        return evidence
    }

    private static func evidence(
        _ receipt: DesktopActionTargetReceipt?) -> DesktopTargetIdentity.Evidence?
    {
        guard let receipt else { return nil }
        return .init(
            processIdentifier: receipt.processIdentifier,
            processIdentity: .init(
                processIdentifier: receipt.processIdentifier,
                processStartIdentity: receipt.processStartIdentity),
            windowID: receipt.windowID)
    }
}

extension PeekabooBridgeOperation {
    fileprivate var responseCarriesPostMutationWindowState: Bool {
        switch self {
        case .focusWindow,
             .moveWindow,
             .resizeWindow,
             .setWindowBounds,
             .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow,
             .restoreWindow,
             .maximizeWindow:
            true
        default:
            false
        }
    }
}
