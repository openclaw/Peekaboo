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
    @Test(arguments: [
        (10.0, 0.0, "E"), (10.0, 10.0, "SE"), (0.0, 10.0, "S"), (-10.0, 10.0, "SW"),
        (-10.0, 0.0, "W"), (-10.0, -10.0, "NW"), (0.0, -10.0, "N"), (10.0, -10.0, "NE"),
    ])
    func `move response reports direction in screen coordinate space`(_ vector: (Double, Double, String)) async throws {
        let start = CGPoint(x: 100, y: 200)
        let automation = MockAutomationService(accessibilityGranted: true, currentMouseLocation: start)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let target = CGPoint(x: start.x + vector.0, y: start.y + vector.1)
        let response = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": "\(target.x),\(target.y)", "foreground": true,
        ]))
        #expect(!response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["direction"] == .string(vector.2))
        #expect(automation.lastMoveTarget == target)
        print("MoveTool delta=\(vector.0),\(vector.1) response.direction=\(String(describing: metadata["direction"]))")
    }

    @Test(arguments: [false, true])
    func `background drag dispatches exact window and consumes snapshot without foreground focus`(
        interrupted: Bool) async throws
    {
        let automation = ExactDragOutcomeAutomationService(accessibilityGranted: true)
        automation.interrupted = interrupted
        let snapshots = InMemorySnapshotManager()
        let windows = MCPFocusResultWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            snapshots: snapshots)
        let snapshot = try await MCPToolTestHelpers.createSnapshot(in: context)
        let bounds = try #require(windows.identity.capturedBounds)
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationProcessId: windows.identity.ownerProcessIdentifier,
            applicationProcessStartIdentity: windows.identity.ownerProcessStartIdentity,
            windowID: windows.identity.windowID,
            windowBounds: bounds,
            windowMutationIdentity: windows.identity))
        try await MCPToolTestHelpers.publishSnapshotMetadata(snapshot, in: context)
        let snapshotID = await snapshot.id
        let arguments = ToolArguments(raw: [
            "from_coords": "\(bounds.midX),\(bounds.midY)",
            "to_coords": "\(bounds.midX + 10),\(bounds.midY + 10)",
            "snapshot": snapshotID,
            "steps": 5,
        ])
        let first = try await DragTool(context: context).execute(arguments: arguments)
        let metadata = try #require(first.meta?.objectValue)
        #expect(first.isError == interrupted)
        #expect(metadata["delivery_mechanism"] == .string("window_targeted_events"))
        #expect(metadata["delivery_mode"] == .string("background"))
        #expect(metadata["dispatched_unit_count"] == .int(interrupted ? 4 : 8))
        #expect(metadata["state"] == .string(interrupted ? "indeterminate" : "dispatched_unverified"))
        #expect(metadata["evidence"] == .string(interrupted ? "completion_unknown" : "delivery_accepted"))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["target_receipt"] != nil)
        let replay = try await DragTool(context: context).execute(arguments: arguments)
        #expect(replay.isError)
        #expect(automation.exactDragCount == 1)
        #expect(windows.focusCalls == 0)
        #expect(automation.globalDragCount == 0)
    }

    @Test(arguments: ["latest", "most-recent", "most_recent", "", " "])
    func `background drag refuses nonconcrete snapshots before service invocation`(snapshot: String) async throws {
        let automation = ExactDragOutcomeAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let result = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "10,20", "to_coords": "30,40", "snapshot": snapshot,
        ]))
        #expect(result.isError)
        #expect(automation.exactDragCount == 0)
        #expect(automation.globalDragCount == 0)
    }

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

@MainActor
private final class ExactDragOutcomeAutomationService: MockAutomationService, ExactWindowDragServiceProtocol {
    let supportsExactWindowDrag = true
    var interrupted = false
    private(set) var exactDragCount = 0
    private(set) var globalDragCount = 0

    override func drag(_: DragOperationRequest) async throws {
        self.globalDragCount += 1
    }

    func dragExactWindow(
        _ request: ExactWindowDragRequest,
        boundTo _: ApplicationProcessIdentity?) async throws -> UIAutomationActionResult<Void>
    {
        try request.validate()
        self.exactDragCount += 1
        if self.interrupted {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .completionUnknown,
                unitCount: .init(4),
                message: "Interrupted after one sample and cleanup")
                .attributed(to: request.target.identity.actionTargetReceipt)
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(request.dispatchedUnitCount)),
            targetIdentity: DesktopTargetIdentity(exactWindow: request.target))
    }
}
