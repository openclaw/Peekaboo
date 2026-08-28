import CoreGraphics
import CryptoKit
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

public struct PeekabooBridgeAttestedOperationRequest: Codable, Sendable {
    public let requestID: UUID
    public let sessionID: UUID
    public let sessionSequence: PeekabooBridgeOperationSessionSequence
    public let expectedListenerInstanceID: UUID
    public let clientInstanceID: UUID
    public let client: PeekabooBridgeOperationProcessIdentity
    public let request: PeekabooBridgeRequest

    public init(
        requestID: UUID,
        sessionID: UUID,
        sessionSequence: PeekabooBridgeOperationSessionSequence,
        expectedListenerInstanceID: UUID,
        clientInstanceID: UUID,
        client: PeekabooBridgeOperationProcessIdentity,
        request: PeekabooBridgeRequest)
    {
        self.requestID = requestID
        self.sessionID = sessionID
        self.sessionSequence = sessionSequence
        self.expectedListenerInstanceID = expectedListenerInstanceID
        self.clientInstanceID = clientInstanceID
        self.client = client
        self.request = request
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case sessionID
        case sessionSequence
        case expectedListenerInstanceID
        case clientInstanceID
        case client
        case request
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.requestID = try container.decode(UUID.self, forKey: .requestID)
        self.sessionID = try container.decode(UUID.self, forKey: .sessionID)
        self.sessionSequence = try container.decode(
            PeekabooBridgeOperationSessionSequence.self,
            forKey: .sessionSequence)
        self.expectedListenerInstanceID = try container.decode(UUID.self, forKey: .expectedListenerInstanceID)
        self.clientInstanceID = try container.decode(UUID.self, forKey: .clientInstanceID)
        self.client = try container.decode(PeekabooBridgeOperationProcessIdentity.self, forKey: .client)
        self.request = try container.decode(PeekabooBridgeRequestCodingBox.self, forKey: .request).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.requestID, forKey: .requestID)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.sessionSequence, forKey: .sessionSequence)
        try container.encode(self.expectedListenerInstanceID, forKey: .expectedListenerInstanceID)
        try container.encode(self.clientInstanceID, forKey: .clientInstanceID)
        try container.encode(self.client, forKey: .client)
        try container.encode(PeekabooBridgeRequestCodingBox(self.request), forKey: .request)
    }

    func validateEnvelope() throws {
        guard self.requestID == PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
            sessionID: self.sessionID,
            sequence: self.sessionSequence)
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Attested Bridge operation request ID does not match its session sequence")
        }
    }

    func validatedRequest() throws -> PeekabooBridgeRequest {
        try self.validateEnvelope()
        try self.request.validateAttestedOperationCarriage()
        return self.request
    }
}

extension PeekabooBridgeOperationReceiptSemantics {
    static func validateTargetAttribution(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        try self.validateTargetAttribution(
            payload,
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response)
    }

    static func validateReceiptCarriage(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        try self.validateReceiptCarriage(
            payload,
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            response: response)
    }
}

extension PeekabooBridgeRequest {
    fileprivate func validateAttestedOperationCarriage() throws {
        try self.validateAttestedOperationCarriage(
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: self))
    }

    fileprivate func validateAttestedOperationCarriage(
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
    {
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
        case _ where plan.result.completion.mutatesDesktop:
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

public struct PeekabooBridgeOperationReceiptBundle: Codable, Equatable, Sendable {
    public let operationAttestation: PeekabooBridgeListenerAttestation
    public let operationSessionAttestation: PeekabooBridgeOperationSessionAttestation
    public let receipt: PeekabooBridgeOperationReceipt
    public let canonicalListenerAttestationPayload: Data
    public let canonicalSessionAttestationPayload: Data
    public let canonicalReceiptPayload: Data
    public let canonicalRequest: Data
    public let canonicalResponse: Data

    public init(
        operationAttestation: PeekabooBridgeListenerAttestation,
        operationSessionAttestation: PeekabooBridgeOperationSessionAttestation,
        receipt: PeekabooBridgeOperationReceipt,
        canonicalListenerAttestationPayload: Data,
        canonicalSessionAttestationPayload: Data,
        canonicalReceiptPayload: Data,
        canonicalRequest: Data,
        canonicalResponse: Data)
    {
        self.operationAttestation = operationAttestation
        self.operationSessionAttestation = operationSessionAttestation
        self.receipt = receipt
        self.canonicalListenerAttestationPayload = canonicalListenerAttestationPayload
        self.canonicalSessionAttestationPayload = canonicalSessionAttestationPayload
        self.canonicalReceiptPayload = canonicalReceiptPayload
        self.canonicalRequest = canonicalRequest
        self.canonicalResponse = canonicalResponse
    }

    /// Validates canonical encoding, signatures, request/response semantics, and target attribution.
    ///
    /// The listener attestation is carried by the bundle and self-signed, so this compatibility API
    /// proves internal integrity only. Certification must call ``validate(trustAnchor:)`` with an
    /// independently authenticated listener anchor.
    public func validate() throws {
        try self.validateIntegrity()
    }

    public func validate(trustAnchor: PeekabooBridgeOperationReceiptTrustAnchor) throws {
        let matches = switch trustAnchor {
        case let .listenerAttestation(expected):
            self.operationAttestation == expected
        case let .listenerPublicKey(expected):
            self.operationAttestation.publicKey == expected
        case let .listenerPublicKeySHA256(expected):
            PeekabooBridgeOperationReceiptCoding.sha256(self.operationAttestation.publicKey) == expected
        case let .listenerAttestationSHA256(expected):
            try PeekabooBridgeOperationReceiptCoding.sha256(self.operationAttestation) == expected
        }
        guard matches else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "the independently trusted listener anchor")
        }
        try self.validateIntegrity()
    }

    public func validateIntegrity() throws {
        guard try self.canonicalListenerAttestationPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
            self.operationAttestation.unsignedPayload)),
            try self.canonicalSessionAttestationPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
                self.operationSessionAttestation.unsignedPayload)),
            try self.canonicalReceiptPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
                self.receipt.payload))
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported signature payload bytes")
        }
        try self.operationAttestation.validateSignature()
        try self.operationSessionAttestation.validateSignature(listenerAttestation: self.operationAttestation)
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
            if case .projectedAction = request {
                // Invalid projected carriage can have one canonical signed refusal, validated below.
            } else {
                try request.validateAttestedOperationCarriage()
            }
        } catch {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported request or response bytes")
        }
        let payload = self.receipt.payload
        guard try self.canonicalRequest == PeekabooBridgeOperationReceiptCoding.canonicalData(request),
              try self.canonicalResponse == PeekabooBridgeOperationReceiptCoding.canonicalData(response),
              payload.schemaVersion == 1,
              payload.requestID == PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                  sessionID: payload.sessionID,
                  sequence: payload.sessionSequence),
              payload.sessionID == self.operationSessionAttestation.sessionID,
              payload.sessionSequence.value < UInt64(self.operationSessionAttestation.maximumRequestCount),
              try payload.sessionAttestationSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.operationSessionAttestation),
              payload.listenerInstanceID == self.operationAttestation.listenerInstanceID,
              self.receipt.payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.operationAttestation.publicKey),
              payload.host == self.operationAttestation.host,
              payload.clientInstanceID == self.operationSessionAttestation.clientInstanceID,
              payload.client == self.operationSessionAttestation.client,
              payload.client.processIdentifier > 0,
              payload.client.processStartIdentity > 0,
              !payload.client.codeSignatureHash.isEmpty,
              payload.operation == request.operation,
              payload.requestSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.canonicalRequest),
              payload.responseSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(self.canonicalResponse),
              payload.outcome == PeekabooBridgeOperationReceiptSemantics.outcome(in: response),
              payload.remainingClaimCount >= 0,
              payload.remainingClaimCount < self.operationSessionAttestation.maximumRequestCount,
              payload.startedAtUnixMilliseconds > 0,
              payload.completedAtUnixMilliseconds >= payload.startedAtUnixMilliseconds
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported verification bundle")
        }
        try PeekabooBridgeOperationReceiptSemantics.validateTargetAttribution(
            payload,
            request: request,
            response: response)
        if case let .certificationProducerAttestation(certificationRequest) = request,
           case let .certificationProducerAttestation(certificationResponse) = response
        {
            try certificationResponse.validate(
                request: certificationRequest,
                listenerAttestation: self.operationAttestation)
        }
    }

    /// Exact deterministic bytes accepted by `bridge receipt validate` and offline verifiers.
    public func canonicalEncodedData() throws -> Data {
        try PeekabooBridgeOperationReceiptCoding.canonicalData(self)
    }
}

enum PeekabooBridgeOperationReceiptSemantics {
    private struct ExpectedSelectedLeaf {
        let kind: DesktopSelectedLeafEvidence.Kind
        let selector: String
        let index: Int?
        let resolvedLeaf: DesktopSelectedLeafEvidence?
        let requiresResolvedLeaf: Bool
    }

    static func outcome(in response: PeekabooBridgeResponse) -> DesktopActionOutcome.Projection? {
        switch response {
        case let .projectedAction(payload): payload.outcome
        case let .error(envelope): envelope.actionOutcome
        default: nil
        }
    }

    static func allowsTargetlessFailureReceipt(for response: PeekabooBridgeResponse) -> Bool {
        PeekabooBridgeOperationResultSemantics.isNoDispatchFailure(response) &&
            PeekabooBridgeOperationReceiptPayload.isCanonicalTargetlessFailureOutcome(self.outcome(in: response))
    }

    static func validateTargetAttribution(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse) throws
    {
        try payload.validateTargetState()
        try self.validateReceiptCarriage(payload, plan: plan, response: response)
        guard let failure = payload.targetAttributionFailure else {
            if self.errorEnvelope(in: response)?.context?.hasPrefix("bridge_target_attribution:") == true {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "target attribution success response context")
            }
            try self.validateSuccessfulTargetAttribution(
                payload,
                plan: plan,
                response: response)
            return
        }
        try self.validateFailedTargetAttribution(
            payload,
            failure: failure,
            plan: plan,
            response: response)
    }

    static func validateReceiptCarriage(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse) throws
    {
        let request = plan.carriageRequest
        do {
            try request.validateAttestedOperationCarriage(plan: plan)
        } catch {
            try self.validateInvalidRequestCarriageRefusal(
                payload,
                request: request,
                response: response)
            return
        }
        let semanticResponse: PeekabooBridgeResponse = if case let .projectedAction(projected) = response {
            projected.response
        } else {
            response
        }
        guard PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            semanticResponse,
            plan: plan)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("operation response family")
        }
        if plan.result.completion.mutatesDesktop {
            guard case .projectedAction = request,
                  case let .projectedAction(projected) = response,
                  let outcome = projected.outcome,
                  outcome.route == .bridge,
                  payload.outcome == outcome
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("mutating action outcome carriage")
            }
        } else {
            if case .projectedAction = response, case .projectedAction = request {
                // Read-only application checks opt into action carriage so a canonical refusal is not erased.
            } else if case .projectedAction = response {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("read-only projected response carriage")
            }
            let readOnlyOutcome = self.outcome(in: response)
            guard payload.outcome == readOnlyOutcome else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("read-only action outcome carriage")
            }
            if let outcome = readOnlyOutcome?.outcome {
                guard case .error = semanticResponse,
                      outcome.route == .bridge,
                      !outcome.isConfirmed,
                      PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                          outcome,
                          plan: plan)
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "read-only action outcome semantics")
                }
            }
        }
        if request.operation == .agentExecutionTrace {
            if case .error = semanticResponse {
                // Signed pre-release refusals have no spawned-process response to bind.
            } else {
                guard case let .agentExecutionTrace(result) = semanticResponse,
                      result.requestingPeer == payload.client
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "Agent execution authenticated requesting peer")
                }
            }
        }
        try self.validateTypedResponseSemantics(semanticResponse, outerResponse: response, plan: plan)
        try self.validateResponseOutcomeConsistency(response, plan: plan)
        try self.validateSelectedLeafEvidence(payload, request: request, response: semanticResponse)
    }

    private static func validateInvalidRequestCarriageRefusal(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        guard case .projectedAction = request,
              case let .projectedAction(projected) = response,
              case let .error(envelope) = projected.response,
              envelope.code == .invalidRequest,
              let outcome = envelope.actionOutcome?.outcome,
              projected.outcome == envelope.actionOutcome,
              payload.outcome == projected.outcome,
              payload.target == nil,
              payload.targetAttributionFailure == nil,
              payload.targetAttributionEvidence == nil,
              payload.focusedElement == nil,
              payload.selectedLeafEvidence == nil,
              outcome.route == .bridge,
              outcome.state == .refused,
              outcome.effect == .refused,
              outcome.delivery == nil,
              outcome.evidence == .requestRefused,
              outcome.dispatchState == .none,
              outcome.retrySafety == .safe,
              outcome.refusalReason == .invalidRequest
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("attested request carriage")
        }
    }

    private static func validateSelectedLeafEvidence(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws
    {
        let request = request.unwrappedOperationRequest
        let errorEnvelope: PeekabooBridgeErrorEnvelope? = if case let .error(envelope) = response {
            envelope
        } else {
            nil
        }
        if let errorEnvelope,
           errorEnvelope.actionOutcome?.mutationDispatched != true
        {
            guard payload.selectedLeafEvidence == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "no-dispatch failure selected-leaf evidence")
            }
            return
        }

        let expected: [ExpectedSelectedLeaf]? = switch request {
        case let .clickMenuExtra(value):
            [.init(
                kind: .menuBarItem,
                selector: DeterministicDesktopLeafSelector.normalized(value.name),
                index: nil,
                resolvedLeaf: nil,
                requiresResolvedLeaf: false)]
        case let .clickMenuBarItemNamed(value):
            [.init(
                kind: .menuBarItem,
                selector: DeterministicDesktopLeafSelector.normalized(value.name),
                index: nil,
                resolvedLeaf: value.expectedLeafEvidence,
                requiresResolvedLeaf: true)]
        case let .clickMenuBarItemIndex(value):
            [.init(
                kind: .menuBarItem,
                selector: String(value.index),
                index: value.index,
                resolvedLeaf: value.expectedLeafEvidence,
                requiresResolvedLeaf: true)]
        case let .launchDockItem(value):
            [.init(
                kind: .dockItem,
                selector: DeterministicDesktopLeafSelector.normalized(value.appName),
                index: nil,
                resolvedLeaf: nil,
                requiresResolvedLeaf: false)]
        case let .rightClickDockItem(value):
            if let menuItem = value.menuItem {
                [
                    .init(
                        kind: .dockItem,
                        selector: DeterministicDesktopLeafSelector.normalized(value.appName),
                        index: nil,
                        resolvedLeaf: nil,
                        requiresResolvedLeaf: false),
                    .init(
                        kind: .dockContextMenuItem,
                        selector: DeterministicDesktopLeafSelector.normalized(menuItem),
                        index: nil,
                        resolvedLeaf: nil,
                        requiresResolvedLeaf: false),
                ]
            } else {
                [.init(
                    kind: .dockItem,
                    selector: DeterministicDesktopLeafSelector.normalized(value.appName),
                    index: nil,
                    resolvedLeaf: nil,
                    requiresResolvedLeaf: false)]
            }
        case let .desktopObservation(value):
            self.desktopObservationSelectedLeafExpectation(
                value,
                outcome: payload.outcome?.outcome)
        default:
            nil
        }
        guard let expected else {
            guard payload.selectedLeafEvidence == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "unexpected selected-leaf evidence")
            }
            return
        }
        let boundExpected: [ExpectedSelectedLeaf]
        if errorEnvelope != nil {
            guard let dispatchedCount = payload.outcome?.dispatchedUnitCount?.rawValue,
                  dispatchedCount > 0
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "failed selected-leaf dispatch count")
            }
            boundExpected = Array(expected.prefix(min(dispatchedCount, expected.count)))
        } else {
            boundExpected = expected
        }
        guard let evidence = payload.selectedLeafEvidence,
              evidence.count == boundExpected.count,
              !evidence.isEmpty
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("selected-leaf evidence carriage")
        }
        if let errorEnvelope,
           errorEnvelope.actionSelectedLeafEvidence != evidence
        {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "failure selected-leaf response carriage")
        }
        for (actual, expected) in zip(evidence, boundExpected) {
            guard self.selectedLeaf(actual, matches: expected) else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("selected-leaf request binding")
            }
        }
        try self.validateSelectedLeafTarget(evidence, receiptTarget: payload.target)
    }

    private static func desktopObservationSelectedLeafExpectation(
        _ request: DesktopObservationRequest,
        outcome: DesktopActionOutcome?) -> [ExpectedSelectedLeaf]?
    {
        guard case let .menubarPopover(hints, openIfNeeded) = request.target,
              let openIfNeeded
        else { return nil }
        let setupDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        guard outcome?.delivery == setupDelivery else { return nil }
        let selector = ([openIfNeeded.clickHint] + hints.map(Optional.some))
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let selector else { return [] }
        return [.init(
            kind: .menuBarItem,
            selector: DeterministicDesktopLeafSelector.normalized(selector),
            index: nil,
            resolvedLeaf: nil,
            requiresResolvedLeaf: false)]
    }

    private static func selectedLeaf(
        _ actual: DesktopSelectedLeafEvidence,
        matches expected: ExpectedSelectedLeaf) -> Bool
    {
        guard actual.isCanonical,
              actual.kind == expected.kind,
              actual.normalizedSelector == expected.selector,
              actual.winningCandidateCount == 1,
              !actual.hasWinningTie,
              expected.index.map({ actual.matchKind == .index && actual.selectedIndex == $0 }) ??
              (actual.matchKind != .index)
        else {
            return false
        }
        guard expected.requiresResolvedLeaf else { return expected.resolvedLeaf == nil }
        guard let expectedLeaf = expected.resolvedLeaf,
              expectedLeaf.isCanonical,
              expectedLeaf.kind == expected.kind,
              expectedLeaf.normalizedSelector == expected.selector,
              expectedLeaf.winningCandidateCount == 1,
              !expectedLeaf.hasWinningTie,
              expected.index.map({ expectedLeaf.matchKind == .index && expectedLeaf.selectedIndex == $0 }) ??
              (expectedLeaf.matchKind != .index)
        else {
            return false
        }
        return actual.hasSameResolvedLeaf(as: expectedLeaf)
    }

    private static func validateSelectedLeafTarget(
        _ evidence: [DesktopSelectedLeafEvidence],
        receiptTarget: PeekabooBridgeOperationTargetReceipt?) throws
    {
        let expectedProcess: ApplicationProcessIdentity
        let expectedWindow: WindowMutationIdentity?
        switch receiptTarget {
        case let .process(process):
            expectedProcess = process
            expectedWindow = nil
        case let .window(window):
            expectedProcess = window.processIdentity
            expectedWindow = window
        case .global, .browser, nil:
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("selected-leaf target attribution")
        }
        guard evidence.allSatisfy({ $0.selectedProcessIdentity == expectedProcess }),
              expectedWindow.map({ evidence.first?.selects(window: $0) == true }) ?? true
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("selected-leaf target identity")
        }
    }

    private static func validateSuccessfulTargetAttribution(
        _ payload: PeekabooBridgeOperationReceiptPayload,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse) throws
    {
        let request = plan.carriageRequest
        if self.allowsTargetlessFailureReceipt(for: response) {
            guard payload.target == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("no-dispatch failure target")
            }
            return
        }
        guard payload.target != nil else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("targetless successful attribution")
        }
        do {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(plan)
        } catch {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "successful request target contract")
        }
        if [.browserConnect, .browserExecute].contains(request.operation),
           plan.result.completion.mutatesDesktop,
           !PeekabooBridgeOperationResultSemantics.isNoDispatchFailure(response)
        {
            guard let responseReceipt = response.browserExecutionConnectionReceipt,
                  responseReceipt.isCanonicalTarget
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser connection target attribution")
            }
            if request.operation == .browserConnect {
                guard let connectRequest = request.browserConnectRequest,
                      responseReceipt.matchesConnectRequest(connectRequest)
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser connection request attribution")
                }
            } else if request.operation == .browserExecute {
                if let requestedChannel = request.browserRequestedChannel,
                   responseReceipt.channel != requestedChannel
                {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser connection channel attribution")
                }
                guard let expectedReceipt = request.browserExecutionRequest?.expectedConnectionReceipt else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser request connection attribution")
                }
                guard responseReceipt == expectedReceipt else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser connection request attribution")
                }
            }
            if responseReceipt.isCanonicalExternalTarget {
                guard payload.target == .browser(responseReceipt),
                      payload.focusedElement == nil
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "external browser connection target attribution")
                }
                return
            }
        }
        if case .browser = payload.target,
           ![PeekabooBridgeOperation.browserConnect, .browserExecute].contains(request.operation)
        {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "browser target used outside external browser execution")
        }
        let signedIdentity = try payload.resolvedTargetIdentity()
        let targetPolicy = plan.target.policy
        let handledTarget: DesktopTargetIdentity? = switch targetPolicy {
        case .handlerRequired, .handlerResolvedOrGlobal, .external:
            signedIdentity
        case .responseResolved:
            self.errorEnvelope(in: response)?.actionTargetReceipt == nil ? nil : signedIdentity
        case .notApplicable, .requestDependent, .global, .requestPinned:
            nil
        }
        let resolvedIdentity: DesktopTargetIdentity?
        do {
            resolvedIdentity = try PeekabooBridgeOperationTargetAttribution.resolve(
                plan: plan,
                response: response,
                handledTarget: handledTarget)
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
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        response: PeekabooBridgeResponse) throws
    {
        let request = plan.carriageRequest
        let envelope = self.errorEnvelope(in: response)
        guard envelope?.context == "bridge_target_attribution:\(failure.code.rawValue)" else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution failure response")
        }
        guard let envelope else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("target attribution error envelope")
        }
        try self.validateFailureResponseSemantics(
            failure,
            plan: plan,
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
                _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(plan)
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
                _ = try PeekabooBridgeOperationTargetAttribution.resolveRequest(plan)
            } catch {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "post-execution request target evidence")
            }
        }
        do {
            _ = try PeekabooBridgeOperationTargetAttribution.resolveEvidence(
                plan: plan,
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
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        envelope: PeekabooBridgeErrorEnvelope) throws
    {
        guard plan.result.completion.mutatesDesktop else {
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
                  outcome.retrySafety == .unsafe,
                  PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                      outcome,
                      plan: plan)
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "retry-unsafe target attribution failure")
            }
        }
    }

    private static func errorEnvelope(in response: PeekabooBridgeResponse) -> PeekabooBridgeErrorEnvelope? {
        switch response {
        case let .error(envelope):
            envelope
        case let .projectedAction(projected):
            if case let .error(envelope) = projected.response {
                envelope
            } else {
                nil
            }
        default:
            nil
        }
    }

    private static func validateTypedResponseSemantics(
        _ response: PeekabooBridgeResponse,
        outerResponse: PeekabooBridgeResponse,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
    {
        let request = plan.request
        let outerOutcome = self.outcome(in: outerResponse)?.outcome
        try plan.validateBoundTypedResponse(response, outcome: outerOutcome)
        if plan.responseCarriesPostMutationWindowState,
           outerOutcome?.isConfirmed == true,
           case .window = response
        {
            // The typed response below proves the requested postcondition.
        } else if plan.responseCarriesPostMutationWindowState,
                  outerOutcome?.isConfirmed == true
        {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "confirmed window mutation response proof")
        }
        switch (plan.operationPolicy.typedResponse, request, response) {
        case let (.focusedElement, .getFocusedElement(expected), .focusedElement(focused)):
            guard focused.map({ $0.processId == Int(expected.targetProcessIdentifier) }) ?? true else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("focused-element response process")
            }
        case let (.applicationIdentifier, .findApplication(expected), .application(application)):
            try self.validateApplication(
                application,
                identifier: expected.identifier,
                requireSelectorResolutionProof: true)
        case let (.applicationIdentifier, .launchApplication(expected), .application(application)):
            try self.validateApplication(
                application,
                identifier: expected.identifier,
                requireSelectorResolutionProof: true)
        case let (.applicationLaunch, .launchApplicationWithOptions(expected), .application(application)):
            try self.validateApplication(application, launchRequest: expected)
        case let (.applicationRelaunch, .relaunchApplicationWithOptions(expected), .application(application)):
            try self.validateApplication(application, launchRequest: expected.launchRequest)
            guard let oldIdentity = expected.expectedTargetIdentity,
                  let newIdentity = application.processIdentity,
                  newIdentity != oldIdentity
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "relaunch response process generation")
            }
            guard outerOutcome?.state != .confirmedNoChange else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "relaunch response no-change outcome")
            }
        case let (.capture, _, .capture(result)):
            if let mismatch = PeekabooBridgeCaptureBinding.mismatch(
                request: request,
                result: result,
                requireSelectorResolutionProof: true)
            {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("capture \(mismatch)")
            }
        case let (.elementDetection, .detectElements(expected), .elementDetection(actual)):
            try self.validateElementDetection(
                actual,
                expectedSnapshotID: expected.snapshotId,
                expectedWindowContext: expected.windowContext,
                requiresSnapshotBinding: true,
                allowsResolvedWindowContext: false)
        case let (.elementDetection, .inspectAccessibilityTree(expected), .elementDetection(actual)):
            try self.validateElementDetection(
                actual,
                expectedSnapshotID: nil,
                expectedWindowContext: expected.windowContext,
                requiresSnapshotBinding: false,
                allowsResolvedWindowContext: true)
        case let (.desktopObservation, .desktopObservation(expected), .desktopObservation(actual)):
            if let mismatch = PeekabooBridgeDesktopObservationBinding.mismatch(
                request: expected,
                result: actual,
                requireSelectorResolutionProof: true)
            {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "desktop observation \(mismatch)")
            }
            try self.validateDesktopObservationSetupResult(
                actual,
                request: expected,
                outcome: outerOutcome)
        case let (.postMutationWindow, _, .window(window)):
            try self.validatePostMutationWindow(
                window,
                plan: plan,
                outcome: outerOutcome)
        case let (.menuStructureApplication, .listMenus(expected), .menuStructure(actual)):
            try self.validateApplication(
                actual.application,
                identifier: expected.appIdentifier,
                requireSelectorResolutionProof: true)
        case let (.waitElementSelector, .waitForElement(expected), .waitResult(actual)):
            try self.validateWaitResult(actual, target: expected.target)
        case let (.dockItemSelector, .findDockItem(expected), .dockItem(actual)):
            guard let actual,
                  self.dockItem(actual, matches: expected.name)
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("dock-item response selector")
            }
        case let (.storedDetection, .storeDetectionResult(expected), .ok):
            guard expected.snapshotId == expected.result.snapshotId else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("stored detection snapshot")
            }
        case let (.detectionSnapshot, .getDetectionResult(expected), .detection(actual)):
            guard actual.snapshotId == expected.snapshotId else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("detection response snapshot")
            }
        case let (.snapshotMutationLease, .beginSnapshotMutation(expected), .snapshotMutationLease(actual)):
            guard actual.snapshotId == expected.snapshotId else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("snapshot mutation lease snapshot")
            }
        case let (.dialogResult, _, .dialogResult(result)):
            try self.validateDialogResult(result, outerResponse: outerResponse, request: request)
        case let (.preparedDialogAction, .prepareDialogAction(expected), .preparedDialogAction(receipt)):
            try self.validatePreparedDialogAction(receipt, request: expected)
        case let (.targetedDialogElements, .targetedDialogListElements(selector), .dialogElements(elements)):
            guard let resolved = elements.resolvedTarget else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "targeted dialog list selector evidence")
            }
            try self.validateResolvedDialogTarget(
                resolved,
                exactTarget: resolved.target,
                selector: selector)
        case (.familyOnly, _, _),
             (.noSuccessResponse, _, _),
             (.agentExecutionTrace, _, _),
             (.processGenerationObservation, .observeProcessGeneration, .processGenerationObservation),
             (
                 .certificationProducerAttestation,
                 .certificationProducerAttestation,
                 .certificationProducerAttestation),
             (.typeActions, _, _),
             (.setValue, _, _),
             (.performAction, _, _),
             (.elementDetection, _, _),
             (.postMutationWindow, _, _),
             (.menuStructureApplication, _, _),
             (.waitElementSelector, _, _),
             (.dockItemSelector, _, _),
             (.storedDetection, _, _),
             (.detectionSnapshot, _, _),
             (.snapshotMutationLease, _, _),
             (_, _, .error):
            break
        default:
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("typed response semantic plan")
        }
    }

    private static func validateApplication(
        _ application: ServiceApplicationInfo,
        launchRequest: ApplicationLaunchRequest) throws
    {
        if let bundleIdentifier = launchRequest.applicationBundleIdentifier {
            guard application.bundleIdentifier == bundleIdentifier else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("application response bundle")
            }
        } else if let identifier = launchRequest.applicationIdentifier {
            try self.validateApplication(
                application,
                identifier: identifier,
                requireSelectorResolutionProof: true)
        }
    }

    private static func validateElementDetection(
        _ result: ElementDetectionResult,
        expectedSnapshotID: String?,
        expectedWindowContext: WindowContext?,
        requiresSnapshotBinding: Bool,
        allowsResolvedWindowContext: Bool) throws
    {
        if requiresSnapshotBinding {
            if let expectedSnapshotID {
                guard result.snapshotId == expectedSnapshotID else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "element-detection response snapshot")
                }
            } else if result.snapshotId.isEmpty {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "element-detection generated snapshot")
            }
        }
        if result.metadata.isApplicationScopedAccessibilityFallback {
            try PeekabooBridgeWindowContextBinding.validateApplicationScopedFallback(
                result.metadata,
                requested: expectedWindowContext,
                allowsResolvedWindowContext: allowsResolvedWindowContext)
            return
        }
        let windowContextMatches = if allowsResolvedWindowContext {
            PeekabooBridgeWindowContextBinding.refines(
                result.metadata.windowContext,
                requested: expectedWindowContext)
        } else {
            PeekabooBridgeWindowContextBinding.matches(
                result.metadata.windowContext,
                requested: expectedWindowContext)
        }
        guard windowContextMatches else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "element-detection response window context")
        }
    }

    private static func validateWaitResult(
        _ result: WaitForElementResult,
        target: ClickTarget) throws
    {
        switch target {
        case .coordinates:
            guard result.found, result.element == nil else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("wait response coordinate selector")
            }
        case let .elementId(expectedID):
            guard result.found == (result.element != nil),
                  !result.found || result.element?.id == expectedID
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("wait response element selector")
            }
        case let .query(query):
            guard result.found == (result.element != nil),
                  !result.found || result.element.map({ self.element($0, matchesQuery: query) }) == true
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("wait response query selector")
            }
        }
    }

    private static func element(_ element: DetectedElement, matchesQuery query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty, element.isEnabled, !element.isOCRSemanticEvidence else { return false }
        return [
            element.label,
            element.value,
            element.attributes["identifier"],
            element.attributes["title"],
            element.attributes["description"],
            element.attributes["role"],
        ]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains(query) }
    }

    private static func dockItem(_ item: DockItem, matches selector: String) -> Bool {
        let selector = selector.lowercased()
        return !selector.isEmpty && item.title.lowercased().contains(selector)
    }

    private static func validateDesktopObservationSetupResult(
        _ result: DesktopObservationResult,
        request: DesktopObservationRequest,
        outcome: DesktopActionOutcome?) throws
    {
        guard case let .menubarPopover(_, openIfNeeded) = request.target,
              openIfNeeded != nil
        else { return }
        let setupDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        if result.target.mutationTargetIdentity != nil {
            guard outcome?.state == .dispatchedUnverified,
                  outcome?.delivery == setupDelivery,
                  outcome?.dispatchState.unitCount != nil
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "menu-bar observation setup outcome")
            }
        } else {
            let pipelineMode: DesktopActionOutcome.Delivery.Mode = request.capture.focus == .background
                ? .background
                : .foreground
            let requiresConditionalPipeline = request.capture.focus != .background ||
                (request.detection.mode != .none && request.detection.allowWebFocusFallback)
            let isNoOp = !requiresConditionalPipeline &&
                outcome?.state == .confirmedNoChange &&
                outcome?.delivery == nil &&
                outcome?.dispatchState == DesktopActionOutcome.DispatchState.none
            let isConditionalPipeline = requiresConditionalPipeline &&
                outcome?.state == .dispatchedUnverified &&
                outcome?.delivery == .init(mechanism: .capturePipeline, mode: pipelineMode) &&
                outcome?.dispatchState.unitCount != nil
            guard isNoOp || isConditionalPipeline else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "menu-bar observation conditional pipeline outcome")
            }
        }
    }

    private static func validateApplication(
        _ application: ServiceApplicationInfo,
        identifier: String,
        requireSelectorResolutionProof: Bool = false) throws
    {
        guard ApplicationIdentifierMatcher.matches(application, identifier: identifier) else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("application response identifier")
        }
        if let mismatch = PeekabooBridgeSelectorResolutionBinding.applicationMismatch(
            identifier: identifier,
            application: application,
            proofs: application.selectorResolutionProofs,
            requireProof: requireSelectorResolutionProof)
        {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "application response selector proof \(mismatch)")
        }
    }

    private static func validatePreparedDialogAction(
        _ receipt: PreparedDialogActionReceipt,
        request: DialogActionPreparationRequest) throws
    {
        let identity = receipt.target.identity
        guard receipt.kind == request.kind,
              request.target.processIdentifier.map({ $0 == identity.ownerProcessIdentifier }) ?? true,
              request.target.windowID.map({ $0 == identity.windowID }) ?? true
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("prepared dialog action request")
        }
        try self.validateResolvedDialogTarget(
            receipt.resolvedTarget,
            exactTarget: receipt.target,
            selector: request.target)
    }

    static func validatePostMutationWindow(
        _ window: ServiceWindowInfo?,
        request: PeekabooBridgeRequest,
        outcome: DesktopActionOutcome?) throws
    {
        try self.validatePostMutationWindow(
            window,
            plan: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
            outcome: outcome)
    }

    static func validatePostMutationWindow(
        _ window: ServiceWindowInfo?,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan,
        outcome: DesktopActionOutcome?) throws
    {
        let request = plan.request
        guard let expected = plan.pinnedWindowMutation?.identity else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("post-mutation window request target")
        }
        guard let window else {
            guard request.operation == .closeWindow || request.operation == .backgroundCloseWindow else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("post-mutation window response")
            }
            return
        }
        guard window.windowID == expected.windowID,
              let actual = window.mutationIdentity,
              actual.windowID == expected.windowID,
              actual.processIdentity == expected.processIdentity,
              actual.capturedBounds == window.bounds,
              actual.isMinimized.map({ $0 == window.isMinimized }) ?? true
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("post-mutation window identity")
        }
        if [.focusWindow, .minimizeWindow, .restoreWindow].contains(request.operation),
           actual.capturedBounds != expected.capturedBounds
        {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "post-mutation window bounds continuity")
        }
        guard outcome?.isConfirmed == true else { return }

        let postconditionSatisfied: Bool = switch request {
        case let .moveWindow(payload):
            window.mutationPostconditionEvidence == nil &&
                WindowMutationGeometryPostcondition.originMatches(
                    window.bounds.origin,
                    payload.position)
        case let .resizeWindow(payload):
            window.mutationPostconditionEvidence == nil &&
                WindowMutationGeometryPostcondition.sizeMatches(
                    window.bounds.size,
                    payload.size)
        case let .setWindowBounds(payload):
            window.mutationPostconditionEvidence == nil &&
                WindowMutationGeometryPostcondition.boundsMatch(
                    window.bounds,
                    payload.bounds)
        case .minimizeWindow:
            window.mutationPostconditionEvidence == nil && window.isMinimized
        case .restoreWindow:
            window.mutationPostconditionEvidence == nil && !window.isMinimized
        case .focusWindow:
            window.mutationPostconditionEvidence == nil &&
                (window.isKeyWindow == true || window.isFrontmost == true)
        case .closeWindow, .backgroundCloseWindow:
            false
        case .maximizeWindow:
            window.mutationPostconditionEvidence?.isMaximized == true &&
                window.mutationPostconditionEvidence?.verifiedVisibleWorkArea.map {
                    WindowMutationGeometryPostcondition.boundsMatch(window.bounds, $0)
                } == true
        default:
            false
        }
        guard postconditionSatisfied else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("post-mutation window postcondition")
        }
    }

    private static func validateDialogResult(
        _ result: DialogActionResult,
        outerResponse: PeekabooBridgeResponse,
        request: PeekabooBridgeRequest) throws
    {
        let expectedAction: DialogActionType? = switch request.operation {
        case .dialogClickButton, .backgroundDialogClickButton, .exactDialogClickButton: .clickButton
        case .dialogEnterText, .exactDialogEnterText: .enterText
        case .dialogHandleFile: .handleFileDialog
        case .dialogDismiss, .exactDialogDismiss, .exactDialogForceDismiss: .dismiss
        default: nil
        }
        guard expectedAction == result.action,
              result.success,
              let innerOutcome = result.outcome,
              case let .projectedAction(projected) = outerResponse,
              projected.outcome == innerOutcome.routed(to: .bridge).projection
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("dialog response result semantics")
        }
        switch request {
        case let .exactDialogClickButton(receipt):
            guard receipt.kind == .clickButton else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("exact dialog click request kind")
            }
            do {
                _ = try result.requiredPreparedOutcome(kind: .clickButton)
            } catch {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("exact dialog click result")
            }
        case let .exactDialogDismiss(receipt):
            guard receipt.kind == .dismiss else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("exact dialog dismiss request kind")
            }
            do {
                _ = try result.requiredPreparedOutcome(kind: .dismiss)
            } catch {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch("exact dialog dismiss result")
            }
        case let .exactDialogEnterText(payload):
            try self.validateDialogTargetReceipt(result, selector: payload.target)
        case let .exactDialogForceDismiss(payload):
            try self.validateDialogTargetReceipt(result, selector: payload.target)
        default:
            break
        }
    }

    private static func validateDialogTargetReceipt(
        _ result: DialogActionResult,
        selector: DialogTargetSelector) throws
    {
        guard let receipt = result.targetReceipt,
              selector.processIdentifier.map({ $0 == receipt.processIdentifier }) ?? true,
              selector.windowID.map({ $0 == receipt.windowID }) ?? true
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("dialog response target receipt")
        }
        let exactTarget: UIAutomationTarget.ExactWindow? = if let identity = result.targetWindowIdentity,
                                                              let bounds = result.targetWindowBounds
        {
            try .init(
                identity: identity,
                bounds: bounds,
                focusedElement: result.focusedElement)
        } else {
            nil
        }
        guard let exactTarget,
              exactTarget.identity.ownerProcessIdentifier == receipt.processIdentifier,
              exactTarget.identity.ownerProcessStartIdentity == receipt.processStartIdentity,
              receipt.windowID.map({ $0 == exactTarget.identity.windowID }) ?? true
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("dialog response exact target")
        }
        try self.validateResolvedDialogTarget(
            result.resolvedTarget,
            exactTarget: exactTarget,
            selector: selector)
    }

    private static func validateResolvedDialogTarget(
        _ resolved: ResolvedDialogTargetEvidence?,
        exactTarget: UIAutomationTarget.ExactWindow,
        selector: DialogTargetSelector) throws
    {
        let requiresSelectorEvidence = selector.applicationIdentifier != nil ||
            selector.windowTitle != nil || selector.windowIndex != nil
        guard let resolved else {
            guard !requiresSelectorEvidence else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "resolved dialog selector evidence")
            }
            return
        }
        guard resolved.target == exactTarget,
              resolved.matches(selector)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "resolved dialog selector evidence")
        }
        if let mismatch = PeekabooBridgeSelectorResolutionBinding.dialogMismatch(
            selector: selector,
            evidence: resolved,
            requireProof: requiresSelectorEvidence)
        {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "resolved dialog selector proof \(mismatch)")
        }
    }

    private static func validateResponseOutcomeConsistency(
        _ response: PeekabooBridgeResponse,
        plan: PeekabooBridgeOperationResultSemantics.PeekabooBridgeRequestPlan) throws
    {
        let request = plan.request
        guard case let .projectedAction(projected) = response else { return }
        if case let .browserToolResponse(browserResponse) = projected.response {
            guard let browserRequest = request.browserExecutionRequest else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser response request binding")
            }
            let requestedCallCount = browserRequest.mutationCallCount
            guard browserResponse.isError == (browserResponse.actionFailure != nil) else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser response typed failure marker")
            }
            guard let connectionReceipt = browserResponse.connectionReceipt,
                  connectionReceipt.isCanonicalTarget,
                  let outcome = projected.outcome?.outcome
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser response progress and outcome")
            }
            if browserResponse.completedCallCount == nil || browserResponse.dispatchedCallCount == nil {
                guard let failure = browserResponse.actionFailure,
                      browserResponse.completedCallCount == nil,
                      browserResponse.dispatchedCallCount == nil,
                      failure.outcome.projection == projected.outcome,
                      outcome.state == .indeterminate,
                      outcome.route == .bridge,
                      outcome.delivery == .init(mechanism: .browserProtocol, mode: .background),
                      outcome.evidence == .completionUnknown,
                      outcome.dispatchState.mutationDispatched,
                      outcome.dispatchState.unitCount == nil,
                      outcome.retrySafety == .unsafe,
                      PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                          failure.outcome,
                          plan: plan)
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser response unknown progress")
                }
                return
            }
            guard let completedCallCount = browserResponse.completedCallCount,
                  completedCallCount >= 0,
                  let dispatchedCallCount = browserResponse.dispatchedCallCount,
                  dispatchedCallCount >= completedCallCount,
                  dispatchedCallCount <= requestedCallCount
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser response progress and outcome")
            }
            if dispatchedCallCount == 0 {
                guard completedCallCount == 0,
                      let failure = browserResponse.actionFailure,
                      failure.outcome.projection == projected.outcome,
                      outcome.state == .refused,
                      outcome.route == .bridge,
                      outcome.delivery == nil,
                      outcome.evidence == .requestRefused,
                      outcome.dispatchState == .none,
                      outcome.retrySafety == .safe,
                      outcome.refusalReason != nil,
                      PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                          failure.outcome,
                          plan: plan)
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser response zero progress refusal")
                }
                return
            }
            guard let unitCount = DesktopActionOutcome.DispatchUnitCount(dispatchedCallCount),
                  outcome.dispatchState.unitCount == unitCount
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "browser response positive progress")
            }
            if let failure = browserResponse.actionFailure {
                guard failure.outcome.projection == projected.outcome,
                      PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                          failure.outcome,
                          plan: plan)
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "browser response action failure")
                }
            } else {
                guard completedCallCount == requestedCallCount,
                      dispatchedCallCount == requestedCallCount,
                      outcome.state == .dispatchedUnverified,
                      outcome.route == .bridge,
                      outcome.delivery == .init(mechanism: .browserProtocol, mode: .background),
                      outcome.evidence == .deliveryAccepted
                else {
                    throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                        "successful browser response outcome")
                }
            }
            return
        }
        guard let outcome = projected.outcome?.outcome else {
            guard !plan.result.completion.mutatesDesktop else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "projected response outcome")
            }
            if case let .error(envelope) = projected.response,
               envelope.actionOutcome != nil
            {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "read-only projected response outcome")
            }
            return
        }
        if case let .error(envelope) = projected.response {
            guard projected.outcome == envelope.actionOutcome,
                  !outcome.isConfirmed,
                  PeekabooBridgeOperationResultSemantics.failureOutcomeMatchesContract(
                      outcome,
                      plan: plan)
            else {
                throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                    "projected error outcome")
            }
            return
        }
        guard PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
            outcome,
            response: projected.response,
            plan: plan) || PeekabooBridgeOperationResultSemantics.nonErrorResponseAllowsFailureOutcome(
            projected.response,
            outcome: outcome,
            plan: plan)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch(
                "successful projected response outcome")
        }
    }
}
