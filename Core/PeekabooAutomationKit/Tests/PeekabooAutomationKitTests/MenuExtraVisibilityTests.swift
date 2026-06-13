import CoreGraphics
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@MainActor
struct MenuExtraVisibilityTests {
    private let primaryDisplay = CGRect(x: 0, y: 0, width: 1800, height: 1169)
    private let leftDisplay = CGRect(x: -1440, y: 0, width: 1440, height: 900)

    @Test
    func `offscreen parked menu extra is not visible`() {
        let frame = CGRect(x: -4520, y: 8, width: 26, height: 24)

        #expect(!MenuService.isMenuExtraFrameVisible(frame, displayBounds: [self.primaryDisplay]))
        #expect(!MenuService.isMenuExtraPointVisible(
            CGPoint(x: frame.midX, y: frame.midY),
            displayBounds: [self.primaryDisplay]))
    }

    @Test
    func `menu extra on primary display is visible`() {
        let frame = CGRect(x: 1258, y: 8, width: 28, height: 24)

        #expect(MenuService.isMenuExtraFrameVisible(frame, displayBounds: [self.primaryDisplay]))
        #expect(MenuService.isMenuExtraPointVisible(
            CGPoint(x: frame.midX, y: frame.midY),
            displayBounds: [self.primaryDisplay]))
    }

    @Test
    func `negative coordinate secondary display remains valid`() {
        let frame = CGRect(x: -100, y: 8, width: 28, height: 24)
        let displays = [self.primaryDisplay, self.leftDisplay]

        #expect(MenuService.isMenuExtraFrameVisible(frame, displayBounds: displays))
        #expect(MenuService.isMenuExtraPointVisible(
            CGPoint(x: frame.midX, y: frame.midY),
            displayBounds: displays))
    }

    @Test
    func `parked section spanning onto display is not visible`() {
        let frame = CGRect(x: -3793, y: 0, width: 5010, height: 39)

        #expect(frame.intersects(self.primaryDisplay))
        #expect(!MenuService.isMenuExtraFrameVisible(frame, displayBounds: [self.primaryDisplay]))
    }

    @Test
    func `offscreen AX position remains a plausible hidden menu extra`() {
        let service = MenuService()

        #expect(service.isLikelyMenuBarAXPosition(CGPoint(x: -4500, y: 20)))
        #expect(!service.isMenuExtraAXPositionVisible(CGPoint(x: -4500, y: 20)))
        #expect(!service.isLikelyMenuBarAXPosition(CGPoint(x: -4500, y: 500)))
    }

    @Test
    func `offscreen target with visible peers is individually hidden`() {
        let target = CGPoint(x: -4500, y: 20)

        #expect(MenuService.isIndividuallyHiddenMenuExtra(
            position: target,
            allPositions: [target, CGPoint(x: 1200, y: 20)],
            displayBounds: [self.primaryDisplay]))
    }

    @Test
    func `fully auto hidden menu bar can use AX action`() {
        let target = CGPoint(x: -4500, y: 20)

        #expect(!MenuService.isIndividuallyHiddenMenuExtra(
            position: target,
            allPositions: [target, CGPoint(x: -4400, y: 20)],
            displayBounds: [self.primaryDisplay]))
    }

    @Test
    func `window visibility remains authoritative when merging AX metadata`() {
        let position = CGPoint(x: -4500, y: 20)
        let windowExtra = MenuExtraInfo(
            title: "Hidden Item",
            position: position,
            isVisible: false,
            windowID: 42,
            source: "cgs")
        let accessibilityExtra = MenuExtraInfo(
            title: "Hidden Item",
            position: position,
            isVisible: true,
            identifier: "example.hidden-item",
            source: "ax-menubar")

        let merged = MenuService.mergeMenuExtras(
            accessibilityExtras: [accessibilityExtra],
            fallbackExtras: [windowExtra])

        #expect(merged.count == 1)
        #expect(merged.first?.isVisible == false)
        #expect(merged.first?.identifier == "example.hidden-item")
        #expect(merged.first?.windowID == 42)
    }
}
