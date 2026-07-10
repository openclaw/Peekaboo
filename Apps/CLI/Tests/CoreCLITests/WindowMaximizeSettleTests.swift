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
    private var screenSizes: [CGSize] {
        [CGSize(width: 3200, height: 1690)]
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

    // MARK: - windowFillsAnyScreen

    @Test func `screen-fill detection matches a screen-sized window`() {
        #expect(windowFillsAnyScreen(size: CGSize(width: 3200, height: 1690), screenVisibleSizes: self.screenSizes))
    }

    @Test func `screen-fill detection tolerates sub-threshold rounding`() {
        #expect(windowFillsAnyScreen(size: CGSize(width: 3199, height: 1689), screenVisibleSizes: self.screenSizes))
    }

    @Test func `screen-fill detection rejects an oversized-but-not-screen-sized window`() {
        // Larger than the screen in one dimension: not maximized.
        #expect(!windowFillsAnyScreen(size: CGSize(width: 3000, height: 1600), screenVisibleSizes: self.screenSizes))
    }

    // MARK: - Idempotent maximize

    @Test func `maximize from a normal window reports the settled maximized frame`() async throws {
        let window = FakeZoomWindow(isMaximized: false, userFrame: self.userFrame, zoomTarget: self.maxFrame)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleSizes: self.screenSizes,
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
            screenVisibleSizes: self.screenSizes,
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
            screenVisibleSizes: self.screenSizes,
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
            screenVisibleSizes: self.screenSizes,
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
            screenVisibleSizes: self.screenSizes,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        #expect(window.pressCount == 1) // zoom was actually pressed, not skipped
        #expect(!outcome.alreadyMaximized) // not a no-op
        #expect(outcome.info?.bounds == zoomTarget) // reports the real (smaller) settled frame
    }
}
