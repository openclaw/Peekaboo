import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.services, .unit))
@MainActor
struct AgentFollowUpTests {
    @Test
    func `Follow-up waits for the live task and Stop stays available`() async throws {
        let gate = FollowUpGate()
        let agent = makeFollowUpAgent(gate: gate)
        defer { gate.releaseAll() }

        var firstReturned = false
        let first = Task {
            try await agent.executeTask("first")
            firstReturned = true
        }
        await gate.waitUntilEntered("first")
        #expect(agent.isProcessing)

        var followUpReturned = false
        let followUp = Task {
            try await agent.executeTask("second")
            followUpReturned = true
        }
        let followUpSettled = await waitUntil { followUpReturned || gate.didEnter("second") }
        #expect(followUpSettled)
        #expect(followUpReturned)
        #expect(!gate.didEnter("second"))
        #expect(agent.isProcessing)

        gate.release("first")
        await gate.waitUntilEntered("second")
        #expect(!firstReturned)
        #expect(agent.isProcessing)

        gate.release("second")
        try await first.value
        try await followUp.value
        #expect(firstReturned)
        #expect(!agent.isProcessing)
        #expect(gate.entered == ["first", "second"])
    }

    @Test
    func `Stop during a follow-up cancels the live task and drops the queue`() async throws {
        let gate = FollowUpGate()
        let agent = makeFollowUpAgent(gate: gate)
        defer { gate.releaseAll() }

        let first = Task {
            try await agent.executeTask("first")
        }
        await gate.waitUntilEntered("first")

        var followUpReturned = false
        let followUp = Task {
            try await agent.executeTask("second")
            followUpReturned = true
        }
        let followUpSettled = await waitUntil { followUpReturned || gate.didEnter("second") }
        #expect(followUpSettled)
        #expect(followUpReturned)
        #expect(!gate.didEnter("second"))
        #expect(agent.isProcessing)

        agent.cancelCurrentTask()
        let cancelled = await waitUntil { gate.wasCancelled("first") }
        gate.releaseAll()
        let firstResult = await first.result
        try await followUp.value

        #expect(cancelled)
        #expect(gate.wasCancelled("first"))
        #expect(!gate.didEnter("second"))
        #expect(!agent.isProcessing)
        guard case let .failure(error) = firstResult else {
            Issue.record("Stop should fail the live task")
            return
        }
        #expect(error is CancellationError)
    }
}

@MainActor
private final class FollowUpGate {
    private(set) var entered: [String] = []
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var parked: [String: ParkedWork] = [:]

    func didEnter(_ name: String) -> Bool {
        self.entered.contains(name)
    }

    func wasCancelled(_ name: String) -> Bool {
        self.parked[name]?.cancelled == true
    }

    func enter(_ name: String) async throws {
        self.entered.append(name)
        self.waiters.removeValue(forKey: name)?.resume()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.park(name, continuation)
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(name)
            }
        }
    }

    func waitUntilEntered(_ name: String) async {
        if self.didEnter(name) {
            return
        }
        await withCheckedContinuation { continuation in
            if self.didEnter(name) {
                continuation.resume()
                return
            }
            self.waiters[name] = continuation
        }
    }

    func release(_ name: String) {
        self.finish(name, result: .success(()))
    }

    func releaseAll() {
        for name in Array(self.parked.keys) {
            self.release(name)
        }
    }

    private func park(_ name: String, _ continuation: CheckedContinuation<Void, any Error>) {
        var slot = self.parked[name] ?? ParkedWork()
        if slot.finished {
            continuation.resume(with: slot.result ?? .success(()))
            return
        }
        slot.continuation = continuation
        self.parked[name] = slot
    }

    private func cancel(_ name: String) {
        var slot = self.parked[name] ?? ParkedWork()
        slot.cancelled = true
        self.parked[name] = slot
        self.finish(name, result: .failure(CancellationError()))
    }

    private func finish(_ name: String, result: Result<Void, any Error>) {
        var slot = self.parked[name] ?? ParkedWork()
        guard !slot.finished else { return }
        slot.finished = true
        slot.result = result
        let continuation = slot.continuation
        slot.continuation = nil
        self.parked[name] = slot
        continuation?.resume(with: result)
    }
}

@MainActor
private struct ParkedWork {
    var continuation: CheckedContinuation<Void, any Error>?
    var finished = false
    var cancelled = false
    var result: Result<Void, any Error>?
}

@MainActor
private func makeFollowUpAgent(gate: FollowUpGate) -> PeekabooAgent {
    let settings = makeTestSettings()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sessionStore = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
    let session = sessionStore.createSession(title: "Follow-up", modelName: "test")
    sessionStore.selectSession(session)
    let services = PeekabooServices(initializeAgentService: false)
    return PeekabooAgent(
        settings: settings,
        sessionStore: sessionStore,
        services: services,
        taskRunner: { text in
            try await gate.enter(text)
            return sampleFollowUpResult(text)
        })
}

@MainActor
private func sampleFollowUpResult(_ text: String) -> AgentExecutionResult {
    let now = Date()
    return AgentExecutionResult(
        content: text,
        sessionId: "follow-up",
        metadata: AgentMetadata(
            executionTime: 0,
            toolCallCount: 0,
            modelName: "test",
            startTime: now,
            endTime: now))
}

@MainActor
private func waitUntil(
    timeout: Duration = .milliseconds(400),
    _ predicate: @MainActor () -> Bool) async -> Bool
{
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if predicate() {
            return true
        }
        await Task.yield()
    }
    return predicate()
}
