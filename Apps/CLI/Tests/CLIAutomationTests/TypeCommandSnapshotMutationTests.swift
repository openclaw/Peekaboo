import Commander
import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

extension TypeCommandTruthTests {
    @Test
    func `click consumption blocks ordinary typing while preserving snapshot evidence`() async throws {
        let focused = self.textFocus()
        let automation = self.automation(focused: focused)
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted
        )
        let context = self.context(automation: automation)
        let button = DetectedElement(
            id: "elem_1",
            type: .button,
            label: "Apply",
            bounds: CGRect(x: 40, y: 180, width: 100, height: 30),
            isEnabled: true,
            attributes: ["role": "AXButton"]
        )
        let snapshotID = try await self.storeSnapshot(
            focused: focused,
            context: context,
            elements: DetectedElements(buttons: [button])
        )
        let click = try await InProcessCommandRunner.run(
            ["click", "--on", button.id, "--snapshot", snapshotID, "--json"],
            services: context.services
        )
        #expect(click.exitStatus == 0)
        #expect(automation.targetedClickCalls.count == 1)

        let type = try await self.runType(
            ["Must not arrive", "--clear", "--snapshot", snapshotID, "--accept-dispatched", "--json"],
            context: context
        )
        try Self.expectConsumedTypeRefusal(type)
        #expect(automation.exactTypeActionsCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(try await context.snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    @Test(arguments: [false, true], [false, true])
    func `pending and consumed snapshots refuse clear typing regardless of dispatch acceptance`(
        consumed: Bool,
        acceptDispatched: Bool
    ) async throws {
        let focused = self.textFocus()
        let automation = self.automation(focused: focused)
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background)
        )
        let context = self.context(automation: automation)
        let snapshotID = try await self.storeSnapshot(focused: focused, context: context)
        let lease = try await context.snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        if consumed {
            try await context.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: true)
        }
        let arguments = ["Must not arrive", "--clear", "--snapshot", snapshotID, "--json"] +
            (acceptDispatched ? ["--accept-dispatched"] : [])
        let result = try await self.runType(arguments, context: context)

        try Self.expectConsumedTypeRefusal(result)
        #expect(automation.exactTypeActionsCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(context.snapshots.invalidationCutoffs.isEmpty)
        #expect(try await context.snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    @Test
    func `consumed foreground snapshot refuses before setup focus or mutation invalidation`() async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)
        )
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let context = TestServicesFactory.makeAutomationTestContext(automation: automation, windows: windows)
        let snapshotID = try await self.storeSnapshot(focused: self.textFocus(), context: context)
        let lease = try await context.snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await context.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: true)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("type-snapshot-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tracker = InteractionMutationTracker(
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: directory)
        )
        var command = TypeCommand()
        command.text = "Must not arrive"
        command.clear = true
        command.snapshot = snapshotID
        command.target.windowId = InputFocusFixtures.windowID
        command.focusOptions.foreground = true
        command.runtimeOptions.jsonOutput = true
        let runtime = CommandRuntime(
            configuration: command.runtimeOptions.makeConfiguration(),
            services: context.services,
            interactionMutationTracker: tracker
        )

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }
        #expect(tracker.mutationSequence == 0)
        #expect(tracker.mutationStartedAt == nil)
        #expect(windows.pinnedFocusCalls.isEmpty)
        #expect(windows.focusCalls.isEmpty)
        #expect(automation.typeActionsCalls.isEmpty)
        #expect(context.snapshots.invalidationCutoffs.isEmpty)
        #expect(try await context.snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    @Test(arguments: [false, true])
    func `ordinary typing consumes unverified snapshots even when dispatch is accepted`(
        acceptDispatched: Bool
    ) async throws {
        let focused = self.textFocus()
        let automation = self.automation(focused: focused)
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted
        )
        let context = self.context(automation: automation)
        let snapshotID = try await self.storeSnapshot(focused: focused, context: context)
        let arguments = ["Hello", "--snapshot", snapshotID, "--json"] +
            (acceptDispatched ? ["--accept-dispatched"] : [])
        let first = try await self.runType(arguments, context: context)
        #expect(first.exitStatus == (acceptDispatched ? 0 : 1))
        #expect(automation.exactTypeActionsCalls.count == 1)

        let second = try await self.runType(arguments, context: context)
        try Self.expectConsumedTypeRefusal(second)
        #expect(automation.exactTypeActionsCalls.count == 1)
        #expect(try await context.snapshots.getDetectionResult(snapshotId: snapshotID) != nil)
    }

    @Test
    func `confirmed ordinary typing releases its mutation lease`() async throws {
        let focused = self.textFocus()
        let automation = self.automation(focused: focused)
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background)
        )
        let context = self.context(automation: automation)
        let snapshotID = try await self.storeSnapshot(focused: focused, context: context)
        let result = try await self.runType(["Hello", "--snapshot", snapshotID, "--json"], context: context)
        #expect(result.exitStatus == 0)

        let nextLease = try await context.snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await context.snapshots.finishSnapshotMutation(nextLease, requiresFreshObservation: false)
    }

    private static func expectConsumedTypeRefusal(_ result: CommandRunResult) throws {
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(result.exitStatus == 1, "Unexpected result: \(result.combinedOutput)")
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(response.outcome?.state == .refused)
        #expect(response.outcome?.retrySafe == true)
        #expect(response.outcome?.mutationDispatched == false)
    }
}
