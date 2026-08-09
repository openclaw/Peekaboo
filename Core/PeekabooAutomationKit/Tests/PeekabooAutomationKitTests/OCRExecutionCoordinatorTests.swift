import Foundation
import Testing
@testable @_spi(Testing) import PeekabooAutomationKit

@Suite(.serialized)
struct OCRExecutionCoordinatorTests {
    @Test
    func `nested default OCR work reuses the outer async lease`() async throws {
        let value = try await OCRExecutionRunner.runAsync(seconds: 0.2) {
            try await OCRExecutionRunner.run(seconds: 0.2) { 42 }
        }

        #expect(value == 42)
    }

    @Test
    func `timeout quarantines Vision ownership until late completion and then recovers`() async throws {
        let coordinator = OCRExecutionCoordinator()
        let probe = BlockingOCRProbe()
        let first = Task {
            try await coordinator.run(seconds: 0.05) {
                probe.runUntilReleased()
                return 1
            }
        }

        #expect(await self.eventually { probe.startedCount == 1 })
        guard case .failure = await first.result else {
            Issue.record("Expected the noncooperative OCR operation to time out")
            probe.release()
            return
        }
        #expect(await self.eventually { await coordinator.isQuarantined })

        await #expect(throws: OCRServiceError.self) {
            try await coordinator.run(seconds: 0.2) {
                probe.recordUnexpectedOverlap()
                return 2
            }
        }
        #expect(probe.maximumOverlap == 1)

        probe.release()
        #expect(await self.eventually { await !coordinator.isQuarantined })
        let recovered = try await coordinator.run(seconds: 0.2) { 3 }
        #expect(recovered == 3)
    }

    @Test
    func `cancellation returns promptly but keeps noncooperative OCR quarantined`() async throws {
        let coordinator = OCRExecutionCoordinator()
        let probe = BlockingOCRProbe()
        let first = Task {
            try await coordinator.run(seconds: 60) {
                probe.runUntilReleased()
                return 1
            }
        }

        #expect(await self.eventually { probe.startedCount == 1 })
        first.cancel()
        guard case let .failure(error) = await first.result else {
            Issue.record("Expected cancellation")
            probe.release()
            return
        }
        #expect(error is CancellationError)
        #expect(await self.eventually { await coordinator.isQuarantined })

        await #expect(throws: OCRServiceError.self) {
            try await coordinator.run(seconds: 0.2) {
                probe.recordUnexpectedOverlap()
                return 2
            }
        }
        #expect(probe.maximumOverlap == 1)

        probe.release()
        #expect(await self.eventually { await !coordinator.isQuarantined })
    }

    @Test
    func `ordinary concurrent OCR calls serialize without overlap`() async throws {
        let coordinator = OCRExecutionCoordinator()
        let probe = BlockingOCRProbe()
        let first = Task {
            try await coordinator.run(seconds: 2) {
                probe.runUntilReleased()
                return 1
            }
        }
        #expect(await self.eventually { probe.startedCount == 1 })

        let second = Task {
            try await coordinator.run(seconds: 2) {
                probe.recordBriefOperation()
                return 2
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(probe.startedCount == 1)
        #expect(probe.maximumOverlap == 1)

        probe.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(probe.startedCount == 2)
        #expect(probe.maximumOverlap == 1)
    }

    private func eventually(
        attempts: Int = 200,
        _ predicate: @escaping @Sendable () async -> Bool) async -> Bool
    {
        for _ in 0..<attempts {
            if await predicate() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private final class BlockingOCRProbe: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var active = 0
    private var starts = 0
    private var maximum = 0

    var startedCount: Int {
        self.condition.withLock { self.starts }
    }

    var maximumOverlap: Int {
        self.condition.withLock { self.maximum }
    }

    func runUntilReleased() {
        self.condition.lock()
        self.beginLocked()
        while !self.released {
            self.condition.wait()
        }
        self.active -= 1
        self.condition.unlock()
    }

    func recordBriefOperation() {
        self.condition.withLock {
            self.beginLocked()
            self.active -= 1
        }
    }

    func recordUnexpectedOverlap() {
        self.recordBriefOperation()
    }

    func release() {
        self.condition.withLock {
            self.released = true
            self.condition.broadcast()
        }
    }

    private func beginLocked() {
        self.active += 1
        self.starts += 1
        self.maximum = max(self.maximum, self.active)
    }
}
