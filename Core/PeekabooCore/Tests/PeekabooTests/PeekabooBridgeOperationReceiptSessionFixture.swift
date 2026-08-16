import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
@testable import PeekabooBridge

enum OperationReceiptSessionFixtureError: Error {
    case missingProcessIdentity
    case expectedAcceptedClaim
    case expectedRolloverRefusal
}

struct OperationReceiptSessionFixture: Sendable {
    let clientInstanceID: UUID
    let peer: PeekabooBridgePeer
    let attestation: PeekabooBridgeOperationSessionAttestation

    static func make(
        authority: PeekabooBridgeOperationReceiptAuthority,
        clientInstanceID: UUID = UUID(),
        peer: PeekabooBridgePeer? = nil,
        negotiatedCapabilities: PeekabooBridgeNegotiatedSessionCapabilities = .current,
        replacing predecessorSessionID: UUID? = nil) async throws -> Self
    {
        let resolvedPeer = try peer ?? self.currentPeer()
        let attestation = try await authority.createSession(
            clientInstanceID: clientInstanceID,
            peer: resolvedPeer,
            negotiatedCapabilities: negotiatedCapabilities,
            replacing: predecessorSessionID)
        try attestation.validateSignature(listenerAttestation: authority.attestation)
        return Self(
            clientInstanceID: clientInstanceID,
            peer: resolvedPeer,
            attestation: attestation)
    }

    static func currentPeer(
        auditTokenProcessIdentifierVersion: Int32? = 1,
        processStartIdentity: UInt64? = nil,
        codeSignatureHash: String? = nil) throws -> PeekabooBridgePeer
    {
        guard let resolvedStartIdentity = processStartIdentity ??
            SystemIdentityResolver.processStartIdentity(getpid()),
            let resolvedCodeSignatureHash = codeSignatureHash ??
            PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(processIdentifier: getpid())
        else {
            throw OperationReceiptSessionFixtureError.missingProcessIdentity
        }
        guard auditTokenProcessIdentifierVersion != nil else {
            return PeekabooBridgePeer(
                processIdentifier: getpid(),
                auditTokenProcessIdentifierVersion: nil,
                processStartIdentity: resolvedStartIdentity,
                codeSignatureHash: resolvedCodeSignatureHash,
                userIdentifier: geteuid(),
                bundleIdentifier: nil,
                teamIdentifier: nil)
        }
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let auditIdentity = try PeekabooBridgeSocketIO.peerAuditIdentity(fd: descriptors[0])
        let liveIdentity = PeekabooBridgeLivePeerIdentity(
            auditIdentity: auditIdentity,
            processStartIdentity: resolvedStartIdentity,
            codeSignatureHash: resolvedCodeSignatureHash)
        return PeekabooBridgePeer(
            liveIdentity: liveIdentity,
            bundleIdentifier: nil,
            teamIdentifier: nil)
    }

    func request(
        authority: PeekabooBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: PeekabooBridgeRequest) -> PeekabooBridgeAttestedOperationRequest
    {
        let sessionSequence = PeekabooBridgeOperationSessionSequence(sequence)
        return PeekabooBridgeAttestedOperationRequest(
            requestID: PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: self.attestation.sessionID,
                sequence: sessionSequence),
            sessionID: self.attestation.sessionID,
            sessionSequence: sessionSequence,
            expectedListenerInstanceID: authority.attestation.listenerInstanceID,
            clientInstanceID: self.clientInstanceID,
            client: self.attestation.client,
            request: request)
    }

    func acceptedClaim(
        authority: PeekabooBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: PeekabooBridgeRequest) async throws
        -> (request: PeekabooBridgeAttestedOperationRequest, claim: PeekabooBridgeOperationSessionClaim)
    {
        let payload = self.request(authority: authority, sequence: sequence, request: request)
        guard case let .accepted(claim) = try await authority.claim(payload, peer: self.peer) else {
            throw OperationReceiptSessionFixtureError.expectedAcceptedClaim
        }
        return (payload, claim)
    }

    func rolloverRefusal(
        authority: PeekabooBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: PeekabooBridgeRequest) async throws
        -> (request: PeekabooBridgeAttestedOperationRequest, refusal: PeekabooBridgeOperationSessionRefusal)
    {
        let payload = self.request(authority: authority, sequence: sequence, request: request)
        guard case let .rolloverRequired(refusal) = try await authority.claim(payload, peer: self.peer) else {
            throw OperationReceiptSessionFixtureError.expectedRolloverRefusal
        }
        return (payload, refusal)
    }

    static func receiptPayload(
        authority: PeekabooBridgeOperationReceiptAuthority,
        claim: PeekabooBridgeOperationSessionClaim,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        operation: PeekabooBridgeOperation? = nil,
        target: PeekabooBridgeOperationTargetReceipt? = .global,
        focusedElement: FocusedElementIdentity? = nil,
        targetAttributionFailure: PeekabooBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        outcome: DesktopActionOutcome.Projection? = nil) throws -> PeekabooBridgeOperationReceiptPayload
    {
        let now = PeekabooBridgeOperationReceiptCoding.unixMilliseconds()
        return try PeekabooBridgeOperationReceiptPayload(
            requestID: claim.requestID,
            sessionID: claim.sessionID,
            sessionSequence: claim.sessionSequence,
            sessionAttestationSHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                claim.sessionAttestation),
            listenerInstanceID: authority.attestation.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                authority.attestation.publicKey),
            host: authority.attestation.host,
            clientInstanceID: claim.sessionAttestation.clientInstanceID,
            client: claim.sessionAttestation.client,
            operation: operation ?? request.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(request),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: target,
            focusedElement: focusedElement,
            targetAttributionFailure: targetAttributionFailure,
            targetAttributionEvidence: targetAttributionEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: outcome,
            remainingClaimCount: claim.remainingClaimCount,
            startedAtUnixMilliseconds: now,
            completedAtUnixMilliseconds: now)
    }

    func signedBundle(
        authority: PeekabooBridgeOperationReceiptAuthority,
        sequence: UInt64,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse,
        operation: PeekabooBridgeOperation? = nil,
        target: PeekabooBridgeOperationTargetReceipt? = .global,
        focusedElement: FocusedElementIdentity? = nil,
        targetAttributionFailure: PeekabooBridgeTargetAttributionFailure? = nil,
        targetAttributionEvidence: [PeekabooBridgeOperationTargetEvidence]? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil,
        outcome: DesktopActionOutcome.Projection? = nil) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let accepted = try await self.acceptedClaim(
            authority: authority,
            sequence: sequence,
            request: request)
        let payload = try Self.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            operation: operation,
            target: target,
            focusedElement: focusedElement,
            targetAttributionFailure: targetAttributionFailure,
            targetAttributionEvidence: targetAttributionEvidence,
            selectedLeafEvidence: selectedLeafEvidence,
            outcome: outcome)
        let receipt = try await authority.signAndArchive(payload, claim: accepted.claim)
        let bundle = try Self.bundle(
            authority: authority,
            sessionAttestation: self.attestation,
            receipt: receipt,
            request: request,
            response: response)
        authority.complete(accepted.claim)
        return bundle
    }

    static func bundle(
        authority: PeekabooBridgeOperationReceiptAuthority,
        sessionAttestation: PeekabooBridgeOperationSessionAttestation,
        receipt: PeekabooBridgeOperationReceipt,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws -> PeekabooBridgeOperationReceiptBundle
    {
        try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: authority.attestation,
            operationSessionAttestation: sessionAttestation,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                authority.attestation.unsignedPayload),
            canonicalSessionAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(
                sessionAttestation.unsignedPayload),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(receipt.payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(request),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response))
    }
}
