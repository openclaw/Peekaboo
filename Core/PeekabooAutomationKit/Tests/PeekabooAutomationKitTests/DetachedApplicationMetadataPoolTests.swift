import Foundation
import PeekabooFoundation
import XCTest
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
final class DetachedApplicationMetadataPoolTests: XCTestCase {
    func testAggregateRetainedNativeWorkRemainsBoundedAfterCallersFinish() async throws {
        let entered = expectation(description: "first eight native getters entered")
        entered.expectedFulfillmentCount = 8
        let gate = MetadataNativeGate()
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(didComplete: completion.record)
        defer { gate.release() }
        let first = (0..<8).map { index in
            Task {
                try await DetachedApplicationMetadataCoordinator.run(
                    processIdentifier: 980_000 + Int32(index),
                    processStartIdentity: 1,
                    timeoutSeconds: 0.5,
                    pool: pool)
                { _ in
                    gate.enter()
                    entered.fulfill()
                    gate.wait()
                    return Self.metadata
                }
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        for task in first.prefix(4) {
            task.cancel()
        }
        for task in first {
            do {
                _ = try await task.value
                XCTFail("Expected timeout or cancellation")
            } catch is CancellationError {
                // Cancellation must end the caller without freeing native capacity.
            } catch is CaptureError {}
        }
        XCTAssertEqual(gate.count, 8)
        XCTAssertEqual(pool.retainedOperationCount, 8)

        let replacements = (0..<8).map { index in
            Task {
                try await DetachedApplicationMetadataCoordinator.run(
                    processIdentifier: 980_000 + Int32(index),
                    processStartIdentity: 2,
                    timeoutSeconds: 0.5,
                    pool: pool)
                { _ in
                    gate.enter()
                    gate.wait()
                    return Self.metadata
                }
            }
        }
        for task in replacements {
            do {
                _ = try await task.value
                XCTFail("Expected overload or timeout")
            } catch ApplicationMetadataAdmissionError.overloaded {
                // New generations compete for the same aggregate capacity.
            } catch { XCTFail("Unexpected replacement error: \(error)") }
        }
        XCTAssertLessThanOrEqual(gate.count, 8, "Caller completion must not admit more retained native getters")
        print("METADATA RETAINED NATIVE PROOF: entered=\(gate.count), limit=8, first callers finished")
        XCTAssertEqual(pool.retainedOperationCount, 8)
        gate.release()
        await fulfillment(of: [completion.expectation(at: 8)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
    }

    func testCancellationRetainsAllEightSlotsAndRejectsDistinctPIDs() async throws {
        let gate = MetadataNativeGate()
        defer { gate.release() }
        let entered = expectation(description: "eight cancellation getters entered")
        entered.expectedFulfillmentCount = 8
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(didComplete: completion.record)
        let tasks = (0..<8).map { index in
            self.blockedRead(pool: pool, pid: 981_000 + Int32(index), gate: gate, entered: entered)
        }
        await fulfillment(of: [entered], timeout: 2)
        for task in tasks {
            task.cancel()
        }
        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {}
        }
        XCTAssertEqual(pool.retainedOperationCount, 8)
        for index in 0..<24 {
            await self.expectOverload(pool: pool, pid: 982_000 + Int32(index))
        }
        XCTAssertEqual(gate.count, 8)
        gate.release()
        await fulfillment(of: [completion.expectation(at: 8)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
    }

    func testDuplicateKeyIsRejectedWhileDistinctGenerationsShareTheSameCapacity() async throws {
        let gate = MetadataNativeGate()
        defer { gate.release() }
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(capacity: 2, didComplete: completion.record)
        let firstEntered = expectation(description: "first generation entered")
        let first = self.blockedRead(pool: pool, pid: 983_000, gate: gate, entered: firstEntered)
        await fulfillment(of: [firstEntered], timeout: 2)
        do {
            _ = try await self.read(pool: pool, pid: 983_000) { _ in
                XCTFail("Duplicate must not run")
                return Self.metadata
            }
            XCTFail("Expected duplicate timeout")
        } catch is CaptureError {}
        let secondEntered = expectation(description: "second generation entered")
        let second = self.blockedRead(
            pool: pool, pid: 983_000, generation: 2, gate: gate, entered: secondEntered)
        await fulfillment(of: [secondEntered], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 2)
        await self.expectOverload(pool: pool, pid: 983_000, generation: 3)
        gate.release()
        let firstValue = try await first.value
        let secondValue = try await second.value
        XCTAssertEqual(firstValue, Self.metadata)
        XCTAssertEqual(secondValue, Self.metadata)
        await fulfillment(of: [completion.expectation(at: 2)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
    }

    func testTimeoutCapacityReusesExactlyOneSlotAfterActualSuccessOrThrow() async throws {
        let firstGate = MetadataNativeGate()
        let secondGate = MetadataNativeGate()
        defer {
            firstGate.release()
            secondGate.release()
        }
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(capacity: 2, didComplete: completion.record)
        let entered = expectation(description: "both timeout getters entered")
        entered.expectedFulfillmentCount = 2
        let first = self.blockedRead(pool: pool, pid: 984_000, timeout: 0.2, gate: firstGate, entered: entered)
        let second = self.blockedRead(pool: pool, pid: 984_001, timeout: 0.2, gate: secondGate, entered: entered)
        await fulfillment(of: [entered], timeout: 2)
        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("Expected timeout")
            } catch is CaptureError {}
        }
        XCTAssertEqual(pool.retainedOperationCount, 2)
        await self.expectOverload(pool: pool)
        firstGate.release()
        await fulfillment(of: [completion.expectation(at: 1)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 1)
        do {
            _ = try await self.read(pool: pool) { _ in throw MetadataFixtureError.synthetic }
            XCTFail("Expected native throw")
        } catch MetadataFixtureError.synthetic {}
        await fulfillment(of: [completion.expectation(at: 2)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 1)
        let recovered = try await self.read(pool: pool) { _ in Self.metadata }
        XCTAssertEqual(recovered, Self.metadata)
        await fulfillment(of: [completion.expectation(at: 3)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 1)
        secondGate.release()
        await fulfillment(of: [completion.expectation(at: 4)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
    }

    func testCancelledAndExpiredDispatchedWrappersKeepReservationsUntilTheyDrain() async throws {
        let queue = DispatchQueue(label: "metadata.test.delayed-dispatch")
        let queueGate = MetadataNativeGate()
        defer { queueGate.release() }
        let queueEntered = expectation(description: "dispatch queue occupied")
        queue.async {
            queueEntered.fulfill()
            queueGate.wait()
        }
        await fulfillment(of: [queueEntered], timeout: 2)
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(capacity: 2, queue: queue, didComplete: completion.record)
        let payloadReleased = expectation(description: "skipped user payload deinit can reenter the pool")
        let cancelled = Task {
            let probe = MetadataCleanupProbe {
                _ = pool.retainedOperationCount
                payloadReleased.fulfill()
            }
            return try await self.read(pool: pool, pid: 985_000, timeout: 5) { [probe] _ in
                withExtendedLifetime(probe) { XCTFail("Cancelled wrapper must not invoke native work") }
                return Self.metadata
            }
        }
        let expired = Task {
            try await self.read(pool: pool, pid: 985_001, timeout: 0.1) { _ in
                XCTFail("Expired wrapper must not invoke native work")
                return Self.metadata
            }
        }
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while pool.retainedOperationCount < 2, ContinuousClock.now < admissionDeadline {
            await Task.yield()
        }
        XCTAssertEqual(pool.retainedOperationCount, 2)
        cancelled.cancel()
        do {
            _ = try await expired.value
            XCTFail("Expected dispatched wrapper timeout")
        } catch is CaptureError {}
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(pool.retainedOperationCount, 2)
        for _ in 0..<16 {
            await self.expectOverload(pool: pool)
        }
        XCTAssertEqual(pool.retainedOperationCount, 2)
        queueGate.release()
        await fulfillment(of: [completion.expectation(at: 2), payloadReleased], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
        let value = try await self.read(pool: pool) { _ in Self.metadata }
        XCTAssertEqual(value, Self.metadata)
        await fulfillment(of: [completion.expectation(at: 3)], timeout: 2)
    }

    func testInvalidExpiredAndPrecancelledCallsNeverReserveOrInvoke() async throws {
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(didComplete: completion.record)
        for timeout in [0, -1, Double.nan, Double.infinity, Double.leastNonzeroMagnitude] {
            do {
                _ = try await self.read(pool: pool, timeout: timeout) { _ in
                    XCTFail("Invalid or already-expired request must not run")
                    return Self.metadata
                }
                XCTFail("Expected timeout")
            } catch is CaptureError {}
            XCTAssertEqual(pool.retainedOperationCount, 0)
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await self.read(pool: pool) { _ in
                XCTFail("Precancelled request must not run")
                return Self.metadata
            }
        }
        do {
            _ = try await cancelled.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        XCTAssertEqual(pool.retainedOperationCount, 0)
        let value = try await self.read(pool: pool, timeout: Double.greatestFiniteMagnitude) { _ in Self.metadata }
        XCTAssertEqual(value, Self.metadata)
        await fulfillment(of: [completion.expectation(at: 1)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
    }

    func testAutoreleaseCleanupKeepsCapacityAfterNativeReturnAndCallerTimeout() async throws {
        let cleanup = MetadataNativeGate()
        defer { cleanup.release() }
        let cleanupEntered = expectation(description: "autoreleased object cleanup entered")
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(capacity: 1, didComplete: completion.record)
        let task = Task {
            try await self.read(pool: pool, timeout: 0.2) { _ in
                _ = Unmanaged.passRetained(MetadataCleanupProbe {
                    XCTAssertEqual(pool.retainedOperationCount, 1)
                    cleanupEntered.fulfill()
                    cleanup.wait()
                }).autorelease()
                return Self.metadata
            }
        }
        await fulfillment(of: [cleanupEntered], timeout: 2)
        do {
            _ = try await task.value
            XCTFail("Caller must time out during native autorelease cleanup")
        } catch is CaptureError {}
        XCTAssertEqual(pool.retainedOperationCount, 1)
        await self.expectOverload(pool: pool, pid: 986_001)
        cleanup.release()
        await fulfillment(of: [completion.expectation(at: 1)], timeout: 2)
        XCTAssertEqual(pool.retainedOperationCount, 0)
    }

    func testCancellationRacingNativeCompletionResumesOnceAndDrainsEveryReservation() async throws {
        let completion = MetadataCompletionProbe()
        let pool = DetachedApplicationMetadataPool(capacity: 1, didComplete: completion.record)
        for iteration in 1...32 {
            let gate = MetadataNativeGate()
            defer { gate.release() }
            let entered = expectation(description: "racing native getter entered")
            let task = self.blockedRead(pool: pool, pid: 987_000, gate: gate, entered: entered)
            await fulfillment(of: [entered], timeout: 2)
            DispatchQueue.global().async { task.cancel() }
            gate.release()
            do {
                let value = try await task.value
                XCTAssertEqual(value, Self.metadata)
            } catch is CancellationError {}
            await fulfillment(of: [completion.expectation(at: iteration)], timeout: 2)
            XCTAssertEqual(pool.retainedOperationCount, 0)
        }
    }

    private func blockedRead(
        pool: DetachedApplicationMetadataPool,
        pid: Int32,
        generation: UInt64 = 1,
        timeout: TimeInterval = 5,
        gate: MetadataNativeGate,
        entered: XCTestExpectation) -> Task<DetachedApplicationMetadata, any Error>
    {
        Task {
            try await self.read(pool: pool, pid: pid, generation: generation, timeout: timeout) { _ in
                gate.enter()
                entered.fulfill()
                gate.wait()
                return Self.metadata
            }
        }
    }

    private func expectOverload(
        pool: DetachedApplicationMetadataPool,
        pid: Int32 = 989_000,
        generation: UInt64 = 1) async
    {
        do {
            _ = try await self.read(pool: pool, pid: pid, generation: generation) { _ in
                XCTFail("Overflow must not invoke native work")
                return Self.metadata
            }
            XCTFail("Expected overload")
        } catch ApplicationMetadataAdmissionError.overloaded {
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    private func read(
        pool: DetachedApplicationMetadataPool,
        pid: Int32 = 989_000,
        generation: UInt64 = 1,
        timeout: TimeInterval = 2,
        operation: @escaping @Sendable (DetachedApplicationMetadataRequest) throws -> DetachedApplicationMetadata)
        async throws -> DetachedApplicationMetadata
    {
        try await DetachedApplicationMetadataCoordinator.run(
            processIdentifier: pid,
            processStartIdentity: generation,
            timeoutSeconds: timeout,
            pool: pool,
            operation: operation)
    }

    nonisolated static var metadata: DetachedApplicationMetadata {
        DetachedApplicationMetadata(
            bundleIdentifier: "com.example.synthetic",
            name: "Synthetic",
            bundlePath: nil,
            isHidden: false,
            activationPolicy: .regular,
            isFinishedLaunching: true)
    }
}

final class MetadataNativeGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var entries = 0

    var count: Int {
        self.condition.withLock { self.entries }
    }

    func enter() {
        self.condition.withLock { self.entries += 1 }
    }

    func wait(watchdogSeconds: TimeInterval = 15) {
        self.condition.lock()
        defer { self.condition.unlock() }
        let watchdog = Date().addingTimeInterval(watchdogSeconds)
        while !self.released {
            guard self.condition.wait(until: watchdog) else { return }
        }
    }

    func release() {
        self.condition.withLock {
            self.released = true
            self.condition.broadcast()
        }
    }
}

final class MetadataCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var waiters: [(Int, XCTestExpectation)] = []

    func record(_ key: DetachedApplicationMetadataPool.Key) {
        let ready = self.lock.withLock {
            self.count += 1
            let ready = self.waiters.filter { $0.0 <= self.count }
            self.waiters.removeAll { $0.0 <= self.count }
            return ready
        }
        for (_, waiter) in ready {
            waiter.fulfill()
        }
    }

    func expectation(at count: Int) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "pool epilogue count \(count)")
        let ready = self.lock.withLock {
            if self.count >= count {
                return true
            }
            self.waiters.append((count, expectation))
            return false
        }
        if ready {
            expectation.fulfill()
        }
        return expectation
    }
}

private enum MetadataFixtureError: Error {
    case synthetic
}

private final class MetadataCleanupProbe: NSObject, @unchecked Sendable {
    private let cleanup: @Sendable () -> Void

    init(cleanup: @escaping @Sendable () -> Void) {
        self.cleanup = cleanup
    }

    deinit { self.cleanup() }
}
