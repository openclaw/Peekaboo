import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeObservationReceiptProvenanceRaceTests: DesktopObservationBindingFixtureProviding {
    @Test
    func `legacy observation remains digest optional when a signed upgrade completes first`() async throws {
        let root = Self.temporaryRoot("legacy-reply-after-upgrade")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let legacyHandshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: Self.legacyVersion)
            }
            let legacyHandshakeRequest = try await peer.nextRequest()
            #expect(try Self.requireHandshake(legacyHandshakeRequest).protocolVersion == Self.legacyVersion)
            try await peer.respond(.handshake(Self.legacyHandshake()), to: legacyHandshakeRequest)
            #expect(try await legacyHandshake.value.negotiatedVersion == Self.legacyVersion)

            let legacyObservation = Task {
                try await client.desktopObservationWithOutcome(Self.request)
            }
            let heldLegacyRequest = try await peer.nextRequest()
            guard case let .desktopObservation(request) = try heldLegacyRequest.decode() else {
                Issue.record("Expected a raw protocol 1.28 desktop observation request")
                await peer.stop()
                return
            }
            #expect(request == Self.request)

            let signedUpgrade = Task {
                try await client.handshake(client: Self.clientIdentity)
            }
            let signedHandshakeRequest = try await peer.nextRequest()
            #expect(try Self.requireHandshake(signedHandshakeRequest).protocolVersion ==
                PeekabooBridgeConstants.protocolVersion)
            try await peer.respond(
                .handshake(Self.signedHandshake(authority: authority, session: session.attestation)),
                to: signedHandshakeRequest)
            #expect(try await signedUpgrade.value.operationSessionAttestation == session.attestation)

            let digestlessLegacyResult = Self.replacingDigest(Self.screenResult(index: 0), with: nil)
            try await peer.respond(.desktopObservation(digestlessLegacyResult), to: heldLegacyRequest)
            let result = try await legacyObservation.value
            #expect(result.payload.captureContentDigest == nil)
            #expect(result.payload.capture.imageData.isEmpty)
            #expect(await peer.acceptedConnectionCount == 3)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `signed observation still rejects a missing capture digest`() async throws {
        let root = Self.temporaryRoot("signed-digest-required")
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)

        do {
            let handshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let handshakeRequest = try await peer.nextRequest()
            try await peer.respond(
                .handshake(Self.signedHandshake(authority: authority, session: session.attestation)),
                to: handshakeRequest)
            #expect(try await handshake.value.operationSessionAttestation == session.attestation)

            let observation = Task {
                try await client.desktopObservationWithOutcome(Self.request)
            }
            let wireRequest = try await peer.nextRequest()
            let accepted = try await Self.acceptedClaim(
                wireRequest,
                authority: authority,
                peer: session.peer)
            guard case let .desktopObservation(request) = accepted.request.request else {
                Issue.record("Expected an attested desktop observation request")
                await peer.stop()
                return
            }
            #expect(request == Self.request)

            let digestlessResult = Self.replacingDigest(Self.screenResult(index: 0), with: nil)
            let response = PeekabooBridgeResponse.desktopObservation(digestlessResult)
            let receiptPayload = try OperationReceiptSessionFixture.receiptPayload(
                authority: authority,
                claim: accepted.claim,
                request: accepted.request.request,
                response: response,
                target: .global)
            let receipt = try await authority.signAndArchive(receiptPayload, claim: accepted.claim)
            authority.complete(accepted.claim)
            try await peer.respond(
                .attestedOperation(.init(response: response, receipt: receipt)),
                to: wireRequest)

            do {
                _ = try await observation.value
                Issue.record("A signed desktop observation omitted its required capture-content digest")
            } catch let error as PeekabooBridgeOperationReceiptError {
                #expect(error == .receiptMismatch("desktop observation capture-content digest"))
            }
            #expect(await peer.acceptedConnectionCount == 2)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    private static let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
    private static let request = DesktopObservationRequest(
        target: .screen(index: 0),
        detection: .init(mode: .none))
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.observation-receipt-provenance-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    private static func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-observation-provenance-\(suffix)-\(UUID().uuidString)",
            isDirectory: true)
    }

    private static func legacyHandshake() -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: self.legacyVersion,
            hostKind: .gui,
            build: "observation-provenance-legacy-test",
            supportedOperations: [.desktopObservation],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.desktopObservation])
    }

    private static func signedHandshake(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: PeekabooBridgeOperationSessionAttestation) -> PeekabooBridgeHandshakeResponse
    {
        let listener = authority.attestation
        return BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "observation-provenance-signed-test",
            supportedOperations: [.desktopObservation],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.desktopObservation],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.observation-receipt-provenance-tests",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session)
    }

    @discardableResult
    private static func requireHandshake(
        _ request: ConcurrentGatedBridgePeer.Request) throws -> PeekabooBridgeHandshake
    {
        guard case let .handshake(payload) = try request.decode() else {
            throw ObservationReceiptProvenanceFixtureError.expectedHandshake
        }
        return payload
    }

    private static func acceptedClaim(
        _ request: ConcurrentGatedBridgePeer.Request,
        authority: PeekabooBridgeOperationReceiptAuthority,
        peer: PeekabooBridgePeer) async throws
        -> (request: PeekabooBridgeAttestedOperationRequest, claim: PeekabooBridgeOperationSessionClaim)
    {
        guard case let .attestedOperation(payload) = try request.decode() else {
            throw ObservationReceiptProvenanceFixtureError.expectedAttestedOperation
        }
        guard case let .accepted(claim) = try await authority.claim(payload, peer: peer) else {
            throw ObservationReceiptProvenanceFixtureError.expectedAcceptedClaim
        }
        return (payload, claim)
    }
}

private enum ObservationReceiptProvenanceFixtureError: Error {
    case expectedHandshake
    case expectedAttestedOperation
    case expectedAcceptedClaim
}
