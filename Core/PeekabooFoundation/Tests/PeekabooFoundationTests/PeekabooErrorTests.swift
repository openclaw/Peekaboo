import PeekabooFoundation
import Testing

struct PeekabooErrorTests {
    @Test
    func `incomplete Accessibility evidence has a stable public code and fresh-observation recovery`() {
        let error = PeekabooError.accessibilityIncomplete(
            "AX tree incomplete. Retry once to obtain a fresh observation.")

        #expect(error.code == .accessibilityIncomplete)
        #expect(error.errorCode == "ACCESSIBILITY_INCOMPLETE")
        #expect(error.category == .automation)
        #expect(error.context["message"]?.contains("fresh observation") == true)
        #expect(error.recoverySuggestion?.contains("fresh exact-window") == true)
        #expect(error.suggestedAction?.contains("fresh exact-window") == true)
    }
}
