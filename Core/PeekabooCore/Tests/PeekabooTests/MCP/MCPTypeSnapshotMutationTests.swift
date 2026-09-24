import CoreGraphics
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
struct MCPTypeSnapshotMutationTests {
    @Test(arguments: [false, true])
    func `pending and consumed snapshots refuse ordinary typing before element focus`(consumed: Bool) async throws {
        let fixture = try await Self.makeFixture()
        let lease = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        if consumed {
            try await fixture.storage.finishSnapshotMutation(lease, requiresFreshObservation: true)
        }

        let response = try await fixture.context.execute(
            tool: TypeTool(context: fixture.context),
            arguments: Self.arguments(fixture, focus: true))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.automation.focusCalls == 0)
        #expect(fixture.automation.typeCalls == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.isEmpty)
        #expect(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID) != nil)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID) != nil)
        #expect(fixture.coordinator.prepareCount == 1)
        #expect(fixture.coordinator.cancelCount == 1)
        #expect(fixture.coordinator.completeCount == 0)
        #expect(await fixture.context.snapshotExecutionGate.pendingInvalidation() == nil)
    }

    @Test
    func `confirmed ordinary typing finalizes its lease before returning success`() async throws {
        let fixture = try await Self.makeFixture()
        let response = try await TypeTool(context: fixture.context).execute(
            arguments: Self.arguments(fixture, focus: true))

        #expect(!response.isError)
        #expect(fixture.automation.focusCalls == 1)
        #expect(fixture.automation.typeCalls == 1)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        let reusable = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.storage.finishSnapshotMutation(reusable, requiresFreshObservation: false)
    }

    @Test
    func `unverified typing consumes the composed focus and type snapshot`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .init(3)))

        let response = try await TypeTool(context: fixture.context).execute(
            arguments: Self.arguments(fixture, focus: true))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["dispatched_unit_count"] == .int(4))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(fixture.automation.focusCalls == 1)
        #expect(fixture.automation.typeCalls == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)

        let retry = try await TypeTool(context: fixture.context).execute(arguments: Self.arguments(fixture))
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        #expect(fixture.automation.typeCalls == 1)
        #expect(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID) != nil)
    }

    @Test
    func `typing lease finalization failure cannot return success or permit reuse`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.snapshots.failFinish = true

        let response = try await TypeTool(context: fixture.context).execute(arguments: Self.arguments(fixture))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("indeterminate"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(fixture.automation.typeCalls == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)

        let retry = try await TypeTool(context: fixture.context).execute(arguments: Self.arguments(fixture))
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        #expect(fixture.automation.typeCalls == 1)
    }

    @Test
    func `canonical refusal releases ordinary typing lease without dispatch`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.automation.uiAutomationOutcomeScript.appendFailure(
            DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Synthetic receiver refused before dispatch"),
            for: .typeActions)

        let response = try await TypeTool(context: fixture.context).execute(arguments: Self.arguments(fixture))

        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.automation.typeCalls == 0)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        let reusable = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.storage.finishSnapshotMutation(reusable, requiresFreshObservation: false)
    }

    @Test
    func `raw stale failure after typing entry retains the pending lease`() async throws {
        let fixture = try await Self.makeFixture()
        fixture.automation.typeError = PeekabooError.snapshotStale("Synthetic failure after leaf entry")

        let response = try await TypeTool(context: fixture.context).execute(arguments: Self.arguments(fixture))

        #expect(response.isError)
        #expect(fixture.automation.typeCalls == 1)
        #expect(fixture.snapshots.finishCalls.isEmpty)
        let retry = try await TypeTool(context: fixture.context).execute(arguments: Self.arguments(fixture))
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: retry)
        #expect(fixture.automation.typeCalls == 1)
    }

    @Test
    func `pixel focus keeps its service owned lease without a nested MCP reservation`() async throws {
        let fixture = try await Self.makeFixture()

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "coords": "150,100",
            "text": "synthetic",
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
        #expect(fixture.automation.pixelCalls == 1)
        #expect(fixture.automation.typeCalls == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)
    }

    private static func arguments(_ fixture: MCPSnapshotMutationTestFixture, focus: Bool = false) -> ToolArguments {
        var arguments: [String: Any] = ["snapshot": fixture.snapshotID, "text": "synthetic", "clear": true]
        if focus {
            arguments["on"] = "T1"
        }
        return ToolArguments(raw: arguments)
    }

    private static func makeFixture() async throws -> MCPSnapshotMutationTestFixture {
        try await MCPSnapshotMutationTestFixture.make()
    }
}
