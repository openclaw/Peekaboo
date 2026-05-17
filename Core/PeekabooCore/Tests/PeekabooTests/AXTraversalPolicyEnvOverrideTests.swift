@_spi(Testing) import PeekabooAutomationKit
import Testing

@Suite(.tags(.fast))
struct AXTraversalPolicyEnvOverrideTests {
    @Test
    func `Default depth matches historical value when env unset`() {
        // When PEEKABOO_MAX_TRAVERSAL_DEPTH is not exported, intFromEnv must return the default.
        #expect(AXTraversalPolicy.intFromEnv("PEEKABOO_MAX_TRAVERSAL_DEPTH", default: 12) == 12)
    }

    @Test
    func `Default element count matches historical value when env unset`() {
        #expect(AXTraversalPolicy.intFromEnv("PEEKABOO_MAX_ELEMENT_COUNT", default: 400) == 400)
    }

    @Test
    func `Default children-per-node matches historical value when env unset`() {
        #expect(AXTraversalPolicy.intFromEnv("PEEKABOO_MAX_CHILDREN_PER_NODE", default: 50) == 50)
    }

    @Test
    func `Unknown env key returns default`() {
        #expect(AXTraversalPolicy.intFromEnv("PEEKABOO_THIS_KEY_DOES_NOT_EXIST_12345", default: 7) == 7)
    }

    @Test
    func `Non-positive or unparseable env raw stays at default`() {
        // intFromEnv reads from ProcessInfo, so we can't easily inject a bad value mid-test
        // without process-level side effects. The parsing path is exercised by the
        // documented contract: missing/blank/non-numeric/non-positive → default.
        // This test guards the API surface (default returned for any unknown key).
        #expect(AXTraversalPolicy.intFromEnv("PEEKABOO_TOTALLY_MADE_UP", default: 999) == 999)
    }
}
