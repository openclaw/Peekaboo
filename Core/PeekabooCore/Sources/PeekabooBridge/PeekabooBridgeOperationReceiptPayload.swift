import CoreGraphics
import CryptoKit
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// Canonical facts signed by the serving listener after one operation reaches a terminal response.
public struct PeekabooBridgeOperationReceiptPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let sessionID: UUID
    public let sessionSequence: PeekabooBridgeOperationSessionSequence
    public let sessionAttestationSHA256: String
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let clientInstanceID: UUID
    public let host: PeekabooBridgeOperationProcessIdentity
    public let client: PeekabooBridgeOperationProcessIdentity
    public let operation: PeekabooBridgeOperation
    public let requestSHA256: String
    public let responseSHA256: String
    public let target: PeekabooBridgeOperationTargetReceipt?
    public let focusedElement: FocusedElementIdentity?
    public let targetAttributionFailure: PeekabooBridgeTargetAttributionFailure?
    public let targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]?
    public let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
    public let outcome: DesktopActionOutcome.Projection?
    public let remainingClaimCount: Int
    public let startedAtUnixMilliseconds: Int64
    public let completedAtUnixMilliseconds: Int64

    public init(
        requestID: UUID,
        sessionID: UUID,
        sessionSequence: PeekabooBridgeOperationSessionSequence,
        sessionAttestationSHA256: String,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        host: PeekabooBridgeOperationProcessIdentity,
        clientInstanceID: UUID,
        client: PeekabooBridgeOperationProcessIdentity,
        operation: PeekabooBridgeOperation,
        requestSHA256: String,
        responseSHA256: String,
        target: PeekabooBridgeOperationTargetReceipt?,
        focusedElement: FocusedElementIdentity? = nil,
        targetAttributionFailure: PeekabooBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        outcome: DesktopActionOutcome.Projection?,
        remainingClaimCount: Int,
        startedAtUnixMilliseconds: Int64,
        completedAtUnixMilliseconds: Int64)
    {
        let isTargetlessFailure = target == nil &&
            targetAttributionFailure == nil &&
            Self.isCanonicalTargetlessFailureOutcome(outcome)
        precondition(isTargetlessFailure || ((target == nil) != (targetAttributionFailure == nil)))
        precondition((targetAttributionFailure == nil) == (targetAttributionEvidence == nil))
        precondition(requestID == PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
            sessionID: sessionID,
            sequence: sessionSequence))
        precondition(!sessionAttestationSHA256.isEmpty)
        precondition(remainingClaimCount >= 0)
        if focusedElement != nil {
            guard case .window = target else {
                preconditionFailure("Focused operation receipt requires an exact-window target")
            }
        }
        self.schemaVersion = 1
        self.requestID = requestID
        self.sessionID = sessionID
        self.sessionSequence = sessionSequence
        self.sessionAttestationSHA256 = sessionAttestationSHA256
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.clientInstanceID = clientInstanceID
        self.host = host
        self.client = client
        self.operation = operation
        self.requestSHA256 = requestSHA256
        self.responseSHA256 = responseSHA256
        self.target = target
        self.focusedElement = focusedElement
        self.targetAttributionFailure = targetAttributionFailure
        self.targetAttributionEvidence = targetAttributionEvidence
        self.selectedLeafEvidence = selectedLeafEvidence
        self.outcome = outcome
        self.remainingClaimCount = remainingClaimCount
        self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
        self.completedAtUnixMilliseconds = completedAtUnixMilliseconds
    }

    func validateTargetState() throws {
        if self.target == nil, self.targetAttributionFailure == nil {
            guard self.focusedElement == nil,
                  self.targetAttributionEvidence == nil,
                  self.selectedLeafEvidence == nil,
                  Self.isCanonicalTargetlessFailureOutcome(self.outcome)
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("targetless failure state")
            }
            return
        }
        guard (self.target == nil) != (self.targetAttributionFailure == nil) else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution state")
        }
        guard (self.targetAttributionFailure == nil) == (self.targetAttributionEvidence == nil) else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution evidence state")
        }
        guard let target = self.target else {
            guard self.focusedElement == nil, self.selectedLeafEvidence == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("failed target state")
            }
            return
        }
        if case let .browser(receipt) = target {
            guard self.focusedElement == nil, receipt.isCanonicalExternalTarget else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("browser target identity")
            }
            return
        }
        let identity = try self.resolvedTargetIdentity()
        if target != .global, identity == nil {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("stable target identity")
        }
    }

    static func isCanonicalTargetlessFailureOutcome(
        _ projection: DesktopActionOutcome.Projection?) -> Bool
    {
        guard let outcome = projection?.outcome else { return false }
        return outcome.state == .refused &&
            outcome.effect == .refused &&
            outcome.route == .bridge &&
            outcome.delivery == nil &&
            outcome.evidence == .requestRefused &&
            outcome.dispatchState == .none &&
            outcome.retrySafety == .safe &&
            outcome.refusalReason != nil
    }

    func validateSessionState() throws {
        guard self.requestID == PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
            sessionID: self.sessionID,
            sequence: self.sessionSequence),
            !self.sessionAttestationSHA256.isEmpty,
            self.remainingClaimCount >= 0
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("operation session state")
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
                DesktopTargetEvidenceAdapter.evidence(
                    windowIdentity: window,
                    bounds: window.capturedBounds ?? .null,
                    focusedElement: self.focusedElement),
            ])
        case .browser:
            guard self.focusedElement == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("browser target focus")
            }
            return nil
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
        try self.payload.validateSessionState()
        try self.payload.validateTargetState()
        guard self.payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(publicKey) else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the listener public key digest")
        }
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
public enum PeekabooBridgeOperationReceiptTrustAnchor: Equatable, Sendable {
    /// The exact listener attestation captured from an independently authenticated handshake.
    case listenerAttestation(PeekabooBridgeListenerAttestation)
    /// The exact listener public key captured from an independently authenticated handshake.
    case listenerPublicKey(Data)
    /// SHA-256 of the exact listener public key, encoded as lowercase hexadecimal.
    case listenerPublicKeySHA256(String)
    /// SHA-256 of the complete canonical listener attestation, encoded as lowercase hexadecimal.
    case listenerAttestationSHA256(String)
}
