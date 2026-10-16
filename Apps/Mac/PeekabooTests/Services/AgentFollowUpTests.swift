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
        let (agent, _) = makeFollowUpAgent(gate: gate)
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
        let (agent, _) = makeFollowUpAgent(gate: gate)
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

    @Test
    func `A failed task still runs the accepted follow-up`() async throws {
        let gate = FollowUpGate()
        let (agent, store) = makeFollowUpAgent(gate: gate, failingTexts: ["first"])
        defer { gate.releaseAll() }

        let first = Task { try await agent.executeTask("first") }
        await gate.waitUntilEntered("first")

        var followUpReturned = false
        let followUp = Task {
            try await agent.executeTask("second")
            followUpReturned = true
        }
        let accepted = await waitUntil { followUpReturned }
        #expect(accepted)
        #expect(!gate.didEnter("second"))

        gate.release("first")
        await gate.waitUntilEntered("second")
        #expect(agent.isProcessing)
        gate.release("second")
        let firstResult = await first.result
        try await followUp.value

        #expect(gate.entered == ["first", "second"])
        guard case .failure = firstResult else {
            Issue.record("the live failure should still surface")
            return
        }
        let contents = store.sessions.flatMap(\.messages).map(\.content).joined(separator: "\n")
        #expect(contents.contains("network down"))
        #expect(contents.contains("second"))
        #expect(!agent.isProcessing)
    }

    @Test
    func `A prompt sent while Stop is unwinding still runs`() async throws {
        let gate = FollowUpGate()
        gate.holdCancellation = true
        let (agent, _) = makeFollowUpAgent(gate: gate)
        defer { gate.releaseAll() }

        let first = Task { try await agent.executeTask("first") }
        await gate.waitUntilEntered("first")
        agent.cancelCurrentTask()

        var retryReturned = false
        let retry = Task {
            try await agent.executeTask("retry")
            retryReturned = true
        }
        let accepted = await waitUntil { retryReturned }
        #expect(accepted)
        #expect(!gate.didEnter("retry"))
        #expect(agent.isProcessing)

        gate.finishHeldCancellation()
        await gate.waitUntilEntered("retry")
        #expect(agent.isProcessing)
        #expect(gate.wasCancelled("first"))

        gate.release("retry")
        let firstResult = await first.result
        try await retry.value
        #expect(!agent.isProcessing)
        #expect(gate.entered == ["first", "retry"])
        guard case let .failure(error) = firstResult else {
            Issue.record("Stop should fail the live task")
            return
        }
        #expect(error is CancellationError)
    }

    @Test
    func `A queued follow-up stays on the session that accepted it`() async throws {
        let gate = FollowUpGate()
        let (agent, store) = makeFollowUpAgent(gate: gate)
        defer { gate.releaseAll() }
        let originalId = store.currentSession?.id

        let first = Task { try await agent.executeTask("first") }
        await gate.waitUntilEntered("first")

        var followUpReturned = false
        let followUp = Task {
            try await agent.executeTask("second")
            followUpReturned = true
        }
        let accepted = await waitUntil { followUpReturned }
        #expect(accepted)

        let other = store.createSession(title: "Other", modelName: "test")
        gate.release("first")
        await gate.waitUntilEntered("second")
        gate.release("second")
        try await first.value
        try await followUp.value

        let original = store.sessions.first { $0.id == originalId }?.messages.map(\.content) ?? []
        let moved = store.sessions.first { $0.id == other.id }?.messages.map(\.content) ?? []
        #expect(original.contains { $0.contains("second") })
        #expect(moved.allSatisfy { !$0.contains("second") })
    }
}

@MainActor
private final class FollowUpGate {
    var holdCancellation = false
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

    func finishHeldCancellation() {
        for name in Array(self.parked.keys) where self.parked[name]?.cancelled == true {
            self.finish(name, result: .failure(CancellationError()))
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
        if self.holdCancellation {
            return
        }
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
private func makeFollowUpAgent(
    gate: FollowUpGate,
    failingTexts: Set<String> = []) -> (PeekabooAgent, SessionStore)
{
    let settings = makeTestSettings()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sessionStore = SessionStore(storageURL: directory.appendingPathComponent("sessions.json"))
    let session = sessionStore.createSession(title: "Follow-up", modelName: "test")
    sessionStore.selectSession(session)
    let services = PeekabooServices(initializeAgentService: false)
    let agent = PeekabooAgent(
        settings: settings,
        sessionStore: sessionStore,
        services: services,
        taskRunner: { text in
            try await gate.enter(text)
            if failingTexts.contains(text) {
                throw AgentError.executionFailed("network down")
            }
            return sampleFollowUpResult(text)
        })
    return (agent, sessionStore)
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
