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

enum PeekabooBridgeOperationReceiptError: Error, LocalizedError, Equatable, Sendable {
    case invalidListenerAttestation
    case invalidListenerSignature
    case invalidOperationSessionAttestation
    case invalidOperationSessionSignature
    case invalidOperationSessionConfiguration
    case listenerInstanceMismatch
    case operationSessionMismatch
    case operationSessionRegistryExhausted
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
        case .invalidOperationSessionAttestation:
            "Bridge operation session attestation is incomplete or malformed"
        case .invalidOperationSessionSignature:
            "Bridge operation session attestation or rollover signature is invalid"
        case .invalidOperationSessionConfiguration:
            "Bridge operation session capacity and retention limits are invalid"
        case .listenerInstanceMismatch:
            "Bridge listener instance changed after handshake"
        case .operationSessionMismatch:
            "Bridge operation request does not match its peer-bound session"
        case .operationSessionRegistryExhausted:
            "Bridge operation session registry is at capacity"
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
    private static let requestIDDomain = Data("peekaboo.bridge.operation-request.v1\0".utf8)

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

    /// Derives an RFC 9562 version-8 UUID for diagnostics and archive correlation.
    ///
    /// Replay protection keys the complete `(sessionID, sequence)` tuple; the UUID is never used
    /// as a lossy substitute for that tuple.
    static func deterministicRequestID(
        sessionID: UUID,
        sequence: PeekabooBridgeOperationSessionSequence) -> UUID
    {
        let sessionBytes = withUnsafeBytes(of: sessionID.uuid) { Data($0) }
        var bigEndianSequence = sequence.value.bigEndian
        let sequenceBytes = withUnsafeBytes(of: &bigEndianSequence) { Data($0) }
        var input = self.requestIDDomain
        input.append(sessionBytes)
        input.append(sequenceBytes)
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

/// Ephemeral listener signer, bounded session replay fences, and private durable receipt archive.
final class PeekabooBridgeOperationReceiptAuthority: @unchecked Sendable {
    struct SessionAuthorization: Sendable {
        let peer: PeekabooBridgePeer
        let pin: SessionAuthorizationPin
    }

    final class SessionAuthorizationPin: @unchecked Sendable {
        private let lock = NSLock()
        private var authority: PeekabooBridgeOperationReceiptAuthority?
        private let sessionID: UUID

        init(authority: PeekabooBridgeOperationReceiptAuthority, sessionID: UUID) {
            self.authority = authority
            self.sessionID = sessionID
        }

        deinit {
            self.release()
        }

        func release() {
            let authority = self.lock.withLock { () -> PeekabooBridgeOperationReceiptAuthority? in
                defer { self.authority = nil }
                return self.authority
            }
            authority?.releaseAuthorizationPin(sessionID: self.sessionID)
        }
    }

    private static let defaultMaximumClaimCount = 16384
    private static let defaultMaximumSessionCount = 64
    private static let defaultMaximumActiveSessionCountPerPeer = 4
    private static let defaultRetainedRetiredSessionCount = 16
    private static let retainedListenerDirectoryCount = 16

    let attestation: PeekabooBridgeListenerAttestation

    private let privateKey: Curve25519.Signing.PrivateKey
    private let archiveDirectory: URL
    private let sessionArchiveRoot: URL
    private let archiveTrashRoot: URL
    private let maximumClaimCount: Int
    private let maximumSessionCount: Int
    private let maximumActiveSessionCount: Int
    private let maximumActiveSessionCountPerPeer: Int
    private let retainedRetiredSessionCount: Int
    private let archiveMaintenance: PeekabooBridgeOperationReceiptArchiveMaintenance
    private let sessionAttestationWriter: @Sendable (Data, URL) throws -> Void
    private let lock = NSLock()
    private let signingLock = NSLock()
    private var sessions: [UUID: OperationSessionState] = [:]
    private var sessionCreations: [OperationSessionCreationKey: OperationSessionCreationReservation] = [:]
    private var sessionOrdinal: UInt64 = 0

    private enum OperationSessionCreationAction {
        case immediate(PeekabooBridgeOperationSessionAttestation)
        case wait(OperationSessionCreationReservation)
        case persist(OperationSessionCreationReservation)
        case archiveMaintenanceRequired
        case failure(PeekabooBridgeOperationReceiptError)
    }

    private enum OperationSessionClaimPreparation {
        case accepted(PeekabooBridgeOperationSessionClaim)
        case rollover(
            predecessor: PeekabooBridgeOperationSessionAttestation,
            negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
            creation: OperationSessionCreationAction)
    }

    init(
        socketPath: String,
        maximumClaimCount: Int = PeekabooBridgeOperationReceiptAuthority.defaultMaximumClaimCount,
        maximumSessionCount: Int = PeekabooBridgeOperationReceiptAuthority.defaultMaximumSessionCount,
        maximumActiveSessionCountPerPeer: Int =
            PeekabooBridgeOperationReceiptAuthority.defaultMaximumActiveSessionCountPerPeer,
        retainedRetiredSessionCount: Int =
            PeekabooBridgeOperationReceiptAuthority.defaultRetainedRetiredSessionCount,
        archiveFileSystem: PeekabooBridgeOperationReceiptArchiveFileSystem = .live,
        sessionAttestationWriter: @escaping @Sendable (Data, URL) throws -> Void = {
            try PeekabooBridgePrivateReceiptArchive.writeAtomically($0, to: $1)
        }) throws
    {
        guard maximumClaimCount > 0,
              maximumClaimCount <= Self.defaultMaximumClaimCount,
              maximumSessionCount > 0,
              maximumActiveSessionCountPerPeer > 0,
              retainedRetiredSessionCount > 0,
              retainedRetiredSessionCount < maximumSessionCount
        else {
            throw PeekabooBridgeOperationReceiptError.invalidOperationSessionConfiguration
        }
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
        let socketNamespace = PeekabooBridgeOperationReceiptCoding.sha256(Data(socketPath.utf8))
        let archiveRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooOperationReceipts", isDirectory: true)
            .appendingPathComponent(socketNamespace, isDirectory: true)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveRoot)
        let archiveDirectory = archiveRoot.appendingPathComponent(
            listenerInstanceID.uuidString.lowercased(),
            isDirectory: true)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveDirectory)
        let sessionArchiveRoot = archiveDirectory.appendingPathComponent("sessions", isDirectory: true)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(sessionArchiveRoot)
        let archiveTrashRoot = archiveDirectory.appendingPathComponent("retired-sessions", isDirectory: true)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveTrashRoot)
        try Self.pruneOldListenerDirectories(in: archiveRoot, excluding: archiveDirectory)

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
        self.sessionArchiveRoot = sessionArchiveRoot
        self.archiveTrashRoot = archiveTrashRoot
        self.maximumClaimCount = maximumClaimCount
        self.maximumSessionCount = maximumSessionCount
        self.maximumActiveSessionCount = max(1, maximumSessionCount / 2)
        self.maximumActiveSessionCountPerPeer = maximumActiveSessionCountPerPeer
        self.retainedRetiredSessionCount = retainedRetiredSessionCount
        self.archiveMaintenance = PeekabooBridgeOperationReceiptArchiveMaintenance(
            fileSystem: archiveFileSystem,
            capacityBacklogLimit: maximumSessionCount)
        self.sessionAttestationWriter = sessionAttestationWriter
        self.attestation = attestation
    }

    func createSession(
        clientInstanceID: UUID,
        peer: PeekabooBridgePeer,
        negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities = .current,
        replacing predecessorSessionID: UUID? = nil) async throws -> PeekabooBridgeOperationSessionAttestation
    {
        self.scheduleRetiredSessionArchiveCleanup()
        defer { self.scheduleRetiredSessionArchiveCleanup() }
        let peerBinding = try OperationSessionPeerBinding(peer: peer)
        let action = try self.prepareSessionCreation(
            clientInstanceID: clientInstanceID,
            peerBinding: peerBinding,
            negotiatedCapabilities: negotiatedCapabilities,
            replacing: predecessorSessionID)
        return try await self.resolveSessionCreation(
            action,
            clientInstanceID: clientInstanceID,
            peerBinding: peerBinding,
            negotiatedCapabilities: negotiatedCapabilities,
            replacing: predecessorSessionID)
    }

    /// Permits only a bounded request read. Exact session authorization still occurs after the single wire decode.
    func hasProvisionalSession(for liveIdentity: PeekabooBridgeLivePeerIdentity) -> Bool {
        guard liveIdentity.codeSignatureHash?.isEmpty == false else { return false }
        return self.lock.withLock {
            self.sessions.values.contains { $0.peerBinding.liveIdentity == liveIdentity }
        }
    }

    /// Pins and returns the trusted peer cached by one exact logical session without consuming replay state.
    func authorizeSession(
        sessionID: UUID,
        liveIdentity: PeekabooBridgeLivePeerIdentity) -> SessionAuthorization?
    {
        guard liveIdentity.codeSignatureHash?.isEmpty == false else { return nil }
        return self.lock.withLock {
            guard let session = self.sessions[sessionID],
                  session.peerBinding.liveIdentity == liveIdentity
            else {
                return nil
            }
            session.authorizationPinCount += 1
            return SessionAuthorization(
                peer: session.peerBinding.peer,
                pin: SessionAuthorizationPin(authority: self, sessionID: sessionID))
        }
    }

    private func releaseAuthorizationPin(sessionID: UUID) {
        self.lock.withLock {
            guard let session = self.sessions[sessionID], session.authorizationPinCount > 0 else { return }
            session.authorizationPinCount -= 1
            self.pruneRetiredSessionsLocked()
        }
        self.scheduleRetiredSessionArchiveCleanup()
    }

    private func prepareSessionCreation(
        clientInstanceID: UUID,
        peerBinding: OperationSessionPeerBinding,
        negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
        replacing predecessorSessionID: UUID?) throws -> OperationSessionCreationAction
    {
        self.retireDeadClientSessions(replacingWith: peerBinding)
        return try self.lock.withLock {
            try self.prepareSessionCreationLocked(
                clientInstanceID: clientInstanceID,
                peerBinding: peerBinding,
                negotiatedCapabilities: negotiatedCapabilities,
                replacing: predecessorSessionID)
        }
    }

    func retireSession(
        _ sessionID: UUID,
        clientInstanceID: UUID,
        peer: PeekabooBridgePeer) throws
    {
        self.scheduleRetiredSessionArchiveCleanup()
        defer { self.scheduleRetiredSessionArchiveCleanup() }
        let peerBinding = try OperationSessionPeerBinding(peer: peer)
        self.lock.lock()
        guard let session = self.sessions[sessionID],
              session.attestation.clientInstanceID == clientInstanceID,
              session.peerBinding == peerBinding
        else {
            self.lock.unlock()
            throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
        }
        session.acceptingClaims = false
        self.pruneRetiredSessionsLocked()
        self.lock.unlock()
    }

    func claim(
        _ payload: PeekabooBridgeAttestedOperationRequest,
        peer: PeekabooBridgePeer,
        currentProcessStartIdentity: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity) async throws
        -> PeekabooBridgeOperationSessionClaimResult
    {
        self.scheduleRetiredSessionArchiveCleanup()
        defer { self.scheduleRetiredSessionArchiveCleanup() }
        try payload.validateEnvelope()
        let peerBinding = try OperationSessionPeerBinding(peer: peer)
        guard payload.expectedListenerInstanceID == self.attestation.listenerInstanceID else {
            throw PeekabooBridgeOperationReceiptError.listenerInstanceMismatch
        }
        guard payload.client == peerBinding.client,
              currentProcessStartIdentity(peer.processIdentifier) == payload.client.processStartIdentity
        else {
            throw PeekabooBridgeOperationReceiptError.clientIdentityMismatch
        }
        let preparation = try self.lock.withLock { () throws -> OperationSessionClaimPreparation in
            guard let session = self.sessions[payload.sessionID],
                  session.attestation.clientInstanceID == payload.clientInstanceID,
                  session.attestation.client == payload.client,
                  session.peerBinding == peerBinding
            else {
                throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
            }
            let sequence = payload.sessionSequence.value
            if sequence >= UInt64(session.attestation.maximumRequestCount) {
                return .rollover(
                    predecessor: session.attestation,
                    negotiatedCapabilities: session.negotiatedCapabilities,
                    creation: self.prepareRolloverCreationLocked(session: session))
            }
            if session.isClaimed(sequence) {
                throw PeekabooBridgeOperationReceiptError.replayedRequest
            }
            guard session.acceptingClaims else {
                return .rollover(
                    predecessor: session.attestation,
                    negotiatedCapabilities: session.negotiatedCapabilities,
                    creation: self.prepareRolloverCreationLocked(session: session))
            }
            session.markClaimed(sequence)
            session.inFlightCount += 1
            let remainingClaimCount = session.attestation.maximumRequestCount - session.claimedCount
            let claim = PeekabooBridgeOperationSessionClaim(
                requestID: payload.requestID,
                sessionID: payload.sessionID,
                sessionSequence: payload.sessionSequence,
                sessionAttestation: session.attestation,
                negotiatedCapabilities: session.negotiatedCapabilities,
                remainingClaimCount: remainingClaimCount)
            return .accepted(claim)
        }
        switch preparation {
        case let .accepted(claim):
            return .accepted(claim)
        case let .rollover(predecessor, negotiatedCapabilities, creation):
            let successor: PeekabooBridgeOperationSessionAttestation?
            let disposition: PeekabooBridgeOperationSessionRefusal.Disposition
            do {
                successor = try await self.resolveSessionCreation(
                    creation,
                    clientInstanceID: predecessor.clientInstanceID,
                    peerBinding: peerBinding,
                    negotiatedCapabilities: negotiatedCapabilities,
                    replacing: predecessor.sessionID)
                disposition = .sessionRolloverRequired
            } catch {
                successor = nil
                disposition = .sessionRolloverUnavailable
            }
            return try .rolloverRequired(self.makeRolloverRefusal(
                payload: payload,
                predecessor: predecessor,
                successor: successor,
                disposition: disposition))
        }
    }

    func complete(_ claim: PeekabooBridgeOperationSessionClaim) {
        guard claim.beginCompletion() else { return }
        defer { self.scheduleRetiredSessionArchiveCleanup() }
        self.lock.lock()
        if let session = self.sessions[claim.sessionID], session.inFlightCount > 0 {
            session.inFlightCount -= 1
        }
        self.pruneRetiredSessionsLocked()
        self.lock.unlock()
    }

    func signAndArchive(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        claim: PeekabooBridgeOperationSessionClaim) async throws -> PeekabooBridgeOperationReceipt
    {
        guard payload.listenerInstanceID == self.attestation.listenerInstanceID else {
            throw PeekabooBridgeOperationReceiptError.listenerInstanceMismatch
        }
        guard payload.requestID == claim.requestID,
              payload.sessionID == claim.sessionID,
              payload.sessionSequence == claim.sessionSequence,
              try payload.sessionAttestationSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  claim.sessionAttestation),
              payload.clientInstanceID == claim.sessionAttestation.clientInstanceID,
              payload.client == claim.sessionAttestation.client,
              payload.remainingClaimCount == claim.remainingClaimCount
        else {
            throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
        }
        guard claim.beginSigning() else {
            throw PeekabooBridgeOperationReceiptError.replayedRequest
        }
        return try await Task.detached(priority: .userInitiated) { [self] in
            let signature = try self.signCanonical(payload)
            let receipt = PeekabooBridgeOperationReceipt(payload: payload, signature: signature)
            let data = try PeekabooBridgeOperationReceiptCoding.canonicalData(receipt)
            let destination = self.sessionArchiveDirectory(sessionID: payload.sessionID).appendingPathComponent(
                String(payload.sessionSequence.value) + ".json",
                isDirectory: false)
            try PeekabooBridgePrivateReceiptArchive.writeAtomically(data, to: destination)
            return receipt
        }.value
    }

    private func signCanonical(_ payload: some Encodable) throws -> Data {
        self.signingLock.lock()
        defer { self.signingLock.unlock() }
        return try self.privateKey.signature(
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(payload))
    }

    private func prepareSessionCreationLocked(
        clientInstanceID: UUID,
        peerBinding: OperationSessionPeerBinding,
        negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
        replacing predecessorSessionID: UUID?) throws -> OperationSessionCreationAction
    {
        let creationKey = OperationSessionCreationKey(
            clientInstanceID: clientInstanceID,
            peerBinding: peerBinding,
            negotiatedCapabilities: negotiatedCapabilities,
            predecessorSessionID: predecessorSessionID)
        if let existingCreation = self.sessionCreations[creationKey] {
            return .wait(existingCreation)
        }
        let capacityReplacementSessionID: UUID?
        if let predecessorSessionID {
            guard let predecessor = self.sessions[predecessorSessionID],
                  predecessor.attestation.clientInstanceID == clientInstanceID,
                  predecessor.peerBinding == peerBinding
            else {
                throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
            }
            if let successorSessionID = predecessor.successorSessionID {
                guard let successor = self.sessions[successorSessionID],
                      successor.negotiatedCapabilities == negotiatedCapabilities
                else {
                    throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
                }
                return .immediate(successor.attestation)
            }
            if !predecessor.acceptingClaims {
                capacityReplacementSessionID = try self.capacityReplacementSessionIDLocked(
                    peerBinding: peerBinding,
                    excludingSessionID: predecessorSessionID)
            } else {
                capacityReplacementSessionID = nil
            }
        } else {
            let matchingSession = self.sessions.values.first(where: {
                $0.acceptingClaims &&
                    $0.attestation.clientInstanceID == clientInstanceID &&
                    $0.negotiatedCapabilities == negotiatedCapabilities &&
                    $0.peerBinding == peerBinding
            })
            if let matchingSession, matchingSession.claimedCount == 0 {
                return .immediate(matchingSession.attestation)
            }
            guard matchingSession == nil else {
                throw PeekabooBridgeOperationReceiptError.operationSessionMismatch
            }
            capacityReplacementSessionID = try self.capacityReplacementSessionIDLocked(
                peerBinding: peerBinding)
        }

        if self.archiveMaintenance.backlogIsSaturated {
            return .archiveMaintenanceRequired
        }
        self.pruneRetiredSessionsLocked(
            removeUntilBelowMaximum: true,
            excludingSessionID: predecessorSessionID)
        let registryIsFull = self.sessions.count + self.sessionCreations.count >= self.maximumSessionCount
        if self.archiveMaintenance.backlogIsSaturated ||
            (registryIsFull && self.archiveMaintenance.hasUncommittedRetiredSession)
        {
            return .archiveMaintenanceRequired
        }
        guard !registryIsFull else {
            throw PeekabooBridgeOperationReceiptError.operationSessionRegistryExhausted
        }
        let reservedSessionIDs = Set(self.sessionCreations.values.map(\.sessionID))
        var sessionID = UUID()
        while self.sessions[sessionID] != nil || reservedSessionIDs.contains(sessionID) {
            sessionID = UUID()
        }
        if let capacityReplacementSessionID {
            guard let replacedSession = self.sessions[capacityReplacementSessionID],
                  replacedSession.capacityReplacementSessionID == nil
            else {
                throw PeekabooBridgeOperationReceiptError.operationSessionRegistryExhausted
            }
            replacedSession.capacityReplacementSessionID = sessionID
        }
        let unsigned = PeekabooBridgeOperationSessionAttestation.UnsignedPayload(
            schemaVersion: 1,
            sessionID: sessionID,
            listenerInstanceID: self.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(self.attestation.publicKey),
            clientInstanceID: clientInstanceID,
            client: peerBinding.client,
            maximumRequestCount: self.maximumClaimCount,
            remainingClaimCount: self.maximumClaimCount,
            predecessorSessionID: predecessorSessionID,
            createdAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds())
        self.sessionOrdinal &+= 1
        let reservation = OperationSessionCreationReservation(
            key: creationKey,
            sessionID: sessionID,
            unsignedAttestation: unsigned,
            peerBinding: peerBinding,
            ordinal: self.sessionOrdinal,
            capacityReplacementSessionID: capacityReplacementSessionID)
        self.sessionCreations[creationKey] = reservation
        return .persist(reservation)
    }

    /// Reserves capacity for a creation that adds one accepting session instead of replacing one.
    ///
    /// A fresh logical client has no transport lifetime: bridge sockets are per request, so an
    /// abandoned client cannot be distinguished from an idle one. At the peer cap, retire only the
    /// oldest quiescent session and retain its replay fence. A late request then follows the signed
    /// rollover path; in-flight and predecessor/successor-owned sessions are never displaced.
    private func capacityReplacementSessionIDLocked(
        peerBinding: OperationSessionPeerBinding,
        excludingSessionID: UUID? = nil) throws -> UUID?
    {
        let counts = self.additionalActiveSessionCapacityCountsLocked(peerBinding: peerBinding)
        if counts.peer >= self.maximumActiveSessionCountPerPeer {
            guard counts.global <= self.maximumActiveSessionCount,
                  counts.peer == self.maximumActiveSessionCountPerPeer,
                  let replacementSessionID = self.oldestQuiescentPeerSessionIDLocked(
                      peerBinding: peerBinding,
                      excludingSessionID: excludingSessionID)
            else {
                throw PeekabooBridgeOperationReceiptError.operationSessionRegistryExhausted
            }
            return replacementSessionID
        }
        guard counts.global < self.maximumActiveSessionCount,
              counts.peer < self.maximumActiveSessionCountPerPeer
        else {
            throw PeekabooBridgeOperationReceiptError.operationSessionRegistryExhausted
        }
        return nil
    }

    private func additionalActiveSessionCapacityCountsLocked(
        peerBinding: OperationSessionPeerBinding) -> (global: Int, peer: Int)
    {
        let acceptingSessions = self.sessions.values.filter(\.acceptingClaims)
        let additionalCreations = self.sessionCreations.values.filter { reservation in
            let addsAcceptingSession: Bool = if let predecessorSessionID = reservation.predecessorSessionID,
                                                let predecessor = self.sessions[predecessorSessionID]
            {
                !predecessor.acceptingClaims
            } else {
                true
            }
            guard addsAcceptingSession else { return false }
            guard let replacementSessionID = reservation.capacityReplacementSessionID,
                  let replacement = self.sessions[replacementSessionID],
                  replacement.acceptingClaims,
                  replacement.capacityReplacementSessionID == reservation.sessionID
            else { return true }
            return false
        }
        return (
            global: acceptingSessions.count + additionalCreations.count,
            peer: acceptingSessions.count(where: { $0.peerBinding == peerBinding }) +
                additionalCreations.count(where: { $0.peerBinding == peerBinding }))
    }

    private func oldestQuiescentPeerSessionIDLocked(
        peerBinding: OperationSessionPeerBinding,
        excludingSessionID: UUID?) -> UUID?
    {
        let referencedSuccessorSessionIDs = Set(self.sessions.values.compactMap(\.successorSessionID))
        let reservedPredecessorSessionIDs = Set(self.sessionCreations.values.compactMap(\.predecessorSessionID))
        guard let session = self.sessions.values
            .filter({
                $0.acceptingClaims &&
                    $0.peerBinding == peerBinding &&
                    $0.inFlightCount == 0 &&
                    $0.authorizationPinCount == 0 &&
                    $0.archiveCleanupReservationID == nil &&
                    $0.capacityReplacementSessionID == nil &&
                    $0.attestation.sessionID != excludingSessionID &&
                    $0.successorSessionID == nil &&
                    !referencedSuccessorSessionIDs.contains($0.attestation.sessionID) &&
                    !reservedPredecessorSessionIDs.contains($0.attestation.sessionID)
            })
            .min(by: { $0.ordinal < $1.ordinal })
        else { return nil }
        return session.attestation.sessionID
    }

    private func resolveSessionCreation(
        _ initialAction: OperationSessionCreationAction,
        clientInstanceID: UUID,
        peerBinding: OperationSessionPeerBinding,
        negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
        replacing predecessorSessionID: UUID?) async throws -> PeekabooBridgeOperationSessionAttestation
    {
        var action = initialAction
        while true {
            switch action {
            case let .immediate(attestation):
                return attestation
            case let .failure(error):
                throw error
            case .archiveMaintenanceRequired:
                guard await self.performRequiredArchiveMaintenance() else {
                    throw PeekabooBridgeOperationReceiptError.operationSessionRegistryExhausted
                }
                action = try self.prepareSessionCreation(
                    clientInstanceID: clientInstanceID,
                    peerBinding: peerBinding,
                    negotiatedCapabilities: negotiatedCapabilities,
                    replacing: predecessorSessionID)
            case let .wait(reservation):
                return try await reservation.waitForResult()
            case let .persist(reservation):
                let persistenceResult = await Task.detached(priority: .utility) { [self] in
                    do {
                        return try Result<
                            PeekabooBridgeOperationSessionAttestation,
                            PeekabooBridgeOperationReceiptError,
                        >.success(self.persistSessionAttestation(reservation))
                    } catch let error as PeekabooBridgeOperationReceiptError {
                        return .failure(error)
                    } catch {
                        return .failure(.archiveWriteFailed(error.localizedDescription))
                    }
                }.value
                let result = self.commitSessionCreation(reservation, persistenceResult: persistenceResult)
                reservation.resolve(result)
                return try result.get()
            }
        }
    }

    private func commitSessionCreation(
        _ reservation: OperationSessionCreationReservation,
        persistenceResult: Result<
            PeekabooBridgeOperationSessionAttestation,
            PeekabooBridgeOperationReceiptError,
        >)
        -> Result<PeekabooBridgeOperationSessionAttestation, PeekabooBridgeOperationReceiptError>
    {
        self.lock.withLock {
            let creationKey = reservation.key
            let sessionID = reservation.sessionID
            if case let .failure(error) = persistenceResult {
                if self.sessionCreations[creationKey] === reservation {
                    self.sessionCreations[creationKey] = nil
                }
                self.releaseCapacityReplacementLocked(reservation)
                self.queueArchiveCleanupLocked(self.sessionArchiveDirectory(sessionID: sessionID))
                return .failure(error)
            }
            guard case let .success(sessionAttestation) = persistenceResult,
                  self.sessionCreations[creationKey] === reservation
            else {
                let error = PeekabooBridgeOperationReceiptError.operationSessionMismatch
                self.releaseCapacityReplacementLocked(reservation)
                self.queueArchiveCleanupLocked(self.sessionArchiveDirectory(sessionID: sessionID))
                return .failure(error)
            }
            let capacityReplacement: OperationSessionState?
            if let replacementSessionID = reservation.capacityReplacementSessionID {
                let referencedSuccessorSessionIDs = Set(self.sessions.values.compactMap(\.successorSessionID))
                let reservedPredecessorSessionIDs = Set(
                    self.sessionCreations.values.compactMap(\.predecessorSessionID))
                guard let replacement = self.sessions[replacementSessionID],
                      replacement.capacityReplacementSessionID == sessionID,
                      replacement.acceptingClaims,
                      replacement.peerBinding == reservation.peerBinding,
                      replacement.inFlightCount == 0,
                      replacement.authorizationPinCount == 0,
                      replacement.archiveCleanupReservationID == nil,
                      replacement.successorSessionID == nil,
                      !referencedSuccessorSessionIDs.contains(replacementSessionID),
                      !reservedPredecessorSessionIDs.contains(replacementSessionID)
                else {
                    self.sessionCreations[creationKey] = nil
                    self.releaseCapacityReplacementLocked(reservation)
                    self.queueArchiveCleanupLocked(self.sessionArchiveDirectory(sessionID: sessionID))
                    return .failure(.operationSessionRegistryExhausted)
                }
                capacityReplacement = replacement
            } else {
                capacityReplacement = nil
            }
            if let predecessorSessionID = reservation.predecessorSessionID {
                guard let predecessor = self.sessions[predecessorSessionID],
                      predecessor.attestation.clientInstanceID == creationKey.clientInstanceID,
                      predecessor.peerBinding == reservation.peerBinding,
                      predecessor.successorSessionID == nil
                else {
                    self.sessionCreations[creationKey] = nil
                    let error = PeekabooBridgeOperationReceiptError.operationSessionMismatch
                    self.releaseCapacityReplacementLocked(reservation)
                    self.queueArchiveCleanupLocked(self.sessionArchiveDirectory(sessionID: sessionID))
                    return .failure(error)
                }
                predecessor.acceptingClaims = false
                predecessor.successorSessionID = sessionID
            }
            capacityReplacement?.acceptingClaims = false
            capacityReplacement?.capacityReplacementSessionID = nil
            self.sessions[sessionID] = OperationSessionState(
                attestation: sessionAttestation,
                peerBinding: reservation.peerBinding,
                negotiatedCapabilities: reservation.key.negotiatedCapabilities,
                ordinal: reservation.ordinal)
            self.sessionCreations[creationKey] = nil
            self.pruneRetiredSessionsLocked()
            return .success(sessionAttestation)
        }
    }

    private func releaseCapacityReplacementLocked(_ reservation: OperationSessionCreationReservation) {
        guard let replacementSessionID = reservation.capacityReplacementSessionID,
              let replacement = self.sessions[replacementSessionID],
              replacement.capacityReplacementSessionID == reservation.sessionID
        else { return }
        replacement.capacityReplacementSessionID = nil
    }

    private func persistSessionAttestation(
        _ reservation: OperationSessionCreationReservation) throws
        -> PeekabooBridgeOperationSessionAttestation
    {
        let unsigned = reservation.unsignedAttestation
        let signature = try self.signCanonical(unsigned)
        let sessionAttestation = PeekabooBridgeOperationSessionAttestation(
            sessionID: unsigned.sessionID,
            listenerInstanceID: unsigned.listenerInstanceID,
            listenerPublicKeySHA256: unsigned.listenerPublicKeySHA256,
            clientInstanceID: unsigned.clientInstanceID,
            client: unsigned.client,
            maximumRequestCount: unsigned.maximumRequestCount,
            remainingClaimCount: unsigned.remainingClaimCount,
            predecessorSessionID: unsigned.predecessorSessionID,
            createdAtUnixMilliseconds: unsigned.createdAtUnixMilliseconds,
            signature: signature)
        let sessionArchiveDirectory = self.sessionArchiveDirectory(sessionID: reservation.sessionID)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(sessionArchiveDirectory)
        try self.sessionAttestationWriter(
            PeekabooBridgeOperationReceiptCoding.canonicalData(sessionAttestation),
            sessionArchiveDirectory.appendingPathComponent("attestation.json"))
        return sessionAttestation
    }

    private func prepareRolloverCreationLocked(
        session: OperationSessionState) -> OperationSessionCreationAction
    {
        if let successorSessionID = session.successorSessionID {
            if let existing = self.sessions[successorSessionID] {
                return .immediate(existing.attestation)
            }
            return .failure(.operationSessionMismatch)
        }
        do {
            return try self.prepareSessionCreationLocked(
                clientInstanceID: session.attestation.clientInstanceID,
                peerBinding: session.peerBinding,
                negotiatedCapabilities: session.negotiatedCapabilities,
                replacing: session.attestation.sessionID)
        } catch let error as PeekabooBridgeOperationReceiptError {
            return .failure(error)
        } catch {
            return .failure(.archiveWriteFailed(error.localizedDescription))
        }
    }

    private func makeRolloverRefusal(
        payload: PeekabooBridgeAttestedOperationRequest,
        predecessor: PeekabooBridgeOperationSessionAttestation,
        successor: PeekabooBridgeOperationSessionAttestation?,
        disposition: PeekabooBridgeOperationSessionRefusal.Disposition) throws
        -> PeekabooBridgeOperationSessionRefusal
    {
        let refusalPayload = try PeekabooBridgeOperationSessionRefusal.Payload(
            listenerInstanceID: self.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(self.attestation.publicKey),
            sessionID: payload.sessionID,
            sessionSequence: payload.sessionSequence,
            requestID: payload.requestID,
            clientInstanceID: payload.clientInstanceID,
            client: payload.client,
            operation: payload.request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(payload.request),
            attestedRequestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(payload),
            disposition: disposition,
            successorSessionAttestation: successor,
            refusedAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds())
        return try PeekabooBridgeOperationSessionRefusal(
            payload: refusalPayload,
            signature: self.signCanonical(refusalPayload))
    }

    private func pruneRetiredSessionsLocked(
        removeUntilBelowMaximum: Bool = false,
        excludingSessionID: UUID? = nil)
    {
        let referencedSuccessorSessionIDs = Set(self.sessions.values.compactMap(\.successorSessionID))
        let reservedPredecessorSessionIDs = Set(self.sessionCreations.values.compactMap(\.predecessorSessionID))
        let removable = self.sessions.values
            .filter {
                !$0.acceptingClaims &&
                    $0.inFlightCount == 0 &&
                    $0.authorizationPinCount == 0 &&
                    $0.archiveCleanupReservationID == nil &&
                    $0.capacityReplacementSessionID == nil &&
                    $0.attestation.sessionID != excludingSessionID &&
                    !reservedPredecessorSessionIDs.contains($0.attestation.sessionID) &&
                    !referencedSuccessorSessionIDs.contains($0.attestation.sessionID)
            }
            .sorted { $0.ordinal < $1.ordinal }
        let retainedCount = removeUntilBelowMaximum
            ? min(self.retainedRetiredSessionCount, max(0, self.maximumSessionCount - 1))
            : self.retainedRetiredSessionCount
        let excessRetiredCount = max(0, removable.count - retainedCount)
        var removalCount = excessRetiredCount
        if removeUntilBelowMaximum {
            removalCount = max(
                removalCount,
                max(0, self.sessions.count + self.sessionCreations.count - self.maximumSessionCount + 1))
        }
        for session in removable.prefix(removalCount) {
            let sessionID = session.attestation.sessionID
            let source = self.sessionArchiveDirectory(sessionID: sessionID)
            let reservationID = self.archiveMaintenance.enqueue(
                owner: .retiredSession(sessionID),
                source: source,
                quarantine: self.archiveTrashRoot.appendingPathComponent(
                    UUID().uuidString.lowercased(),
                    isDirectory: true))
            session.archiveCleanupReservationID = reservationID
        }
    }

    private func queueArchiveCleanupLocked(_ archiveDirectory: URL) {
        _ = self.archiveMaintenance.enqueue(
            owner: .orphan,
            source: archiveDirectory,
            quarantine: self.archiveTrashRoot.appendingPathComponent(
                UUID().uuidString.lowercased(),
                isDirectory: true))
    }

    private func scheduleRetiredSessionArchiveCleanup() {
        self.archiveMaintenance.schedule { [self] job in
            self.commitArchiveQuarantine(job)
        }
    }

    private func performRequiredArchiveMaintenance() async -> Bool {
        await self.archiveMaintenance.performRequired { [self] job in
            self.commitArchiveQuarantine(job)
        }
    }

    private func commitArchiveQuarantine(
        _ job: PeekabooBridgeOperationReceiptArchiveCleanupJob) -> Bool
    {
        self.lock.withLock {
            switch job.owner {
            case .orphan:
                return true
            case let .retiredSession(sessionID):
                let referencedSuccessorSessionIDs = Set(self.sessions.values.compactMap(\.successorSessionID))
                let reservedPredecessorSessionIDs = Set(
                    self.sessionCreations.values.compactMap(\.predecessorSessionID))
                guard let session = self.sessions[sessionID],
                      session.archiveCleanupReservationID == job.id,
                      !session.acceptingClaims,
                      session.inFlightCount == 0,
                      session.authorizationPinCount == 0,
                      session.capacityReplacementSessionID == nil,
                      !referencedSuccessorSessionIDs.contains(sessionID),
                      !reservedPredecessorSessionIDs.contains(sessionID)
                else { return false }
                self.sessions[sessionID] = nil
                return true
            }
        }
    }

    private func retireDeadClientSessions(replacingWith currentPeer: OperationSessionPeerBinding) {
        let candidates = self.lock.withLock {
            self.sessions.values.compactMap { session -> DeadClientProbe? in
                guard session.acceptingClaims else { return nil }
                return DeadClientProbe(
                    sessionID: session.attestation.sessionID,
                    client: session.peerBinding.client,
                    liveIdentity: session.peerBinding.liveIdentity)
            }
        }
        let evaluated = candidates.map { candidate in
            let processIsDead = SystemIdentityResolver.processStartIdentity(candidate.client.processIdentifier) !=
                candidate.client.processStartIdentity
            let exactPeerWasReplaced = candidate.client.processIdentifier == currentPeer.client.processIdentifier &&
                candidate.client.processStartIdentity == currentPeer.client.processStartIdentity &&
                candidate.liveIdentity != currentPeer.liveIdentity
            return (candidate, processIsDead, exactPeerWasReplaced)
        }
        guard evaluated.contains(where: { $0.1 || $0.2 }) else { return }
        self.lock.withLock {
            let referencedSuccessorSessionIDs = Set(self.sessions.values.compactMap(\.successorSessionID))
            let reservedPredecessorSessionIDs = Set(self.sessionCreations.values.compactMap(\.predecessorSessionID))
            for (candidate, processIsDead, exactPeerWasReplaced) in evaluated
                where processIsDead || exactPeerWasReplaced
            {
                guard let session = self.sessions[candidate.sessionID],
                      session.acceptingClaims,
                      session.peerBinding.client == candidate.client,
                      session.peerBinding.liveIdentity == candidate.liveIdentity
                else { continue }
                if exactPeerWasReplaced, !processIsDead {
                    guard session.inFlightCount == 0,
                          session.authorizationPinCount == 0,
                          session.archiveCleanupReservationID == nil,
                          session.capacityReplacementSessionID == nil,
                          session.successorSessionID == nil,
                          !referencedSuccessorSessionIDs.contains(candidate.sessionID),
                          !reservedPredecessorSessionIDs.contains(candidate.sessionID)
                    else { continue }
                }
                session.acceptingClaims = false
            }
            self.pruneRetiredSessionsLocked(removeUntilBelowMaximum: true)
        }
    }

    private struct DeadClientProbe {
        let sessionID: UUID
        let client: PeekabooBridgeOperationProcessIdentity
        let liveIdentity: PeekabooBridgeLivePeerIdentity
    }

    private func sessionArchiveDirectory(sessionID: UUID) -> URL {
        self.sessionArchiveRoot.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true)
    }

    private struct OperationSessionCreationKey: Hashable {
        let clientInstanceID: UUID
        let predecessorSessionID: UUID?
        let negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
        let codeSignatureHash: String
        let auditTokenProcessIdentifierVersion: Int32
        let userIdentifier: uid_t
        let auditToken: Data
        let bundleIdentifier: String?
        let teamIdentifier: String?

        init(
            clientInstanceID: UUID,
            peerBinding: OperationSessionPeerBinding,
            negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
            predecessorSessionID: UUID?)
        {
            self.clientInstanceID = clientInstanceID
            self.predecessorSessionID = predecessorSessionID
            self.negotiatedCapabilities = negotiatedCapabilities
            self.processIdentifier = peerBinding.client.processIdentifier
            self.processStartIdentity = peerBinding.client.processStartIdentity
            self.codeSignatureHash = peerBinding.client.codeSignatureHash
            self.auditTokenProcessIdentifierVersion = peerBinding.auditTokenProcessIdentifierVersion
            self.userIdentifier = peerBinding.userIdentifier
            self.auditToken = peerBinding.liveIdentity.auditToken
            self.bundleIdentifier = peerBinding.bundleIdentifier
            self.teamIdentifier = peerBinding.teamIdentifier
        }
    }

    private final class OperationSessionCreationReservation: @unchecked Sendable {
        let key: OperationSessionCreationKey
        let sessionID: UUID
        let unsignedAttestation: PeekabooBridgeOperationSessionAttestation.UnsignedPayload
        let peerBinding: OperationSessionPeerBinding
        let ordinal: UInt64
        let capacityReplacementSessionID: UUID?

        var predecessorSessionID: UUID? {
            self.key.predecessorSessionID
        }

        private let lock = NSLock()
        private var result: Result<PeekabooBridgeOperationSessionAttestation, PeekabooBridgeOperationReceiptError>?
        private var waiters: [CheckedContinuation<
            Result<PeekabooBridgeOperationSessionAttestation, PeekabooBridgeOperationReceiptError>,
            Never,
        >] = []

        init(
            key: OperationSessionCreationKey,
            sessionID: UUID,
            unsignedAttestation: PeekabooBridgeOperationSessionAttestation.UnsignedPayload,
            peerBinding: OperationSessionPeerBinding,
            ordinal: UInt64,
            capacityReplacementSessionID: UUID?)
        {
            self.key = key
            self.sessionID = sessionID
            self.unsignedAttestation = unsignedAttestation
            self.peerBinding = peerBinding
            self.ordinal = ordinal
            self.capacityReplacementSessionID = capacityReplacementSessionID
        }

        func waitForResult() async throws -> PeekabooBridgeOperationSessionAttestation {
            let result = await withCheckedContinuation { continuation in
                self.lock.lock()
                if let result = self.result {
                    self.lock.unlock()
                    continuation.resume(returning: result)
                } else {
                    self.waiters.append(continuation)
                    self.lock.unlock()
                }
            }
            return try result.get()
        }

        func resolve(
            _ result: Result<PeekabooBridgeOperationSessionAttestation, PeekabooBridgeOperationReceiptError>)
        {
            self.lock.lock()
            guard self.result == nil else {
                self.lock.unlock()
                return
            }
            self.result = result
            let waiters = self.waiters
            self.waiters.removeAll()
            self.lock.unlock()
            waiters.forEach { $0.resume(returning: result) }
        }
    }

    private final class OperationSessionState {
        let attestation: PeekabooBridgeOperationSessionAttestation
        let peerBinding: OperationSessionPeerBinding
        let negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities
        let ordinal: UInt64
        var acceptingClaims = true
        var successorSessionID: UUID?
        var claimedCount = 0
        var inFlightCount = 0
        var authorizationPinCount = 0
        var archiveCleanupReservationID: UUID?
        var capacityReplacementSessionID: UUID?
        private var claimedSequenceWords: [UInt64]

        init(
            attestation: PeekabooBridgeOperationSessionAttestation,
            peerBinding: OperationSessionPeerBinding,
            negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities,
            ordinal: UInt64)
        {
            self.attestation = attestation
            self.peerBinding = peerBinding
            self.negotiatedCapabilities = negotiatedCapabilities
            self.ordinal = ordinal
            self.claimedSequenceWords = Array(
                repeating: 0,
                count: (attestation.maximumRequestCount + 63) / 64)
        }

        func isClaimed(_ sequence: UInt64) -> Bool {
            let wordIndex = Int(sequence / 64)
            let bitIndex = sequence % 64
            return self.claimedSequenceWords[wordIndex] & (UInt64(1) << bitIndex) != 0
        }

        func markClaimed(_ sequence: UInt64) {
            let wordIndex = Int(sequence / 64)
            let bitIndex = sequence % 64
            self.claimedSequenceWords[wordIndex] |= UInt64(1) << bitIndex
            self.claimedCount += 1
        }
    }

    private struct OperationSessionPeerBinding: Equatable {
        let client: PeekabooBridgeOperationProcessIdentity
        let auditTokenProcessIdentifierVersion: Int32
        let userIdentifier: uid_t
        let liveIdentity: PeekabooBridgeLivePeerIdentity
        let bundleIdentifier: String?
        let teamIdentifier: String?

        var peer: PeekabooBridgePeer {
            PeekabooBridgePeer(
                liveIdentity: self.liveIdentity,
                bundleIdentifier: self.bundleIdentifier,
                teamIdentifier: self.teamIdentifier)
        }

        init(peer: PeekabooBridgePeer) throws {
            guard let liveIdentity = peer.liveIdentity,
                  let codeSignatureHash = liveIdentity.codeSignatureHash,
                  !codeSignatureHash.isEmpty,
                  peer.processIdentifier == liveIdentity.processIdentifier,
                  peer.auditTokenProcessIdentifierVersion == liveIdentity.processIdentifierVersion,
                  peer.processStartIdentity == liveIdentity.processStartIdentity,
                  peer.codeSignatureHash == codeSignatureHash,
                  peer.userIdentifier == liveIdentity.effectiveUserIdentifier
            else {
                throw PeekabooBridgeOperationReceiptError.peerIdentityMismatch
            }
            self.client = PeekabooBridgeOperationProcessIdentity(
                processIdentifier: liveIdentity.processIdentifier,
                processStartIdentity: liveIdentity.processStartIdentity,
                codeSignatureHash: codeSignatureHash)
            self.auditTokenProcessIdentifierVersion = liveIdentity.processIdentifierVersion
            self.userIdentifier = liveIdentity.effectiveUserIdentifier
            self.liveIdentity = liveIdentity
            self.bundleIdentifier = peer.bundleIdentifier
            self.teamIdentifier = peer.teamIdentifier
        }
    }

    private static func pruneOldListenerDirectories(in archiveRoot: URL, excluding current: URL) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        let candidates = try FileManager.default.contentsOfDirectory(
            at: archiveRoot,
            includingPropertiesForKeys: Array(keys))
            .filter { url in
                let values = try? url.resourceValues(forKeys: keys)
                var info = stat()
                return url.standardizedFileURL != current.standardizedFileURL &&
                    UUID(uuidString: url.lastPathComponent) != nil &&
                    values?.isDirectory == true && values?.isSymbolicLink != true
                    && lstat(url.path, &info) == 0
                    && info.st_uid == geteuid()
                    && info.st_mode & 0o077 == 0
            }
            .sorted { lhs, rhs in
                let left = try? lhs.resourceValues(forKeys: keys).contentModificationDate
                let right = try? rhs.resourceValues(forKeys: keys).contentModificationDate
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for stale in candidates.dropFirst(Self.retainedListenerDirectoryCount - 1) {
            try FileManager.default.removeItem(at: stale)
        }
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
            [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: payload.expectedWindowIdentity,
                bounds: payload.expectedWindowBounds,
                focusedElement: payload.expectedFocusedElement)]
        case let .exactWindowPixelFocusType(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: payload.request.windowIdentity,
                bounds: payload.request.windowBounds)]
        case let .foregroundModifierClick(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: payload.request.windowIdentity,
                bounds: payload.request.windowBounds)]
        case let .exactWindowTargetedHotkey(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: payload.expectedWindowIdentity,
                bounds: payload.expectedWindowBounds,
                focusedElement: payload.expectedFocusedElement)]
        case let .beginExactWindowHeldPointer(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: payload.request.windowIdentity,
                bounds: payload.request.windowBounds)]
        case let .releaseExactWindowHeldPointer(payload),
             let .revokeExactWindowHeldPointer(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowIdentity: payload.receipt.windowIdentity,
                bounds: payload.receipt.windowBounds)]
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
        case let .targetedScroll(payload):
            payload.request.expectedWindow.map {
                [.init(target: DesktopTargetIdentity(exactWindow: $0))]
            } ?? []
        case let .moveWindow(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowTarget: payload.target,
                windowIdentity: payload.expectedIdentity)]
        case let .resizeWindow(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowTarget: payload.target,
                windowIdentity: payload.expectedIdentity)]
        case let .setWindowBounds(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowTarget: payload.target,
                windowIdentity: payload.expectedIdentity)]
        case let .focusWindow(payload),
             let .closeWindow(payload),
             let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            [DesktopTargetEvidenceAdapter.evidence(
                windowTarget: payload.target,
                windowIdentity: payload.expectedIdentity)]
        case let .quitApplication(payload):
            payload.expectedIdentity.map {
                [.init(processIdentifier: $0.processIdentifier, processIdentity: $0)]
            } ?? []
        case let .activateApplication(payload):
            payload.expectedIdentity.map {
                [.init(processIdentifier: $0.processIdentifier, processIdentity: $0)]
            } ?? []
        case let .hideApplication(payload):
            if let identity = payload.expectedIdentity,
               (try? ApplicationHideRequest(
                   identifier: payload.identifier,
                   expectedIdentity: identity)) != nil
            {
                [.init(processIdentifier: identity.processIdentifier, processIdentity: identity)]
            } else {
                []
            }
        case let .clickMenuItem(payload):
            payload.expectedIdentity.map {
                [.init(processIdentifier: $0.processIdentifier, processIdentity: $0)]
            } ?? []
        case let .clickMenuItemByName(payload):
            payload.expectedIdentity.map {
                [.init(processIdentifier: $0.processIdentifier, processIdentity: $0)]
            } ?? []
        case let .exactDialogClickButton(receipt), let .exactDialogDismiss(receipt):
            [.init(target: DesktopTargetIdentity(exactWindow: receipt.target))]
        case let .inspectAccessibilityTree(payload):
            payload.windowContext.map(DesktopTargetEvidenceAdapter.evidence(selectorContext:)).map { [$0] } ?? []
        default:
            []
        }
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
        try self.resolveRequest(PeekabooBridgeOperationResultSemantics.semanticPlan(for: request))
    }

    static func resolveRequest(
        _ plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
        -> DesktopTargetIdentity?
    {
        let identity: DesktopTargetIdentity?
        do {
            identity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(
                plan.target.requestEvidence)
        } catch let error as DesktopTargetIdentityError {
            guard plan.target.policy == .responseResolved,
                  error == .missingProcessGeneration || error == .incompleteExactWindow
            else { throw error }
            identity = nil
        }
        if plan.target.requiresStableIdentity, identity == nil {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        return identity
    }

    static func resolve(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity?) throws -> DesktopTargetIdentity?
    {
        try self.resolve(
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response,
            handledTarget: handledTarget)
    }

    static func resolve(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity?) throws -> DesktopTargetIdentity?
    {
        if PeekabooBridgeOperationResultSemantics.isNoDispatchFailure(response) {
            return nil
        }
        return try self.resolveEvidence(
            plan: plan,
            evidence: self.evidence(
                plan: plan,
                response: response,
                handledTarget: handledTarget))
    }

    static func resolveEvidence(
        request: PeekabooBridgeRequest,
        evidence: [DesktopTargetIdentity.Evidence]) throws -> DesktopTargetIdentity?
    {
        try self.resolveEvidence(
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            evidence: evidence)
    }

    static func resolveEvidence(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        evidence: [DesktopTargetIdentity.Evidence]) throws -> DesktopTargetIdentity?
    {
        let identity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(evidence)
        if plan.target.requiresResolvedIdentity, identity == nil {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        try plan.request.validateResolvedOperationTarget(identity)
        return identity
    }

    static func evidence(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity?) -> [DesktopTargetIdentity.Evidence]
    {
        self.evidence(
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response,
            handledTarget: handledTarget)
    }

    static func evidence(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity?) -> [DesktopTargetIdentity.Evidence]
    {
        if case let .inspectAccessibilityTree(payload) = plan.request,
           payload.windowContext?.allowApplicationScopedAccessibilityFallback == true,
           case let .elementDetection(result) = response,
           result.metadata.isApplicationScopedAccessibilityFallback
        {
            // The signed request still binds the exact WindowServer selector, while the labeled
            // fallback response intentionally carries only same-process read authority.
            return response.operationTargetEvidence(for: plan)
        }
        var evidence = plan.target.requestEvidence
        if let handledTarget,
           plan.target.requiresResolvedIdentity || plan.target.policy == .handlerResolvedOrGlobal ||
           !plan.target.requestEvidence.isEmpty
        {
            evidence.append(.init(target: handledTarget))
        }
        evidence.append(contentsOf: response.operationTargetEvidence(for: plan))
        return evidence
    }

    static func resolveReceipt(
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity? = nil) throws -> PeekabooBridgeResolvedOperationTarget
    {
        try self.resolveReceipt(
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response,
            handledTarget: handledTarget)
    }

    static func resolveReceipt(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse,
        handledTarget: DesktopTargetIdentity? = nil) throws -> PeekabooBridgeResolvedOperationTarget
    {
        try PeekabooBridgeResolvedOperationTarget(self.resolve(
            plan: plan,
            response: response,
            handledTarget: handledTarget))
    }
}

extension PeekabooBridgeRequest {
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
        case let .captureWindow(payload):
            guard let expectedWindowID = payload.windowId else { return }
            guard let exactWindow = identity?.exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            guard exactWindow.identity.windowID == expectedWindowID else {
                throw DesktopTargetIdentityError.contradictoryWindowIdentifier
            }
        default:
            return
        }
    }
}
