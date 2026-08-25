import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite("Bridge targeted-click value semantics")
struct PeekabooBridgeTargetedClickValueSemanticsTests {
    @Test
    func `single targeted click accepts one verified background focus value write`() throws {
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 9001,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        let bounds = try #require(identity.capturedBounds)
        let focus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one)

        for request in [
            PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                expectedProcessIdentity: identity.processIdentity)),
            PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: identity.ownerProcessIdentifier,
                targetWindowID: identity.windowID,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)),
        ] {
            #expect(PeekabooBridgeOperationResultSemantics.successfulOutcomeMatchesContract(
                focus,
                response: .ok,
                request: request))
        }
    }
}
