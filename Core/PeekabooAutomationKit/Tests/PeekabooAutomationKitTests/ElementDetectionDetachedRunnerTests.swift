import Foundation
import PeekabooFoundation
import XCTest
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
final class ElementDetectionDetachedRunnerTests: XCTestCase {
    func testDetachedDeadlineWinsEvenWhenMainActorWorkStarvesCallerResumption() async throws {
        let startedAt = ContinuousClock.now

        do {
            _ = try await ElementDetectionTimeoutRunner.run(seconds: 0.03) {
                Self.blockCurrentThread(for: 0.12)
                return "late success"
            }
            XCTFail("Expected the detached deadline to win")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 0.03, accuracy: 0.001)
        }

        let elapsed = startedAt.duration(to: .now)
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(100))
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    func testNoncooperativeWorkTimesOutWithoutBlockingMainActor() async throws {
        let started = expectation(description: "worker started")
        let heartbeat = expectation(description: "main actor heartbeat")
        let release = DispatchSemaphore(value: 0)

        let operation = Task { @MainActor in
            try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_001,
                seconds: 0.08)
            {
                started.fulfill()
                release.wait()
                return 1
            }
        }

        await fulfillment(of: [started], timeout: 1)
        Task { @MainActor in heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 0.2)

        do {
            _ = try await operation.value
            XCTFail("Expected detached AX timeout")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 0.08, accuracy: 0.001)
        }
        release.signal()
    }

    func testBlockedPIDDoesNotDelayDifferentPIDAndExpiredQueuedWorkNeverStarts() async throws {
        let firstStarted = expectation(description: "first PID lane started")
        let release = DispatchSemaphore(value: 0)
        let queuedInvocations = LockedCounter()

        let first = Task {
            try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_002,
                seconds: 2)
            {
                firstStarted.fulfill()
                release.wait()
                return "first"
            }
        }
        await fulfillment(of: [firstStarted], timeout: 1)

        let unrelated = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: 910_003,
            seconds: 0.2)
        {
            "unrelated"
        }
        XCTAssertEqual(unrelated, "unrelated")

        do {
            _ = try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_002,
                seconds: 0.05)
            {
                queuedInvocations.increment()
                return "queued"
            }
            XCTFail("Expected queued same-PID work to expire")
        } catch is CaptureError {
            // Expected.
        }
        XCTAssertEqual(queuedInvocations.value, 0)

        release.signal()
        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "first")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(queuedInvocations.value, 0)
    }

    func testRecycledPIDUsesNewProcessGenerationLaneWithoutOverlappingOldGeneration() async throws {
        let oldGenerationStarted = expectation(description: "old generation started")
        let releaseOldGeneration = DispatchSemaphore(value: 0)
        let oldGeneration = Task {
            try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_004,
                targetProcessStartIdentity: 100,
                seconds: 0.05)
            {
                oldGenerationStarted.fulfill()
                releaseOldGeneration.wait()
                return "old"
            }
        }
        await fulfillment(of: [oldGenerationStarted], timeout: 1)
        do {
            _ = try await oldGeneration.value
            XCTFail("Expected old process generation to time out")
        } catch is CaptureError {
            // The noncooperative old generation remains quarantined on its own lane.
        }

        let newGeneration = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: 910_004,
            targetProcessStartIdentity: 200,
            seconds: 0.2)
        {
            "new"
        }
        XCTAssertEqual(newGeneration, "new")
        releaseOldGeneration.signal()
    }

    func testIdleGenerationLanesAreEvictedOldestFirstAndBounded() async throws {
        for generation in 1...80 {
            _ = try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 920_000 + Int32(generation),
                targetProcessStartIdentity: UInt64(generation),
                seconds: 0.2)
            {
                generation
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertLessThanOrEqual(ElementDetectionTimeoutRunner.retainedIdleLaneCount, 64)
    }

    private nonisolated static func blockCurrentThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}
