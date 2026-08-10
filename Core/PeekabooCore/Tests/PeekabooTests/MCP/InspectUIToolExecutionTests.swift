import CoreGraphics
import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct InspectUIToolExecutionTests {
    @Test
    func `Inspect UI tool returns text without screenshot`() async throws {
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-inspect",
            screenshotPath: "",
            elements: DetectedElements(
                buttons: [
                    DetectedElement(
                        id: "B1",
                        type: .button,
                        label: "Submit",
                        bounds: CGRect(x: 100, y: 200, width: 80, height: 32)),
                ],
                textFields: [
                    DetectedElement(
                        id: "T1",
                        type: .textField,
                        label: "Username",
                        value: "alice",
                        bounds: CGRect(x: 100, y: 100, width: 200, height: 24)),
                ]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 2,
                method: "AXorcist",
                windowContext: WindowContext(applicationName: "TestApp", windowTitle: "Main")))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))
        #expect(response.isError == false)

        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui output")
            return
        }

        #expect(output.contains("UI Text Inspection"))
        #expect(output.contains("Application: TestApp"))
        #expect(output.contains("Window: Main"))
        #expect(output.contains("B1"))
        #expect(output.contains("Submit"))
        #expect(output.contains("T1"))
        #expect(output.contains("Username"))
        #expect(output.contains("value: \"alice\""))
        #expect(output.contains("Use element IDs"))
        #expect(output.contains("If text looks incomplete"))
        #expect(response.content.count == 1)
    }

    @Test
    func `Inspect UI tool returns readable error when AX inspection fails`() async throws {
        let automation = await MainActor.run { InspectUITestAutomationService(accessibilityGranted: true) }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))

        #expect(response.isError == true)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui error")
            return
        }
        #expect(output.contains("Failed to inspect UI"))
        #expect(output.contains("mock inspectAccessibilityTree"))
    }

    @Test
    func `failed read-only Inspect UI removes its snapshot`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run { InspectUITestAutomationService(accessibilityGranted: true) }
        let snapshots = await MainActor.run { InMemorySnapshotManager() }
        let context = await Self.makeContext(automation: automation, snapshots: snapshots)
        let tool = InspectUITool(context: context)

        let response = try await context.execute(tool: tool, arguments: ToolArguments(raw: [:]))

        #expect(response.isError)
        #expect(try await snapshots.listSnapshots().isEmpty)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
        await UISnapshotManager.shared.removeAllSnapshots()
    }

    @Test
    func `timed out Inspect UI retains its pending snapshot tombstone`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                inspectError: POSIXError(.ETIMEDOUT))
        }
        let snapshots = await MainActor.run { InMemorySnapshotManager() }
        let context = await Self.makeContext(automation: automation, snapshots: snapshots)
        let tool = InspectUITool(context: context)

        let response = try await context.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["web_focus": true]))

        #expect(response.isError)
        #expect(try await snapshots.listSnapshots().isEmpty)
        #expect(try await snapshots.cleanAllSnapshots() == 1)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
        await UISnapshotManager.shared.removeAllSnapshots()
    }

    @Test
    func `Inspect UI tool explains empty AX results`() async throws {
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-inspect-empty"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))

        #expect(response.isError == false)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui output")
            return
        }
        #expect(output.contains("Elements found: 0"))
        #expect(output.contains("No accessible UI elements found"))
        #expect(output.contains("Try `see` for screenshot-based detection"))
    }

    @Test
    func `Inspect UI tool annotates cached AX results`() async throws {
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-inspect-cached",
            screenshotPath: "",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Refresh",
                    bounds: CGRect(x: 10, y: 10, width: 80, height: 32)),
            ]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "AXorcist cached"))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))

        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui output")
            return
        }
        #expect(output.contains("(Result from cached accessibility tree)"))
    }

    @Test
    func `Inspect UI tool reuses existing snapshot when provided`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let detectionResult = ElementDetectionResult(
            snapshotId: "ignored-detection-snapshot",
            screenshotPath: "",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Submit",
                    bounds: CGRect(x: 100, y: 200, width: 80, height: 32)),
            ]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "AXorcist"))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let snapshotId = try await context.snapshots.createSnapshot()
        let snapshot = await UISnapshotManager.shared.createSnapshot(id: snapshotId)
        await snapshot.setUIElements([
            UIElement(
                id: "old",
                elementId: "old",
                role: "button",
                title: "Old",
                label: "Old",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: nil,
                identifier: nil,
                frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                isActionable: true),
        ])
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui output")
            return
        }
        #expect(output.contains("Snapshot ID: \(snapshotId)"))
        #expect(await snapshot.getElement(byId: "B1")?.label == "Submit")
        #expect(await snapshot.getElement(byId: "old") == nil)
    }

    @Test
    func `Inspect UI tool rejects a missing explicit snapshot without inspecting frontmost UI`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "must-not-be-used"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)
        let hostSnapshotIDsBefore = try await Set(context.snapshots.listSnapshots().map(\.id))

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "snapshot": "missing-snapshot",
        ]))

        #expect(response.isError)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected missing snapshot error")
            return
        }
        #expect(output.contains("Snapshot 'missing-snapshot' was not found"))
        #expect(output.contains("Omit the `snapshot` argument and run `inspect_ui` again"))
        #expect(!output.contains("--snapshot"))
        #expect(!output.contains("inspect-ui"))
        #expect(await MainActor.run { automation.lastInspectWindowContext } == nil)
        let hostSnapshotIDsAfter = try await Set(context.snapshots.listSnapshots().map(\.id))
        #expect(hostSnapshotIDsAfter == hostSnapshotIDsBefore)
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
    }

    @Test
    func `Inspect UI tool rejects a host-only snapshot unavailable in the current process`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "must-not-be-used"))
        }
        let context = await Self.makeContext(automation: automation)
        let snapshotId = try await context.snapshots.createSnapshot()
        let tool = InspectUITool(context: context)
        let hostSnapshotIDsBefore = try await Set(context.snapshots.listSnapshots().map(\.id))

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected unavailable snapshot error")
            return
        }
        #expect(output.contains("Snapshot '\(snapshotId)' is not available in this process"))
        #expect(output.contains("Omit the `snapshot` argument and run `inspect_ui` again"))
        #expect(!output.contains("--snapshot"))
        #expect(!output.contains("inspect-ui"))
        #expect(await MainActor.run { automation.lastInspectWindowContext } == nil)
        let hostSnapshotIDsAfter = try await Set(context.snapshots.listSnapshots().map(\.id))
        #expect(hostSnapshotIDsAfter == hostSnapshotIDsBefore)
        #expect(hostSnapshotIDsAfter.contains(snapshotId))
        #expect(await UISnapshotManager.shared.getSnapshot(id: nil) == nil)
        try await context.snapshots.cleanSnapshot(snapshotId: snapshotId)
    }

    @Test
    func `Inspect UI tool stores detection result for follow-up automation`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let detectionResult = ElementDetectionResult(
            snapshotId: "automation-owned-snapshot",
            screenshotPath: "",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Submit",
                    bounds: CGRect(x: 100, y: 200, width: 80, height: 32)),
            ]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "AXorcist"))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let snapshotId = try await context.snapshots.createSnapshot()
        _ = await UISnapshotManager.shared.createSnapshot(id: snapshotId)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        let storedResult = try await context.snapshots.getDetectionResult(snapshotId: snapshotId)
        #expect(storedResult?.snapshotId == snapshotId)
        #expect(storedResult?.elements.findById("B1")?.label == "Submit")
    }

    @Test
    func `Inspect UI tool refreshes snapshot target metadata`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let detectionResult = ElementDetectionResult(
            snapshotId: "automation-owned-snapshot",
            screenshotPath: "",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Submit",
                    bounds: CGRect(x: 100, y: 200, width: 80, height: 32)),
            ]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "AXorcist",
                windowContext: WindowContext(
                    applicationName: "NewApp",
                    applicationProcessId: 222,
                    windowTitle: "New Window")))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let snapshotId = try await context.snapshots.createSnapshot()
        let snapshot = await UISnapshotManager.shared.createSnapshot(id: snapshotId)
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationName: "OldApp",
            applicationProcessId: 111,
            windowTitle: "Old Window"))
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "snapshot": snapshotId,
        ]))

        #expect(response.isError == false)
        #expect(snapshot.applicationName == "NewApp")
        #expect(snapshot.windowTitle == "New Window")
        #expect(snapshot.applicationProcessId == 222)
    }

    @Test
    func `Inspect UI tool app target passes identifier to window context`() async throws {
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-inspect-target"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "Safari",
        ]))
        #expect(response.isError == false)
        let lastContext = await MainActor.run { automation.lastWindowContext }
        #expect(lastContext?.applicationName == "Safari")
        #expect(lastContext?.shouldFocusWebContent == false)
    }

    @Test
    func `Inspect UI web focus retry is explicit`() async throws {
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-inspect-web-focus"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "Safari",
            "web_focus": true,
        ]))

        #expect(response.isError == false)
        let lastContext = await MainActor.run { automation.lastWindowContext }
        #expect(lastContext?.shouldFocusWebContent == true)
    }

    @Test
    func `Inspect UI tool app target passes window title to window context`() async throws {
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-inspect-window-title"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "Safari:Main",
        ]))
        #expect(response.isError == false)
        let lastContext = await MainActor.run { automation.lastWindowContext }
        #expect(lastContext?.applicationName == "Safari")
        #expect(lastContext?.windowTitle == "Main")
    }

    @Test
    func `Inspect UI tool pid target passes process id to window context`() async throws {
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-inspect-pid"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "PID:1234:Settings",
        ]))
        #expect(response.isError == false)
        let lastContext = await MainActor.run { automation.lastWindowContext }
        #expect(lastContext?.applicationProcessId == 1234)
        #expect(lastContext?.windowTitle == "Settings")
    }

    @Test
    func `Inspect UI exact window id is forwarded without catalog enumeration`() async throws {
        let windows = UnexpectedWindowListingService()
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-inspect-window-id"))
        }
        let context = await Self.makeContext(automation: automation, windows: windows)
        let tool = InspectUITool(context: context)

        let exact = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "Safari",
            "window_id": 42,
        ]))
        #expect(exact.isError == false)
        let exactContext = await MainActor.run { automation.lastWindowContext }
        #expect(exactContext?.applicationName == "Safari")
        #expect(exactContext?.windowID == 42)

        let mixedSelectors = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "Safari:Main",
            "window_id": 42,
        ]))
        #expect(mixedSelectors.isError)
    }

    @Test
    func `Inspect UI rejects every supplied invalid window id before AX inspection`() async throws {
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: Self.emptyDetectionResult(id: "snapshot-invalid-window-id"))
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)
        let invalidValues: [Any] = [
            "42",
            42.5,
            0,
            -1,
            Int(UInt32.max) + 1,
            true,
            NSNull(),
        ]

        for invalidValue in invalidValues {
            let response = try await tool.execute(arguments: ToolArguments(raw: [
                "app_target": "Safari",
                "window_id": invalidValue,
            ]))
            #expect(response.isError, "Expected window_id \(String(describing: invalidValue)) to fail")
        }
        let conflictingSelectors = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "Safari:Main",
            "window_id": 42,
        ]))
        #expect(conflictingSelectors.isError)
        #expect(await MainActor.run { automation.lastInspectWindowContext } == nil)
    }

    @Test
    func `Inspect UI declares window id as a bounded integer`() async {
        let automation = await MainActor.run { InspectUITestAutomationService(accessibilityGranted: true) }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)
        guard case let .object(root) = tool.inputSchema,
              case let .object(properties)? = root["properties"],
              case let .object(windowID)? = properties["window_id"]
        else {
            Issue.record("Expected window_id schema")
            return
        }

        #expect(windowID["type"] == .string("integer"))
        #expect(windowID["minimum"] == .int(1))
        #expect(windowID["maximum"] == .int(Int(UInt32.max)))
    }

    @Test
    func `Inspect UI tool rejects screenshot-only targets`() async throws {
        let automation = await MainActor.run { InspectUITestAutomationService(accessibilityGranted: true) }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "app_target": "screen:0",
        ]))

        #expect(response.isError == true)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui error")
            return
        }
        #expect(output.contains("Use `see` for screen"))
    }

    @Test
    func `Inspect UI tool limits large text output`() async throws {
        let buttons = (1...125).map { index in
            DetectedElement(
                id: "B\(index)",
                type: .button,
                label: "Button \(index)",
                bounds: CGRect(x: index, y: index, width: 80, height: 32))
        }
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-inspect-large",
            screenshotPath: "",
            elements: DetectedElements(buttons: buttons),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: buttons.count,
                method: "AXorcist",
                windowContext: WindowContext(applicationName: "LargeApp", windowTitle: "Main")))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))
        #expect(response.isError == false)
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui output")
            return
        }
        #expect(output.contains("Elements found: 125"))
        #expect(output.contains("B120"))
        #expect(!output.contains("B121"))
        #expect(output.contains("5 additional elements omitted from text output"))
    }

    @Test
    func `Inspect UI tool truncates long element fields`() async throws {
        let longLabel = String(repeating: "a", count: 300)
        let detectionResult = ElementDetectionResult(
            snapshotId: "snapshot-inspect-long",
            screenshotPath: "",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: longLabel,
                    bounds: CGRect(x: 100, y: 200, width: 80, height: 32)),
            ]),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 1, method: "AXorcist"))
        let automation = await MainActor.run {
            InspectUITestAutomationService(
                accessibilityGranted: true,
                detectionResult: detectionResult)
        }
        let context = await Self.makeContext(automation: automation)
        let tool = InspectUITool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [:]))
        guard case let .text(text: output, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected text response for inspect_ui output")
            return
        }
        #expect(!output.contains(longLabel))
        #expect(output.contains("..."))
    }

    @MainActor
    private static func makeContext(automation: any UIAutomationServiceProtocol) -> MCPToolContext {
        self.makeContext(automation: automation, snapshots: nil, windows: nil)
    }

    @MainActor
    private static func makeContext(
        automation: any UIAutomationServiceProtocol,
        snapshots: (any SnapshotManagerProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil) -> MCPToolContext
    {
        let services = PeekabooServices()
        return MCPToolContext(
            automation: automation,
            menu: services.menu,
            windows: windows ?? services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: DesktopObservationService(
                screenCapture: services.screenCapture,
                automation: automation,
                applications: services.applications,
                screens: services.screens),
            snapshots: snapshots ?? services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser)
    }

    private static func emptyDetectionResult(id: String) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: id,
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0.01, elementCount: 0, method: "AXorcist"))
    }
}

private final class UnexpectedWindowListingService: WindowManagementServiceProtocol, @unchecked Sendable {
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        throw PeekabooError.operationError(message: "Exact window inspection must not enumerate the window catalog")
    }

    func closeWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        fatalError("unused")
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        fatalError("unused")
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        fatalError("unused")
    }

    func focusWindow(target _: WindowTarget) async throws {
        fatalError("unused")
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        fatalError("unused")
    }
}
