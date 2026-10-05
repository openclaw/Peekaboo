import CoreGraphics
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
struct ApplicationMenuExtraTests {
    @Test
    func `Menu discovery fails closed when its shared deadline expires`() {
        #expect(throws: (any Error).self) {
            try MenuExtraAXReader.check(ContinuousClock.now.advanced(by: .seconds(-1)))
        }
    }

    @Test
    func `Same owner retains its routable window identity`() {
        let host = MenuExtraInfo(
            title: "Battery", position: CGPoint(x: 100, y: 16), windowID: 42, ownerPID: 20, source: "cgs")
        let item = MenuExtraInfo(
            title: "Battery", position: CGPoint(x: 100, y: 16), ownerPID: 20, source: "ax-extras")
        let merged = MenuService.mergeMenuExtras(accessibilityExtras: [item], fallbackExtras: [host])
        #expect(merged.count == 1)
        #expect(merged[0].ownerPID == 20)
        #expect(merged[0].windowID == 42)
    }

    @Test
    func `AppKit proxy windows retain the actual AX owner without mixing identities`() {
        let host = MenuExtraInfo(
            title: "Control Center",
            bundleIdentifier: "com.apple.controlcenter",
            position: CGPoint(x: 1076, y: 16.5),
            windowID: 42,
            ownerPID: 10,
            source: "cgs")
        let item = MenuExtraInfo(
            title: "Fixture",
            bundleIdentifier: "test.fixture",
            position: CGPoint(x: 1076, y: 16.5),
            ownerPID: 20,
            source: "ax-extras")
        let merged = MenuService.mergeMenuExtras(accessibilityExtras: [item], fallbackExtras: [host])
        #expect(merged.count == 1)
        #expect(merged[0].title == "Fixture")
        #expect(merged[0].ownerPID == 20)
        #expect(merged[0].bundleIdentifier == "test.fixture")
        #expect(merged[0].windowID == nil)
    }

    @Test
    func `Coincident items belonging to different applications remain ambiguous`() {
        let first = MenuExtraInfo(
            title: "Fixture", position: CGPoint(x: 100, y: 16), ownerPID: 20, source: "ax-extras")
        let second = MenuExtraInfo(
            title: "Fixture", position: CGPoint(x: 100, y: 16), ownerPID: 30, source: "ax-extras")
        #expect(MenuService.mergeMenuExtras(accessibilityExtras: [first, second], fallbackExtras: []).count == 2)
    }
}
