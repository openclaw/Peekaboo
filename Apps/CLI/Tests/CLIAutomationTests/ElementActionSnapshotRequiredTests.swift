import Foundation
@testable import PeekabooCLI
import Testing

@Suite(.serialized)
struct ElementActionSnapshotRequiredTests {
    @Test
    func `Snapshotless element action commands refuse before automation dispatch`() async throws {
        let cases: [(arguments: [String], expectedCommand: String)] = [
            (["action", "AXPress", "--on", "Delete"], "action"),
            (["set-value", "yes", "--on", "Delete"], "set-value"),
        ]

        for testCase in cases {
            let context = await TestServicesFactory.makeAutomationTestContext()
            let result = try await InProcessCommandRunner.run(
                testCase.arguments + ["--json", "--no-remote"],
                services: context.services
            )

            #expect(result.exitStatus == 1, "Expected \(testCase.expectedCommand) to refuse")
            #expect(result.combinedOutput.contains("No UI snapshot is available"))
            #expect(context.automation.setValueCalls.isEmpty)
            #expect(context.automation.performActionCalls.isEmpty)
            #expect(context.snapshots.invalidationCutoffs.isEmpty)
        }
    }
}
