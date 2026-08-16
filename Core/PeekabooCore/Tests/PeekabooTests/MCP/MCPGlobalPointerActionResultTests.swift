import CoreGraphics
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct MCPGlobalPointerActionResultTests {
    @Test
    func `drag and move publish canonical global pointer results`() async throws {
        let automation = PointerOutcomeAutomationService(outcome: Self.pointerOutcome)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)

        let drag = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "10,20",
            "to_coords": "30,40",
            "foreground": true,
        ]))
        let move = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": "50,60",
            "foreground": true,
        ]))

        for response in [drag, move] {
            #expect(!response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(Self.pointerOutcome, in: response)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["target_identity"] == nil)
            #expect(meta["target_receipt"] == nil)
        }
        #expect(automation.dragCallCount == 1)
        #expect(automation.moveCallCount == 1)
    }

    @Test
    func `legacy pointer provider receives conservative canonical success metadata`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)

        let response = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": "50,60",
            "foreground": true,
        ]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(Self.pointerOutcome, in: response)
        #expect(await MainActor.run { automation.lastMoveTarget } == CGPoint(x: 50, y: 60))
    }

    @Test
    func `non success drag result becomes a canonical tool error`() async throws {
        let partial = DesktopActionOutcome.partial(
            delivery: Self.pointerDelivery,
            unitCount: .one)
        let automation = PointerOutcomeAutomationService(outcome: partial)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)

        let response = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "10,20",
            "to_coords": "30,40",
            "foreground": true,
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(partial, in: response)
        #expect(automation.dragCallCount == 1)
    }

    @Test
    func `raw drag failure is retry unsafe and is never replayed`() async throws {
        let automation = PointerOutcomeAutomationService(
            outcome: Self.pointerOutcome,
            error: CancellationError())
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)

        let response = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "10,20",
            "to_coords": "30,40",
            "foreground": true,
        ]))
        let meta = try #require(response.meta?.objectValue)

        #expect(response.isError)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.indeterminate.rawValue))
        #expect(meta["delivery_mechanism"] == .string("global_events"))
        #expect(meta["delivery_mode"] == .string("foreground"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["target_identity"] == nil)
        #expect(meta["target_receipt"] == nil)
        #expect(automation.dragCallCount == 1)
    }

    @Test
    func `exact setup focus composes with drag without claiming an exact mutation target`() async throws {
        await UISnapshotManager.shared.removeAllSnapshots()
        let windows = MCPFocusResultWindowService()
        let automation = PointerOutcomeAutomationService(outcome: Self.pointerOutcome)
        let context = await MCPToolTestHelpers.makeLegacyContext(
            automation: automation,
            windows: windows)
        let snapshot = await UISnapshotManager.shared.createSnapshot()
        let snapshotID = await snapshot.id
        let bounds = try #require(windows.identity.capturedBounds)
        let window = ServiceWindowInfo(
            windowID: windows.identity.windowID,
            title: "Editor",
            bounds: bounds,
            mutationIdentity: windows.identity)
        await snapshot.setScreenshot(
            path: "/tmp/mcp-global-pointer-result.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: windows.identity.ownerProcessIdentifier,
                    processStartIdentity: windows.identity.ownerProcessStartIdentity,
                    bundleIdentifier: "dev.peekaboo.pointer-fixture",
                    name: "Pointer Fixture"),
                windowInfo: window))
        await snapshot.setUIElements([
            Self.element(id: "B1", frame: CGRect(x: 20, y: 30, width: 50, height: 30)),
            Self.element(id: "B2", frame: CGRect(x: 120, y: 130, width: 50, height: 30)),
        ])

        let response = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from": "B1",
            "to": "B2",
            "snapshot": snapshotID,
            "foreground": true,
        ]))
        let meta = try #require(response.meta?.objectValue)

        #expect(!response.isError)
        #expect(meta["state"] == .string(DesktopActionOutcome.State.dispatchedUnverified.rawValue))
        #expect(meta["delivery_mechanism"] == .string("composite"))
        #expect(meta["delivery_mode"] == .string("foreground"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["target_identity"] == nil)
        #expect(meta["target_receipt"] == nil)
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(windows.focusCalls == 1)
        #expect(automation.dragCallCount == 1)
    }

    private static let pointerDelivery = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground)
    private static let pointerOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: pointerDelivery,
        evidence: .deliveryAccepted,
        unitCount: .one)

    private static func element(id: String, frame: CGRect) -> UIElement {
        UIElement(
            id: id,
            elementId: id,
            role: "button",
            title: id,
            label: id,
            value: nil,
            description: nil,
            help: nil,
            roleDescription: "button",
            identifier: nil,
            frame: frame,
            isActionable: true)
    }
}

@MainActor
private final class PointerOutcomeAutomationService: MockAutomationService,
UIAutomationGlobalPointerActionResultProviding {
    let pointerOutcome: DesktopActionOutcome?
    let pointerError: (any Error)?
    private(set) var dragCallCount = 0
    private(set) var moveCallCount = 0

    init(outcome: DesktopActionOutcome?, error: (any Error)? = nil) {
        self.pointerOutcome = outcome
        self.pointerError = error
        super.init(accessibilityGranted: true)
    }

    func dragWithOutcome(_ request: DragOperationRequest) async throws -> UIAutomationActionResult<Void> {
        self.dragCallCount += 1
        try await super.drag(request)
        if let pointerError {
            throw pointerError
        }
        return UIAutomationActionResult(payload: (), outcome: self.pointerOutcome)
    }

    func moveMouseWithOutcome(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws -> UIAutomationActionResult<Void>
    {
        self.moveCallCount += 1
        try await super.moveMouse(to: to, duration: duration, steps: steps, profile: profile)
        if let pointerError {
            throw pointerError
        }
        return UIAutomationActionResult(payload: (), outcome: self.pointerOutcome)
    }
}
