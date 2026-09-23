import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct TypeServiceTypingCadenceTests {
    @Test(arguments: [9_007_199_254_740_992, Int.max])
    func `huge fixed cadence waits remain cancellable`(milliseconds: Int) async {
        let service = TypeService(snapshotManager: InMemorySnapshotManager())
        let cadence = TypingCadence.fixed(milliseconds: milliseconds)
        let delay = service.fixedDelaySeconds(for: cadence)
        let operation = Task { @MainActor in
            var context: HumanTypingContext?
            try await service.sleepAfterKeystroke(
                typedCharacter: "a",
                cadence: cadence,
                fixedDelaySeconds: delay,
                humanContext: &context)
        }
        operation.cancel()
        await #expect(throws: CancellationError.self) {
            try await operation.value
        }
    }
}
