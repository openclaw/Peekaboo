import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DialogOperationDeadlineTests {
    @Test(arguments: [1.0, 5, 20, 60])
    func `explicit caller budgets are not replaced by a shorter service default`(_ seconds: Double) throws {
        let caller = try DialogOperationDeadline.bounded(timeoutSeconds: seconds, operationName: "dialog list")
        try DialogOperationDeadline.$current.withValue(caller) {
            let resolved = try DialogOperationDeadline.resolve(operationName: "service")
            #expect(resolved.deadline == caller.deadline)
            #expect(resolved.timeoutSeconds == seconds)
            #expect(resolved.operationName == "dialog list")
        }
    }

    @Test
    func `absent caller context gets the documented finite fallback`() throws {
        let resolved = try DialogOperationDeadline.resolve(operationName: "service")
        #expect(resolved.timeoutSeconds == 20)
        #expect(resolved.remainingSeconds > 19)
        #expect(resolved.remainingSeconds <= 20)
    }

    @Test
    func `nested budgets only tighten and never restart an ancestor`() async throws {
        let ancestor = try DialogOperationDeadline.bounded(timeoutSeconds: 20, operationName: "ancestor")
        try await DialogOperationDeadline.$current.withValue(ancestor) {
            let before = ancestor.remainingSeconds
            try await Task.sleep(for: .milliseconds(5))
            let longer = try DialogOperationDeadline.bounded(timeoutSeconds: 60, operationName: "child")
            #expect(longer.deadline == ancestor.deadline)
            #expect(longer.remainingSeconds < before)
            let shorter = try DialogOperationDeadline.bounded(timeoutSeconds: 1, operationName: "child")
            #expect(shorter.deadline < ancestor.deadline)
            #expect(shorter.timeoutSeconds == 1)
        }
    }

    @Test(arguments: [0.0, -1, Double.infinity, -.infinity, .nan])
    func `invalid metadata cannot establish a deadline`(_ seconds: Double) {
        #expect(throws: PeekabooError.self) {
            try DialogOperationDeadline.bounded(timeoutSeconds: seconds, operationName: "dialog")
        }
    }

    @Test
    func `expired parent stays expired across service and nested contexts`() async throws {
        let parent = try DialogOperationDeadline.bounded(timeoutSeconds: 0.001, operationName: "caller")
        try await Task.sleep(for: .milliseconds(5))
        try DialogOperationDeadline.$current.withValue(parent) {
            let inherited = try DialogOperationDeadline.resolve(operationName: "service")
            let nested = try DialogOperationDeadline.bounded(timeoutSeconds: 20, operationName: "nested")
            for budget in [inherited, nested] {
                let failure = #expect(throws: PeekabooError.self) { try budget.check() }
                guard let failure, case let .timeout(message) = failure else {
                    Issue.record("Expected the original caller timeout")
                    continue
                }
                #expect(message.contains("caller"))
                #expect(budget.timeoutSeconds == 0.001)
            }
        }
    }

    @Test
    func `cancellation wins even with a long remaining deadline`() async throws {
        let deadline = try DialogOperationDeadline.bounded(timeoutSeconds: 60, operationName: "dialog")
        let entered = AsyncStream.makeStream(of: Void.self)
        let operation = Task {
            entered.continuation.yield(())
            try? await Task.sleep(for: .seconds(60))
            try deadline.check()
        }
        for await _ in entered.stream {
            break
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) { try await operation.value }
        entered.continuation.finish()
    }
}
