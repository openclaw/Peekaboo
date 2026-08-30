import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

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
    case browser(PeekabooBridgeBrowserConnectionReceipt)

    private enum CodingKeys: String, CodingKey {
        case kind
        case processIdentifier
        case processStartIdentity
        case windowID
        case capturedBounds
        case isMinimized
        case browserConnectionReceipt
    }

    private enum Kind: String, Codable {
        case global
        case process
        case window
        case browser
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
        case .browser:
            let receipt = try container.decode(
                PeekabooBridgeBrowserConnectionReceipt.self,
                forKey: .browserConnectionReceipt)
            guard receipt.isCanonicalExternalTarget else {
                throw DecodingError.dataCorruptedError(
                    forKey: .browserConnectionReceipt,
                    in: container,
                    debugDescription: "Bridge browser target receipt is incomplete or inconsistent")
            }
            self = .browser(receipt)
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
        case let .browser(receipt):
            guard receipt.isCanonicalExternalTarget else {
                throw EncodingError.invalidValue(
                    receipt,
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "Bridge browser target receipt is incomplete or inconsistent"))
            }
            try container.encode(Kind.browser, forKey: .kind)
            try container.encode(receipt, forKey: .browserConnectionReceipt)
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
        case snapshotSourceMismatch = "snapshot_source_mismatch"
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
        case .snapshotSourceMismatch: .snapshotSourceMismatch
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

/// A listener-signed, peer-bound replay domain for a bounded sequence of operations.
///
/// The listener identity remains stable for the socket lifetime. Sessions can therefore roll over
/// without invalidating receipts that an older session is still completing.
public struct PeekabooBridgeOperationSessionAttestation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let sessionID: UUID
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let clientInstanceID: UUID
    public let client: PeekabooBridgeOperationProcessIdentity
    public let maximumRequestCount: Int
    public let remainingClaimCount: Int
    public let predecessorSessionID: UUID?
    public let createdAtUnixMilliseconds: Int64
    public let signature: Data

    init(
        sessionID: UUID,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        clientInstanceID: UUID,
        client: PeekabooBridgeOperationProcessIdentity,
        maximumRequestCount: Int,
        remainingClaimCount: Int,
        predecessorSessionID: UUID?,
        createdAtUnixMilliseconds: Int64,
        signature: Data)
    {
        self.schemaVersion = 1
        self.sessionID = sessionID
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.clientInstanceID = clientInstanceID
        self.client = client
        self.maximumRequestCount = maximumRequestCount
        self.remainingClaimCount = remainingClaimCount
        self.predecessorSessionID = predecessorSessionID
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.signature = signature
    }

    public func validateSignature(listenerAttestation: PeekabooBridgeListenerAttestation) throws {
        try listenerAttestation.validateSignature()
        guard self.schemaVersion == 1,
              self.listenerInstanceID == listenerAttestation.listenerInstanceID,
              self.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  listenerAttestation.publicKey),
              self.client.processIdentifier > 0,
              self.client.processStartIdentity > 0,
              !self.client.codeSignatureHash.isEmpty,
              self.maximumRequestCount > 0,
              self.remainingClaimCount >= 0,
              self.remainingClaimCount <= self.maximumRequestCount,
              self.predecessorSessionID != self.sessionID,
              self.createdAtUnixMilliseconds > 0
        else {
            throw PeekabooBridgeOperationReceiptError.invalidOperationSessionAttestation
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: listenerAttestation.publicKey)
        } catch {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        guard try key.isValidSignature(
            self.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(self.unsignedPayload))
        else {
            throw PeekabooBridgeOperationReceiptError.invalidOperationSessionSignature
        }
    }

    var unsignedPayload: UnsignedPayload {
        UnsignedPayload(
            schemaVersion: self.schemaVersion,
            sessionID: self.sessionID,
            listenerInstanceID: self.listenerInstanceID,
            listenerPublicKeySHA256: self.listenerPublicKeySHA256,
            clientInstanceID: self.clientInstanceID,
            client: self.client,
            maximumRequestCount: self.maximumRequestCount,
            remainingClaimCount: self.remainingClaimCount,
            predecessorSessionID: self.predecessorSessionID,
            createdAtUnixMilliseconds: self.createdAtUnixMilliseconds)
    }

    struct UnsignedPayload: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let sessionID: UUID
        let listenerInstanceID: UUID
        let listenerPublicKeySHA256: String
        let clientInstanceID: UUID
        let client: PeekabooBridgeOperationProcessIdentity
        let maximumRequestCount: Int
        let remainingClaimCount: Int
        let predecessorSessionID: UUID?
        let createdAtUnixMilliseconds: Int64
    }
}

/// Lossless wire representation of a protocol-1.29 operation sequence number.
///
/// JSON numbers do not preserve every `UInt64`, so the canonical wire value is a decimal string.
public struct PeekabooBridgeOperationSessionSequence: Codable, Equatable, Hashable, Sendable, Comparable {
    public let value: UInt64

    public init(_ value: UInt64) {
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decimal = try container.decode(String.self)
        guard let value = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Bridge operation session sequence is not canonical")
        }
        self.init(value)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(self.value))
    }

    public static func < (
        lhs: PeekabooBridgeOperationSessionSequence,
        rhs: PeekabooBridgeOperationSessionSequence) -> Bool
    {
        lhs.value < rhs.value
    }
}

// One unique, listener-bound operation request.

public struct PeekabooBridgeAttestedOperationResponse: Codable, Sendable {
    public let response: PeekabooBridgeResponse
    public let receipt: PeekabooBridgeOperationReceipt

    public init(response: PeekabooBridgeResponse, receipt: PeekabooBridgeOperationReceipt) {
        self.response = response
        self.receipt = receipt
    }
}

/// Listener-signed proof that an operation was refused before dispatch and must use a successor session.
public struct PeekabooBridgeOperationSessionRefusal: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable {
        case sessionRolloverRequired = "session_rollover_required"
        case sessionRolloverUnavailable = "session_rollover_unavailable"
    }

    public let payload: Payload
    public let signature: Data

    public init(payload: Payload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public func validate(
        listenerAttestation: PeekabooBridgeListenerAttestation,
        predecessorSession: PeekabooBridgeOperationSessionAttestation,
        request: PeekabooBridgeAttestedOperationRequest) throws
    {
        try listenerAttestation.validateSignature()
        try predecessorSession.validateSignature(listenerAttestation: listenerAttestation)
        if let successor = self.payload.successorSessionAttestation {
            try successor.validateSignature(listenerAttestation: listenerAttestation)
        }
        try request.validateEnvelope()
        guard self.payload.schemaVersion == 1,
              self.payload.listenerInstanceID == listenerAttestation.listenerInstanceID,
              self.payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  listenerAttestation.publicKey),
              self.payload.sessionID == predecessorSession.sessionID,
              self.payload.clientInstanceID == predecessorSession.clientInstanceID,
              self.payload.client == predecessorSession.client,
              self.payload.requestID == request.requestID,
              self.payload.sessionID == request.sessionID,
              self.payload.sessionSequence == request.sessionSequence,
              self.payload.clientInstanceID == request.clientInstanceID,
              self.payload.client == request.client,
              request.expectedListenerInstanceID == listenerAttestation.listenerInstanceID,
              self.payload.operation == request.request.operation,
              try self.payload.requestSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(request.request),
              try self.payload.attestedRequestSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(request),
              self.payload.hasValidSuccessorState(predecessorSession: predecessorSession),
              !self.payload.mutationDispatched,
              self.payload.retrySafe,
              self.payload.refusedAtUnixMilliseconds > 0
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the operation session rollover refusal")
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: listenerAttestation.publicKey)
        } catch {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        guard try key.isValidSignature(
            self.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(self.payload))
        else {
            throw PeekabooBridgeOperationReceiptError.invalidOperationSessionSignature
        }
    }

    public struct Payload: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let listenerInstanceID: UUID
        public let listenerPublicKeySHA256: String
        public let sessionID: UUID
        public let sessionSequence: PeekabooBridgeOperationSessionSequence
        public let requestID: UUID
        public let clientInstanceID: UUID
        public let client: PeekabooBridgeOperationProcessIdentity
        public let operation: PeekabooBridgeOperation
        public let requestSHA256: String
        public let attestedRequestSHA256: String
        public let successorSessionAttestation: PeekabooBridgeOperationSessionAttestation?
        public let disposition: Disposition
        public let mutationDispatched: Bool
        public let retrySafe: Bool
        public let refusedAtUnixMilliseconds: Int64

        init(
            listenerInstanceID: UUID,
            listenerPublicKeySHA256: String,
            sessionID: UUID,
            sessionSequence: PeekabooBridgeOperationSessionSequence,
            requestID: UUID,
            clientInstanceID: UUID,
            client: PeekabooBridgeOperationProcessIdentity,
            operation: PeekabooBridgeOperation,
            requestSHA256: String,
            attestedRequestSHA256: String,
            disposition: Disposition,
            successorSessionAttestation: PeekabooBridgeOperationSessionAttestation?,
            refusedAtUnixMilliseconds: Int64)
        {
            self.schemaVersion = 1
            self.listenerInstanceID = listenerInstanceID
            self.listenerPublicKeySHA256 = listenerPublicKeySHA256
            self.sessionID = sessionID
            self.sessionSequence = sessionSequence
            self.requestID = requestID
            self.clientInstanceID = clientInstanceID
            self.client = client
            self.operation = operation
            self.requestSHA256 = requestSHA256
            self.attestedRequestSHA256 = attestedRequestSHA256
            self.disposition = disposition
            self.successorSessionAttestation = successorSessionAttestation
            self.mutationDispatched = false
            self.retrySafe = true
            self.refusedAtUnixMilliseconds = refusedAtUnixMilliseconds
        }

        fileprivate func hasValidSuccessorState(
            predecessorSession: PeekabooBridgeOperationSessionAttestation) -> Bool
        {
            switch (self.disposition, self.successorSessionAttestation) {
            case let (.sessionRolloverRequired, successor?):
                successor.predecessorSessionID == predecessorSession.sessionID &&
                    successor.clientInstanceID == predecessorSession.clientInstanceID &&
                    successor.client == predecessorSession.client
            case (.sessionRolloverUnavailable, nil):
                true
            default:
                false
            }
        }
    }
}
