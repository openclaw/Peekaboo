import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct SetValueOutcomeCommandTests {
    @Test
    func `post-dispatch readback failure preserves receipt and blocks blind replay`() async throws {
        let automation = OutcomeStubAutomationService()
        let snapshots = StubSnapshotManager()
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            automation: automation
        )
        let snapshotID = try await ActionOutcomeCommandTests.storeExactWindowElementSnapshot(in: snapshots)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: 12345,
            processStartIdentity: 7,
            windowID: 42
        )
        automation.uiAutomationOutcomeScript.appendFailure(
            DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "The submitted value could not be read back.",
                hint: "Observe the exact target before retrying."
            )
            .attributed(to: targetReceipt),
            for: .setValue
        )
        let arguments = [
            "set-value", "updated", "--on", "elem_3", "--snapshot", snapshotID,
            "--json", "--no-remote",
        ]

        let first = try await InProcessCommandRunner.run(arguments, services: services)
        let firstObject = try Self.jsonObject(first.stdout)
        let outcome = try #require(firstObject["outcome"] as? [String: Any])
        let error = try #require(firstObject["error"] as? [String: Any])
        let receipt = try #require(firstObject["target_receipt"] as? [String: Any])
        #expect(first.exitStatus == 1)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["delivery_mechanism"] as? String == "accessibility_value")
        #expect(outcome["delivery_mode"] as? String == "background")
        #expect(outcome["dispatch_state"] as? String == "may_have_dispatched")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(outcome["requires_fresh_observation"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(receipt["pid"] as? Int == Int(targetReceipt.processIdentifier))
        #expect(receipt["process_start_identity_decimal"] as? String == "7")
        #expect(receipt["window_id"] as? Int == targetReceipt.windowID)

        let second = try await InProcessCommandRunner.run(arguments, services: services)
        let secondObject = try Self.jsonObject(second.stdout)
        let secondOutcome = try #require(secondObject["outcome"] as? [String: Any])
        #expect(second.exitStatus == 1)
        #expect(secondOutcome["state"] as? String == "refused")
        #expect(secondOutcome["mutation_dispatched"] as? Bool == false)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .setValue) == 1)
        #expect(try await snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
