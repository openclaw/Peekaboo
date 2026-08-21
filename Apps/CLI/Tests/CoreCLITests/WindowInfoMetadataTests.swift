import CoreGraphics
import Foundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooCLI

@Suite("Window JSON metadata")
struct WindowInfoMetadataTests {
    @Test
    func `CLI maps focus and observation capability fields`() throws {
        let source = ServiceWindowInfo(
            windowID: 541,
            title: "Actions settings · openclaw",
            bounds: CGRect(x: 773, y: 52, width: 1151, height: 996),
            isKeyWindow: true,
            isFrontmost: true,
            subrole: "AXStandardWindow",
            windowLevel: 0,
            index: 3,
            layer: 0,
            isOnScreen: true,
            observationCapability: .pixelsOnly(reason: .noMatchingAccessibilityWindow)
        )

        let mapped = WindowInfo(serviceWindow: source)

        #expect(mapped.window_id == 541)
        #expect(mapped.is_key == true)
        #expect(mapped.is_frontmost == true)
        #expect(mapped.layer == 0)
        #expect(mapped.subrole == "AXStandardWindow")
        #expect(mapped.observation_capability == .pixelsOnly)
        #expect(mapped.observation_capability_reason == .noMatchingAccessibilityWindow)

        let object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(mapped)
        ) as? [String: Any])
        #expect(object["observation_capability"] as? String == "pixels_only")
        #expect(object["observation_capability_reason"] as? String == "no_matching_accessibility_window")
    }

    @Test
    @MainActor
    func `CLI text gives screenshot-only guidance for pixels-only windows`() {
        let description = WindowCommand.WindowListSubcommand.observationDescription(
            .pixelsOnly(reason: .noMatchingAccessibilityWindow),
            windowID: 541
        )

        #expect(description.contains("pixels_only"))
        #expect(description.contains("no_matching_accessibility_window"))
        #expect(description.contains("see --window-id 541 --no-elements"))
    }

    @Test
    @MainActor
    func `CLI text keeps incomplete Accessibility eligibility unknown`() {
        let description = WindowCommand.WindowListSubcommand.observationDescription(
            .unknown(reason: .accessibilityEnumerationIncomplete),
            windowID: 541
        )

        #expect(description.contains("unknown"))
        #expect(description.contains("accessibility_enumeration_incomplete"))
        #expect(description.contains("refresh the window inventory"))
        #expect(!description.contains("--no-elements"))
    }
}
