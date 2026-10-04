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
}
