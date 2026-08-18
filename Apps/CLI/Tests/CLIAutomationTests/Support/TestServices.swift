import AppKit
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import UniformTypeIdentifiers
@testable import PeekabooCLI
@testable import PeekabooCore

enum TestStubError: Error {
    case unimplemented(StaticString)
}

@MainActor
func stubUnimplemented(_ function: StaticString = #function) -> Never {
    fatalError("Test stub method not implemented: \(function)")
}

// MARK: - Stub Services

@MainActor
final class StubScreenCaptureService: ScreenCaptureServiceProtocol {
    var permissionGranted: Bool
    var defaultCaptureResult: CaptureResult?
    var captureScreenHandler: ((Int?, CaptureScalePreference) async throws -> CaptureResult)?
    var captureWindowHandler: ((String, Int?, CaptureScalePreference) async throws -> CaptureResult)?
    var captureWindowByIdHandler: ((CGWindowID, CaptureScalePreference) async throws -> CaptureResult)?
    var captureFrontmostHandler: ((CaptureScalePreference) async throws -> CaptureResult)?
    var captureAreaHandler: ((CGRect, CaptureScalePreference) async throws -> CaptureResult)?
    private(set) var captureVisualizerModes: [CaptureVisualizerMode] = []

    init(permissionGranted: Bool = true) {
        self.permissionGranted = permissionGranted
    }

    func captureScreen(
        displayIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        self.captureVisualizerModes.append(visualizerMode)
        if let handler = captureScreenHandler {
            return try await handler(displayIndex, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        self.captureVisualizerModes.append(visualizerMode)
        if let handler = captureWindowHandler {
            return try await handler(appIdentifier, windowIndex, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        self.captureVisualizerModes.append(visualizerMode)
        if let handler = captureWindowByIdHandler {
            return try await handler(windowID, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        self.captureVisualizerModes.append(visualizerMode)
        if let handler = captureFrontmostHandler {
            return try await handler(scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        self.captureVisualizerModes.append(visualizerMode)
        if let handler = captureAreaHandler {
            return try await handler(rect, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func hasScreenRecordingPermission() async -> Bool {
        self.permissionGranted
    }

    private func makeDefaultCaptureResult(function: StaticString) async throws -> CaptureResult {
        if let result = defaultCaptureResult {
            return result
        }

        // Provide a harmless stub image so unexpected capture calls don't crash the test run.
        return CaptureResult(
            imageData: Data(),
            metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen)
        )
    }
}

@MainActor
class StubAutomationService: TargetedHotkeyServiceProtocol, TargetedTypeServiceProtocol,
ExactWindowTargetedClickServiceProtocol, ElementActionAutomationServiceProtocol {
    struct ClickCall {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotId: String?
    }

    struct TypeTextCall {
        let text: String
        let target: String?
        let clearExisting: Bool
        let typingDelay: Int
        let snapshotId: String?
    }

    struct TypeActionsCall {
        let actions: [TypeAction]
        let cadence: TypingCadence
        let snapshotId: String?
    }

    struct ScrollCall {
        let request: ScrollRequest
    }

    struct SwipeCall {
        let from: CGPoint
        let to: CGPoint
        let duration: Int
        let steps: Int
        let profile: MouseMovementProfile
    }

    struct DragCall {
        let from: CGPoint
        let to: CGPoint
        let duration: Int
        let steps: Int
        let modifiers: String?
        let profile: MouseMovementProfile
    }

    struct MoveMouseCall {
        let destination: CGPoint
        let duration: Int
        let steps: Int
        let profile: MouseMovementProfile
    }

    struct HotkeyCall {
        let keys: String
        let holdDuration: Int
    }

    struct TargetedHotkeyCall {
        let keys: String
        let holdDuration: Int
        let targetProcessIdentifier: pid_t
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct TargetedTypeActionsCall {
        let actions: [TypeAction]
        let cadence: TypingCadence
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct TargetedClickCall {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
        let targetWindowID: Int?
        let expectedProcessIdentity: ApplicationProcessIdentity?
    }

    struct WaitForElementCall {
        let target: ClickTarget
        let timeout: TimeInterval
        let snapshotId: String?
    }

    struct SetValueCall {
        let target: String
        let value: UIElementValue
        let snapshotId: String?
    }

    struct PerformActionCall {
        let target: String
        let actionName: String
        let snapshotId: String?
    }

    private enum WaitTargetKey: Hashable {
        case elementId(String)
        case query(String)
        case coordinates(x: Double, y: Double)
    }

    var clickCalls: [ClickCall] = []
    var typeTextCalls: [TypeTextCall] = []
    var typeActionsCalls: [TypeActionsCall] = []
    var scrollCalls: [ScrollCall] = []
    var scrollError: (any Error)?
    var swipeCalls: [SwipeCall] = []
    var dragCalls: [DragCall] = []
    var moveMouseCalls: [MoveMouseCall] = []
    var hotkeyCalls: [HotkeyCall] = []
    var targetedHotkeyCalls: [TargetedHotkeyCall] = []
    var targetedTypeActionsCalls: [TargetedTypeActionsCall] = []
    var targetedClickCalls: [TargetedClickCall] = []
    var waitForElementCalls: [WaitForElementCall] = []
    var setValueCalls: [SetValueCall] = []
    var performActionCalls: [PerformActionCall] = []
    var detectElementsCalls: [(imageData: Data, snapshotId: String?, windowContext: WindowContext?)] = []
    var inspectAccessibilityTreeCalls: [WindowContext?] = []
    var supportsTargetedHotkeys = true
    var supportsProcessGenerationPinnedHotkeys = true
    var targetedHotkeyUnavailableReason: String?
    var targetedHotkeyRequiresEventSynthesizingPermission = false
    var hotkeyError: (any Error)?
    var targetedHotkeyError: (any Error)?
    var currentHotkeyProcessIdentity: ((pid_t) -> ApplicationProcessIdentity?)?
    var afterPinnedHotkey: (() -> Void)?
    var supportsTargetedTypeActions = true
    var supportsProcessGenerationPinnedTypeActions = true
    var targetedTypeUnavailableReason: String?
    var targetedTypeRequiresEventSynthesizingPermission = false
    var supportsTargetedClicks = true
    var supportsProcessGenerationPinnedClicks = true
    var supportsStatelessClickVariants = true
    var targetedClickUnavailableReason: String?
    var targetedClickRequiresEventSynthesizingPermission = false
    var clickError: (any Error)?

    var nextTypeActionsResult: TypeResult?
    var typeActionsResultProvider: (([TypeAction], TypingCadence, String?) -> TypeResult)?
    var waitForElementProvider: ((ClickTarget, TimeInterval, String?) -> WaitForElementResult)?
    private var waitForElementResults: [WaitTargetKey: WaitForElementResult] = [:]
    var detectElementsHandler: ((Data, String?, WindowContext?) async throws -> ElementDetectionResult)?
    var inspectAccessibilityTreeHandler: ((WindowContext?) async throws -> ElementDetectionResult)?
    var nextDetectionResult: ElementDetectionResult?
    var stubCurrentMouseLocation: CGPoint?

    func setWaitForElementResult(_ result: WaitForElementResult, for target: ClickTarget) {
        self.waitForElementResults[self.key(for: target)] = result
    }

    func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?
    ) async throws -> ElementDetectionResult {
        self.detectElementsCalls.append((imageData, snapshotId, windowContext))

        if let handler = detectElementsHandler {
            return try await handler(imageData, snapshotId, windowContext)
        }

        if let nextDetectionResult {
            return nextDetectionResult
        }

        throw TestStubError.unimplemented(#function)
    }

    func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        self.inspectAccessibilityTreeCalls.append(windowContext)
        guard let inspectAccessibilityTreeHandler else {
            throw TestStubError.unimplemented(#function)
        }
        return try await inspectAccessibilityTreeHandler(windowContext)
    }

    func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        self.clickCalls.append(ClickCall(target: target, clickType: clickType, snapshotId: snapshotId))
        if let clickError {
            throw clickError
        }
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t
    ) async throws {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: nil,
            expectedProcessIdentity: nil
        ))
        if let clickError {
            throw clickError
        }
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t,
        targetWindowID: Int
    ) async throws {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID,
            expectedProcessIdentity: nil
        ))
        if let clickError {
            throw clickError
        }
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds _: CGRect
    ) async throws {
        self.targetedClickCalls.append(TargetedClickCall(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
            targetWindowID: expectedWindowIdentity.windowID,
            expectedProcessIdentity: ApplicationProcessIdentity(
                processIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
                processStartIdentity: expectedWindowIdentity.ownerProcessStartIdentity
            )
        ))
        if let clickError {
            throw clickError
        }
    }

    func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?
    ) async throws {
        self.typeTextCalls.append(
            TypeTextCall(
                text: text,
                target: target,
                clearExisting: clearExisting,
                typingDelay: typingDelay,
                snapshotId: snapshotId
            )
        )
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?
    ) async throws -> TypeResult {
        self.typeActionsCalls.append(
            TypeActionsCall(actions: actions, cadence: cadence, snapshotId: snapshotId)
        )

        if let provider = typeActionsResultProvider {
            return provider(actions, cadence, snapshotId)
        }

        if let nextResult = nextTypeActionsResult {
            return nextResult
        }

        let totals = actions.reduce(into: (characters: 0, keyPresses: 0)) { partial, action in
            switch action {
            case let .text(text):
                partial.characters += text.count
                partial.keyPresses += text.count
            case .key:
                partial.keyPresses += 1
            case .clear:
                partial.keyPresses += 2
            }
        }

        return TypeResult(totalCharacters: totals.characters, keyPresses: totals.keyPresses)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?,
        targetProcessIdentifier: pid_t
    ) async throws -> TypeResult {
        self.targetedTypeActionsCalls.append(
            TargetedTypeActionsCall(
                actions: actions,
                cadence: cadence,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                expectedProcessIdentity: nil
            )
        )
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func scroll(_ request: ScrollRequest) async throws {
        self.scrollCalls.append(
            ScrollCall(request: request)
        )
        if let scrollError {
            throw scrollError
        }
    }

    func setValue(
        target: String,
        value: UIElementValue,
        snapshotId: String?
    ) async throws -> ElementActionResult {
        self.setValueCalls.append(SetValueCall(target: target, value: value, snapshotId: snapshotId))
        return ElementActionResult(target: target, actionName: nil, anchorPoint: nil)
    }

    func performAction(
        target: String,
        actionName: String,
        snapshotId: String?
    ) async throws -> ElementActionResult {
        self.performActionCalls.append(PerformActionCall(
            target: target,
            actionName: actionName,
            snapshotId: snapshotId
        ))
        return ElementActionResult(target: target, actionName: actionName, anchorPoint: nil)
    }

    func hotkey(keys: String, holdDuration: Int) async throws {
        self.hotkeyCalls.append(HotkeyCall(keys: keys, holdDuration: holdDuration))
        if let hotkeyError {
            throw hotkeyError
        }
    }

    func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        self.targetedHotkeyCalls.append(TargetedHotkeyCall(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier,
            expectedProcessIdentity: nil
        ))
        if let targetedHotkeyError {
            throw targetedHotkeyError
        }
    }

    func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws {
        if let currentHotkeyProcessIdentity,
           currentHotkeyProcessIdentity(expectedProcessIdentity.processIdentifier) != expectedProcessIdentity {
            throw PeekabooError.invalidInput(
                "Background hotkey target process exited or changed process generation"
            )
        }
        self.targetedHotkeyCalls.append(TargetedHotkeyCall(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: expectedProcessIdentity.processIdentifier,
            expectedProcessIdentity: expectedProcessIdentity
        ))
        if let targetedHotkeyError {
            throw targetedHotkeyError
        }
        self.afterPinnedHotkey?()
    }

    func swipe(from: CGPoint, to: CGPoint, duration: Int, steps: Int, profile: MouseMovementProfile) async throws {
        self.swipeCalls.append(
            SwipeCall(from: from, to: to, duration: duration, steps: steps, profile: profile)
        )
    }

    var accessibilityPermissionGranted = true

    func hasAccessibilityPermission() async -> Bool {
        self.accessibilityPermissionGranted
    }

    func waitForElement(
        target: ClickTarget,
        timeout: TimeInterval,
        snapshotId: String?
    ) async throws -> WaitForElementResult {
        self.waitForElementCalls.append(
            WaitForElementCall(target: target, timeout: timeout, snapshotId: snapshotId)
        )

        if let provider = waitForElementProvider {
            return provider(target, timeout, snapshotId)
        }

        if let stored = waitForElementResults[key(for: target)] {
            return stored
        }

        return WaitForElementResult(found: false, element: nil, waitTime: 0)
    }

    func drag(_ request: DragOperationRequest) async throws {
        self.dragCalls.append(
            DragCall(
                from: request.from,
                to: request.to,
                duration: request.duration,
                steps: request.steps,
                modifiers: request.modifiers,
                profile: request.profile
            )
        )
    }

    func moveMouse(to: CGPoint, duration: Int, steps: Int, profile: MouseMovementProfile) async throws {
        self.moveMouseCalls.append(
            MoveMouseCall(destination: to, duration: duration, steps: steps, profile: profile)
        )
    }

    func currentMouseLocation() -> CGPoint? {
        self.stubCurrentMouseLocation
    }

    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(
        matching criteria: UIElementSearchCriteria,
        in appName: String?
    ) async throws -> DetectedElement {
        throw TestStubError.unimplemented(#function)
    }

    private func key(for target: ClickTarget) -> WaitTargetKey {
        switch target {
        case let .elementId(identifier):
            .elementId(identifier)
        case let .query(query):
            .query(query)
        case let .coordinates(point):
            .coordinates(x: point.x, y: point.y)
        }
    }
}

@MainActor
class StubApplicationService: ScriptedApplicationInventoryService {
    var launchResults: [String: ServiceApplicationInfo]
    var launchCalls: [String] = []
    var activateCalls: [String] = []
    var activateApplicationHandler: ((String) async throws -> Void)?
    var quitCalls: [(identifier: String, force: Bool)] = []
    var quitRequests: [ApplicationQuitRequest] = []
    var quitShouldSucceed = true
    var terminationCount = 0
    var hideCalls: [String] = []
    var unhideCalls: [String] = []
    var hideOtherCalls: [String] = []
    var showAllCallCount = 0

    init(applications: [ServiceApplicationInfo], windowsByApp: [String: [ServiceWindowInfo]] = [:]) {
        self.launchResults = [:]
        super.init(
            applications: applications,
            windowsByIdentifier: windowsByApp,
            propagatesApplicationMetadataWarnings: false,
            supportsApplicationLaunchOptions: true,
            supportsApplicationRelaunch: true,
            supportsProcessGenerationPinnedApplicationQuit: true,
            supportsProcessGenerationPinnedApplicationActivation: true
        )
    }

    override func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.launchCalls.append(identifier)
        if let result = launchResults[identifier] {
            return result
        }
        if let existing = applications
            .first(where: { $0.name == identifier || $0.bundleIdentifier == identifier }) {
            return existing
        }
        return ServiceApplicationInfo(
            processIdentifier: Int32.random(in: 1000...2000),
            bundleIdentifier: "launched.\(identifier)",
            name: identifier
        )
    }

    override func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        let identifier = request.applicationBundleIdentifier ?? request.applicationIdentifier ?? "default handler"
        return try await self.launchApplication(identifier: identifier)
    }

    override func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        try await self.launchApplication(request: request.launchRequest)
    }

    override func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        guard let application = self.applications.first else {
            throw PeekabooError.appNotFound("frontmost")
        }
        return application
    }

    override func activateApplication(identifier: String) async throws {
        self.activateCalls.append(identifier)
        try await self.activateApplicationHandler?(identifier)
    }

    override func activateApplication(request: ApplicationActivationRequest) async throws {
        if let expectedIdentity = request.expectedIdentity {
            let application = try await self.findApplication(identifier: request.identifier)
            guard application.processIdentity == expectedIdentity else {
                throw PeekabooError.commandFailed("Application process generation changed before activation")
            }
        }
        try await self.activateApplication(identifier: request.identifier)
    }

    override func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        self.quitCalls.append((identifier: identifier, force: force))
        return self.quitShouldSucceed
    }

    override func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.quitRequests.append(request)
        guard let expectedIdentity = request.expectedIdentity,
              self.applications.first(where: {
                  $0.processIdentifier == expectedIdentity.processIdentifier
              })?.processIdentity == expectedIdentity
        else {
            throw PeekabooError.commandFailed("Application process generation changed")
        }
        self.quitCalls.append((identifier: request.identifier, force: request.force))
        if self.quitShouldSucceed {
            self.terminationCount += 1
        }
        return self.quitShouldSucceed
    }

    override func hideApplication(identifier: String) async throws {
        self.hideCalls.append(identifier)
    }

    override func unhideApplication(identifier: String) async throws {
        self.unhideCalls.append(identifier)
    }

    override func hideOtherApplications(identifier: String) async throws {
        self.hideOtherCalls.append(identifier)
    }

    override func showAllApplications() async throws {
        self.showAllCallCount += 1
    }
}

final class StubSnapshotManager: SnapshotManagerProtocol, @unchecked Sendable {
    let supportsImplicitLatestSnapshotInvalidation = true
    let supportsSnapshotMutationLeases = true
    var copiesScreenshotArtifactsIntoStorage = false
    var effectiveImplicitLatestInvalidationWatermark: Date?
    private(set) var detectionResults: [String: ElementDetectionResult] = [:]
    private(set) var snapshotInfos: [String: SnapshotInfo] = [:]
    private(set) var storedElements: [String: [String: PeekabooCore.UIElement]] = [:]
    private(set) var storedAnnotatedScreenshots: [String: [String]] = [:]
    var mostRecentSnapshotId: String?
    var uiAutomationSnapshotError: PeekabooError?
    var uiAutomationSnapshotCancellation = false
    var invalidationError: (any Error)?
    var mutationFinishError: (any Error)?
    var snapshotCreationDelay: Duration?
    var preservingInvalidationDelay: Duration?
    private(set) var invalidationCutoffs: [Date] = []
    private var pendingSnapshotIDs: Set<String> = []
    private var mutationLeases: [String: SnapshotMutationLease] = [:]
    private var snapshotsRequiringFreshObservation: Set<String> = []
    private(set) var exposedPendingSnapshotDuringWrite = false
    struct ScreenshotRecord {
        let path: String
        let applicationBundleId: String?
        let applicationProcessId: Int32?
        let applicationName: String?
        let windowTitle: String?
        let windowBounds: CGRect?
    }

    private(set) var storedScreenshots: [String: [ScreenshotRecord]] = [:]

    func createSnapshot() async throws -> String {
        if let snapshotCreationDelay {
            try await Task.sleep(for: snapshotCreationDelay)
        }
        return self.createSnapshotImpl(pendingAt: nil)
    }

    func createSnapshot(pendingAt observationStartedAt: Date) async throws -> String {
        if let snapshotCreationDelay {
            try await Task.sleep(for: snapshotCreationDelay)
        }
        return self.createSnapshotImpl(pendingAt: observationStartedAt)
    }

    private func createSnapshotImpl(pendingAt observationStartedAt: Date?) -> String {
        let snapshotId = UUID().uuidString
        let now = observationStartedAt ?? Date()
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: 0,
            createdAt: now,
            lastAccessedAt: now,
            sizeInBytes: 0,
            screenshotCount: 0,
            isActive: true
        )
        if observationStartedAt != nil {
            self.pendingSnapshotIDs.insert(snapshotId)
        } else {
            self.mostRecentSnapshotId = snapshotId
        }
        return snapshotId
    }

    func storeDetectionResult(snapshotId: String, result: ElementDetectionResult) async throws {
        if self.pendingSnapshotIDs.contains(snapshotId), self.mostRecentSnapshotId == snapshotId {
            self.exposedPendingSnapshotDuringWrite = true
        }
        self.detectionResults[snapshotId] = result
        if !self.pendingSnapshotIDs.contains(snapshotId) {
            self.mostRecentSnapshotId = snapshotId
        }

        let existingInfo = self.snapshotInfos[snapshotId]
        let createdAt = existingInfo?.createdAt ?? Date()
        self.snapshotInfos[snapshotId] = SnapshotInfo(
            id: snapshotId,
            processId: existingInfo?.processId ?? 0,
            createdAt: createdAt,
            lastAccessedAt: Date(),
            sizeInBytes: existingInfo?.sizeInBytes ?? 0,
            screenshotCount: (existingInfo?.screenshotCount ?? 0) + 1,
            isActive: true
        )

        self.storedElements[snapshotId] = result.elements.all
            .reduce(into: [String: PeekabooCore.UIElement]()) { partial, element in
                partial[element.id] = PeekabooCore.UIElement(
                    id: element.id,
                    elementId: element.id,
                    role: element.attributes["role"] ?? element.type.rawValue,
                    title: element.attributes["title"],
                    label: element.label,
                    value: element.value,
                    description: element.attributes["description"],
                    help: element.attributes["help"],
                    roleDescription: element.attributes["roleDescription"],
                    identifier: element.attributes["identifier"],
                    frame: element.bounds,
                    isActionable: element.isActionable,
                    isEnabled: element.knownIsEnabled,
                    isSelected: element.isSelected,
                    isValueSettable: element.isValueSettable,
                    parentId: nil,
                    children: [],
                    keyboardShortcut: nil
                )
            }
    }

    func getDetectionResult(snapshotId: String) async throws -> ElementDetectionResult? {
        self.detectionResults[snapshotId]
    }

    func getMostRecentSnapshot() async -> String? {
        self.mostRecentSnapshotId
    }

    func getMostRecentSnapshot(applicationBundleId _: String) async -> String? {
        self.mostRecentSnapshotId
    }

    func beginSnapshotMutation(snapshotId: String) async throws -> SnapshotMutationLease {
        guard self.snapshotInfos[snapshotId] != nil else {
            throw SnapshotError.snapshotNotFound
        }
        guard self.mutationLeases[snapshotId] == nil,
              !self.snapshotsRequiringFreshObservation.contains(snapshotId)
        else {
            throw PeekabooError.snapshotStale(
                "Snapshot '\(snapshotId)' already drove a mutation whose result requires a fresh observation. " +
                    "Run 'peekaboo see' again before another mutation. " +
                    "Read-only snapshot inspection is still available."
            )
        }
        let lease = SnapshotMutationLease(snapshotId: snapshotId)
        self.mutationLeases[snapshotId] = lease
        return lease
    }

    func finishSnapshotMutation(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool
    ) async throws {
        guard self.mutationLeases[lease.snapshotId] == lease else {
            throw SnapshotError.storageError("Mutation lease changed before completion")
        }
        if let mutationFinishError {
            throw mutationFinishError
        }
        self.mutationLeases.removeValue(forKey: lease.snapshotId)
        if requiresFreshObservation {
            self.snapshotsRequiringFreshObservation.insert(lease.snapshotId)
        }
    }

    func invalidateImplicitLatestSnapshot(through cutoff: Date) async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: nil,
            preservedAt: nil
        )
    }

    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?
    ) async throws -> String? {
        try await self.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: snapshotId,
            preservedAt: snapshotId == nil ? nil : Date()
        )
    }

    func invalidateImplicitLatestSnapshot(
        through cutoff: Date,
        preserving snapshotId: String?,
        preservedAt _: Date?
    ) async throws -> String? {
        self.invalidationCutoffs.append(cutoff)
        if snapshotId != nil, let preservingInvalidationDelay {
            try await Task.sleep(for: preservingInvalidationDelay)
        }
        if let invalidationError {
            throw invalidationError
        }
        let invalidatedSnapshotID = self.mostRecentSnapshotId
        if let snapshotId, snapshotInfos[snapshotId] != nil {
            self.pendingSnapshotIDs.remove(snapshotId)
            self.mostRecentSnapshotId = snapshotId
        } else {
            self.mostRecentSnapshotId = nil
        }
        return invalidatedSnapshotID
    }

    func listSnapshots() async throws -> [SnapshotInfo] {
        self.snapshotInfos.values.filter { !self.pendingSnapshotIDs.contains($0.id) }
    }

    func cleanSnapshot(snapshotId: String) async throws {
        self.detectionResults.removeValue(forKey: snapshotId)
        self.snapshotInfos.removeValue(forKey: snapshotId)
        self.storedElements.removeValue(forKey: snapshotId)
        self.pendingSnapshotIDs.remove(snapshotId)
        self.mutationLeases.removeValue(forKey: snapshotId)
        self.snapshotsRequiringFreshObservation.remove(snapshotId)
        if self.mostRecentSnapshotId == snapshotId {
            self.mostRecentSnapshotId = nil
        }
    }

    func cleanSnapshotsOlderThan(days: Int) async throws -> Int {
        let threshold = Date().addingTimeInterval(TimeInterval(-days * 24 * 60 * 60))
        let ids: [String] = self.snapshotInfos.values
            .filter { $0.lastAccessedAt < threshold }
            .reduce(into: []) { partialResult, info in
                partialResult.append(info.id)
            }
        for id in ids {
            try await self.cleanSnapshot(snapshotId: id)
        }
        return ids.count
    }

    func cleanAllSnapshots() async throws -> Int {
        let count = self.snapshotInfos.count
        self.detectionResults.removeAll()
        self.snapshotInfos.removeAll()
        self.storedElements.removeAll()
        self.pendingSnapshotIDs.removeAll()
        self.mutationLeases.removeAll()
        self.snapshotsRequiringFreshObservation.removeAll()
        self.mostRecentSnapshotId = nil
        return count
    }

    func getSnapshotStoragePath() -> String {
        "/tmp/peekaboo-snapshots"
    }

    func storeScreenshot(_ request: SnapshotScreenshotRequest) async throws {
        if self.pendingSnapshotIDs.contains(request.snapshotId), self.mostRecentSnapshotId == request.snapshotId {
            self.exposedPendingSnapshotDuringWrite = true
        }
        let existingInfo = self.snapshotInfos[request.snapshotId]
        let createdAt = existingInfo?.createdAt ?? Date()
        let screenshotCount = (existingInfo?.screenshotCount ?? 0) + 1
        self.snapshotInfos[request.snapshotId] = SnapshotInfo(
            id: request.snapshotId,
            processId: existingInfo?.processId ?? 0,
            createdAt: createdAt,
            lastAccessedAt: Date(),
            sizeInBytes: existingInfo?.sizeInBytes ?? 0,
            screenshotCount: screenshotCount,
            isActive: existingInfo?.isActive ?? true
        )
        var records = self.storedScreenshots[request.snapshotId] ?? []
        records.append(
            ScreenshotRecord(
                path: request.screenshotPath,
                applicationBundleId: request.applicationBundleId,
                applicationProcessId: request.applicationProcessId,
                applicationName: request.applicationName,
                windowTitle: request.windowTitle,
                windowBounds: request.windowBounds
            )
        )
        self.storedScreenshots[request.snapshotId] = records
    }

    func storeAnnotatedScreenshot(snapshotId: String, annotatedScreenshotPath: String) async throws {
        var records = self.storedAnnotatedScreenshots[snapshotId] ?? []
        records.append(annotatedScreenshotPath)
        self.storedAnnotatedScreenshots[snapshotId] = records
    }

    func getElement(snapshotId: String, elementId: String) async throws -> PeekabooCore.UIElement? {
        self.storedElements[snapshotId]?[elementId]
    }

    func findElements(snapshotId: String, matching query: String) async throws -> [PeekabooCore.UIElement] {
        self.storedElements[snapshotId]?.values.filter {
            $0.label?.localizedCaseInsensitiveContains(query) == true ||
                $0.title?.localizedCaseInsensitiveContains(query) == true
        } ?? []
    }

    func getUIAutomationSnapshot(snapshotId _: String) async throws -> UIAutomationSnapshot? {
        if self.uiAutomationSnapshotCancellation {
            throw CancellationError()
        }
        if let uiAutomationSnapshotError {
            throw uiAutomationSnapshotError
        }
        return nil
    }
}

final class StubFileService: FileServiceProtocol {
    private let cleanSpecificError: FileServiceError?

    init(cleanSpecificError: FileServiceError? = nil) {
        self.cleanSpecificError = cleanSpecificError
    }

    func cleanAllSnapshots(dryRun: Bool) async throws -> SnapshotCleanResult {
        SnapshotCleanResult(snapshotsRemoved: 0, bytesFreed: 0, snapshotDetails: [], dryRun: dryRun)
    }

    func cleanOldSnapshots(hours _: Int, dryRun: Bool) async throws -> SnapshotCleanResult {
        SnapshotCleanResult(snapshotsRemoved: 0, bytesFreed: 0, snapshotDetails: [], dryRun: dryRun)
    }

    func cleanSpecificSnapshot(snapshotId _: String, dryRun: Bool) async throws -> SnapshotCleanResult {
        if let cleanSpecificError {
            throw cleanSpecificError
        }
        return SnapshotCleanResult(snapshotsRemoved: 0, bytesFreed: 0, snapshotDetails: [], dryRun: dryRun)
    }

    func getSnapshotCacheDirectory() -> URL {
        URL(fileURLWithPath: "/tmp/peekaboo-snapshots")
    }

    func calculateDirectorySize(_ directory: URL) async throws -> Int64 {
        0
    }

    func listSnapshots() async throws -> [FileSnapshotInfo] {
        []
    }
}

@MainActor
class StubDockService: DockServiceProtocol {
    var items: [DockItem]
    var autoHidden: Bool

    init(items: [DockItem] = [], autoHidden: Bool = false) {
        self.items = items
        self.autoHidden = autoHidden
    }

    func listDockItems(includeAll: Bool) async throws -> [DockItem] {
        self.items
    }

    func launchFromDock(appName: String) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func addToDock(path: String, persistent: Bool) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func removeFromDock(appName: String) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func rightClickDockItem(appName: String, menuItem: String?) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func hideDock() async throws {
        throw TestStubError.unimplemented(#function)
    }

    func showDock() async throws {
        throw TestStubError.unimplemented(#function)
    }

    func isDockAutoHidden() async -> Bool {
        self.autoHidden
    }

    func findDockItem(name: String) async throws -> DockItem {
        guard let match = items.first(where: { $0.title == name }) else {
            throw PeekabooError.elementNotFound(name)
        }
        return match
    }
}

@MainActor
final class StubScreenService: ScreenServiceProtocol {
    var screens: [ScreenInfo]

    init(screens: [ScreenInfo] = []) {
        self.screens = screens
    }

    func listScreens() -> [ScreenInfo] {
        self.screens
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screens.first
    }

    func screen(at index: Int) -> ScreenInfo? {
        guard index >= 0, index < self.screens.count else { return nil }
        return self.screens[index]
    }

    var primaryScreen: ScreenInfo? {
        self.screens.first
    }
}

@MainActor
final class StubClipboardService: ClipboardServiceProtocol {
    var current: ClipboardReadResult?
    var slots: [String: ClipboardReadResult] = [:]
    var beforeMutation: (() -> Void)?
    var afterSave: (() -> Void)?
    var afterSet: (() -> Void)?
    var getError: (any Error)?
    var setError: (any Error)?
    var setMutatesBeforeThrow = false
    var restoreError: (any Error)?
    private(set) var getCallCount = 0
    private(set) var setCallCount = 0
    private(set) var clearCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var restoreCallCount = 0

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.getCallCount += 1
        if let getError {
            throw getError
        }
        return self.current
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        self.beforeMutation?()
        self.setCallCount += 1
        guard let primary = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided")
        }
        let result = ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: request.alsoText
        )
        if let setError {
            if self.setMutatesBeforeThrow {
                self.current = result
            }
            throw setError
        }
        self.current = result
        self.afterSet?()
        return result
    }

    func clear() {
        self.beforeMutation?()
        self.clearCallCount += 1
        self.current = nil
    }

    func save(slot: String) throws {
        self.saveCallCount += 1
        guard let current else {
            throw ClipboardServiceError.empty
        }
        self.slots[slot] = current
        self.afterSave?()
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        self.beforeMutation?()
        self.restoreCallCount += 1
        if let restoreError {
            throw restoreError
        }
        guard let saved = slots[slot] else {
            throw ClipboardServiceError.slotNotFound(slot)
        }
        self.current = saved
        return saved
    }
}

@MainActor
class StubMenuService: MenuServiceProtocol {
    var menusByApp: [String: MenuStructure]
    var frontmostMenus: MenuStructure?
    var menuExtras: [MenuExtraInfo]
    var clickPathCalls: [(app: String, path: String)] = []
    var clickItemCalls: [(app: String, item: String)] = []
    var clickExtraCalls: [String] = []
    var listMenusRequests: [String] = []

    init(
        menusByApp: [String: MenuStructure],
        frontmostMenus: MenuStructure? = nil,
        menuExtras: [MenuExtraInfo] = []
    ) {
        self.menusByApp = menusByApp
        self.frontmostMenus = frontmostMenus
        self.menuExtras = menuExtras
    }

    func listMenus(for appIdentifier: String) async throws -> MenuStructure {
        self.listMenusRequests.append(appIdentifier)
        guard let structure = menusByApp[appIdentifier] else {
            throw PeekabooError.menuNotFound(appIdentifier)
        }
        return structure
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        guard let menus = frontmostMenus else {
            throw PeekabooError.menuNotFound("frontmost")
        }
        return menus
    }

    func clickMenuItem(app: String, itemPath: String) async throws {
        guard self.menusByApp[app] != nil else {
            throw PeekabooError.menuNotFound(app)
        }
        self.clickPathCalls.append((app, itemPath))
    }

    func clickMenuItemByName(app: String, itemName: String) async throws {
        guard self.menusByApp[app] != nil else {
            throw PeekabooError.menuNotFound(app)
        }
        self.clickItemCalls.append((app, itemName))
    }

    func clickMenuExtra(title: String) async throws {
        guard self.menuExtras.contains(where: { $0.title == title }) else {
            throw PeekabooError.menuNotFound(title)
        }
        self.clickExtraCalls.append(title)
    }

    func isMenuExtraMenuOpen(title: String, ownerPID _: pid_t?) async throws -> Bool {
        self.menuExtras.contains(where: { $0.title == title })
    }

    func menuExtraOpenMenuFrame(title: String, ownerPID _: pid_t?) async throws -> CGRect? {
        self.menuExtras.contains(where: { $0.title == title }) ? CGRect(x: 0, y: 0, width: 100, height: 100) : nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        self.menuExtras
    }

    func listMenuBarItems(includeRaw: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) async throws -> PeekabooCore.ClickResult {
        throw TestStubError.unimplemented(#function)
    }

    func clickMenuBarItem(at index: Int) async throws -> PeekabooCore.ClickResult {
        throw TestStubError.unimplemented(#function)
    }
}

@MainActor
final class StubDialogService: DialogServiceProtocol {
    let supportsBackgroundExactDialogInput = true
    var dialogElements: DialogElements?
    var clickButtonResult: DialogActionResult?
    var handleFileDialogResult: DialogActionResult?
    var handleFileDialogDelay: TimeInterval?
    var dismissResult: DialogActionResult?
    var enterTextResult: DialogActionResult?
    private(set) var exactInputRequests: [DialogInputExecutionRequest] = []
    private(set) var foregroundExactInputRequests: [DialogInputExecutionRequest] = []
    var exactForcedDismissRequests: [DialogForcedDismissExecutionRequest] = []
    var legacyInputFocusPolicies: [DialogForegroundFocusPolicy] = []
    private var preparedDialogRequest: DialogActionPreparationRequest?

    private(set) var recordedButtonClicks: [(button: String, window: String?)] = []
    private(set) var clickFallbackRequests: [Bool] = []
    private(set) var enterTextCallCount = 0
    private(set) var handleFileDialogCallCount = 0

    init(elements: DialogElements? = nil) {
        self.dialogElements = elements
    }

    func findActiveDialog(windowTitle: String?, appName: String?) async throws -> DialogInfo {
        guard let elements = dialogElements else {
            throw DialogError.noActiveDialog
        }
        return elements.dialogInfo
    }

    func clickButton(buttonText: String, windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        self.recordedButtonClicks.append((buttonText, windowTitle))
        if let result = clickButtonResult {
            return result
        }
        throw DialogError.buttonNotFound(buttonText)
    }

    func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool
    ) async throws -> DialogActionResult {
        self.clickFallbackRequests.append(allowGlobalFallback)
        return try await self.clickButton(buttonText: buttonText, windowTitle: windowTitle, appName: appName)
    }

    func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?
    ) async throws -> DialogActionResult {
        self.enterTextCallCount += 1
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        if let result = enterTextResult {
            return result
        }
        throw DialogError.fieldNotFound
    }

    func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.exactInputRequests.append(request)
        self.enterTextCallCount += 1
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        if let result = self.enterTextResult {
            return result
        }
        throw DialogError.fieldNotFound
    }

    func enterTextForegroundCompatible(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.foregroundExactInputRequests.append(request)
        self.enterTextCallCount += 1
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        if let result = self.enterTextResult {
            return result
        }
        throw DialogError.fieldNotFound
    }

    func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws -> PreparedDialogActionReceipt {
        self.preparedDialogRequest = request
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: request.target.windowID ?? 73,
            ownerProcessIdentifier: request.target.processIdentifier ?? 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        return try PreparedDialogActionReceipt(
            token: UUID(),
            kind: request.kind,
            target: .init(identity: identity, bounds: bounds)
        )
    }

    func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws -> DialogActionResult {
        let provided = receipt.kind == .clickButton ? self.clickButtonResult : self.dismissResult
        let action: DialogActionType = receipt.kind == .clickButton ? .clickButton : .dismiss
        if receipt.kind == .clickButton, let button = self.preparedDialogRequest?.buttonText {
            self.recordedButtonClicks.append((button, nil))
        }
        return DialogActionResult(
            success: provided?.success ?? true,
            action: provided?.action ?? action,
            details: provided?.details ?? [:],
            outcome: provided?.outcome ?? .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one
            ),
            targetReceipt: provided?.targetReceipt ?? DialogCommand.targetReceipt(receipt.target),
            targetWindowIdentity: provided?.targetWindowIdentity ?? receipt.target.identity,
            targetWindowBounds: provided?.targetWindowBounds ?? receipt.target.bounds,
            focusedElement: provided?.focusedElement,
            resolvedTarget: provided?.resolvedTarget
        )
    }

    func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool,
        appName: String?
    ) async throws -> DialogActionResult {
        self.handleFileDialogCallCount += 1
        guard let elements = dialogElements else {
            throw DialogError.noActiveDialog
        }
        guard elements.dialogInfo.isFileDialog else {
            throw DialogError.noFileDialog
        }
        if let handleFileDialogDelay {
            try await Task.sleep(nanoseconds: UInt64(handleFileDialogDelay * 1_000_000_000))
        }
        if let result = handleFileDialogResult {
            return result
        }
        throw DialogError.buttonNotFound(actionButton ?? "default")
    }

    func dismissDialog(force: Bool, windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        if let result = dismissResult {
            return result
        }
        throw DialogError.noDismissButton
    }

    func listDialogElements(windowTitle: String?, appName: String?) async throws -> DialogElements {
        guard let elements = dialogElements else {
            throw DialogError.noActiveDialog
        }
        return elements
    }

    func listDialogElements(target _: DialogTargetSelector) async throws -> DialogElements {
        guard let elements = self.dialogElements else {
            throw DialogError.noActiveDialog
        }
        return elements
    }
}

@MainActor
class StubWindowService: WindowManagementServiceProtocol, WindowMutationInventoryProviding {
    var windowsByApp: [String: [ServiceWindowInfo]]
    var inventoryCompleteness: DesktopTargetPlanning.Inventory<ServiceWindowInfo>.Completeness = .complete
    var inventoryWarnings: [String] = []
    var focusCalls: [WindowTarget] = []
    var closeFallbackRequests: [Bool] = []
    var moveCalls: [WindowTarget] = []
    var resizeCalls: [WindowTarget] = []
    var setBoundsCalls: [WindowTarget] = []

    init(windowsByApp: [String: [ServiceWindowInfo]]) {
        self.windowsByApp = windowsByApp.mapValues { windows in
            windows.map { $0.withMutationIdentityForTesting() }
        }
    }

    func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    @MainActor
    func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        self.closeFallbackRequests.append(allowForegroundFallback)
        let selection = try self.resolveWindowLocation(target: target)
        let window = self.windowsByApp[selection.app]?[selection.index]
        if window?.isMinimized == true, !allowForegroundFallback {
            throw OperationError.interactionFailed(
                action: "close window",
                reason: "A minimized window cannot be closed with a verified background-only route; " +
                    "run `peekaboo window restore` for the same exact target first, or retry with --foreground"
            )
        }
    }

    func closeWindow(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback: Bool
    ) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: allowForegroundFallback)
    }

    func maximizeWindow(target: WindowTarget) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func maximizeWindow(target: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        try await self.maximizeWindow(target: target)
    }

    @MainActor
    func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        self.moveCalls.append(target)
        try self.updateWindow(target: target) { info in
            let newBounds = CGRect(origin: position, size: info.bounds.size)
            return info.withBounds(newBounds)
        }
    }

    func moveWindow(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to position: CGPoint
    ) async throws {
        try await self.moveWindow(target: target, to: position)
    }

    @MainActor
    func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        self.resizeCalls.append(target)
        try self.updateWindow(target: target) { info in
            let newBounds = CGRect(origin: info.bounds.origin, size: size)
            return info.withBounds(newBounds)
        }
    }

    func resizeWindow(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to size: CGSize
    ) async throws {
        try await self.resizeWindow(target: target, to: size)
    }

    @MainActor
    func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        self.setBoundsCalls.append(target)
        try self.updateWindow(target: target) { info in
            info.withBounds(bounds)
        }
    }

    func setWindowBounds(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds: CGRect
    ) async throws {
        try await self.setWindowBounds(target: target, bounds: bounds)
    }

    @MainActor
    func focusWindow(target: WindowTarget) async throws {
        self.focusCalls.append(target)
    }

    @MainActor
    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        switch target {
        case let .application(app):
            return self.windowsForApplicationTarget(app)
        case let .applicationAndTitle(app, title):
            return self.windowsByApp[app]?.filter { $0.title.contains(title) } ?? []
        case .frontmost:
            return self.windowsByApp.values.first ?? []
        case let .windowId(id):
            return self.windowsByApp.values.flatMap(\.self).filter { $0.windowID == id }
        case let .title(title):
            return self.windowsByApp.values.flatMap(\.self).filter { $0.title.contains(title) }
        case let .index(app, index):
            guard let windows = windowsByApp[app], index < windows.count else { return [] }
            return [windows[index]]
        }
    }

    func windowMutationInventory(
        target: WindowTarget
    ) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo> {
        try await .init(
            items: self.listWindows(target: target),
            completeness: self.inventoryCompleteness,
            warnings: self.inventoryWarnings
        )
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    @MainActor
    func updateWindow(
        target: WindowTarget,
        transform: (ServiceWindowInfo) -> ServiceWindowInfo
    ) throws {
        let selection = try resolveWindowLocation(target: target)
        var windows = self.windowsByApp[selection.app] ?? []
        guard selection.index < windows.count else {
            throw PeekabooError.windowNotFound(criteria: selection.app)
        }
        let updated = transform(windows[selection.index])
        windows[selection.index] = updated
        self.windowsByApp[selection.app] = windows
    }

    @MainActor
    private func resolveWindowLocation(target: WindowTarget) throws -> (app: String, index: Int) {
        switch target {
        case let .application(app):
            guard let windows = windowsByApp[app], !windows.isEmpty else {
                throw PeekabooError.windowNotFound(criteria: app)
            }
            return (app, 0)
        case let .applicationAndTitle(app, title):
            guard
                let windows = windowsByApp[app],
                let index = windows.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(title) })
            else {
                throw PeekabooError.windowNotFound(criteria: "title contains \(title)")
            }
            return (app, index)
        case .frontmost:
            if let entry = windowsByApp.first(where: { !$0.value.isEmpty }) {
                return (entry.key, 0)
            }
            throw PeekabooError.windowNotFound(criteria: "frontmost")
        case let .windowId(id):
            for (app, windows) in self.windowsByApp {
                if let index = windows.firstIndex(where: { $0.windowID == id }) {
                    return (app, index)
                }
            }
            throw PeekabooError.windowNotFound(criteria: "windowId \(id)")
        case let .title(title):
            for (app, windows) in self.windowsByApp {
                if let index = windows.firstIndex(where: { $0.title.localizedCaseInsensitiveContains(title) }) {
                    return (app, index)
                }
            }
            throw PeekabooError.windowNotFound(criteria: "title contains \(title)")
        case let .index(app, index):
            guard let windows = windowsByApp[app], index < windows.count else {
                throw PeekabooError.windowNotFound(criteria: "index \(index) in \(app)")
            }
            return (app, index)
        }
    }
}

extension ServiceWindowInfo {
    fileprivate func withBounds(_ bounds: CGRect) -> ServiceWindowInfo {
        let refreshedIdentity = self.mutationIdentity.map {
            WindowMutationIdentity(
                windowID: $0.windowID,
                ownerProcessIdentifier: $0.ownerProcessIdentifier,
                ownerProcessStartIdentity: $0.ownerProcessStartIdentity,
                capturedBounds: bounds,
                isMinimized: $0.isMinimized
            )
        }
        return ServiceWindowInfo(
            windowID: windowID,
            title: title,
            bounds: bounds,
            isMinimized: isMinimized,
            isMainWindow: isMainWindow,
            windowLevel: windowLevel,
            alpha: alpha,
            index: index,
            spaceID: spaceID,
            spaceName: spaceName,
            screenIndex: screenIndex,
            screenName: screenName,
            mutationIdentity: refreshedIdentity
        )
    }

    func withMutationIdentityForTesting(
        ownerProcessIdentifier: Int32 = 42,
        ownerProcessStartIdentity: UInt64 = 7
    ) -> ServiceWindowInfo {
        guard self.mutationIdentity == nil else { return self }
        return ServiceWindowInfo(
            windowID: self.windowID,
            title: self.title,
            bounds: self.bounds,
            isMinimized: self.isMinimized,
            isMainWindow: self.isMainWindow,
            isKeyWindow: self.isKeyWindow,
            isFrontmost: self.isFrontmost,
            subrole: self.subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: self.isOffScreen,
            layer: self.layer,
            isOnScreen: self.isOnScreen,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: WindowMutationIdentity(
                windowID: self.windowID,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerProcessStartIdentity: ownerProcessStartIdentity,
                capturedBounds: self.bounds
            )
        )
    }
}

@MainActor
final class StubSpaceService: SpaceCommandSpaceService {
    let spaces: [SpaceInfo]
    let windowSpaces: [Int: [SpaceInfo]]
    var switchCalls: [CGSSpaceID] = []
    var switchOutcome: DesktopActionOutcome = .dispatchedUnverified(
        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one
    )
    var switchFailure: DesktopActionFailure?
    var moveOutcome: DesktopActionOutcome = .dispatchedUnverified(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        evidence: .deliveryAccepted,
        unitCount: .one
    )
    var moveWindowCalls: [(windowID: CGWindowID, spaceID: CGSSpaceID?)] = []
    var moveToCurrentCalls: [CGWindowID] = []

    init(spaces: [SpaceInfo], windowSpaces: [Int: [SpaceInfo]] = [:]) {
        self.spaces = spaces
        self.windowSpaces = windowSpaces
    }

    func getAllSpaces() async -> [SpaceInfo] {
        self.spaces
    }

    func getSpacesForWindow(windowID: CGWindowID) async -> [SpaceInfo] {
        self.windowSpaces[Int(windowID)] ?? []
    }

    func moveWindowToCurrentSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.moveToCurrentCalls.append(windowID)
        return try Self.moveResult(outcome: self.moveOutcome, expectedIdentity: expectedIdentity)
    }

    func moveWindowToSpaceResult(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        spaceID: CGSSpaceID
    ) async throws -> UIAutomationActionResult<Void> {
        self.moveWindowCalls.append((windowID, spaceID))
        return try Self.moveResult(outcome: self.moveOutcome, expectedIdentity: expectedIdentity)
    }

    func switchToSpaceResult(_ spaceID: CGSSpaceID) async throws -> DesktopActionResult<Void> {
        self.switchCalls.append(spaceID)
        if let switchFailure {
            throw switchFailure
        }
        return DesktopActionResult(outcome: self.switchOutcome)
    }

    private static func moveResult(
        outcome: DesktopActionOutcome,
        expectedIdentity: WindowMutationIdentity
    ) throws -> UIAutomationActionResult<Void> {
        guard let bounds = expectedIdentity.capturedBounds else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Test Space target is missing exact bounds."
            )
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity,
                    bounds: bounds
                )
            )
        )
    }
}

// MARK: - Aggregator

@MainActor
enum TestServicesFactory {
    static func makePeekabooServices(
        applications: any ApplicationServiceProtocol = StubApplicationService(applications: []),
        windows: any WindowManagementServiceProtocol = StubWindowService(windowsByApp: [:]),
        menu: any MenuServiceProtocol = StubMenuService(menusByApp: [:]),
        dialogs: any DialogServiceProtocol = StubDialogService(),
        dock: any DockServiceProtocol = StubDockService(),
        snapshots: any SnapshotManagerProtocol = StubSnapshotManager(),
        files: any FileServiceProtocol = StubFileService(),
        clipboard: any ClipboardServiceProtocol = StubClipboardService(),
        screens: [ScreenInfo] = [],
        automation: any UIAutomationServiceProtocol = StubAutomationService(),
        screenCapture: any ScreenCaptureServiceProtocol = StubScreenCaptureService()
    ) -> PeekabooServices {
        let screenService = StubScreenService(screens: screens)
        return PeekabooServices(
            logging: LoggingService(),
            screenCapture: screenCapture,
            applications: applications,
            automation: automation,
            windows: windows,
            menu: menu,
            dock: dock,
            dialogs: dialogs,
            snapshots: snapshots,
            files: files,
            clipboard: clipboard,
            permissions: PermissionsService(),
            audioInput: AudioInputService(aiService: PeekabooAIService()),
            agent: nil,
            configuration: ConfigurationManager.shared,
            screens: screenService
        )
    }

    @MainActor
    struct AutomationTestContext {
        let services: PeekabooServices
        let automation: StubAutomationService
        let snapshots: StubSnapshotManager
    }

    static func makeAutomationTestContext(
        automation: StubAutomationService = StubAutomationService(),
        snapshots: StubSnapshotManager = StubSnapshotManager(),
        applications: any ApplicationServiceProtocol = StubApplicationService(applications: []),
        windows: any WindowManagementServiceProtocol = StubWindowService(windowsByApp: [:]),
        menu: any MenuServiceProtocol = StubMenuService(menusByApp: [:]),
        dialogs: any DialogServiceProtocol = StubDialogService(),
        dock: any DockServiceProtocol = StubDockService(),
        files: any FileServiceProtocol = StubFileService(),
        clipboard: any ClipboardServiceProtocol = StubClipboardService(),
        screens: [ScreenInfo] = [],
        screenCapture: any ScreenCaptureServiceProtocol = StubScreenCaptureService()
    ) -> AutomationTestContext {
        let services = self.makePeekabooServices(
            applications: applications,
            windows: windows,
            menu: menu,
            dialogs: dialogs,
            dock: dock,
            snapshots: snapshots,
            files: files,
            clipboard: clipboard,
            screens: screens,
            automation: automation,
            screenCapture: screenCapture
        )

        return AutomationTestContext(services: services, automation: automation, snapshots: snapshots)
    }
}
