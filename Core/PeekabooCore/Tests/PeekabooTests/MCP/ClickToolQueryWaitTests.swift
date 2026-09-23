import CoreGraphics
import Foundation
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct ClickToolQueryWaitTests {
    @Test
    func `missing snapshot-local id does not wait`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B9",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(response.isError == true)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `zero wait reports the current snapshot once`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        await snapshot.setUIElements([
            UIElement(
                id: "B1",
                elementId: "B1",
                role: "button",
                title: "Stay",
                label: "Stay",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "button",
                identifier: nil,
                frame: CGRect(x: 0, y: 0, width: 40, height: 20),
                isActionable: true),
        ])
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 0,
        ]))
        #expect(response.isError == true)
        let text = response.content.compactMap { item -> String? in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined()
        #expect(text.contains("LateControl"))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    @Test
    func `negative wait is rejected`() async throws {
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: MockAutomationService(accessibilityGranted: true))
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "wait_for": -1,
        ]))
        #expect(response.isError == true)
    }

    @Test
    func `query wait requires an exact window`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let started = Date()
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl",
            "snapshot": snapshotID,
            "wait_for": 5000,
        ]))
        #expect(Date().timeIntervalSince(started) < 1)
        let text = response.content.compactMap { item -> String? in
            guard case let .text(text, _, _) = item else { return nil }
            return text
        }.joined()
        #expect(text.contains("exact window"))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }
}
