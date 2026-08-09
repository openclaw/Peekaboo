import CoreGraphics
import Foundation
import XCTest
@testable @_spi(Testing) import PeekabooAutomationKit

@MainActor
final class DesktopObservationOCRCoordinatorTests: XCTestCase {
    func testNoncooperativeInjectedOCRTimeoutQuarantinesUntilLateCompletion() async throws {
        let recognizer = NoncooperativeInjectedOCRRecognizer()
        defer { recognizer.release() }
        let service = makeOCRObservationServiceForTesting(recognizer)
        let heartbeat = expectation(description: "main actor remained responsive")
        Task { @MainActor in heartbeat.fulfill() }
        let startedAt = ContinuousClock.now

        let result = try await service.observe(self.request(timeout: 0.02))

        await fulfillment(of: [heartbeat], timeout: 0.2)
        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(250))
        XCTAssertEqual(recognizer.receivedTimeout, 0.02, accuracy: 0.001)
        XCTAssertEqual(recognizer.startedCount, 1)
        XCTAssertEqual(result.ocr?.isComplete, false)
        XCTAssertEqual(result.ocr?.deadlineReached, true)
        XCTAssertEqual(result.elements?.metadata.truncationInfo?.deadlineReached, true)

        let didQuarantine = await self.waitForOCRQuarantine(true)
        XCTAssertTrue(didQuarantine)
        let quarantined = try await service.observe(self.request(timeout: 0.2))
        XCTAssertEqual(quarantined.ocr?.isComplete, false)
        XCTAssertEqual(quarantined.ocr?.deadlineReached, false)
        XCTAssertTrue(quarantined.ocr?.warnings.contains(where: { $0.contains("still finishing") }) == true)
        XCTAssertEqual(recognizer.startedCount, 1)
        XCTAssertEqual(recognizer.maximumOverlap, 1)

        recognizer.release()
        let didRecover = await self.waitForOCRQuarantine(false)
        XCTAssertTrue(didRecover)
        let recovered = try await service.observe(self.request(timeout: 0.2))
        XCTAssertEqual(recovered.ocr?.isComplete, true)
        XCTAssertEqual(recognizer.startedCount, 2)
        XCTAssertEqual(recognizer.maximumOverlap, 1)
    }

    func testNoncooperativeInjectedOCRCancellationQuarantinesUntilLateCompletion() async throws {
        let recognizer = NoncooperativeInjectedOCRRecognizer()
        defer { recognizer.release() }
        let service = makeOCRObservationServiceForTesting(recognizer)
        let observation = Task { @MainActor in
            try await service.observe(self.request(timeout: 60))
        }
        let didStart = await self.waitForOCRStarts(recognizer, count: 1)
        XCTAssertTrue(didStart)

        let cancellationStart = ContinuousClock.now
        observation.cancel()
        do {
            _ = try await observation.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertLessThan(cancellationStart.duration(to: .now), .seconds(1))
        let didQuarantine = await self.waitForOCRQuarantine(true)
        XCTAssertTrue(didQuarantine)

        let quarantined = try await service.observe(self.request(timeout: 0.2))
        XCTAssertEqual(quarantined.ocr?.isComplete, false)
        XCTAssertEqual(quarantined.ocr?.deadlineReached, false)
        XCTAssertEqual(recognizer.startedCount, 1)
        XCTAssertEqual(recognizer.maximumOverlap, 1)

        recognizer.release()
        let didRecover = await self.waitForOCRQuarantine(false)
        XCTAssertTrue(didRecover)
        let recovered = try await service.observe(self.request(timeout: 0.2))
        XCTAssertEqual(recovered.ocr?.isComplete, true)
        XCTAssertEqual(recognizer.startedCount, 2)
        XCTAssertEqual(recognizer.maximumOverlap, 1)
    }

    private func request(timeout: TimeInterval) -> DesktopObservationRequest {
        DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none, preferOCR: true),
            timeout: DesktopObservationTimeouts(ocr: timeout))
    }

    private func waitForOCRStarts(_ recognizer: NoncooperativeInjectedOCRRecognizer, count: Int) async -> Bool {
        for _ in 0..<200 {
            if recognizer.startedCount >= count {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return recognizer.startedCount >= count
    }

    private func waitForOCRQuarantine(_ expected: Bool) async -> Bool {
        for _ in 0..<200 {
            if await OCRExecutionRunner.isQuarantinedForTesting() == expected {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await OCRExecutionRunner.isQuarantinedForTesting() == expected
    }
}

private final class NoncooperativeInjectedOCRRecognizer: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var timeout: TimeInterval = 0
    private var starts = 0
    private var active = 0
    private var maximum = 0

    var receivedTimeout: TimeInterval {
        self.lock.withLock { self.timeout }
    }

    var startedCount: Int {
        self.lock.withLock { self.starts }
    }

    var maximumOverlap: Int {
        self.lock.withLock { self.maximum }
    }

    func recognizeText(in _: Data, timeoutSeconds: TimeInterval) async throws -> OCRTextResult {
        let shouldWait = self.lock.withLock {
            self.timeout = timeoutSeconds
            self.starts += 1
            self.active += 1
            self.maximum = max(self.maximum, self.active)
            return !self.released
        }
        if shouldWait {
            await withCheckedContinuation { continuation in
                let resumeImmediately = self.lock.withLock {
                    guard !self.released else { return true }
                    self.continuations.append(continuation)
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        }
        self.lock.withLock { self.active -= 1 }
        return OCRTextResult(observations: [], imageSize: CGSize(width: 1, height: 1))
    }

    func release() {
        let continuations = self.lock.withLock {
            self.released = true
            let continuations = self.continuations
            self.continuations.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.resume()
        }
    }
}
