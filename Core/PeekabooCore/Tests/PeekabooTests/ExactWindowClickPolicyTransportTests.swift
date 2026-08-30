import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct ExactWindowClickPolicyTransportTests {
    @Test
    func `legacy exact click omits policy and explicit values refuse before transport`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 22)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            supportedOperations: [.targetedClick])
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake), .ok])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        do {
            _ = try await client.handshake(
                client: .init(
                    bundleIdentifier: "dev.peekaboo.exact-click-policy-tests",
                    teamIdentifier: nil,
                    processIdentifier: getpid()),
                protocolVersion: version)
            let evidence = Self.evidence
            let invalidEvidence = ExactWindowClickEvidence(identity: evidence.identity, bounds: .zero)

            for policy in [false, true] {
                do {
                    _ = try await client.clickWithOutcome(
                        target: .coordinates(.zero),
                        clickType: .single,
                        snapshotId: nil,
                        windowEvidence: invalidEvidence,
                        allowsAccessibilityValueDelivery: policy)
                    Issue.record("Expected explicit-policy refusal before writing a click request")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome.state == .refused)
                    #expect(failure.outcome.refusalReason == .runtimeIncompatible)
                    #expect(failure.outcome.dispatchState == .none)
                    #expect(failure.outcome.retrySafety == .safe)
                    #expect(failure
                        .message == "This Bridge host cannot honor an explicit accessibility-value click policy.")
                }
                #expect(await peer.requests.count == 1)
            }

            try await client.click(
                target: .coordinates(.zero),
                clickType: .single,
                snapshotId: nil,
                expectedWindowIdentity: evidence.identity,
                expectedWindowBounds: evidence.bounds)
            await peer.waitUntilFinished()
            let requests = await peer.requests
            #expect(requests.count == 2)
            let bytes = try #require(requests.last)
            guard case let .targetedClick(payload) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self,
                from: bytes)
            else {
                Issue.record("Expected a raw legacy exact-window click")
                await peer.stop()
                return
            }
            #expect(payload.allowsAccessibilityValueDelivery == nil)
            #expect(payload.expectedWindowIdentity == evidence.identity)
            #expect(payload.expectedWindowBounds == evidence.bounds)
            #expect(payload.targetProcessIdentifier == evidence.identity.ownerProcessIdentifier)
            #expect(payload.targetWindowID == evidence.identity.windowID)
            let json = try #require(String(data: bytes, encoding: .utf8))
            #expect(!json.contains("allowsAccessibilityValueDelivery"))
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `exact click wire policy preserves omission true and false with distinct bindings`() throws {
        let policies: [Bool?] = [nil, true, false]
        var hashes: Set<String> = []
        for policy in policies {
            let evidence = Self.evidence
            let request = PeekabooBridgeTargetedClickRequest(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: evidence.identity.ownerProcessIdentifier,
                targetWindowID: evidence.identity.windowID,
                expectedWindowIdentity: evidence.identity,
                expectedWindowBounds: evidence.bounds,
                allowsAccessibilityValueDelivery: policy)
            let bytes = try JSONEncoder.peekabooBridgeEncoder().encode(request)
            let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeTargetedClickRequest.self,
                from: bytes)
            #expect(decoded.allowsAccessibilityValueDelivery == policy)
            #expect(decoded.expectedWindowIdentity == evidence.identity)
            #expect(decoded.expectedWindowBounds == evidence.bounds)
            let fields = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(fields["allowsAccessibilityValueDelivery"] as? Bool == policy)
            #expect((fields["allowsAccessibilityValueDelivery"] == nil) == (policy == nil))
            try hashes.insert(PeekabooBridgeOperationReceiptCoding.sha256(PeekabooBridgeRequest.targetedClick(request)))
        }
        #expect(hashes.count == 3)
    }

    private static var evidence: ExactWindowClickEvidence {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        return ExactWindowClickEvidence(
            identity: WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001,
                capturedBounds: bounds),
            bounds: bounds)
    }
}
