import CoreGraphics
import PeekabooAutomation
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct SeeToolVisualizerTests {
    @Test
    func `Global conversion flips against the primary display`() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)

        // Element on the primary display.
        let onPrimary = VisualizerBoundsConverter.convertGlobalAccessibilityRect(
            CGRect(x: 120, y: 50, width: 200, height: 40),
            primaryScreenFrame: primary)
        #expect(onPrimary == CGRect(x: 120, y: 900 - 50 - 40, width: 200, height: 40))

        // Element on a display arranged ABOVE the primary: global accessibility
        // coordinates are negative there, and the same primary-height flip must
        // land it above the primary in AppKit space.
        let onUpperDisplay = VisualizerBoundsConverter.convertGlobalAccessibilityRect(
            CGRect(x: 100, y: -1100, width: 200, height: 40),
            primaryScreenFrame: primary)
        #expect(onUpperDisplay == CGRect(x: 100, y: 900 + 1100 - 40, width: 200, height: 40))
    }

    @Test
    func `Global conversion passes rects through without a primary screen`() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(VisualizerBoundsConverter.convertGlobalAccessibilityRect(rect, primaryScreenFrame: nil) == rect)
    }

    @Test
    func `Global conversion handles displays below the primary`() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let below = VisualizerBoundsConverter.convertGlobalAccessibilityRect(
            CGRect(x: -100, y: 1000, width: 200, height: 40),
            primaryScreenFrame: primary)

        #expect(below == CGRect(x: -100, y: -140, width: 200, height: 40))
    }

    @Test
    func `Element detection dispatch requires config or env opt-in`() {
        // Regression: element boxes default to OFF — no env, no config ⇒ no dispatch.
        #expect(!SeeTool.elementDetectionVisualsEnabled(environment: [:], configuration: nil))

        var config = PeekabooAutomation.Configuration()
        #expect(!SeeTool.elementDetectionVisualsEnabled(environment: [:], configuration: config))

        // config.json opt-in enables dispatch.
        config.visualizer = PeekabooAutomation.Configuration.VisualizerConfig(elementDetectionEnabled: true)
        #expect(SeeTool.elementDetectionVisualsEnabled(environment: [:], configuration: config))

        // The env var overrides config in both directions.
        #expect(!SeeTool.elementDetectionVisualsEnabled(
            environment: ["PEEKABOO_VISUAL_ELEMENT_BOXES": "false"],
            configuration: config))
        #expect(SeeTool.elementDetectionVisualsEnabled(
            environment: ["PEEKABOO_VISUAL_ELEMENT_BOXES": "true"],
            configuration: nil))
    }

    @Test
    func `Produces protocol elements with flipped coordinates`() {
        let sample = PeekabooAutomation.DetectedElement(
            id: "B1",
            type: .button,
            label: "Submit",
            value: nil,
            bounds: CGRect(x: 10, y: 20, width: 60, height: 24),
            isEnabled: true)

        let elements = VisualizerBoundsConverter.makeVisualizerElements(
            from: [sample],
            primaryScreenFrame: CGRect(x: 0, y: 0, width: 300, height: 200))

        #expect(elements.count == 1)
        guard let first = elements.first else {
            Issue.record("Expected at least one converted element")
            return
        }
        let expectedY: CGFloat = 200 - 20 - 24
        #expect(first.bounds.origin.y == expectedY)
    }
}
