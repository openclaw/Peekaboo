import Testing
@testable import PeekabooCore

@Suite(.serialized)
struct ProcessTerminationGateTests {
    @Test
    @MainActor
    func `termination remains deferred until asynchronous shutdown completes`() async {
        let gate = ProcessTerminationGate()
        let entered = TerminationTestGate()
        let release = TerminationTestGate()
        var replies: [Bool] = []

        let first = gate.begin(
            shutdown: {
                await entered.open()
                await release.wait()
            },
            reply: { replies.append($0) })
        let second = gate.begin(
            shutdown: { Issue.record("Concurrent termination must join the existing shutdown") },
            reply: { _ in Issue.record("Concurrent termination must not install another reply") })

        #expect(first == .terminateLater)
        #expect(second == .terminateLater)
        await entered.wait()
        #expect(replies.isEmpty)

        await release.open()
        for _ in 0..<100 where replies.isEmpty {
            await Task.yield()
        }
        #expect(replies == [true])
        #expect(gate.begin(shutdown: {}, reply: { _ in }) == .terminateNow)
    }
}

private actor TerminationTestGate {
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func open() {
        self.isOpen = true
        let continuations = self.continuations
        self.continuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.isOpen else { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }
}
