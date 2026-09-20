import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

struct ClickToolWaitForTests {
    @Test
    func `ClickRequest defaults wait_for to 5000 milliseconds`() throws {
        let request = try ClickRequest(arguments: ToolArguments(raw: ["on": "B1"]))
        #expect(request.waitForMilliseconds == 5000)
    }

    @Test
    func `ClickRequest reads wait_for milliseconds`() throws {
        let request = try ClickRequest(arguments: ToolArguments(raw: [
            "query": "Save",
            "wait_for": 1500,
        ]))
        #expect(request.waitForMilliseconds == 1500)
    }

    @Test
    func `ClickRequest rejects a negative wait_for`() throws {
        #expect(throws: ClickToolError.self) {
            _ = try ClickRequest(arguments: ToolArguments(raw: [
                "on": "B1",
                "wait_for": -1,
            ]))
        }
    }

    @Test
    func `Click tool waits for an element id using wait_for`() async throws {
        let (tool, automation, snapshotId) = try await Self.makeElementClickHarness()
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "wait_for": 1500,
        ]))

        #expect(response.isError == false)
        let waitCalls = await MainActor.run { automation.waitForElementCalls }
        let waitCall = try #require(waitCalls.first)
        #expect(waitCalls.count == 1)
        #expect(waitCall.timeout == 1.5)
        #expect(waitCall.snapshotId == snapshotId)
        if case let .elementId(id) = waitCall.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected waitForElement to poll .elementId")
        }
        #expect(await MainActor.run { automation.targetedClickCalls.count } == 1)
    }

    @Test
    func `Click tool defaults wait_for to 5000 milliseconds when omitted`() async throws {
        let (tool, automation, snapshotId) = try await Self.makeElementClickHarness()
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        let waitCall = try #require(await MainActor.run { automation.waitForElementCalls.first })
        #expect(waitCall.timeout == 5)
        #expect(waitCall.snapshotId == snapshotId)
    }

    @Test
    func `Click tool waits for a query using wait_for`() async throws {
        let (tool, automation, snapshotId) = try await Self.makeElementClickHarness()
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "query": "OK",
            "snapshot": snapshotId,
            "wait_for": 2500,
        ]))

        #expect(response.isError == false)
        let waitCall = try #require(await MainActor.run { automation.waitForElementCalls.first })
        #expect(waitCall.timeout == 2.5)
        #expect(waitCall.snapshotId == snapshotId)
        if case let .query(text) = waitCall.target {
            #expect(text == "OK")
        } else {
            Issue.record("Expected waitForElement to poll .query")
        }
    }

    @Test
    func `Click tool skips wait_for for coordinate clicks`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "40,50",
            "foreground": true,
            "wait_for": 1500,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { automation.waitForElementCalls.isEmpty })
        #expect(await MainActor.run { automation.clickCalls.count } == 1)
    }

    @Test
    func `Click tool refuses when wait_for expires before the element is actionable`() async throws {
        let (tool, automation, snapshotId) = try await Self.makeElementClickHarness()
        await MainActor.run {
            automation.waitForElementResult = WaitForElementResult(found: false, element: nil, waitTime: 1.5)
        }

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "wait_for": 1500,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.waitForElementCalls.count } == 1)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        guard case let .text(text, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected a wait timeout error message")
            return
        }
        #expect(text.contains("1500ms"))
        #expect(text.contains("B1"))
    }

    @Test
    func `Click tool rejects a negative wait_for before waiting or clicking`() async throws {
        let (tool, automation, snapshotId) = try await Self.makeElementClickHarness()
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "snapshot": snapshotId,
            "wait_for": -1,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.waitForElementCalls.isEmpty })
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }

    private static func makeElementClickHarness() async throws -> (ClickTool, MockAutomationService, String) {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/screenshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    processStartIdentity: 11,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp")))
        await snapshot.setUIElements([
            UIElement(
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
                isActionable: true),
        ])
        return (ClickTool(context: context), automation, snapshotId)
    }
}
