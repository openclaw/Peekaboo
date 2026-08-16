import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
struct ElementActionSnapshotRequiredTests {
    @Test
    func `Foreground-capable and unclassified accessibility actions require consent before setup`() async throws {
        let actions = [
            "AXPress",
            "press",
            "AXPick",
            "pick",
            "AXConfirm",
            "AXCancel",
            "AXOpen",
            "AXRaise",
            "AXScrollToVisible",
            "AXShowMenu",
            "AXShowAlternateUI",
            "AXShowDefaultUI",
            "AXCustomAction",
        ]
        for action in actions {
            let context = TestServicesFactory.makeAutomationTestContext()
            let result = try await InProcessCommandRunner.run(
                ["action", action, "--on", "Menu", "--json", "--no-remote"],
                services: context.services
            )

            #expect(result.exitStatus == 1, "Expected foreground refusal for \(action)")
            #expect(result.combinedOutput.contains("requires --foreground"))
            #expect(result.combinedOutput.contains("\"refusal_reason\" : \"foreground_consent_required\""))
            #expect(context.automation.performActionCalls.isEmpty)
            #expect(context.snapshots.invalidationCutoffs.isEmpty)
        }
    }

    @Test
    func `Explicit foreground consent advances a surfacing action to snapshot validation`() async throws {
        let context = TestServicesFactory.makeAutomationTestContext()
        let result = try await InProcessCommandRunner.run(
            ["action", "AXPress", "--on", "Button", "--foreground", "--json", "--no-remote"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("No UI snapshot is available"))
        #expect(!result.combinedOutput.contains("requires --foreground"))
        #expect(context.automation.performActionCalls.isEmpty)
        #expect(context.snapshots.invalidationCutoffs.isEmpty)
    }

    @Test
    func `Background-safe actions advance to snapshot validation without foreground consent`() async throws {
        for action in ["AXIncrement", "decrement"] {
            let context = TestServicesFactory.makeAutomationTestContext()
            let result = try await InProcessCommandRunner.run(
                ["action", action, "--on", "Stepper", "--json", "--no-remote"],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(result.combinedOutput.contains("No UI snapshot is available"))
            #expect(!result.combinedOutput.contains("requires --foreground"))
            #expect(context.automation.performActionCalls.isEmpty)
            #expect(context.snapshots.invalidationCutoffs.isEmpty)
        }
    }

    @Test
    func `Snapshotless element action commands refuse before automation dispatch`() async throws {
        let cases: [(arguments: [String], expectedCommand: String)] = [
            (["action", "AXIncrement", "--on", "Stepper"], "action"),
            (["set-value", "yes", "--on", "Delete"], "set-value"),
        ]

        for testCase in cases {
            let context = TestServicesFactory.makeAutomationTestContext()
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
