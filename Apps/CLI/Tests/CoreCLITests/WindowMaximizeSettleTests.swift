import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

/// Fake window whose green-button zoom is a toggle and whose frame changes asynchronously across
/// reads, mirroring AppKit: `maximize` presses an animated toggle, so an immediate read-back returns
/// an intermediate frame, and pressing again on an already-maximized window restores the user frame.
///
/// `zoomTarget` is the frame the zoom button produces from the user frame. For most apps this fills
/// the screen (`maxFrame`), but some apps zoom to a preferred size smaller than the current window.
@MainActor
private final class FakeZoomWindow {
    private(set) var isMaximized: Bool
    private(set) var pressCount = 0
    let userFrame: CGRect
    let zoomTarget: CGRect
    let title: String
    /// Number of upcoming reads that return a mid-animation frame before the settled frame appears.
    private var pendingIntermediateReads = 0

    init(isMaximized: Bool, userFrame: CGRect, zoomTarget: CGRect, title: String = "Zoom Fixture") {
        self.isMaximized = isMaximized
        self.userFrame = userFrame
        self.zoomTarget = zoomTarget
        self.title = title
    }

    var currentInfo: ServiceWindowInfo {
        self.info(self.isMaximized ? self.zoomTarget : self.userFrame)
    }

    func press() {
        self.pressCount += 1
        self.isMaximized.toggle()
        // The zoom animation makes the first read after a press return an intermediate frame.
        self.pendingIntermediateReads = 1
    }

    func read() -> ServiceWindowInfo? {
        let settledFrame = self.isMaximized ? self.zoomTarget : self.userFrame
        if self.pendingIntermediateReads > 0 {
            self.pendingIntermediateReads -= 1
            return self.info(self.intermediateFrame(towards: settledFrame))
        }
        return self.info(settledFrame)
    }

    private func intermediateFrame(towards target: CGRect) -> CGRect {
        // Midpoint between the two toggle states: clearly different from the settled target so the
        // settle loop must poll at least once more.
        let other = self.isMaximized ? self.userFrame : self.zoomTarget
        return CGRect(
            x: (target.origin.x + other.origin.x) / 2,
            y: (target.origin.y + other.origin.y) / 2,
            width: (target.size.width + other.size.width) / 2,
            height: (target.size.height + other.size.height) / 2
        )
    }

    private func info(_ frame: CGRect) -> ServiceWindowInfo {
        ServiceWindowInfo(windowID: 7, title: self.title, bounds: frame)
    }
}

@MainActor
struct WindowMaximizeSettleTests {
    private let userFrame = CGRect(x: 463, y: 179, width: 700, height: 500)
    private let maxFrame = CGRect(x: 0, y: 0, width: 3200, height: 1690)
    /// The maximized frame in the same top-left space as window bounds, as the command would pass it.
    private var screenFrames: [CGRect] {
        [CGRect(x: 0, y: 0, width: 3200, height: 1690)]
    }

    // MARK: - Settle logic

    @Test func `settle returns the stabilized frame, not the first read`() async {
        // The zoom animation surfaces two intermediate frames before the window settles.
        let mid1 = ServiceWindowInfo(windowID: 1, title: "W", bounds: CGRect(x: -1050, y: 150, width: 586, height: 488))
        let mid2 = ServiceWindowInfo(windowID: 1, title: "W", bounds: CGRect(x: -400, y: 60, width: 1800, height: 1100))
        let settled = ServiceWindowInfo(windowID: 1, title: "W", bounds: self.maxFrame)
        var frames = [mid1, mid2, settled, settled, settled]

        let result = await settleWindowFrame(pollInterval: .zero) {
            frames.isEmpty ? nil : frames.removeFirst()
        }

        #expect(result.stabilized)
        #expect(result.info?.bounds == self.maxFrame)
    }

    @Test func `settle reports not stabilized when the frame never settles`() async {
        var counter = 0
        let result = await settleWindowFrame(maxAttempts: 5, pollInterval: .zero) {
            counter += 1
            // Every read is a different frame, so it can never stabilize.
            return ServiceWindowInfo(
                windowID: 1,
                title: "W",
                bounds: CGRect(x: CGFloat(counter) * 10, y: 0, width: 800, height: 600)
            )
        }
        #expect(!result.stabilized)
        #expect(result.info != nil)
    }

    // MARK: - Coordinate conversion & maximized detection

    @Test func `AppKit frame flips into the top-left coordinate space`() {
        // Primary display 1800pt tall; visible frame excludes a 25pt menu bar and a 110pt dock.
        let visible = CGRect(x: 0, y: 110, width: 3200, height: 1665)
        let converted = convertAppKitFrameToTopLeft(visible, primaryDisplayHeight: 1800)
        #expect(converted == CGRect(x: 0, y: 25, width: 3200, height: 1665))
    }

    @Test func `maximized detection matches a window at the visible frame`() {
        #expect(windowMatchesAnyScreen(bounds: self.maxFrame, screenVisibleFramesTopLeft: self.screenFrames))
    }

    @Test func `maximized detection tolerates sub-threshold rounding`() {
        let jittered = CGRect(x: 1, y: 1, width: 3199, height: 1689)
        #expect(windowMatchesAnyScreen(bounds: jittered, screenVisibleFramesTopLeft: self.screenFrames))
    }

    @Test func `maximized detection rejects a screen-sized window that was moved`() {
        // Same size as the screen but displaced: NOT maximized (reviewer regression).
        let displaced = CGRect(x: 500, y: 300, width: 3200, height: 1690)
        #expect(!windowMatchesAnyScreen(bounds: displaced, screenVisibleFramesTopLeft: self.screenFrames))
    }

    @Test func `maximized detection rejects an oversized window`() {
        let oversized = CGRect(x: 0, y: 0, width: 3000, height: 1600)
        #expect(!windowMatchesAnyScreen(bounds: oversized, screenVisibleFramesTopLeft: self.screenFrames))
    }

    // MARK: - Idempotent maximize

    @Test func `maximize from a normal window reports the settled maximized frame`() async throws {
        let window = FakeZoomWindow(isMaximized: false, userFrame: self.userFrame, zoomTarget: self.maxFrame)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        #expect(window.isMaximized)
        #expect(window.pressCount == 1)
        #expect(outcome.info?.bounds == self.maxFrame)
        #expect(!outcome.alreadyMaximized)
        #expect(outcome.stabilized)
    }

    @Test func `maximizing an already-maximized window is a no-op that stays maximized`() async throws {
        // Already screen-sized: pressing the toggle would un-maximize it, so it must be skipped.
        let window = FakeZoomWindow(isMaximized: true, userFrame: self.userFrame, zoomTarget: self.maxFrame)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        #expect(window.isMaximized)
        #expect(window.pressCount == 0) // no toggle press at all
        #expect(outcome.info?.bounds == self.maxFrame)
        #expect(outcome.alreadyMaximized)
    }

    @Test func `maximize twice in a row leaves the window maximized`() async throws {
        let window = FakeZoomWindow(isMaximized: false, userFrame: self.userFrame, zoomTarget: self.maxFrame)

        let first = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )
        #expect(window.isMaximized)
        #expect(first.info?.bounds == self.maxFrame)
        #expect(!first.alreadyMaximized)

        // Second call: the window now fills the screen, so it must be a no-op, not a toggle.
        let second = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )
        #expect(window.isMaximized)
        #expect(window.pressCount == 1) // only the first call pressed
        #expect(second.info?.bounds == self.maxFrame)
        #expect(second.alreadyMaximized)
    }

    @Test func `maximizing an oversized window whose zoom target is smaller is not misclassified`() async throws {
        // Reviewer regression: a not-maximized window larger than its app's zoom target. Pressing zoom
        // legitimately shrinks it; this must NOT be treated as an already-maximized no-op.
        let oversized = CGRect(x: 20, y: 40, width: 3000, height: 1600) // larger than the 1200x800 zoom target
        let zoomTarget = CGRect(x: 100, y: 100, width: 1200, height: 800)
        let window = FakeZoomWindow(isMaximized: false, userFrame: oversized, zoomTarget: zoomTarget)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        #expect(window.pressCount == 1) // zoom was actually pressed, not skipped
        #expect(!outcome.alreadyMaximized) // not a no-op
        #expect(outcome.info?.bounds == zoomTarget) // reports the real (smaller) settled frame
    }

    @Test func `maximizing a moved screen-sized window presses zoom to reposition it`() async throws {
        // Reviewer regression: a window the size of the screen but displaced must NOT be skipped;
        // maximize should press zoom and move it back to the visible frame.
        let displaced = CGRect(x: 500, y: 300, width: 3200, height: 1690)
        let window = FakeZoomWindow(isMaximized: false, userFrame: displaced, zoomTarget: self.maxFrame)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        #expect(window.pressCount == 1) // pressed, not skipped
        #expect(!outcome.alreadyMaximized)
        #expect(outcome.info?.bounds == self.maxFrame) // repositioned to the visible frame
    }
}
