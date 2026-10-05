import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooCLI

struct ActionOutcomePresentationTests {
    private struct Payload: Codable {
        let requestedUnits: Int
    }

    @Test
    func `human presentation preserves success envelopes and absent outcome evidence`() throws {
        let outcomes: [DesktopActionOutcome?] = [nil] + DesktopActionOutcomeFixtures.canonicalOutcomes.map(\.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        for outcome in outcomes {
            let envelope = makeSuccessEnvelope(
                data: Payload(requestedUnits: 1),
                effect: .unverifiable,
                outcome: outcome
            )
            let before = try encoder.encode(envelope)
            let line = ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Scroll")
            let after = try encoder.encode(envelope)
            #expect(before == after)
            #expect(envelope.success)
            #expect(envelope.outcome == outcome?.projection)
            #expect(envelope.effect == (outcome?.effect ?? .unverifiable))
            if outcome == nil {
                #expect(line.contains("receiver effect was not reported"))
                #expect(!line.contains("confirmed"))
                let object = try #require(JSONSerialization.jsonObject(with: after) as? [String: Any])
                #expect(object["outcome"] == nil)
                #expect(object["target_receipt"] == nil)
            }
        }
    }

    @Test
    @MainActor
    func `verified outcome promotion drives canonical JSON and human status`() throws {
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3)
        )
        let postconditionOnly = try #require(canonicalActionOutcomeAfterSuccessfulVerification(dispatched))
        let promoted = try #require(canonicalActionOutcomeAfterSuccessfulVerification(
            dispatched,
            observedChange: true
        ))
        let verifiedNoChange = try #require(canonicalActionOutcomeAfterSuccessfulVerification(
            dispatched,
            observedChange: false
        ))
        let envelope = try makeSuccessEnvelope(
            data: Empty?.none,
            effect: .unverifiable,
            outcome: promoted,
            targetIdentity: Self.windowTarget()
        )

        #expect(postconditionOnly == dispatched)
        #expect(promoted.state == .confirmedChange)
        #expect(promoted.route == .bridge)
        #expect(promoted.delivery == dispatched.delivery)
        #expect(promoted.dispatchState.unitCount == dispatched.dispatchState.unitCount)
        #expect(envelope.effect == .confirmed)
        #expect(envelope.outcome?.state == .confirmedChange)
        #expect(envelope.target_receipt?.windowID == 73)
        #expect(ActionOutcomeHumanRenderer.statusLine(
            for: promoted,
            operation: "Window focus"
        ) == "✅ Window focus confirmed")
        #expect(verifiedNoChange == dispatched)
        #expect(verifiedNoChange.delivery == dispatched.delivery)
        #expect(verifiedNoChange.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(3))
        let noChangeEnvelope = try makeSuccessEnvelope(
            data: Empty?.none,
            effect: .unverifiable,
            outcome: verifiedNoChange,
            targetIdentity: Self.windowTarget()
        )
        #expect(noChangeEnvelope.outcome?.state == .dispatchedUnverified)
        #expect(noChangeEnvelope.outcome?.retrySafe == false)
        #expect(noChangeEnvelope.outcome?.requiresFreshObservation == true)
        #expect(ActionOutcomeHumanRenderer.statusLine(
            for: verifiedNoChange,
            operation: "Window focus"
        ) == "⚠️ Window focus dispatched but not verified; observe the target before retrying")

        let noChange = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        let idempotent = try #require(canonicalActionOutcomeAfterSuccessfulVerification(noChange))
        #expect(idempotent == noChange)
        #expect(canonicalActionOutcomeAfterSuccessfulVerification(noChange, observedChange: false) == noChange)
        #expect(idempotent.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(ActionOutcomeHumanRenderer.statusLine(
            for: idempotent,
            operation: "Dock launch"
        ) == "✅ Dock launch confirmed; no change was needed")
    }

    @Test
    func `clipboard cleanup presentation requires its own status evidence`() {
        let cases: [(ClipboardTemporaryCleanupStatus?, String)] = [
            (nil, "Clipboard cleanup status was not reported."),
            (.restored, "Clipboard restored."),
            (.preservedNewerContents, "Newer clipboard contents preserved."),
            (.notNeeded, "Clipboard cleanup was not needed."),
        ]
        for (status, expected) in cases {
            #expect(ClipboardTemporaryCleanupStatus.humanDescription(for: status) == expected)
            if status != .restored {
                #expect(!expected.contains("restored"))
            }
        }
    }

    private static func windowTarget() throws -> DesktopTargetIdentity {
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds
        )
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds
        ))
    }
}
