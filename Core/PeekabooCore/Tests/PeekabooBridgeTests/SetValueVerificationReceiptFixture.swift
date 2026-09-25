import CryptoKit
import Foundation
import PeekabooFoundation
@testable import PeekabooBridge

/// In-memory receipt signer with synthetic identities; never resolves a process or creates a host/archive.
enum SetValueVerificationReceiptFixture {
    static func bundle(
        requested: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse) throws -> PeekabooBridgeOperationReceiptBundle
    {
        let key = Curve25519.Signing.PrivateKey()
        let host = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 71, processStartIdentity: 2001, codeSignatureHash: "synthetic-host")
        let client = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 72, processStartIdentity: 2002, codeSignatureHash: "synthetic-client")
        let listenerID = UUID()
        let sessionID = UUID()
        let clientID = UUID()
        let listenerPayload = PeekabooBridgeListenerAttestation.UnsignedPayload(
            schemaVersion: 1,
            listenerInstanceID: listenerID,
            publicKey: key.publicKey.rawRepresentation,
            host: host,
            createdAtUnixMilliseconds: 1000,
            receiptArchiveDirectory: "/synthetic/not-created")
        let listener = try PeekabooBridgeListenerAttestation(
            listenerInstanceID: listenerID,
            publicKey: listenerPayload.publicKey,
            host: host,
            createdAtUnixMilliseconds: listenerPayload.createdAtUnixMilliseconds,
            receiptArchiveDirectory: listenerPayload.receiptArchiveDirectory,
            signature: key.signature(for: PeekabooBridgeOperationReceiptCoding.canonicalData(listenerPayload)))
        let sessionPayload = PeekabooBridgeOperationSessionAttestation.UnsignedPayload(
            schemaVersion: 1,
            sessionID: sessionID,
            listenerInstanceID: listenerID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(listener.publicKey),
            clientInstanceID: clientID,
            client: client,
            maximumRequestCount: 8,
            remainingClaimCount: 8,
            predecessorSessionID: nil,
            createdAtUnixMilliseconds: 1001)
        let session = try PeekabooBridgeOperationSessionAttestation(
            sessionID: sessionID,
            listenerInstanceID: listenerID,
            listenerPublicKeySHA256: sessionPayload.listenerPublicKeySHA256,
            clientInstanceID: clientID,
            client: client,
            maximumRequestCount: sessionPayload.maximumRequestCount,
            remainingClaimCount: sessionPayload.remainingClaimCount,
            predecessorSessionID: nil,
            createdAtUnixMilliseconds: sessionPayload.createdAtUnixMilliseconds,
            signature: key.signature(for: PeekabooBridgeOperationReceiptCoding.canonicalData(sessionPayload)))
        let sequence = PeekabooBridgeOperationSessionSequence(0)
        let payload = try PeekabooBridgeOperationReceiptPayload(
            requestID: PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                sessionID: sessionID, sequence: sequence),
            sessionID: sessionID,
            sessionSequence: sequence,
            sessionAttestationSHA256: PeekabooBridgeOperationReceiptCoding.sha256(session),
            listenerInstanceID: listenerID,
            listenerPublicKeySHA256: sessionPayload.listenerPublicKeySHA256,
            host: host,
            clientInstanceID: clientID,
            client: client,
            operation: requested.operation,
            requestSHA256: PeekabooBridgeOperationReceiptCoding.sha256(requested),
            responseSHA256: PeekabooBridgeOperationReceiptCoding.sha256(response),
            target: .process(.init(processIdentifier: 42, processStartIdentity: 1001)),
            outcome: PeekabooBridgeOperationReceiptSemantics.outcome(in: response),
            remainingClaimCount: 7,
            startedAtUnixMilliseconds: 1002,
            completedAtUnixMilliseconds: 1003)
        let receipt = try PeekabooBridgeOperationReceipt(
            payload: payload,
            signature: key.signature(for: PeekabooBridgeOperationReceiptCoding.canonicalData(payload)))
        return try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: listener,
            operationSessionAttestation: session,
            receipt: receipt,
            canonicalListenerAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(listenerPayload),
            canonicalSessionAttestationPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(sessionPayload),
            canonicalReceiptPayload: PeekabooBridgeOperationReceiptCoding.canonicalData(payload),
            canonicalRequest: PeekabooBridgeOperationReceiptCoding.canonicalData(requested),
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(response))
    }
}
