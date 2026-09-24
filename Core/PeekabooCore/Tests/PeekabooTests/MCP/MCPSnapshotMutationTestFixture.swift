import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

@MainActor
struct MCPSnapshotMutationTestFixture {
    let snapshotID: String
    let storage: InMemorySnapshotManager
    let snapshots: SnapshotMutationRecordingManager
    let automation: MCPSnapshotLeaseAutomationService
    let windows: MCPSnapshotLeaseWindowService
    let coordinator: MCPSnapshotLeaseMutationCoordinator
    let context: MCPToolContext

    static func make() async throws -> Self {
        let focused = FocusedElementIdentity(
            processIdentifier: 333,
            windowID: 42,
            role: "AXTextField",
            title: "Editor",
            identifier: "editor",
            frame: CGRect(x: 120, y: 80, width: 180, height: 30))
        let linked = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: SnapshotReference.generate().rawValue,
            processIdentity: .init(processIdentifier: 333, processStartIdentity: 33),
            bundleIdentifier: "com.example.lease-editor",
            applicationName: "Lease Editor",
            windowID: 42,
            bounds: CGRect(x: 100, y: 50, width: 500, height: 400),
            focusedElement: focused)
        let storage = try await InMemorySnapshotManager.containing(linked.detectionResult)
        let snapshots = SnapshotMutationRecordingManager(wrapping: storage)
        let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())
        let mirror = await uiSnapshots.createSnapshot(id: linked.snapshotID)
        await mirror.setScreenshot(
            path: linked.detectionResult.screenshotPath,
            metadata: CaptureMetadata(
                size: linked.desktopTarget.window.bounds.size,
                mode: .window,
                applicationInfo: linked.desktopTarget.application,
                windowInfo: linked.desktopTarget.window),
            context: linked.desktopTarget.windowContext)
        await mirror.setUIElements([AutomationTestFixtures.storedElement(
            id: "T1",
            role: focused.role,
            title: focused.title,
            label: "Editor",
            roleDescription: "text field",
            identifier: focused.identifier,
            frame: focused.frame)])
        let graph = try LinkedApplicationInventoryGraph(nodes: [
            .init(application: linked.desktopTarget.application, windows: [linked.desktopTarget.window]),
        ])
        let automation = try MCPSnapshotLeaseAutomationService(
            focused: focused,
            targetIdentity: linked.targetIdentity,
            snapshots: snapshots)
        let windows = MCPSnapshotLeaseWindowService(graph: graph, window: linked.desktopTarget.window)
        let coordinator = MCPSnapshotLeaseMutationCoordinator()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: ScriptedApplicationInventoryService(graph: graph),
            windows: windows,
            snapshots: snapshots,
            snapshotMutationCoordinator: coordinator,
            snapshotOwner: uiSnapshots.owner)
        return Self(
            snapshotID: linked.snapshotID,
            storage: storage,
            snapshots: snapshots,
            automation: automation,
            windows: windows,
            coordinator: coordinator,
            context: context)
    }
}

@MainActor
final class MCPSnapshotLeaseAutomationService: MockAutomationService,
    ExactWindowTargetedKeyboardServiceProtocol,
    ScriptedUIAutomationActionOutcomeProviding,
    TargetedFocusedElementServiceProtocol,
    ExactWindowFocusedElementServiceProtocol,
    ElementActionAutomationServiceProtocol
{
    let supportsExactWindowTargetedKeyboard = true
    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    let supportsExactWindowFocusedElementFocus = true
    let supportsSetValueResultTargetBinding = true
    let supportsProcessGenerationBoundElementMutations = true
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()
    let uiAutomationOutcomeTargetIdentity: DesktopTargetIdentity?
    private let focused: FocusedElementIdentity
    private let snapshots: SnapshotMutationRecordingManager
    private(set) var focusCalls = 0
    private(set) var typeCalls = 0
    private(set) var pixelCalls = 0
    private(set) var modifierCalls = 0
    private(set) var actionCalls = 0
    private(set) var setValueCalls = 0
    private(set) var exactHotkeyCalls = 0
    var typeError: (any Error)?
    var mutationError: (any Error)?

    var mutationCalls: Int {
        self.clickCalls.count + self.targetedClickCalls.count + self.scrollRequests.count +
            self.typeCalls + self.pixelCalls + self.modifierCalls + self.actionCalls +
            self.setValueCalls + self.exactHotkeyCalls
    }

    init(
        focused: FocusedElementIdentity,
        targetIdentity: DesktopTargetIdentity,
        snapshots: SnapshotMutationRecordingManager)
    {
        self.focused = focused
        self.uiAutomationOutcomeTargetIdentity = targetIdentity
        self.snapshots = snapshots
        super.init(accessibilityGranted: true)
        self.uiAutomationOutcomeScript.setDefaultOutcome(.confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background)))
    }

    func getFocusedElement(targetProcessIdentifier _: pid_t) async -> UIFocusInfo? {
        UIFocusInfo(
            role: self.focused.role,
            title: self.focused.title,
            value: nil,
            frame: self.focused.frame,
            applicationName: "Lease Editor",
            bundleIdentifier: "com.example.lease-editor",
            processId: Int(self.focused.processIdentifier),
            windowID: self.focused.windowID,
            identifier: self.focused.identifier)
    }

    func focusExactElementWithOutcome(
        target _: ClickTarget,
        snapshotId _: String,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<FocusedElementIdentity>
    {
        self.focusCalls += 1
        return try UIAutomationActionResult(
            payload: self.focused,
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .background)),
            targetIdentity: DesktopTargetIdentity(exactWindow: .init(
                identity: expectedWindowIdentity,
                bounds: expectedWindowBounds)))
    }

    override func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        try await super.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        try self.throwMutationErrorIfNeeded()
    }

    override func scroll(_ request: ScrollRequest) async throws {
        try await super.scroll(request)
        try self.throwMutationErrorIfNeeded()
    }

    func hotkey(keys _: String, holdDuration _: Int, target _: ExactWindowKeyboardTarget) async throws {
        self.exactHotkeyCalls += 1
        try self.throwMutationErrorIfNeeded()
    }

    func setValue(target: String, value: UIElementValue, snapshotId _: String?) async throws -> ElementActionResult {
        self.setValueCalls += 1
        try self.throwMutationErrorIfNeeded()
        return ElementActionResult(
            target: target,
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: value.displayString)
    }

    func performAction(target: String, actionName: String, snapshotId _: String?) async throws -> ElementActionResult {
        self.actionCalls += 1
        try self.throwMutationErrorIfNeeded()
        return ElementActionResult(target: target, actionName: actionName, anchorPoint: nil)
    }

    func typeActions(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        target _: ExactWindowKeyboardTarget) async throws -> TypeResult
    {
        self.typeCalls += 1
        if let typeError {
            throw typeError
        }
        try self.throwMutationErrorIfNeeded()
        return TypeResult(totalCharacters: 9, keyPresses: 9)
    }

    override func typeActionsByFocusingPixelWithOutcome(
        _ request: ExactWindowPixelFocusTypeRequest) async throws -> UIAutomationActionResult<TypeResult>
    {
        let lease = try await self.snapshots.beginSnapshotMutation(snapshotId: request.snapshotID)
        self.pixelCalls += 1
        try await self.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: true)
        return try UIAutomationActionResult(
            payload: TypeResult(totalCharacters: 9, keyPresses: 9),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .background),
                evidence: .deliveryAccepted),
            targetIdentity: DesktopTargetIdentity(exactWindow: .init(
                identity: request.windowIdentity,
                bounds: request.windowBounds)))
    }

    override func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let lease = try await self.snapshots.beginSnapshotMutation(snapshotId: request.snapshotID)
        self.modifierCalls += 1
        try await self.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: true)
        return try UIAutomationActionResult(
            payload: .init(cursorRestoration: .restored, focusRestoration: .preservedNewerState),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .deliveryAccepted),
            targetIdentity: DesktopTargetIdentity(exactWindow: .init(
                identity: request.windowIdentity,
                bounds: request.windowBounds)))
    }

    private func throwMutationErrorIfNeeded() throws {
        if let mutationError {
            throw mutationError
        }
    }
}

@MainActor
final class MCPSnapshotLeaseWindowService: ScriptedWindowInventoryService,
    WindowManagementPinnedFocusActionResultProviding
{
    private let window: ServiceWindowInfo
    private(set) var pinnedFocusCalls = 0
    var focusOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
        unitCount: .one)

    init(graph: LinkedApplicationInventoryGraph, window: ServiceWindowInfo) {
        self.window = window
        super.init(windowsByIdentifier: graph.windowsByIdentifier)
    }

    @MainActor
    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.commandFailed("Unpinned focus must not be used")
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        self.pinnedFocusCalls += 1
        guard case let .windowId(windowID) = target,
              windowID == self.window.windowID,
              let identity = self.window.mutationIdentity,
              expectedIdentity.hasSameStableReceipt(as: identity)
        else {
            throw PeekabooError.commandFailed("Unexpected exact focus target")
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.focusOutcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: .init(identity: identity, bounds: self.window.bounds)))
    }
}

@MainActor
final class MCPSnapshotLeaseMutationCoordinator: MCPToolSnapshotMutationCoordinating {
    private(set) var prepareCount = 0
    private(set) var cancelCount = 0
    private(set) var completeCount = 0

    func prepareMutation(_: MCPToolSnapshotMutationScope) async throws {
        self.prepareCount += 1
    }

    func cancelMutation(_: MCPToolSnapshotMutationScope) async -> Bool {
        self.cancelCount += 1
        return true
    }

    func completeMutation(_: MCPToolSnapshotMutationScope, succeeded _: Bool) async -> Bool {
        self.completeCount += 1
        return true
    }
}
