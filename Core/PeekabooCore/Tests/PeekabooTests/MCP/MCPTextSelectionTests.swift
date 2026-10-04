import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

@MainActor
@Suite(.serialized)
struct MCPTextSelectionTests {
    @Test
    func `schema exposes literal context and only the three selection modes`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        guard case let .object(schema) = SelectTextTool(context: fixture.context).inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(mode)? = properties["selection_type"]
        else { Issue.record("Missing selection schema"); return }
        #expect(mode["enum"] == .array([.string("text"), .string("cursor_before"), .string("cursor_after")]))
        #expect(properties["prefix"] != nil && properties["suffix"] != nil)
        #expect(properties["foreground"] == nil)
        #expect(schema["required"] == .array([.string("on"), .string("text")]))
    }

    @Test
    func `selection uses exact snapshot authority without focusing or editing`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let response = try await fixture.context.execute(
            tool: SelectTextTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "on": "T1", "text": "needle", "selection_type": "cursor_after", "snapshot": fixture.snapshotID,
            ]))
        #expect(!response.isError)
        #expect(fixture.automation.selectTextCalls == 1)
        #expect(fixture.automation.focusCalls == 0 && fixture.automation.setValueCalls == 0)
        #expect(fixture.windows.focusRequests.isEmpty)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
    }

    @Test(arguments: [false, true])
    func `process and screen observations request an exact window before selection`(screen: Bool) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshotID = try await fixture.storage.createSnapshot()
        let snapshot = await fixture.context.uiSnapshots.createSnapshot(id: snapshotID)
        if screen {
            await snapshot.setScreenshot(
                path: "/tmp/selection-screen.png",
                metadata: CaptureMetadata(size: CGSize(width: 1200, height: 800), mode: .screen))
        } else {
            await snapshot.setTargetMetadata(from: WindowContext(
                applicationProcessId: 333,
                applicationProcessStartIdentity: 33))
        }

        let response = try await SelectTextTool(context: fixture.context).execute(
            arguments: ToolArguments(raw: ["on": "T1", "text": "needle", "snapshot": snapshotID]))
        let fields = try #require(response.meta?.objectValue)
        let message = Self.text(response)
        #expect(response.isError)
        #expect(message.contains("Text selection requires a fresh exact-window snapshot."))
        #expect(message.contains("window_id"))
        #expect(!message.contains("no consistent process-generation receipt"))
        #expect(fields["error_code"]?.stringValue == "INVALID_INPUT")
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .invalidRequest, in: response)
        #expect(fields["retry_safe"]?.boolValue == true)
        #expect(fields["mutation_dispatched"]?.boolValue == false)
        #expect(fields["requires_fresh_observation"]?.boolValue == false)
        #expect(fixture.automation.mutationCalls == 0 && fixture.automation.focusCalls == 0)
        #expect(fixture.windows.focusRequests.isEmpty)
        #expect(fixture.snapshots.beginCalls.isEmpty)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test(arguments: [false, true])
    func `malformed or invalidated selection receipts still report snapshot stale`(invalidated: Bool) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshotID = try await fixture.storage.createSnapshot()
        let snapshot = await fixture.context.uiSnapshots.createSnapshot(id: snapshotID)
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationProcessId: 333,
            applicationProcessStartIdentity: invalidated ? 33 : nil))
        if invalidated {
            await snapshot.setTargetMetadata(from: WindowContext(
                applicationProcessId: 333,
                applicationProcessStartIdentity: 34))
        }

        let response = try await SelectTextTool(context: fixture.context).execute(
            arguments: ToolArguments(raw: ["on": "T1", "text": "needle", "snapshot": snapshotID]))
        let fields = try #require(response.meta?.objectValue)
        #expect(response.isError)
        #expect(Self.text(response).contains("no consistent process-generation receipt"))
        #expect(fields["error_code"]?.stringValue == "SNAPSHOT_STALE")
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.automation.mutationCalls == 0 && fixture.automation.focusCalls == 0)
        #expect(fixture.windows.focusRequests.isEmpty)
        #expect(fixture.snapshots.beginCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func `pending or consumed selection snapshots refuse before dispatch`(consumed: Bool) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let lease = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        if consumed {
            try await fixture.storage.finishSnapshotMutation(lease, requiresFreshObservation: true)
        }
        let response = try await fixture.context.execute(
            tool: SelectTextTool(context: fixture.context),
            arguments: ToolArguments(raw: ["on": "T1", "text": "needle", "snapshot": fixture.snapshotID]))
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
        #expect(fixture.automation.selectTextCalls == 0)
        #expect(fixture.automation.focusCalls == 0)
    }

    @Test
    func `accepted selection failure consumes snapshot and cannot replay`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        fixture.automation.mutationError = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Selection accepted without readback",
            hint: "Observe again")
        let tool = SelectTextTool(context: fixture.context)
        let arguments = ToolArguments(raw: ["on": "T1", "text": "needle", "snapshot": fixture.snapshotID])
        let first = try await fixture.context.execute(tool: tool, arguments: arguments)
        #expect(first.isError)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)
        let second = try await fixture.context.execute(tool: tool, arguments: arguments)
        #expect(second.isError)
        #expect(fixture.automation.selectTextCalls == 1)
    }

    private static func text(_ response: ToolResponse) -> String {
        response.content.compactMap { content in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
    }
}
