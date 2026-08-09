import CoreGraphics
import Foundation
import Testing
@testable import PeekabooVisualizer

struct TargetWindowVisibilityEvaluatorTests {
    private static func windowEntry(
        pid: Int32,
        windowID: UInt32,
        layer: Int = 0,
        alpha: Double = 1,
        onScreen: Bool = true,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 300, height: 200)) -> [String: Any]
    {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowNumber as String: NSNumber(value: windowID),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowIsOnscreen as String: NSNumber(value: onScreen),
            kCGWindowBounds as String: [
                "X": bounds.origin.x, "Y": bounds.origin.y,
                "Width": bounds.width, "Height": bounds.height,
            ],
        ]
    }

    @Test
    func `Frontmost window of the pid resolves to its bounds`() {
        let info = [
            Self.windowEntry(pid: 99, windowID: 1), // other app in front
            Self.windowEntry(pid: 42, windowID: 7),
            Self.windowEntry(pid: 42, windowID: 8),
        ]
        let frame = TargetWindowVisibilityEvaluator.frontmostWindowBounds(ofPID: 42, windowID: 7, in: info)
        #expect(frame == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test
    func `Window occluded by a sibling of the same app is rejected`() {
        let info = [
            Self.windowEntry(pid: 42, windowID: 8), // sibling covers the target
            Self.windowEntry(pid: 42, windowID: 7),
        ]
        #expect(TargetWindowVisibilityEvaluator.frontmostWindowBounds(ofPID: 42, windowID: 7, in: info) == nil)
    }

    @Test
    func `Non-ordinary siblings do not shadow the target`() {
        let info = [
            Self.windowEntry(pid: 42, windowID: 5, layer: 25), // floating panel, ignored
            Self.windowEntry(pid: 42, windowID: 6, alpha: 0), // invisible, ignored
            Self.windowEntry(pid: 42, windowID: 9, onScreen: false), // off-screen, ignored
            Self.windowEntry(pid: 42, windowID: 7),
        ]
        #expect(TargetWindowVisibilityEvaluator.frontmostWindowBounds(ofPID: 42, windowID: 7, in: info) != nil)
    }

    @Test
    func `Missing window is rejected`() {
        let info = [Self.windowEntry(pid: 42, windowID: 8)]
        #expect(TargetWindowVisibilityEvaluator.frontmostWindowBounds(ofPID: 42, windowID: 3, in: info) == nil)
    }
}
