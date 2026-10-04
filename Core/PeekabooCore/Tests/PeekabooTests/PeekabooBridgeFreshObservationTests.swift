import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeFreshObservationTests: DesktopObservationBindingFixtureProviding {
    @Test(arguments: [false, true])
    func `fresh capability gates transport while ordinary requests remain compatible`(capable: Bool) async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: version,
            supportedOperations: [.desktopObservation],
            hostCapabilities: capable ? [PeekabooBridgeHostCapability.desktopObservationFreshAccessibilityTree] : [])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .desktopObservation(Self.screenResult(index: 0)),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        do {
            _ = try await client.handshake(
                client: .init(
                    bundleIdentifier: "dev.peekaboo.fresh-tests",
                    teamIdentifier: nil,
                    processIdentifier: getpid()),
                protocolVersion: version)
            let fresh = DesktopObservationRequest(
                target: .screen(index: 0), detection: .init(requiresFreshAccessibilityTree: true))
            if !capable {
                let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                    try await client.send(.desktopObservation(fresh))
                }
                #expect(error?.code == .operationNotSupported)
                #expect(error?.message
                    .contains(PeekabooBridgeHostCapability.desktopObservationFreshAccessibilityTree) == true)
                #expect(await peer.requests.count == 1)
            }
            _ = try await client.send(.desktopObservation(capable ? fresh : DesktopObservationRequest(
                target: .screen(index: 0), detection: .init(mode: .none))))
            await peer.waitUntilFinished()
            let requests = await peer.requests
            #expect(requests.count == 2)
            let bytes = try #require(requests.last)
            #expect(try #require(String(data: bytes, encoding: .utf8))
                .contains("requiresFreshAccessibilityTree") == capable)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test(arguments: ["AXorcist", "AXorcist (cached)", "ignored", "unknown"])
    func `signed observation binding requires acknowledged uncached evidence`(method: String) async throws {
        let options = DesktopDetectionOptions(requiresFreshAccessibilityTree: true)
        let request = DesktopObservationRequest(target: .screen(index: 0), detection: options)
        let result = Self.replacingElements(Self.screenResult(index: 0), with: ElementDetectionResult(
            snapshotId: "fresh-binding",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: method == "ignored" ? "AXorcist" : method,
                windowContext: WindowContext(
                    shouldFocusWebContent: false,
                    includeMenuBarElements: false,
                    traversalBudget: options.traversalBudget,
                    requiresFreshAccessibilityTree: method != "ignored"),
                truncationInfo: DetectionTruncationInfo(deadlineReached: true))))
        let accepted = method == "AXorcist"
        #expect((PeekabooBridgeDesktopObservationBinding.mismatch(request: request, result: result) == nil) == accepted)
        let signed = try await Self.makeBundle(
            request: .desktopObservation(request), response: .desktopObservation(result), target: .global)
        if accepted {
            try signed.validateIntegrity()
        } else {
            #expect(throws: PeekabooBridgeOperationReceiptError.self) { try signed.validateIntegrity() }
        }
    }

    @Test
    func `signed pixel only request cannot claim freshness`() async throws {
        let request = DesktopObservationRequest(
            target: .screen(index: 0), detection: .init(mode: .none, requiresFreshAccessibilityTree: true))
        let result = Self.screenResult(index: 0)
        #expect(PeekabooBridgeDesktopObservationBinding.mismatch(request: request, result: result)
            == "fresh accessibility request without detection")
        let signed = try await Self.makeBundle(
            request: .desktopObservation(request), response: .desktopObservation(result), target: .global)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) { try signed.validateIntegrity() }
    }
}
