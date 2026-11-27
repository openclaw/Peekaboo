import AppKit
import CoreGraphics
import SwiftUI
import Testing
@testable import PeekabooVisualizer

@MainActor
struct ArrowGuidanceTests {
    @Test
    func `Global display rectangle becomes an onscreen arrow target and placement`() throws {
        let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let globalRect = CGRect(x: 100, y: 50, width: 200, height: 40)
        let appKitRect = VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: globalRect,
            primaryScreenFrame: primary)
        let localRect = VisualizerScreenGeometry.windowLocalRect(appKitRect, in: primary)
        let localPoint = CGPoint(x: localRect.midX, y: localRect.midY)

        #expect(localRect == globalRect)
        let layout = try #require(ArrowGuidanceLayout.make(
            targetPoint: localPoint,
            targetRect: localRect,
            size: primary.size))

        #expect(layout.tip == CGPoint(x: 200, y: 70))
        #expect(layout.targetRect == globalRect)
        #expect(layout.labelCenter.x >= 88)
        #expect(layout.labelCenter.x <= primary.width - 88)
        #expect(layout.labelCenter.y >= 0)
        #expect(layout.labelCenter.y <= primary.height)
    }

    @Test
    func `Edge point keeps the target exact while moving the label inside the screen`() throws {
        let size = CGSize(width: 1440, height: 900)
        let layout = try #require(ArrowGuidanceLayout.make(
            targetPoint: CGPoint(x: 5, y: 5),
            targetRect: nil,
            size: size))

        #expect(layout.tip == CGPoint(x: 5, y: 5))
        #expect(layout.tail.x == 48)
        #expect(layout.labelCenter.x == 88)
        #expect(layout.labelCenter.y >= 0)
        #expect(layout.labelCenter.y <= size.height)
    }

    @Test
    func `Persistent overlay stays registered until explicit dismissal`() {
        _ = NSApplication.shared
        let manager = AnimationOverlayManager()
        let key = "arrow-guidance-test"
        _ = manager.showAnimation(
            at: CGRect(x: 10, y: 10, width: 200, height: 200),
            content: Color.clear,
            duration: nil,
            fadeOut: true,
            chromeMargin: 0,
            replaceKey: key)
        defer { manager.removeAllWindows() }

        #expect(manager.activeReplaceKeys.contains(key))
        #expect(manager.fadeOutAnimation(replaceKey: key))
        #expect(!manager.activeReplaceKeys.contains(key))
    }
}
