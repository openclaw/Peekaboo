import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
@MainActor
struct ClickToolPinnedWaitTests {
    @Test
    func `query waits for fresh pinned AX evidence and clicks its new snapshot element`() async throws {
        let automation = QueryWaitAutomation()
        let pixels = QueryWaitPixelCapture()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: QueryWaitWindows(),
            snapshots: InMemorySnapshotManager(),
            desktopObservation: pixels)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshotID, "wait_for": 1000,
        ]))
        #expect(pixels.calls == 0)
        #expect(automation.contexts.count == 2)
        for observed in automation.contexts {
            #expect(observed.windowMutationIdentity == Self.identity)
            #expect(observed.applicationProcessStartIdentity == 1001)
            #expect(observed.requiresFreshAccessibilityTree == true)
            #expect(observed.shouldFocusWebContent == false)
            #expect(observed.allowApplicationScopedAccessibilityFallback == false)
        }
        let click = try #require(automation.targetedClickCalls.first)
        #expect(automation.targetedClickCalls.count == 1)
        if case let .elementId(id) = click.target {
            #expect(id == "late-id")
        } else {
            Issue.record("Expected the refreshed snapshot's element ID")
        }
        #expect(click.snapshotId != snapshotID)
        #expect(click.expectedProcessIdentity?.processStartIdentity == 1001)
        #expect(!response.isError)
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test
    func `changed AX receipt cannot dispatch a query click`() async throws {
        let automation = QueryWaitAutomation()
        automation.replaceGeneration = true
        let pixels = QueryWaitPixelCapture()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: QueryWaitWindows(),
            snapshots: InMemorySnapshotManager(),
            desktopObservation: pixels)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshotID, "wait_for": 1000,
        ]))
        #expect(response.isError)
        #expect(pixels.calls == 0)
        #expect(automation.contexts.count == 1)
        #expect(automation.targetedClickCalls.isEmpty)
    }

    @Test
    func `a match returned after the wait deadline does not dispatch`() async throws {
        let automation = QueryWaitAutomation()
        automation.delay = .milliseconds(800)
        automation.appearsAfter = 1
        let snapshots = InMemorySnapshotManager()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: snapshots)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshot.id, "wait_for": 500,
        ]))
        #expect(response.isError)
        #expect(automation.contexts.count == 1)
        #expect(automation.targetedClickCalls.isEmpty)
        let remaining = try await snapshots.listSnapshots()
        #expect(remaining.isEmpty)
    }

    @Test
    func `inspection timeouts retain their error code and stop polling`() async throws {
        let automation = QueryWaitAutomation()
        automation.inspectionError = PeekabooError.timeout("Synthetic AX deadline")
        let snapshots = InMemorySnapshotManager()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: snapshots)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshot.id, "wait_for": 1000,
        ]))
        #expect(response.isError)
        #expect(response.meta?.objectValue?["error_code"] == .string("TIMEOUT"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(automation.contexts.count == 1)
        #expect(automation.targetedClickCalls.isEmpty)
        let remaining = try await snapshots.listSnapshots()
        #expect(remaining.isEmpty)
    }

    @Test
    func `inspection cancellation escapes the click and cleans its observation`() async throws {
        let automation = QueryWaitAutomation()
        automation.inspectionError = CancellationError()
        let snapshots = InMemorySnapshotManager()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: snapshots)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let arguments = await ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshot.id, "wait_for": 1000,
        ])
        await #expect(throws: CancellationError.self) {
            try await ClickTool(context: context).execute(arguments: arguments)
        }
        #expect(automation.contexts.count == 1)
        #expect(automation.targetedClickCalls.isEmpty)
        let remaining = try await snapshots.listSnapshots()
        #expect(remaining.isEmpty)
    }

    @Test
    func `invalid wait values are refused instead of taking the default`() async throws {
        let context = await MCPToolTestHelpers.makeContext()
        let invalid: [Value] = [.string("500"), .bool(true), .null, .double(.infinity), .int(-1), .int(60001)]
        for value in invalid {
            let response = try await ClickTool(context: context).execute(arguments: ToolArguments(value: .object([
                "query": .string("LateControl"), "wait_for": value,
            ])))
            #expect(response.isError)
            #expect(response.content.contains { content in
                guard case let .text(text, _, _) = content else { return false }
                return text.contains("wait_for")
            })
        }
    }

    @Test
    func `inspection refusal preserves its permission classification`() async throws {
        let automation = QueryWaitAutomation()
        automation.inspectionError = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Synthetic AX permission denied")
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshots: InMemorySnapshotManager())
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshot.id, "wait_for": 1000,
        ]))
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("permission_denied"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(automation.targetedClickCalls.isEmpty)
    }

    @Test
    func `unsupported click cleans its matched temporary observation`() async throws {
        let automation = QueryWaitAutomation()
        automation.appearsAfter = 1
        automation.supportsStatelessClickVariants = false
        let snapshots = InMemorySnapshotManager()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: snapshots)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshotID, "wait_for": 1000, "middle": true,
        ]))
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("runtime_incompatible"))
        #expect(automation.contexts.count == 1)
        #expect(automation.targetedClickCalls.isEmpty)
        let remaining = try await snapshots.listSnapshots()
        #expect(remaining.isEmpty)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test
    func `returned modifier refusal cleans its matched temporary observation`() async throws {
        let automation = QueryWaitAutomation()
        automation.appearsAfter = 1
        automation.foregroundModifierClickRefusalReason = .permissionDenied
        let snapshots = InMemorySnapshotManager()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: snapshots)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshotID, "wait_for": 1000,
            "foreground": true, "modifiers": ["shift"],
        ]))
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("permission_denied"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(automation.foregroundModifierClickRequests.count == 1)
        let remaining = try await snapshots.listSnapshots()
        #expect(remaining.isEmpty)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test
    func `cleanup failure preserves the primary refusal and retires the temporary handle`() async throws {
        let automation = QueryWaitAutomation()
        automation.appearsAfter = 1
        automation.supportsStatelessClickVariants = false
        let snapshots = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
        snapshots.cleanSnapshotError = PeekabooError.operationError(message: "Synthetic cleanup failure")
        let context = await MCPToolTestHelpers.makeContext(automation: automation, snapshots: snapshots)
        let snapshot = await context.uiSnapshots.createSnapshot()
        await snapshot.setTargetMetadata(from: Self.windowContext)
        let snapshotID = await snapshot.id
        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "query": "LateControl", "snapshot": snapshotID, "wait_for": 1000, "middle": true,
        ]))
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("runtime_incompatible"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        let temporaryID = try #require(snapshots.cleanCalls.first)
        #expect(temporaryID != snapshotID)
        #expect(await context.uiSnapshots.getSnapshot(id: temporaryID) == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
        #expect(automation.targetedClickCalls.isEmpty)
    }

    static let bounds = CGRect(x: 10, y: 20, width: 100, height: 40)
    static let identity = WindowMutationIdentity(
        windowID: 6781,
        ownerProcessIdentifier: 42,
        ownerProcessStartIdentity: 1001,
        capturedBounds: bounds)
    static var windowContext: WindowContext {
        WindowContext(
            applicationName: "Fixture",
            applicationProcessId: 42,
            applicationProcessStartIdentity: 1001,
            windowID: 6781,
            windowBounds: self.bounds,
            windowMutationIdentity: self.identity)
    }
}

@MainActor
private final class QueryWaitAutomation: MockAutomationService {
    var contexts: [WindowContext] = []
    var replaceGeneration = false
    var appearsAfter = 2
    var inspectionError: (any Error)?
    var delay: Duration?

    init() {
        super.init(accessibilityGranted: true)
    }

    override func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        let context = try #require(windowContext)
        self.contexts.append(context)
        if let inspectionError {
            throw inspectionError
        }
        if let delay {
            try await Task.sleep(for: delay)
        }
        let appeared = self.contexts.count >= self.appearsAfter || self.replaceGeneration
        let identity = WindowMutationIdentity(
            windowID: 6781,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: self.replaceGeneration ? 1002 : 1001,
            capturedBounds: ClickToolPinnedWaitTests.bounds,
            isMinimized: false)
        return ElementDetectionResult(
            snapshotId: "fixture-unbound",
            screenshotPath: "",
            elements: DetectedElements(buttons: [DetectedElement(
                id: appeared ? "late-id" : "other-id",
                type: .button,
                label: appeared ? "LateControl" : "Other",
                bounds: ClickToolPinnedWaitTests.bounds)]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "accessibility",
                windowContext: WindowContext(
                    applicationName: "Fixture",
                    applicationProcessId: 42,
                    applicationProcessStartIdentity: identity.ownerProcessStartIdentity,
                    windowID: 6781,
                    windowBounds: ClickToolPinnedWaitTests.bounds,
                    windowMutationIdentity: identity)))
    }
}

@MainActor
private final class QueryWaitPixelCapture: DesktopObservationServiceProtocol {
    var calls = 0
    func observe(_: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.calls += 1
        throw CancellationError()
    }
}

private actor QueryWaitWindows: WindowManagementServiceProtocol {
    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        await [ServiceWindowInfo(
            windowID: 6781,
            title: "Fixture",
            bounds: ClickToolPinnedWaitTests.bounds,
            mutationIdentity: ClickToolPinnedWaitTests.identity)]
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
