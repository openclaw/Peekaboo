import AppKit
import Testing
@testable import PeekabooVisualizer

@MainActor
struct VisualizerOverlayWindowPolicyTests {
    @Test
    func `Overlay windows ignore app hiding without accepting input or presenting themselves`() {
        _ = NSApplication.shared
        let frame = CGRect(x: 32, y: 32, width: 64, height: 64)
        let window = AnimationOverlayManager.makeOverlayWindow(at: frame)
        defer { window.close() }

        #expect(window.frame == frame)
        #expect(!window.canHide)
        #expect(window.ignoresMouseEvents)
        #expect(!window.canBecomeKey)
        #expect(!window.canBecomeMain)
        #expect(!window.isVisible)
        #expect(window.styleMask == .borderless)
        #expect(window.level == .screenSaver)
        #expect(!window.isOpaque)
        #expect(!window.hasShadow)
        #expect(!window.isReleasedWhenClosed)
    }
}
