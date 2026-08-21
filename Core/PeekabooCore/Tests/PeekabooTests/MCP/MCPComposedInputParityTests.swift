import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

@Suite(.serialized)
struct MCPComposedInputParityTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `pixel focus type maps capture coordinates and routes one exact composite request`() async throws {
        let fixture = await Self.makeFixture()
        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "500,250",
            "coordinate_space": "image_pixels",
            "snapshot": fixture.snapshotID,
            "text": "hi",
        ]))

        #expect(!response.isError)
        let request = try #require(await MainActor.run { fixture.automation.pixelFocusTypeRequests.first })
        #expect(request.point == CGPoint(x: 600, y: 300))
        #expect(request.snapshotID == fixture.snapshotID)
        #expect(request.windowIdentity == fixture.window.mutationIdentity)
        #expect(request.windowBounds == fixture.window.bounds)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["delivery_mode"] == .string("background"))
        #expect(metadata["delivery_mechanism"] == .string("composite"))
        #expect(metadata["dispatched_unit_count"] == .int(3))
        #expect(metadata["target_window_id"] == .int(fixture.window.windowID))
    }

    @Test
    func `modifier click refuses background then projects truthful foreground restoration`() async throws {
        let fixture = await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickLeaseProbe = {
                do {
                    _ = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
                    return false
                } catch {
                    return true
                }
            }
        }
        let refused = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "modifiers": ["cmd", "shift"],
        ]))
        #expect(refused.isError)
        #expect(refused.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })

        for contextual in [
            ["coords": "600,300", "snapshot": fixture.snapshotID, "foreground": true, "modifiers": ["ctrl"]],
            [
                "coords": "600,300", "snapshot": fixture.snapshotID, "foreground": true,
                "modifiers": ["cmd"], "right": true,
            ],
        ] as [[String: Any]] {
            let contextualResponse = try await ClickTool(context: fixture.context).execute(
                arguments: ToolArguments(raw: contextual))
            #expect(contextualResponse.isError)
            #expect(contextualResponse.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        }
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd", "shift"],
        ]))

        #expect(!response.isError)
        let request = try #require(await MainActor.run { fixture.automation.foregroundModifierClickRequests.first })
        #expect(request.point == CGPoint(x: 600, y: 300))
        #expect(request.modifiers == [.command, .shift])
        #expect(request.windowIdentity == fixture.window.mutationIdentity)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["cursor_restoration"] == .string("restored"))
        #expect(metadata["focus_restoration"] == .string("preserved_newer_state"))
        #expect(metadata["modifiers"] == .array([.string("command"), .string("shift")]))
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickLeaseWasHeld } == true)
    }

    @Test
    func `modifier click preserves non stale lease acquisition failures`() async throws {
        let fixture = await Self.makeFixture()
        try await fixture.snapshots.cleanSnapshot(snapshotId: fixture.snapshotID)

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected a text error response")
            return
        }
        #expect(message.contains("Snapshot not found or expired"))
        #expect(!message.contains("snapshot is stale"))
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })
    }

    @Test
    func `rejected modifier click result releases its snapshot lease`() async throws {
        let fixture = await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickRefusalReason = .targetUnavailable
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        let subsequentLease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(
            subsequentLease,
            requiresFreshObservation: false)
    }

    @Test
    func `typed receipt refusal releases modifier click snapshot lease`() async throws {
        let fixture = await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = SnapshotTargetReceiptPreDispatchError(
                .incompleteExactWindow)
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        let subsequentLease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(
            subsequentLease,
            requiresFreshObservation: false)
    }

    @Test
    func `unknown modifier click failure keeps snapshot replay blocked`() async throws {
        let fixture = await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = MCPComposedInputTestError.unknownServiceFailure
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        await #expect(throws: (any Error).self) {
            _ = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `pixel focus type rejects ambiguous authority before dispatch`() async throws {
        let fixture = await Self.makeFixture()
        let invalidArguments: [[String: Any]] = [
            ["coords": "600,300", "text": "hi"],
            ["coords": "600,300", "text": "hi", "snapshot": fixture.snapshotID, "foreground": true],
            ["coords": "600,300", "text": "hi", "snapshot": fixture.snapshotID, "app": "TextEdit"],
            ["coords": "600,300", "text": "hi", "snapshot": fixture.snapshotID, "on": "T1"],
        ]

        for arguments in invalidArguments {
            let response = try await TypeTool(context: fixture.context).execute(
                arguments: ToolArguments(raw: arguments))
            #expect(response.isError)
            #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        }
        #expect(await MainActor.run { fixture.automation.pixelFocusTypeRequests.isEmpty })
    }

    @Test
    func `composed input schemas expose closed coordinate and modifier vocabularies`() async throws {
        let fixture = await Self.makeFixture()
        let typeProperties = try #require(TypeTool(context: fixture.context).inputSchema
            .objectValue?["properties"]?.objectValue)
        let clickProperties = try #require(ClickTool(context: fixture.context).inputSchema
            .objectValue?["properties"]?.objectValue)

        #expect(typeProperties["coords"] != nil)
        #expect(typeProperties["coordinate_space"]?.objectValue?["enum"] == .array(
            CaptureCoordinateSpace.allCases.map { .string($0.rawValue) }))
        #expect(clickProperties["modifiers"]?.objectValue?["items"]?.objectValue?["enum"] == .array([
            .string("cmd"), .string("shift"), .string("option"),
        ]))
    }

    private static func makeFixture() async
        -> (
            context: MCPToolContext,
            automation: MockAutomationService,
            snapshots: InMemorySnapshotManager,
            snapshotID: String,
            window: ServiceWindowInfo)
    {
        await self.uiSnapshots.removeAllSnapshots()
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: "composed-input-\(UUID().uuidString)",
            processIdentity: .init(processIdentifier: 111, processStartIdentity: 7),
            bundleIdentifier: "com.example.composed-input",
            applicationName: "ComposedInput",
            windowID: 42,
            windowTitle: "Composed Input Window",
            bounds: CGRect(x: 100, y: 50, width: 1000, height: 500))
        let window = fixture.desktopTarget.window
        let snapshot = await self.uiSnapshots.createSnapshot(id: fixture.snapshotID)
        let snapshotID = fixture.snapshotID
        let application = fixture.desktopTarget.application
        await snapshot.setScreenshot(
            path: "/tmp/composed-input.png",
            metadata: CaptureMetadata(
                size: window.bounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: window))
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let snapshots = await MainActor.run {
            InMemorySnapshotManager(detectionResult: fixture.detectionResult)
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window),
            snapshots: snapshots,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        return (context, automation, snapshots, snapshotID, window)
    }
}

private enum MCPComposedInputTestError: Error {
    case unknownServiceFailure
}
