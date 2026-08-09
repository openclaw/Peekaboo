import CoreGraphics
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPBackgroundPolicyExecutionTests {
    @Test
    func `App tool launch defaults to background`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(applications: mockApps)
        let tool = AppTool(context: context)
        let args = ToolArguments(raw: [
            "action": "launch",
            "name": "TextEdit",
        ])

        let response = try await tool.execute(arguments: args)

        #expect(response.isError == false)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.applicationIdentifier == "TextEdit")
        #expect(request.activates == false)
    }

    @Test
    func `App tool launch foreground is explicit`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(applications: mockApps)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "Calendar",
            "foreground": true,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { mockApps.launchRequests.first?.activates } == true)
    }

    @Test
    func `App tool open sends URL to default handler in background`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(applications: mockApps)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "open",
            "openTargets": ["https://example.com"],
        ]))

        #expect(response.isError == false)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.applicationIdentifier == nil)
        #expect(request.applicationBundleIdentifier == nil)
        #expect(request.openURLs.map(\.absoluteString) == ["https://example.com"])
        #expect(request.activates == false)
    }

    @Test
    func `App tool open resolves files and preserves strict bundle handler`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(applications: mockApps)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "open",
            "bundleId": "com.apple.TextEdit",
            "openTargets": ["notes.txt", "/tmp/report.txt"],
        ]))

        #expect(response.isError == false)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.applicationIdentifier == nil)
        #expect(request.applicationBundleIdentifier == "com.apple.TextEdit")
        #expect(request.openURLs[0].isFileURL)
        #expect(request.openURLs[0].path.hasSuffix("/notes.txt"))
        #expect(request.openURLs[1].path == "/tmp/report.txt")
        #expect(request.activates == false)
    }

    @Test
    func `Click tool pins background coordinates to snapshot window`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Snapshot Window",
            bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
            index: 0)
        let windows = PointerPolicyWindowService(window: window)
        let context = await MCPToolTestHelpers.makeContext(automation: automation, windows: windows)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/exact-window-coordinate-snapshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 1000, height: 500),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: window))

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "300,200",
            "snapshot": snapshotId,
        ]))

        #expect(!response.isError)
        let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 111)
        #expect(call.targetWindowID == 42)
    }
}
