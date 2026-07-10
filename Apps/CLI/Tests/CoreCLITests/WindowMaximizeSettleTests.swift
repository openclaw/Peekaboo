import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

/// Fake window whose green-button zoom is a toggle and whose frame changes asynchronously across
/// reads, mirroring AppKit: `maximize` presses an animated toggle, so an immediate read-back returns
/// an intermediate frame, and pressing again on an already-maximized window restores the user frame.
@MainActor
private final class FakeZoomWindow {
    private(set) var isMaximized: Bool
    let userFrame: CGRect
    let maxFrame: CGRect
    let title: String
    /// Number of upcoming reads that return a mid-animation frame before the settled frame appears.
    private var pendingIntermediateReads = 0

    init(isMaximized: Bool, userFrame: CGRect, maxFrame: CGRect, title: String = "Zoom Fixture") {
        self.isMaximized = isMaximized
        self.userFrame = userFrame
        self.maxFrame = maxFrame
        self.title = title
    }

    var currentInfo: ServiceWindowInfo {
        self.info(self.isMaximized ? self.maxFrame : self.userFrame)
    }

    func press() {
        self.isMaximized.toggle()
        // The zoom animation makes the first read after a press return an intermediate frame.
        self.pendingIntermediateReads = 1
    }

    func read() -> ServiceWindowInfo? {
        let settledFrame = self.isMaximized ? self.maxFrame : self.userFrame
        if self.pendingIntermediateReads > 0 {
            self.pendingIntermediateReads -= 1
            return self.info(self.intermediateFrame(towards: settledFrame))
        }
        return self.info(settledFrame)
    }

    private func intermediateFrame(towards target: CGRect) -> CGRect {
        // Midpoint between the two toggle states: clearly different from the settled target so the
        // settle loop must poll at least once more.
        let other = self.isMaximized ? self.userFrame : self.maxFrame
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

    // MARK: - maximizeToggleUndidMaximization

    @Test func `undo detection fires when the window shrank substantially`() {
        #expect(maximizeToggleUndidMaximization(original: self.maxFrame, achieved: self.userFrame))
    }

    @Test func `undo detection stays quiet when the window grew`() {
        #expect(!maximizeToggleUndidMaximization(original: self.userFrame, achieved: self.maxFrame))
    }

    @Test func `undo detection ignores sub-threshold noise`() {
        let jittered = CGRect(x: 0, y: 0, width: 3199, height: 1689)
        #expect(!maximizeToggleUndidMaximization(original: self.maxFrame, achieved: jittered))
    }

    // MARK: - Idempotent maximize

    @Test func `maximize from a normal window reports the settled maximized frame without re-press`() async throws {
        let window = FakeZoomWindow(isMaximized: false, userFrame: self.userFrame, maxFrame: self.maxFrame)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        #expect(window.isMaximized)
        #expect(outcome.info?.bounds == self.maxFrame)
        #expect(!outcome.alreadyMaximized)
        #expect(outcome.stabilized)
    }

    @Test func `maximizing an already-maximized window leaves it maximized`() async throws {
        // Start already maximized: a naive toggle would un-maximize it.
        let window = FakeZoomWindow(isMaximized: true, userFrame: self.userFrame, maxFrame: self.maxFrame)

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )

        // Idempotent: the window is left maximized and reports the maximized frame.
        #expect(window.isMaximized)
        #expect(outcome.info?.bounds == self.maxFrame)
        #expect(outcome.alreadyMaximized)
        #expect(outcome.stabilized)
    }

    @Test func `maximize twice in a row leaves the window maximized`() async throws {
        let window = FakeZoomWindow(isMaximized: false, userFrame: self.userFrame, maxFrame: self.maxFrame)

        let first = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )
        #expect(window.isMaximized)
        #expect(first.info?.bounds == self.maxFrame)
        #expect(!first.alreadyMaximized)

        // Second maximize call must not un-maximize the window.
        let second = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            pollInterval: .zero,
            press: { window.press() },
            read: { window.read() }
        )
        #expect(window.isMaximized)
        #expect(second.info?.bounds == self.maxFrame)
        #expect(second.alreadyMaximized)
    }
}
