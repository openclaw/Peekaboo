import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct ClickToolWaitForTests {
    @Test
    func `wait_for clicks the element once it is in the selected snapshot`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await Self.installTarget(on: snapshot, processIdentifier: 111, processStartIdentity: 11)
        await snapshot.setUIElements([])

        let tool = ClickTool(context: context)
        let click = Task {
            try await tool.execute(arguments: ToolArguments(raw: [
                "on": "B1",
                "snapshot": snapshotId,
                "wait_for": 400,
            ]))
        }
        try await Task.sleep(for: .milliseconds(80))
        await snapshot.setUIElements([Self.button])
        let response = try await click.value

        #expect(response.isError == false)
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.count == 1)
        #expect(calls.first?.snapshotId == snapshotId)
        #expect(calls.first?.targetProcessIdentifier == 111)
        if case let .elementId(id) = calls.first?.target {
            #expect(id == "B1")
        } else {
            Issue.record("Click dispatched something other than the selected snapshot element")
        }
        let waits = await MainActor.run { automation.waitForElementCallCount }
        #expect(waits == 0)
    }

    @Test
    func `wait_for zero inspects the selected snapshot once`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await Self.installTarget(on: snapshot, processIdentifier: 111, processStartIdentity: 11)
        await snapshot.setUIElements([])

        let started = ContinuousClock.now
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "wait_for": 0,
        ]))
        let elapsed = started.duration(to: .now)

        #expect(response.isError == true)
        #expect(elapsed < .milliseconds(200))
        guard case let .text(message, _, _) = response.content.first else {
            Issue.record("Expected a text error")
            return
        }
        #expect(message.contains("not found after 0ms"))
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.isEmpty)
    }

    @Test
    func `negative wait_for is rejected`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "wait_for": -1,
        ]))
        #expect(response.isError == true)
        guard case let .text(message, _, _) = response.content.first else {
            Issue.record("Expected a text error")
            return
        }
        #expect(message.contains("non-negative"))
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.isEmpty)
    }

    @Test
    func `a later snapshot of a different process is not clicked`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let selected = await UISnapshotManager.shared.createSnapshot()
        await Self.installTarget(on: selected, processIdentifier: 111, processStartIdentity: 11)
        await selected.setUIElements([])

        let tool = ClickTool(context: context)
        let click = Task {
            try await tool.execute(arguments: ToolArguments(raw: [
                "on": "B1",
                "wait_for": 400,
            ]))
        }
        try await Task.sleep(for: .milliseconds(80))
        let other = await UISnapshotManager.shared.createSnapshot()
        await Self.installTarget(on: other, processIdentifier: 222, processStartIdentity: 22)
        await other.setUIElements([Self.button])
        let response = try await click.value

        #expect(response.isError == true)
        guard case let .text(message, _, _) = response.content.first else {
            Issue.record("Expected a text error")
            return
        }
        #expect(message.contains("selected click target changed"))
        let calls = await MainActor.run { automation.targetedClickCalls }
        #expect(calls.isEmpty)
    }

    private static let button = UIElement(
        id: "B1",
        elementId: "B1",
        role: "button",
        title: "OK",
        label: "OK",
        value: nil,
        description: nil,
        help: nil,
        roleDescription: "button",
        identifier: nil,
        frame: CGRect(x: 10, y: 20, width: 80, height: 30),
        isActionable: true)

    private static func installTarget(
        on snapshot: UISnapshot,
        processIdentifier: Int32,
        processStartIdentity: UInt64) async
    {
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
    }
}
