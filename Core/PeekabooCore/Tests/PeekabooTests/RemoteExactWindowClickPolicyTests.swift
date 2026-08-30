import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing

@MainActor
struct RemoteExactWindowClickPolicyTests {
    @Test(arguments: [false, true])
    func `explicit policy refuses unsupported remote before invalid bounds or transport`(policy: Bool) async throws {
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/peekaboo-unused-exact-policy-\(UUID().uuidString).sock",
                requestTimeoutSec: 1),
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: true)
        let evidence = ExactWindowClickEvidence(
            identity: WindowMutationIdentity(
                windowID: 71,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 1001,
                capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200)),
            bounds: .zero)
        let clicks: any ExactWindowTargetedClickServiceProtocol = remote
        let outcomes: any UIAutomationActionOutcomeProviding = remote

        do {
            try await clicks.click(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: nil,
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: policy)
            Issue.record("Expected explicit-policy capability refusal without connecting")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message == "Remote bridge host cannot honor an explicit accessibility-value click policy")
        }

        do {
            _ = try await outcomes.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: nil,
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: policy)
            Issue.record("Expected explicit-policy capability refusal without connecting")
        } catch let PeekabooError.serviceUnavailable(message) {
            #expect(message == "Remote bridge host cannot honor an explicit accessibility-value click policy")
        }
    }
}
