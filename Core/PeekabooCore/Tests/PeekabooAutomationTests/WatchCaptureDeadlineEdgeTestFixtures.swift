import CoreGraphics
import Foundation
@testable @_spi(Testing) import PeekabooAutomationKit

final class DeadlineEdgeWatchCaptureClock: WatchCaptureMonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 0

    func nowNanoseconds() -> UInt64 {
        self.lock.withLock { self.now }
    }

    func advance(to nanoseconds: UInt64) {
        self.lock.withLock {
            self.now = nanoseconds
        }
    }

    func sleep(nanoseconds _: UInt64) async throws {
        // Keep the deadline observer pending so the test deterministically exercises late-result admission.
        try await Task.sleep(nanoseconds: 60_000_000_000)
    }
}

@MainActor
final class DeadlineEdgeCaptureFrameSource: CaptureFrameSource {
    private let image: CGImage
    private let clock: DeadlineEdgeWatchCaptureClock
    private let completionNs: UInt64

    init(image: CGImage, clock: DeadlineEdgeWatchCaptureClock, completionNs: UInt64) {
        self.image = image
        self.clock = clock
        self.completionNs = completionNs
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        self.clock.advance(to: self.completionNs)
        return (
            self.image,
            CaptureMetadata(
                size: CGSize(width: self.image.width, height: self.image.height),
                mode: .screen,
                timestamp: Date()))
    }
}
