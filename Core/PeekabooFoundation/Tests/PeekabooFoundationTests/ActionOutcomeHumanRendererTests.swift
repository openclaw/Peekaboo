import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing

struct ActionOutcomeHumanRendererTests {
    @Test
    func `reported outcomes share state and escalation aware wording`() {
        let expected = [
            "✅ Click confirmed",
            "✅ Click confirmed; no change was needed",
            "⚠️ Click partially completed; recover the remaining side effect before another attempt",
            "⚠️ Click dispatched but not verified; observe the target before retrying",
            "⚠️ Click may have had no effect; refresh the target before retrying",
            "⛔ Click refused before dispatch; grant the required permission before retrying",
            "⚠️ Click outcome is indeterminate; observe the target before retrying",
        ]
        for (outcome, line) in zip(DesktopActionOutcomeFixtures.canonicalOutcomes, expected) {
            #expect(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Click") == line)
        }
    }

    @Test
    func `unreported outcome is neither confirmation nor an inferred canonical state`() {
        let line = ActionOutcomeHumanRenderer.statusLine(for: nil, operation: "Scroll")
        #expect(line == "⚠️ Scroll request completed; receiver effect was not reported; " +
            "observe the target before retrying")
        #expect(!line.contains("confirmed"))
        #expect(!line.contains("dispatched"))
        #expect(!line.contains("retry-safe"))
    }
}
