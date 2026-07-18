import CoreGraphics
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooCLI

@Suite("Window JSON metadata")
struct WindowInfoMetadataTests {
    @Test
    func `CLI maps key frontmost layer and subrole fields`() {
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
            isOnScreen: true
        )

        let mapped = WindowInfo(serviceWindow: source)

        #expect(mapped.window_id == 541)
        #expect(mapped.is_key == true)
        #expect(mapped.is_frontmost == true)
        #expect(mapped.layer == 0)
        #expect(mapped.subrole == "AXStandardWindow")
    }
}
