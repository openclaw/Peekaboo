import CoreGraphics
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPExactWindowKeyboardToolTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `Press exact window pins focused element and never uses global delivery`() async throws {
        let fixture = await Self.makeFixture(focusedWindowID: 42)
        let response = try await PressTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "window_id": 42,
            "keys": ["cmd+l"],
        ]))

        #expect(!response.isError)
        let call = try #require(await MainActor.run { fixture.automation.exactHotkeyCalls.first })
        #expect(call.target.windowIdentity.windowID == 42)
        #expect(call.target.focusedElement.identifier == "editor")
        #expect(await MainActor.run { fixture.automation.lastHotkeyKeys } == nil)
        #expect(await MainActor.run { fixture.automation.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Press exact window refuses focused owner drift without dispatch`() async throws {
        let fixture = await Self.makeFixture(focusedWindowID: 41)
        let response = try await PressTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "window_id": 42,
            "keys": ["cmd+l"],
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("target_unavailable"))
        #expect(await MainActor.run { fixture.automation.exactHotkeyCalls.isEmpty })
        #expect(await MainActor.run { fixture.automation.lastHotkeyKeys } == nil)
    }

    @Test
    func `Press target resolution cancellation is not projected as a target refusal`() async throws {
        let fixture = await Self.makeFixture(
            focusedWindowID: 42,
            cancelWindowListing: true)
        let response = try await PressTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "window_id": 42,
            "keys": ["cmd+l"],
        ]))

        #expect(response.isError)
        #expect(response.meta == nil)
        #expect(await MainActor.run { fixture.automation.exactHotkeyCalls.isEmpty })
        #expect(await MainActor.run { fixture.automation.lastHotkeyKeys } == nil)
    }

    @Test
    func `Type app target upgrades one eligible window and refuses ambiguity`() async throws {
        let one = await Self.makeFixture(focusedWindowID: 42)
        let success = try await TypeTool(context: one.context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "hello",
        ]))

        #expect(!success.isError)
        let call = try #require(await MainActor.run { one.automation.exactTypeCalls.first })
        #expect(call.target.windowIdentity.windowID == 42)
        #expect(call.target.focusedElement.identifier == "editor")
        #expect(success.meta?.objectValue?["target_window_id"] == .int(42))

        let ambiguous = await Self.makeFixture(
            focusedWindowID: nil,
            windows: [Self.keyboardWindow(id: 41, index: 0), Self.keyboardWindow(id: 42, index: 1)])
        let refusal = try await TypeTool(context: ambiguous.context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "hello",
        ]))

        #expect(refusal.isError)
        #expect(refusal.meta?.objectValue?["refusal_reason"] == .string("target_unavailable"))
        #expect(await MainActor.run { ambiguous.automation.exactTypeCalls.isEmpty })
        #expect(await MainActor.run { ambiguous.automation.targetedTypeActionsCalls.isEmpty })
    }

    @Test
    func `Background-only exact snapshot press reaches the exact leaf`() async throws {
        let snapshot = await Self.makeSnapshot(window: Self.keyboardWindow(id: 42, index: 0))
        let snapshots = try await InMemorySnapshotManager.containing(snapshot.detectionResult)
        let fixture = await Self.makeFixture(
            focusedWindowID: 42,
            backgroundOnly: true,
            snapshots: snapshots)

        let response = try await fixture.context.execute(
            tool: PressTool(context: fixture.context),
            arguments: ToolArguments(raw: [
                "snapshot": snapshot.id,
                "keys": ["cmd+l"],
            ]))

        #expect(!response.isError)
        let call = try #require(await MainActor.run { fixture.automation.exactHotkeyCalls.first })
        #expect(call.target.windowIdentity.windowID == 42)
        #expect(await MainActor.run { fixture.automation.lastHotkeyKeys } == nil)
        await Self.uiSnapshots.removeSnapshot(id: snapshot.id)
    }

    @Test
    func `Type revalidates matching focused snapshot evidence before exact dispatch`() async throws {
        let window = Self.keyboardWindow(id: 42, index: 0)
        let snapshot = await Self.makeSnapshot(window: window)
        let focused = Self.focusInfo(windowID: 42)
        let focusedIdentity = try #require(FocusedElementIdentity(focused))
        let stored = try #require(await Self.uiSnapshots.getSnapshot(id: snapshot.id))
        await stored.setTargetMetadata(from: WindowContext(
            applicationName: "Editor",
            applicationBundleId: "com.example.editor",
            applicationProcessId: 333,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: window.bounds,
            windowMutationIdentity: window.mutationIdentity,
            focusedElement: focusedIdentity))
        let fixture = await Self.makeFixture(focusedWindowID: 42)

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": snapshot.id,
            "pid": 333,
            "window_id": 42,
            "text": "hello",
        ]))

        #expect(!response.isError)
        let call = try #require(await MainActor.run { fixture.automation.exactTypeCalls.first })
        #expect(call.target.focusedElement == focusedIdentity)
        await Self.uiSnapshots.removeSnapshot(id: snapshot.id)
    }

    @Test
    func `Type refuses stale button focus evidence when AXPress left keyboard focus elsewhere`() async throws {
        let window = Self.keyboardWindow(id: 42, index: 0)
        let snapshot = await Self.makeSnapshot(window: window)
        let staleButtonFocus = FocusedElementIdentity(
            processIdentifier: 333,
            windowID: 42,
            role: "AXButton",
            title: "Focus",
            identifier: "focus-basic-button",
            frame: CGRect(x: 20, y: 70, width: 100, height: 30))
        let stored = try #require(await Self.uiSnapshots.getSnapshot(id: snapshot.id))
        await stored.setTargetMetadata(from: WindowContext(
            applicationName: "Editor",
            applicationBundleId: "com.example.editor",
            applicationProcessId: 333,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: window.bounds,
            windowMutationIdentity: window.mutationIdentity,
            focusedElement: staleButtonFocus))
        let fixture = await Self.makeFixture(focusedWindowID: 42)

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": snapshot.id,
            "pid": 333,
            "window_id": 42,
            "text": "hello",
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("target_unavailable"))
        #expect(await MainActor.run { fixture.automation.exactTypeCalls.isEmpty })
        await Self.uiSnapshots.removeSnapshot(id: snapshot.id)
    }

    @Test
    func `Exact Type CLI parity treats dispatched-unverified characters as non-success`() async throws {
        let fixture = await Self.makeFixture(focusedWindowID: 42)
        await MainActor.run {
            fixture.automation.uiAutomationOutcomeScript.setDefaultOutcome(.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one))
        }

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "text": "hello",
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("dispatched_unverified"))
        #expect(response.meta?.objectValue?["characters_typed"] == .null)
        #expect(await MainActor.run { fixture.automation.exactTypeCalls.count } == 1)
    }

    private static func makeFixture(
        focusedWindowID: Int?,
        windows: [ServiceWindowInfo] = [Self.keyboardWindow(id: 42, index: 0)],
        backgroundOnly: Bool = false,
        cancelWindowListing: Bool = false,
        snapshots: (any SnapshotManagerProtocol)? = nil) async
        -> (context: MCPToolContext, automation: ExactKeyboardAutomationService)
    {
        let automation = await MainActor.run {
            let service = ExactKeyboardAutomationService(accessibilityGranted: true)
            service.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedChange(delivery: .init(
                mechanism: .windowTargetedEvents,
                mode: .background)))
            if let focusedWindowID {
                service.focusedElementsByPID[333] = Self.focusInfo(windowID: focusedWindowID)
            }
            return service
        }
        let applications = await MainActor.run {
            MockApplicationService(applications: [AutomationTestFixtures.application(
                processIdentifier: 333,
                processStartIdentity: 33,
                bundleIdentifier: "com.example.editor",
                name: "Editor")])
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications,
            windows: ExactKeyboardWindowService(
                windows: windows,
                cancelWindowListing: cancelWindowListing),
            snapshots: snapshots,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: backgroundOnly ? .backgroundOnly : .unrestricted)
        return (context, automation)
    }

    private static func keyboardWindow(id: Int, index: Int) -> ServiceWindowInfo {
        let bounds = CGRect(x: CGFloat(index * 500), y: 0, width: 480, height: 360)
        return ServiceWindowInfo(
            windowID: id,
            title: "Document \(index + 1)",
            bounds: bounds,
            index: index,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: 333,
                ownerProcessStartIdentity: 33,
                capturedBounds: bounds))
    }

    private static func focusInfo(windowID: Int) -> UIFocusInfo {
        UIFocusInfo(
            role: "AXTextField",
            title: "Editor",
            value: nil,
            frame: CGRect(x: 20, y: 20, width: 100, height: 30),
            applicationName: "Editor",
            bundleIdentifier: "com.example.editor",
            processId: 333,
            windowID: windowID,
            identifier: "editor")
    }

    private static func makeSnapshot(window: ServiceWindowInfo) async
        -> (id: String, detectionResult: ElementDetectionResult)
    {
        await self.uiSnapshots.removeAllSnapshots()
        let snapshot = await self.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/exact-keyboard.png",
            metadata: CaptureMetadata(
                size: window.bounds.size,
                mode: .window,
                applicationInfo: AutomationTestFixtures.application(
                    processIdentifier: 333,
                    processStartIdentity: 33,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor"),
                windowInfo: window))
        let windowContext = WindowContext(
            applicationName: "Editor",
            applicationBundleId: "com.example.editor",
            applicationProcessId: 333,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: window.bounds,
            windowMutationIdentity: window.mutationIdentity)
        return (
            snapshotID,
            ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/exact-keyboard.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 0,
                    method: "test",
                    windowContext: windowContext)))
    }
}

@MainActor
private final class ExactKeyboardAutomationService: MockAutomationService,
    ExactWindowTargetedKeyboardServiceProtocol,
    ScriptedUIAutomationActionOutcomeProviding,
    TargetedFocusedElementServiceProtocol
{
    struct TypeCall {
        let target: ExactWindowKeyboardTarget
    }

    struct HotkeyCall {
        let keys: String
        let target: ExactWindowKeyboardTarget
    }

    let supportsExactWindowTargetedKeyboard = true
    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()
    var focusedElementsByPID: [pid_t: UIFocusInfo] = [:]
    private(set) var exactTypeCalls: [TypeCall] = []
    private(set) var exactHotkeyCalls: [HotkeyCall] = []

    func getFocusedElement(targetProcessIdentifier: pid_t) async -> UIFocusInfo? {
        self.focusedElementsByPID[targetProcessIdentifier]
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        target: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        self.exactTypeCalls.append(TypeCall(target: target))
        let characterCount = actions.reduce(into: 0) { count, action in
            if case let .text(text) = action {
                count += text.count
            }
        }
        return TypeResult(totalCharacters: characterCount, keyPresses: 0)
    }

    func hotkey(
        keys: String,
        holdDuration _: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        self.exactHotkeyCalls.append(HotkeyCall(keys: keys, target: target))
    }
}

private actor ExactKeyboardWindowService: WindowManagementServiceProtocol, WindowMutationInventoryProviding {
    let windows: [ServiceWindowInfo]
    let cancelWindowListing: Bool

    init(windows: [ServiceWindowInfo], cancelWindowListing: Bool = false) {
        self.windows = windows
        self.cancelWindowListing = cancelWindowListing
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        if self.cancelWindowListing {
            throw CancellationError()
        }
        return switch target {
        case let .windowId(windowID): self.windows.filter { $0.windowID == windowID }
        case let .title(title), let .applicationAndTitle(_, title):
            self.windows.filter { $0.title.localizedCaseInsensitiveContains(title) }
        case let .index(_, index): self.windows.filter { $0.index == index }
        case .application, .frontmost: self.windows
        }
    }

    func windowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        try await .complete(self.listWindows(target: target))
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.windows.first
    }
}
