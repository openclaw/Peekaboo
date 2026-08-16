import PeekabooFoundation
import Testing

struct AccessibilityActionPolicyTests {
    @Test
    func `Standard actions that can surface UI require foreground consent after normalization`() {
        let actions = [
            "AXPress",
            " press ",
            "AXPick",
            "pick",
            "AXConfirm",
            "cancel",
            "AXOpen",
            "AXRaise",
            "AXScrollToVisible",
            "AXShowAlternateUI",
            "AXShowDefaultUI",
            "AXShowMenu",
        ]

        for action in actions {
            #expect(AccessibilityActionPolicy.classification(action) == .foregroundCapable)
            #expect(AccessibilityActionPolicy.requiresForegroundConsent(action))
        }
    }

    @Test
    func `Known value adjustments remain background safe`() {
        for action in ["AXIncrement", "increment", " AXDECREMENT\n", "decrement"] {
            #expect(AccessibilityActionPolicy.classification(action) == .backgroundSafe)
            #expect(!AccessibilityActionPolicy.requiresForegroundConsent(action))
        }
    }

    @Test
    func `Unclassified actions fail closed at foreground consent boundaries`() {
        for action in ["", "  ", "AX", "AXCustomAction", "customaction"] {
            #expect(AccessibilityActionPolicy.classification(action) == .unclassified)
            #expect(AccessibilityActionPolicy.requiresForegroundConsent(action))
        }
    }
}
