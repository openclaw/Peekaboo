import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct MCPOrdinarySnapshotMutationTests {
    @Test(arguments: SnapshotVerb.allCases, [false, true])
    func `pending and consumed snapshots refuse every ordinary verb before dispatch`(
        verb: SnapshotVerb,
        consumed: Bool) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let lease = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        if consumed {
            try await fixture.storage.finishSnapshotMutation(lease, requiresFreshObservation: true)
        }

        let response = try await fixture.context.execute(
            tool: verb.tool(in: fixture.context),
            arguments: verb.arguments(snapshotID: fixture.snapshotID))

        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(fixture.automation.uiAutomationOutcomeScript.totalCallCount == 0)
        #expect(fixture.automation.focusCalls == 0)
        #expect(fixture.windows.focusRequests.isEmpty)
        #expect(fixture.windows.pinnedFocusCalls == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.isEmpty)
        #expect(fixture.coordinator.prepareCount == 1)
        #expect(fixture.coordinator.cancelCount == 1)
        #expect(fixture.coordinator.completeCount == 0)
        #expect(await fixture.context.snapshotExecutionGate.pendingInvalidation() == nil)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test(arguments: SnapshotVerb.allCases, [false, true])
    func `confirmed change and no change release ordinary snapshot authority`(
        verb: SnapshotVerb,
        noChange: Bool) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        if noChange {
            fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedNoChange())
        }

        let response = try await verb.execute(in: fixture)

        #expect(!response.isError)
        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        try await Self.expectReusable(fixture)
    }

    @Test(arguments: SnapshotVerb.allCases, [false, true])
    func `unverified and missing outcomes consume authority across every verb`(
        verb: SnapshotVerb,
        missingOutcome: Bool) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(missingOutcome ? nil : .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted))

        _ = try await verb.execute(in: fixture)

        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)
        for retryVerb in SnapshotVerb.allCases {
            let retry = try await retryVerb.execute(in: fixture)
            try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        }
        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.automation.uiAutomationOutcomeScript.totalCallCount == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test(arguments: SnapshotVerb.allCases)
    func `lease finalization failure never returns success or permits replay`(verb: SnapshotVerb) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.snapshots.failFinish = true

        let response = try await verb.execute(in: fixture)

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("indeterminate"))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)
        let retry = try await verb.execute(in: fixture)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)
    }

    @Test(arguments: SnapshotVerb.allCases)
    func `canonical predispatch refusal releases ordinary authority`(verb: SnapshotVerb) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.appendFailure(
            DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Synthetic receiver refused before dispatch"),
            for: verb.operation)

        let response = try await verb.execute(in: fixture)

        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        try await Self.expectReusable(fixture)
    }

    @Test(arguments: SnapshotVerb.allCases, [false, true])
    func `unknown postentry error and cancellation retain pending authority`(
        verb: SnapshotVerb,
        cancellation: Bool) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = cancellation
            ? CancellationError()
            : PeekabooError.snapshotStale("Synthetic completion unknown after leaf entry")

        do {
            let response = try await verb.execute(in: fixture)
            #expect(response.isError)
        } catch {
            #expect(cancellation && error is CancellationError)
        }

        #expect(fixture.automation.mutationCalls == 1)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.isEmpty)
        let retry = try await verb.execute(in: fixture)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        #expect(fixture.automation.mutationCalls == 1)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test
    func `mixed route no op press releases authority without inventing an aggregate`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.append(.confirmedNoChange(route: .local), for: .hotkey)
        fixture.automation.uiAutomationOutcomeScript.append(.confirmedNoChange(route: .bridge), for: .hotkey)

        let response = try await PressTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "keys": ["Tab", "Return"],
            "delay": 0,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["state"] == nil)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(response.meta?.objectValue?["requires_fresh_observation"] == .bool(false))
        #expect(fixture.automation.exactHotkeyCalls == 2)
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        try await Self.expectReusable(fixture)
    }

    @Test
    func `modifier click retains exactly one host owned lease`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "coords": "150,100",
            "modifiers": ["shift"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
        #expect(fixture.automation.modifierCalls == 1)
        #expect(fixture.automation.uiAutomationOutcomeScript.totalCallCount == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)
    }

    @Test(arguments: [false, true])
    func `foreground scroll refuses stale authority before its setup focus`(consumed: Bool) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let lease = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        if consumed {
            try await fixture.storage.finishSnapshotMutation(lease, requiresFreshObservation: true)
        }

        let response = try await ScrollTool(context: fixture.context).execute(
            arguments: Self.foregroundScrollArguments(fixture))

        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.windows.pinnedFocusCalls == 0)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(fixture.automation.uiAutomationOutcomeScript.totalCallCount == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.isEmpty)
    }

    @Test(arguments: ScrollLeafResult.allCases)
    func `foreground scroll completes its lease from composed focus and leaf evidence`(
        leaf: ScrollLeafResult) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        switch leaf {
        case .noChange:
            fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedNoChange())
        case .missingOutcome:
            fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(nil)
        case .refusal:
            fixture.automation.uiAutomationOutcomeScript.appendFailure(
                DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Synthetic refusal after setup focus"),
                for: .scroll)
        case .unknownError:
            fixture.automation.mutationError = PeekabooError.snapshotStale("Synthetic unknown scroll completion")
        }

        _ = try await ScrollTool(context: fixture.context).execute(arguments: Self.foregroundScrollArguments(fixture))

        #expect(fixture.windows.pinnedFocusCalls == 1)
        #expect(fixture.automation.uiAutomationOutcomeScript.callCount(for: .scroll) == 1)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == (leaf != .noChange))
        if leaf == .noChange {
            try await Self.expectReusable(fixture)
        } else {
            let retry = try await SnapshotVerb.click.execute(in: fixture)
            try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        }
    }

    @Test(arguments: SnapshotVerb.allCases)
    func `malformed ordinary requests never reserve snapshot authority`(verb: SnapshotVerb) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()

        let response = try await verb.tool(in: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
        ]))

        #expect(response.isError)
        #expect(fixture.automation.mutationCalls == 0)
        #expect(fixture.windows.pinnedFocusCalls == 0)
        #expect(fixture.snapshots.beginCalls.isEmpty)
        #expect(fixture.snapshots.finishCalls.isEmpty)
        try await Self.expectReusable(fixture)
    }

    @Test(arguments: [SnapshotVerb.click, .scroll, .press])
    func `snapshot free foreground routes do not reserve unrelated authority`(verb: SnapshotVerb) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground)))

        let response = try await verb.tool(in: fixture.context).execute(arguments: verb.foregroundArguments())

        #expect(!response.isError)
        #expect(fixture.automation.uiAutomationOutcomeScript.totalCallCount == 1)
        #expect(fixture.snapshots.beginCalls.isEmpty)
        #expect(fixture.snapshots.finishCalls.isEmpty)
        try await Self.expectReusable(fixture)
    }

    private static func expectReusable(_ fixture: MCPSnapshotMutationTestFixture) async throws {
        let reusable = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.storage.finishSnapshotMutation(reusable, requiresFreshObservation: false)
    }

    private static func expectHistoricalReads(_ fixture: MCPSnapshotMutationTestFixture) async throws {
        #expect(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID) != nil)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID) != nil)
    }

    private static func foregroundScrollArguments(_ fixture: MCPSnapshotMutationTestFixture) -> ToolArguments {
        ToolArguments(raw: ["snapshot": fixture.snapshotID, "on": "T1", "direction": "down", "foreground": true])
    }
}

extension MCPOrdinarySnapshotMutationTests {
    enum ScrollLeafResult: String, CaseIterable, Sendable {
        case noChange, missingOutcome, refusal, unknownError
    }

    enum SnapshotVerb: String, CaseIterable, Sendable {
        case click, action, setValue, scroll, press

        var operation: UIAutomationOutcomeScript.Operation {
            switch self {
            case .click: .click
            case .action: .performAction
            case .setValue: .setValue
            case .scroll: .scroll
            case .press: .hotkey
            }
        }

        @MainActor
        func tool(in context: MCPToolContext) -> any MCPTool {
            switch self {
            case .click: ClickTool(context: context)
            case .action: ActionTool(context: context)
            case .setValue: SetValueTool(context: context)
            case .scroll: ScrollTool(context: context)
            case .press: PressTool(context: context)
            }
        }

        func arguments(snapshotID: String) -> ToolArguments {
            let values: [String: Any] = switch self {
            case .click: ["snapshot": snapshotID, "on": "T1", "wait_for": 0]
            case .action: ["snapshot": snapshotID, "on": "T1", "action": "AXIncrement"]
            case .setValue: ["snapshot": snapshotID, "on": "T1", "value": "synthetic"]
            case .scroll: ["snapshot": snapshotID, "on": "T1", "direction": "down"]
            case .press: ["snapshot": snapshotID, "key": "Tab", "delay": 0]
            }
            return ToolArguments(raw: values)
        }

        @MainActor
        func execute(in fixture: MCPSnapshotMutationTestFixture) async throws -> ToolResponse {
            try await self.tool(in: fixture.context).execute(arguments: self.arguments(snapshotID: fixture.snapshotID))
        }

        func foregroundArguments() -> ToolArguments {
            let values: [String: Any] = switch self {
            case .click: ["coords": "150,100", "foreground": true]
            case .scroll: ["direction": "down", "foreground": true]
            case .press: ["key": "Tab", "foreground": true]
            case .action, .setValue: [:]
            }
            return ToolArguments(raw: values)
        }
    }
}
