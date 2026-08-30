import Foundation
import PeekabooFoundation
import XCTest
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
final class ElementDetectionDetachedRunnerTests: XCTestCase {
    func testDetachedDeadlineWinsEvenWhenMainActorWorkStarvesCallerResumption() async {
        let finished = expectation(description: "deadline caller resumed")
        let caller = Task { @MainActor in
            var workDuration: Duration?
            do {
                _ = try await ElementDetectionTimeoutRunner.run(seconds: 0.03) {
                    let startedAt = ContinuousClock.now
                    Self.blockCurrentThread(for: 0.12)
                    workDuration = startedAt.duration(to: .now)
                    return "late success"
                }
                XCTFail("Expected the detached deadline to win")
            } catch let CaptureError.detectionTimedOut(seconds) {
                XCTAssertEqual(seconds, 0.03, accuracy: 0.001)
            } catch {
                XCTFail("Expected detection timeout, got \(error)")
            }

            // Work may already be expired when MainActor admits it. If it started, it blocked synchronously.
            if let workDuration {
                XCTAssertGreaterThanOrEqual(workDuration, .milliseconds(100))
            }
            finished.fulfill()
        }
        defer { caller.cancel() }
        await fulfillment(of: [finished], timeout: 10)
    }

    func testNoncooperativeWorkTimesOutWithoutBlockingMainActor() async throws {
        let started = expectation(description: "worker started")
        let heartbeat = expectation(description: "main actor heartbeat")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let operation = Task { @MainActor in
            try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_001,
                seconds: 0.08)
            {
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
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
        defer { release.signal() }
        let queuedInvocations = LockedCounter()

        let first = Task {
            try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_002,
                seconds: 2)
            {
                firstStarted.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
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
        _ = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: 910_002,
            seconds: 10) { "lane drained" }
        XCTAssertEqual(queuedInvocations.value, 0)
    }

    func testRecycledPIDUsesNewProcessGenerationLaneWithoutOverlappingOldGeneration() async throws {
        let oldGenerationStarted = expectation(description: "old generation started")
        let releaseOldGeneration = DispatchSemaphore(value: 0)
        defer { releaseOldGeneration.signal() }
        let oldGeneration = Task {
            try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_004,
                targetProcessStartIdentity: 100,
                seconds: 0.05)
            {
                oldGenerationStarted.fulfill()
                XCTAssertEqual(releaseOldGeneration.wait(timeout: .now() + 10), .success)
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

    func testExpiredCompletionCannotWinWhenTimerCallbackIsDelayed() async throws {
        for completion: Result<Int, any Error> in [.success(42), .failure(DetectionFailure.original)] {
            let owner = try ElementDetectionDeadline<Int>(seconds: 0.03)
            XCTAssertTrue(owner.claimWork())
            let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            let timer = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            defer {
                work.cancel()
                timer.cancel()
            }
            // Use the production timer's absolute wait, but deliberately withhold its timeOut callback.
            try await owner.waitForDeadline()
            let result = await self.finish(owner, with: completion, work: work, timer: timer)
            self.assertTimeout(result, seconds: 0.03)
            XCTAssertTrue(work.isCancelled)
            XCTAssertTrue(timer.isCancelled)
            await work.value
            await timer.value
        }
    }

    func testExpiredQueuedWorkCannotStartBeforeTimerCallback() async throws {
        let owner = try ElementDetectionDeadline<Int>(seconds: 0.03)
        try await owner.waitForDeadline()
        var invocations = 0
        do {
            _ = try await withCheckedThrowingContinuation { continuation in
                owner.install(continuation)
                if owner.claimWork() {
                    invocations += 1
                    owner.complete(with: .success(42))
                }
            }
            XCTFail("Expired queued work must time out without waiting for the timer callback")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 0.03)
        }
        XCTAssertEqual(invocations, 0)
        XCTAssertFalse(owner.claimWork())
    }

    func testTimelyCompletionPreservesValueAndOriginalErrorAndCleansUp() async throws {
        for completion: Result<Int, any Error> in [.success(42), .failure(DetectionFailure.original)] {
            let owner = try ElementDetectionDeadline<Int>(seconds: 60)
            XCTAssertTrue(owner.claimWork())
            XCTAssertFalse(owner.claimWork())
            let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            let timer = Task<Void, Never> { try? await owner.waitForDeadline() }
            let result = await self.finish(owner, with: completion, work: work, timer: timer)
            switch (completion, result) {
            case let (.success(expected), .success(actual)):
                XCTAssertEqual(actual, expected)
            case let (.failure, .failure(error)):
                XCTAssertEqual(error as? DetectionFailure, .original)
            default:
                XCTFail("Timely completion was replaced: \(result)")
            }
            XCTAssertTrue(work.isCancelled)
            XCTAssertTrue(timer.isCancelled)
            await work.value
            await timer.value
        }
    }

    func testCancellationWinsBeforeInstallationAndAfterExpiryAndCancelsLateTaskRegistration() async throws {
        for cancelBeforeInstall in [true, false] {
            let owner = try ElementDetectionDeadline<Int>(seconds: 0.03)
            try await owner.waitForDeadline()
            if cancelBeforeInstall {
                owner.cancel()
            }
            do {
                _ = try await withCheckedThrowingContinuation { continuation in
                    owner.install(continuation)
                    owner.cancel()
                    owner.complete(with: .success(42))
                    owner.timeOut()
                }
                XCTFail("Expected cancellation even when the timer callback is late")
            } catch is CancellationError {
                // Parent cancellation is independent of result/deadline admission.
            }
            let work = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
            let timer = Task<Void, Never> { try? await owner.waitForDeadline() }
            owner.setTasks(work: work, timeout: timer)
            XCTAssertTrue(work.isCancelled)
            XCTAssertTrue(timer.isCancelled)
            XCTAssertFalse(owner.claimWork())
            await work.value
            await timer.value
        }
    }

    func testDetachedCancellationDoesNotReleaseHeldLaneCapacity() async throws {
        let started = expectation(description: "held worker started")
        let cancelled = expectation(description: "caller cancelled while worker is held")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let caller = Task {
            do {
                _ = try await ElementDetectionTimeoutRunner.runDetached(
                    targetProcessIdentifier: 910_005,
                    targetProcessStartIdentity: 1,
                    seconds: 60,
                    maximumPendingOperationCount: 1)
                {
                    started.fulfill()
                    XCTAssertEqual(release.wait(timeout: .now() + 10), .success)
                    return 1
                }
                XCTFail("Cancelled caller admitted held work's result")
            } catch is CancellationError {
                cancelled.fulfill()
            } catch {
                XCTFail("Expected cancellation, got \(error)")
            }
        }
        defer { caller.cancel() }
        await fulfillment(of: [started], timeout: 10)
        caller.cancel()
        await fulfillment(of: [cancelled], timeout: 10)

        do {
            _ = try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_005,
                targetProcessStartIdentity: 1,
                seconds: 60,
                maximumPendingOperationCount: 1)
            {
                XCTFail("Cancellation must not free capacity still held by noncooperative work")
                return 2
            }
            XCTFail("Expected capacity refusal")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 60)
        }
        release.signal()
        // A serial marker proves held work and any quarantined result have actually drained.
        let marker = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: 910_005,
            targetProcessStartIdentity: 1,
            seconds: 10) { 3 }
        XCTAssertEqual(marker, 3)
    }

    func testBothRunnersRejectInvalidBudgetsAndAcceptExtremeFiniteBudgets() async throws {
        let invocations = LockedCounter()
        for seconds in [0, -1, .infinity, -.infinity, .nan] as [TimeInterval] {
            for detached in [false, true] {
                do {
                    _ = try await self.runSynthetic(detached: detached, seconds: seconds) {
                        invocations.increment()
                        return 1
                    }
                    XCTFail("Expected invalid budget refusal")
                } catch let CaptureError.detectionTimedOut(actual) {
                    XCTAssertTrue(actual == seconds || (actual.isNaN && seconds.isNaN))
                }
            }
        }
        XCTAssertEqual(invocations.value, 0)
        for seconds in [TimeInterval(UInt64.max) / 1_000_000_000, .greatestFiniteMagnitude] {
            for detached in [false, true] {
                let result = try await self.runSynthetic(detached: detached, seconds: seconds) { 42 }
                XCTAssertEqual(result, 42)
            }
        }
    }

    private func runSynthetic(
        detached: Bool,
        seconds: TimeInterval,
        operation: @escaping @Sendable () throws -> Int) async throws -> Int
    {
        if detached {
            return try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: 910_006,
                targetProcessStartIdentity: 1,
                seconds: seconds,
                operation: operation)
        }
        return try await ElementDetectionTimeoutRunner.run(seconds: seconds) { try operation() }
    }

    private func finish(
        _ owner: ElementDetectionDeadline<Int>,
        with result: Result<Int, any Error>,
        work: Task<Void, Never>,
        timer: Task<Void, Never>) async -> Result<Int, any Error>
    {
        do {
            return try await .success(withCheckedThrowingContinuation { continuation in
                owner.install(continuation)
                owner.setTasks(work: work, timeout: timer)
                owner.complete(with: result)
                // Losing callbacks must neither replace the result nor resume the continuation again.
                owner.timeOut()
                owner.cancel()
                owner.complete(with: .success(-1))
            })
        } catch {
            return .failure(error)
        }
    }

    private func assertTimeout(_ result: Result<Int, any Error>, seconds: TimeInterval) {
        guard case let .failure(error) = result,
              case let CaptureError.detectionTimedOut(actual) = error
        else {
            return XCTFail("Expected deadline refusal, got \(result)")
        }
        XCTAssertEqual(actual, seconds)
    }

    private nonisolated static func blockCurrentThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}

private enum DetectionFailure: Error, Equatable {
    case original
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
