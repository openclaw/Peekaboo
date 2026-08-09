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
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected app launch metadata")
            return
        }
        #expect(meta["process_start_identity"] == .double(1000))
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
    func `App tool exposes background new-instance launch`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(applications: mockApps)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "TextEdit",
            "newInstance": true,
            "waitForWindow": true,
        ]))

        #expect(!response.isError)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.createsNewInstance)
        #expect(request.waitForWindow)
        #expect(!request.activates)
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
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 111,
                ownerProcessStartIdentity: 1))
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

        let tool = ClickTool(context: context)
        let arguments = ToolArguments(raw: [
            "coords": "300,200",
            "snapshot": snapshotId,
        ])
        let response = try await tool.execute(arguments: arguments)

        #expect(!response.isError)
        let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 111)
        #expect(call.targetWindowID == 42)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected click metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(true))
    }

    @Test
    func `Click tool refuses empty or missing background coordinate references before dispatch`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let retainedSnapshot = await UISnapshotManager.shared.createSnapshot()
        let retainedSnapshotID = await retainedSnapshot.id
        let requests: [[String: Any]] = [
            ["coords": "100,200", "pid": 111, "snapshot": "", "coordinate_reference": ""],
            ["coords": "100,200", "pid": 111],
        ]

        for raw in requests {
            let response = try await context.execute(
                tool: ClickTool(context: context),
                arguments: ToolArguments(raw: raw))
            #expect(response.isError)
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected refusal metadata")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }

        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil)?.id == retainedSnapshotID)
    }

    @Test
    func `Click tool rejects same ID replacement generation before automation`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let capturedIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 1)
        let replacementIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 2)
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let capturedWindow = ServiceWindowInfo(
            windowID: 42,
            title: "Captured",
            bounds: bounds,
            index: 0,
            mutationIdentity: capturedIdentity)
        let replacementWindow = ServiceWindowInfo(
            windowID: 42,
            title: "Replacement",
            bounds: bounds,
            index: 0,
            mutationIdentity: replacementIdentity)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: replacementWindow))
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/replaced-coordinate-window.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: capturedWindow))

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "300,200",
                "snapshot": snapshotID,
            ]))

        #expect(response.isError)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected refusal metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    func `Click tool never mints a missing snapshot window receipt at dispatch`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Legacy Snapshot Window",
            bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
            index: 0)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window))
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/missing-window-receipt.png",
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

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }
}
