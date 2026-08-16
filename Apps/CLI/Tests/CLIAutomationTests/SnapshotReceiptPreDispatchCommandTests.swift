import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
@MainActor
struct SnapshotReceiptPreDispatchCommandTests {
    @Test
    func `incomplete exact receipt refusals release the snapshot lease across action commands`() async throws {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await Self.storeIncompleteExactWindowElementSnapshot(in: snapshots)
        let automation = UIAutomationService(snapshotManager: snapshots)
        let services = TestServicesFactory.makePeekabooServices(
            snapshots: snapshots,
            automation: automation
        )
        let actionArguments = [
            ["set-value", "updated", "--on", "E1"],
            ["action", "AXIncrement", "--on", "B1"],
            ["scroll", "--direction", "down", "--amount", "1", "--on", "B1"],
            ["click", "--on", "B1"],
        ]

        for _ in 0..<2 {
            for arguments in actionArguments {
                let result = try await InProcessCommandRunner.run(
                    arguments + ["--snapshot", snapshotID, "--no-remote", "--json"],
                    services: services
                )
                let object = try Self.jsonObject(result.stdout)
                let outcome = try #require(object["outcome"] as? [String: Any])
                let error = try #require(object["error"] as? [String: Any])

                #expect(result.exitStatus == 1, "Expected receipt refusal for \(arguments[0])")
                #expect(error["code"] as? String == ErrorCode.SNAPSHOT_STALE.rawValue)
                #expect((error["message"] as? String)?.contains("incomplete") == true)
                #expect((error["message"] as? String)?.contains("immutable captured bounds") == true)
                #expect(error["retry_safe"] as? Bool == true)
                #expect(error["mutation_dispatched"] as? Bool == false)
                #expect(outcome["state"] as? String == "refused")
                #expect(outcome["dispatch_state"] as? String == "none")
                #expect(outcome["requires_fresh_observation"] as? Bool == false)
                #expect(!result.combinedOutput.contains("already drove a mutation"))
            }
        }

        let typeResult = try await InProcessCommandRunner.run(
            ["type", "hello", "--snapshot", snapshotID, "--no-remote", "--json"],
            services: services
        )
        let typeObject = try Self.jsonObject(typeResult.stdout)
        let typeError = try #require(typeObject["error"] as? [String: Any])
        #expect(typeResult.exitStatus == 1)
        #expect(typeError["code"] as? String == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(typeResult.combinedOutput.contains("no exact process-generation, window, and bounds receipt"))
        #expect(!typeResult.combinedOutput.contains("already drove a mutation"))

        let humanResult = try await InProcessCommandRunner.run(
            ["set-value", "updated", "--on", "E1", "--snapshot", snapshotID, "--no-remote"],
            services: services
        )
        #expect(humanResult.exitStatus == 1)
        #expect(humanResult.combinedOutput.contains("Snapshot target receipt is incomplete"))
        #expect(humanResult.combinedOutput.contains("immutable captured bounds"))
        #expect(humanResult.combinedOutput.contains("complete exact-window snapshot"))
        #expect(!humanResult.combinedOutput.contains("already drove a mutation"))

        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    private static func storeIncompleteExactWindowElementSnapshot(
        in snapshots: StubSnapshotManager
    ) async throws -> String {
        let snapshotID = try await snapshots.createSnapshot()
        let process = AutomationTestFixtures.processIdentity(
            processIdentifier: getpid(),
            processStartIdentity: 71
        )
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let identity = AutomationTestFixtures.windowIdentity(
            windowID: 42,
            processIdentity: process,
            bounds: nil
        )
        let button = AutomationTestFixtures.detectedElement(
            id: "B1",
            type: .button,
            label: "Button",
            bounds: CGRect(x: 120, y: 140, width: 100, height: 40),
            isEnabled: true,
            attributes: ["role": "AXButton"]
        )
        let textField = AutomationTestFixtures.detectedElement(
            id: "E1",
            type: .textField,
            label: "Value",
            bounds: CGRect(x: 120, y: 200, width: 200, height: 30),
            isEnabled: true,
            attributes: ["role": "AXTextField"]
        )
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: AutomationTestFixtures.detectionResult(
                snapshotID: snapshotID,
                screenshotPath: "/tmp/incomplete-exact-window.png",
                elements: DetectedElements(
                    buttons: [button],
                    textFields: [textField]
                ),
                windowContext: WindowContext(
                    applicationProcessId: process.processIdentifier,
                    windowID: identity.windowID,
                    windowBounds: bounds,
                    windowMutationIdentity: identity
                )
            )
        )
        return snapshotID
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
