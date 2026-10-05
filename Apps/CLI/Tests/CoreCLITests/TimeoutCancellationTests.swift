import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct TimeoutCancellationTests {
    @Test(arguments: [(0.2, "200 milliseconds"), (1.5, "1.5 seconds")])
    func `command deadline retains fractional duration in caught errors`(
        seconds: Double, expected: String) async throws
    {
        let error = try #require(await #expect(throws: PeekabooError.self) {
            try await withCommandTimeout(seconds: seconds, operationName: "Synthetic wait") {
                try await Task.sleep(for: .seconds(30))
            }
        })

        #expect(error.localizedDescription ==
            "Operation timed out: Operation 'Synthetic wait' timed out after \(expected)")
        #expect(TimeoutErrorHandlingCommand().mapErrorToCode(error) == .TIMEOUT)
        #expect(error.context["reason"] == "Operation 'Synthetic wait' timed out after \(expected)")
    }

    @Test
    func `completed command retains its result with a fractional deadline`() async throws {
        let result = try await withCommandTimeout(seconds: 0.2, operationName: "Synthetic immediate result") { 42 }
        #expect(result == 42)
    }

    @Test
    func `generic timeout returns caller cancellation promptly`() async throws {
        let gate = TimeoutOperationGate()
        let task = Task {
            try await withTimeout(seconds: 5) {
                await gate.run()
            }
        }
        await gate.waitUntilStarted()

        let cancelledAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
        await gate.finish(with: 1)
    }

    @Test
    func `generic timeout returns promptly when operation ignores cancellation`() async {
        let gate = TimeoutOperationGate()
        let startedAt = ContinuousClock.now
        let error = await #expect(throws: CaptureError.self) {
            try await withTimeout(seconds: 0.02) {
                await gate.run()
            }
        }

        guard case let .captureFailure(message) = error else {
            Issue.record("Expected capture failure timeout")
            return
        }
        #expect(message == "Operation timed out after 0.02 seconds")
        #expect(startedAt.duration(to: .now) < .seconds(1))
        await gate.finish(with: 1)
    }

    @Test
    func `config timeout returns caller cancellation over concurrent success`() async {
        let gate = TimeoutOperationGate()
        let task = Task {
            await withTimeout(.seconds(5)) {
                await gate.run()
            }
        }
        await gate.waitUntilStarted()

        task.cancel()
        await gate.finish(with: 42)

        guard case .failure(.cancelled) = await task.value else {
            Issue.record("Expected caller cancellation to win over operation success")
            return
        }
    }

    @Test
    func `config timeout returns promptly when operation ignores cancellation`() async {
        let gate = TimeoutOperationGate()
        let startedAt = ContinuousClock.now
        let result = await withTimeout(.milliseconds(20)) {
            await gate.run()
        }

        guard case .failure(.timedOut) = result else {
            Issue.record("Expected wall-clock timeout")
            return
        }
        #expect(startedAt.duration(to: .now) < .seconds(1))
        await gate.finish(with: 1)
    }
}

private struct TimeoutErrorHandlingCommand: ErrorHandlingCommand {
    let jsonOutput = false
}

private actor TimeoutOperationGate {
    private var operationContinuation: CheckedContinuation<Int, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var started = false

    func run() async -> Int {
        await withCheckedContinuation { continuation in
            self.operationContinuation = continuation
            self.started = true
            let waiters = self.startWaiters
            self.startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func finish(with value: Int) {
        self.operationContinuation?.resume(returning: value)
        self.operationContinuation = nil
    }
}
