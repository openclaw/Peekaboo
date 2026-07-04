import CoreGraphics
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ScreenServiceCoordinateTests {
    @Test
    func `Screen lookup converts global display bounds before vertical matching`() {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let above = CGRect(x: 0, y: 900, width: 1440, height: 900)
        let below = CGRect(x: 0, y: -900, width: 1440, height: 900)

        #expect(ScreenService.screenIndex(
            containingGlobalDisplayBounds: CGRect(x: 100, y: -800, width: 300, height: 200),
            appKitScreenFrames: [primary, above, below],
            primaryScreenFrame: primary) == 1)
        #expect(ScreenService.screenIndex(
            containingGlobalDisplayBounds: CGRect(x: 100, y: 1500, width: 300, height: 200),
            appKitScreenFrames: [primary, above, below],
            primaryScreenFrame: primary) == 2)
    }

    @Test
    func `Screen lookup falls back to largest overlap`() {
        let primary = CGRect(x: 0, y: 0, width: 100, height: 100)
        let right = CGRect(x: 100, y: 0, width: 100, height: 100)

        #expect(ScreenService.screenIndex(
            containingGlobalDisplayBounds: CGRect(x: -80, y: 10, width: 120, height: 80),
            appKitScreenFrames: [primary, right],
            primaryScreenFrame: primary) == 0)
    }
}
