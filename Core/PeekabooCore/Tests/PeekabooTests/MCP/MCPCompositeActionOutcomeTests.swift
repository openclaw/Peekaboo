import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct MCPCompositeActionOutcomeTests {
    @Test
    @MainActor
    func `press preserves emitted units for a canonical dispatched failure`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["emitted_units"] == .int(2))
    }

    @Test
    @MainActor
    func `successful dispatched press invalidates the session implicit snapshot`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground))
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: MCPToolSnapshotOwner())
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `legacy successful press invalidates the session implicit snapshot`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: MCPToolSnapshotOwner())
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `confirmed no change press preserves the session implicit snapshot`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: MCPToolSnapshotOwner())
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    @MainActor
    func `confirmed no change prefix does not fabricate legacy emitted units`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.append(.confirmedNoChange(), for: .hotkey)
        automation.uiAutomationOutcomeScript.append(.refused(reason: .permissionDenied), for: .hotkey)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("refused"))
        #expect(response.meta?.objectValue?["emitted_units"] == nil)
    }

    @Test
    @MainActor
    func `canonical prefix count drives legacy emitted units`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.append(
            .confirmedChange(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            for: .hotkey)
        automation.uiAutomationOutcomeScript.append(.refused(reason: .permissionDenied), for: .hotkey)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("indeterminate"))
        #expect(response.meta?.objectValue?["emitted_units"] == .int(2))
    }

    @Test
    @MainActor
    func `press failure message distinguishes completed presses from setup focus`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .refused(reason: .permissionDenied)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: MCPFocusResultWindowService())

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "app": "Example",
            "foreground": true,
        ]))

        #expect(response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected text response")
            return
        }
        #expect(text.contains("0 completed press(es)"))
        #expect(!text.contains("completed action unit"))
        #expect(response.meta?.objectValue?["dispatched_unit_count"] == .int(1))
    }
}
