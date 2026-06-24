import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct SeeCommandTimeoutTests {
    @Test
    func `returns result before timeout`() async throws {
        let result = try await SeeCommand.withWallClockTimeout(seconds: 1.0) {
            "ok"
        }
        #expect(result == "ok")
    }

    @Test
    func `throws detectionTimedOut when operation exceeds deadline`() async {
        let startedAt = Date()
        let error = await #expect(throws: CaptureError.self) {
            try await SeeCommand.withWallClockTimeout(seconds: 0.05) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                        continuation.resume(returning: "late")
                    }
                }
            }
        }

        switch error {
        case let .detectionTimedOut(seconds):
            #expect(seconds == 0.05, "Timeout should propagate configured deadline")
        default:
            Issue.record("Unexpected capture error: \(error)")
        }
        #expect(Date().timeIntervalSince(startedAt) < 0.25)
    }

    @Test
    func `parent cancellation remains cancellation`() async throws {
        let task = Task {
            try await SeeCommand.withWallClockTimeout(seconds: 5) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "late"
            }
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    func `nested timeout errors pass through unchanged`() async {
        let error = await #expect(throws: PeekabooError.self) {
            try await SeeCommand.withWallClockTimeout(seconds: 5) {
                throw PeekabooError.timeout("nested capture timeout")
            }
        }

        guard case let .timeout(reason) = error else {
            Issue.record("Expected nested PeekabooError.timeout")
            return
        }
        #expect(reason == "nested capture timeout")
    }

    @Test
    @MainActor
    func `timed out mutation keeps barrier until ignored cancellation work finishes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-local-timeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)

        await #expect(throws: PeekabooError.self) {
            try await withMainActorCommandTimeout(
                seconds: 0.01,
                operationName: "delayed mutation",
                desktopMutationWatermarkStore: store
            ) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        #expect(try #require(store.effectiveWatermark()) > firstPendingRead)

        #expect(try await Self.waitForStableWatermark(store))
    }

    @Test
    @MainActor
    func `see timeout retains the command barrier until ignored cancellation work finishes`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-see-timeout-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root)
        let tracker = InteractionMutationTracker(desktopMutationWatermarkStore: store)
        #expect(try tracker.beginDurableMutation())

        await #expect(throws: CaptureError.self) {
            try await SeeCommand.withWallClockTimeout(
                seconds: 0.01,
                interactionMutationTracker: tracker
            ) {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                        continuation.resume(returning: ())
                    }
                }
            }
        }

        #expect(try tracker.completeDurableMutation(through: Date()) == nil)
        let firstPendingRead = try #require(store.effectiveWatermark())
        try await Task.sleep(for: .milliseconds(2))
        #expect(try #require(store.effectiveWatermark()) > firstPendingRead)

        #expect(try await Self.waitForStableWatermark(store))
    }

    private static func waitForStableWatermark(
        _ store: DesktopMutationWatermarkStore,
        timeout: Duration = .seconds(1)
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var previous = store.effectiveWatermark()

        repeat {
            try await Task.sleep(for: .milliseconds(5))
            let current = store.effectiveWatermark()
            if current != nil, current == previous {
                return true
            }
            previous = current
        } while clock.now < deadline

        return false
    }
}
