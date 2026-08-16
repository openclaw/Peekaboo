import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

/// Fake exact-window geometry backend whose frame changes asynchronously across reads.
@MainActor
private final class FakeMaximizeWindow {
    private(set) var isMaximized: Bool
    private(set) var applyCount = 0
    let userFrame: CGRect
    let maximizeTarget: CGRect
    let title: String
    /// Number of upcoming reads that return a mid-animation frame before the settled frame appears.
    private var pendingIntermediateReads = 0

    init(isMaximized: Bool, userFrame: CGRect, maximizeTarget: CGRect, title: String = "Maximize Fixture") {
        self.isMaximized = isMaximized
        self.userFrame = userFrame
        self.maximizeTarget = maximizeTarget
        self.title = title
    }

    var currentInfo: ServiceWindowInfo {
        self.info(self.isMaximized ? self.maximizeTarget : self.userFrame)
    }

    func apply() {
        self.applyCount += 1
        self.isMaximized = true
        self.pendingIntermediateReads = 1
    }

    func read() -> ServiceWindowInfo? {
        let settledFrame = self.isMaximized ? self.maximizeTarget : self.userFrame
        if self.pendingIntermediateReads > 0 {
            self.pendingIntermediateReads -= 1
            return self.info(self.intermediateFrame(towards: settledFrame))
        }
        return self.info(settledFrame)
    }

    private func intermediateFrame(towards target: CGRect) -> CGRect {
        let other = self.isMaximized ? self.userFrame : self.maximizeTarget
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
    private enum PollError: Error {
        case transient
        case identityContradiction
    }

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

    @Test func `settle stops before another read when sleep is cancelled`() async {
        var reads = 0
        let settleTask = Task { @MainActor in
            await settleWindowFrame(maxAttempts: 80, pollInterval: .seconds(30)) {
                reads += 1
                return ServiceWindowInfo(
                    windowID: 1,
                    title: "W",
                    bounds: CGRect(x: CGFloat(reads) * 10, y: 0, width: 800, height: 600)
                )
            }
        }

        while reads == 0 {
            await Task.yield()
        }
        #expect(reads == 1)

        settleTask.cancel()
        let result = await settleTask.value

        #expect(!result.stabilized)
        #expect(reads == 1)
    }

    @Test func `pre-cancelled settle performs no reads`() async {
        var reads = 0
        let result = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await settleWindowFrame(pollInterval: .zero) {
                reads += 1
                return ServiceWindowInfo(windowID: 1, title: "W", bounds: .zero)
            }
        }.value

        #expect(!result.stabilized)
        #expect(result.info == nil)
        #expect(reads == 0)
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

    @Test func `successful exact readback clears an earlier transient inventory error`() {
        var tracker = MaximizeReadbackErrorTracker()
        tracker.recordInventoryFailure(PollError.transient)
        #expect(tracker.unresolvedError != nil)

        tracker.recordSuccessfulExactReadback()

        #expect(tracker.unresolvedError == nil)
    }

    @Test func `successful readback never clears identity contradiction or cancellation`() {
        var identityTracker = MaximizeReadbackErrorTracker()
        identityTracker.recordIdentityContradiction(PollError.identityContradiction)
        identityTracker.recordSuccessfulExactReadback()
        #expect(identityTracker.unresolvedError is PollError)

        var cancellationTracker = MaximizeReadbackErrorTracker()
        cancellationTracker.recordInventoryFailure(CancellationError())
        cancellationTracker.recordSuccessfulExactReadback()
        #expect(cancellationTracker.unresolvedError is CancellationError)
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
        let window = FakeMaximizeWindow(
            isMaximized: false,
            userFrame: self.userFrame,
            maximizeTarget: self.maxFrame
        )

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            apply: { window.apply() },
            read: { window.read() }
        )

        #expect(window.isMaximized)
        #expect(window.applyCount == 1)
        #expect(outcome.info?.bounds == self.maxFrame)
        #expect(!outcome.alreadyMaximized)
        #expect(outcome.stabilized)
    }

    @Test func `maximizing an already-maximized window is a no-op that stays maximized`() async throws {
        let window = FakeMaximizeWindow(
            isMaximized: true,
            userFrame: self.userFrame,
            maximizeTarget: self.maxFrame
        )

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            apply: { window.apply() },
            read: { window.read() }
        )

        #expect(window.isMaximized)
        #expect(window.applyCount == 0)
        #expect(outcome.info?.bounds == self.maxFrame)
        #expect(outcome.alreadyMaximized)
    }

    @Test func `maximize output publishes service receipt or canonical idempotent no-change`() {
        let serviceOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            unitCount: .one
        )
        let actionResult = DesktopActionResult<Void>(outcome: serviceOutcome)

        #expect(reportedMaximizeOutcome(
            actionResult: actionResult,
            alreadyMaximized: false
        ) == serviceOutcome)
        #expect(reportedMaximizeOutcome(
            actionResult: actionResult,
            alreadyMaximized: true
        ) == .confirmedNoChange())
        #expect(reportedMaximizeOutcome(
            actionResult: actionResult,
            alreadyMaximized: true,
            noChangeRoute: .bridge
        ) == .confirmedNoChange(route: .bridge))
        #expect(reportedMaximizeOutcome(
            actionResult: nil,
            alreadyMaximized: false
        ) == nil)
    }

    @Test func `idempotent maximize route follows selected execution host`() {
        #expect(maximizeNoChangeRoute(executionHost: .local) == .local)
        #expect(maximizeNoChangeRoute(executionHost: .remote) == .bridge)
    }

    @Test func `maximize twice in a row leaves the window maximized`() async throws {
        let window = FakeMaximizeWindow(
            isMaximized: false,
            userFrame: self.userFrame,
            maximizeTarget: self.maxFrame
        )

        let first = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            apply: { window.apply() },
            read: { window.read() }
        )
        #expect(window.isMaximized)
        #expect(first.info?.bounds == self.maxFrame)
        #expect(!first.alreadyMaximized)

        // Second call: the window now fills the screen, so the redundant AX request is skipped.
        let second = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            apply: { window.apply() },
            read: { window.read() }
        )
        #expect(window.isMaximized)
        #expect(window.applyCount == 1)
        #expect(second.info?.bounds == self.maxFrame)
        #expect(second.alreadyMaximized)
    }

    @Test func `maximizing an oversized window applies the exact visible frame`() async throws {
        let oversized = CGRect(x: 20, y: 40, width: 3600, height: 1900)
        let window = FakeMaximizeWindow(
            isMaximized: false,
            userFrame: oversized,
            maximizeTarget: self.maxFrame
        )

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            apply: { window.apply() },
            read: { window.read() }
        )

        #expect(window.applyCount == 1)
        #expect(!outcome.alreadyMaximized)
        #expect(outcome.info?.bounds == self.maxFrame)
    }

    @Test func `maximizing a moved screen-sized window repositions it`() async throws {
        let displaced = CGRect(x: 500, y: 300, width: 3200, height: 1690)
        let window = FakeMaximizeWindow(
            isMaximized: false,
            userFrame: displaced,
            maximizeTarget: self.maxFrame
        )

        let outcome = try await resolveIdempotentMaximize(
            original: window.currentInfo,
            screenVisibleFramesTopLeft: self.screenFrames,
            pollInterval: .zero,
            apply: { window.apply() },
            read: { window.read() }
        )

        #expect(window.applyCount == 1)
        #expect(!outcome.alreadyMaximized)
        #expect(outcome.info?.bounds == self.maxFrame)
    }
}
