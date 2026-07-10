import AppKit
import CoreGraphics
import Foundation
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

    init(permissionGranted: Bool = true) {
        self.permissionGranted = permissionGranted
    }

    func captureScreen(
        displayIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        if let handler = captureScreenHandler {
            return try await handler(displayIndex, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        if let handler = captureWindowHandler {
            return try await handler(appIdentifier, windowIndex, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        if let handler = captureWindowByIdHandler {
            return try await handler(windowID, scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
        if let handler = captureFrontmostHandler {
            return try await handler(scale)
        }
        return try await self.makeDefaultCaptureResult(function: #function)
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference
    ) async throws -> CaptureResult {
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
final class StubAutomationService: TargetedHotkeyServiceProtocol, TargetedTypeServiceProtocol,
ExactWindowTargetedClickServiceProtocol {
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
    }

    struct TargetedTypeActionsCall {
        let actions: [TypeAction]
        let cadence: TypingCadence
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
    }

    struct TargetedClickCall {
        let target: ClickTarget
        let clickType: ClickType
        let snapshotId: String?
        let targetProcessIdentifier: pid_t
        let targetWindowID: Int?
    }

    struct WaitForElementCall {
        let target: ClickTarget
        let timeout: TimeInterval
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
    var swipeCalls: [SwipeCall] = []
    var dragCalls: [DragCall] = []
    var moveMouseCalls: [MoveMouseCall] = []
    var hotkeyCalls: [HotkeyCall] = []
    var targetedHotkeyCalls: [TargetedHotkeyCall] = []
    var targetedTypeActionsCalls: [TargetedTypeActionsCall] = []
    var targetedClickCalls: [TargetedClickCall] = []
    var waitForElementCalls: [WaitForElementCall] = []
    var detectElementsCalls: [(imageData: Data, snapshotId: String?, windowContext: WindowContext?)] = []
    var supportsTargetedHotkeys = true
    var targetedHotkeyUnavailableReason: String?
    var targetedHotkeyRequiresEventSynthesizingPermission = false
    var supportsTargetedTypeActions = true
    var targetedTypeUnavailableReason: String?
    var targetedTypeRequiresEventSynthesizingPermission = false
    var supportsTargetedClicks = true
    var targetedClickUnavailableReason: String?
    var targetedClickRequiresEventSynthesizingPermission = false
    var clickError: (any Error)?

    var nextTypeActionsResult: TypeResult?
    var typeActionsResultProvider: (([TypeAction], TypingCadence, String?) -> TypeResult)?
    var waitForElementProvider: ((ClickTarget, TimeInterval, String?) -> WaitForElementResult)?
    private var waitForElementResults: [WaitTargetKey: WaitForElementResult] = [:]
    var detectElementsHandler: ((Data, String?, WindowContext?) async throws -> ElementDetectionResult)?
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
            targetWindowID: nil
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
            targetWindowID: targetWindowID
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
                targetProcessIdentifier: targetProcessIdentifier
            )
        )
        return try await self.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func scroll(_ request: ScrollRequest) async throws {
        self.scrollCalls.append(
            ScrollCall(request: request)
        )
    }

    func hotkey(keys: String, holdDuration: Int) async throws {
        self.hotkeyCalls.append(HotkeyCall(keys: keys, holdDuration: holdDuration))
    }

    func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        self.targetedHotkeyCalls.append(TargetedHotkeyCall(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier
        ))
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
final class StubApplicationService: ApplicationServiceProtocol {
    var applications: [ServiceApplicationInfo]
    var windowsByApp: [String: [ServiceWindowInfo]]
    var launchResults: [String: ServiceApplicationInfo]
    var launchCalls: [String] = []
    var activateCalls: [String] = []
    var activateApplicationHandler: ((String) async throws -> Void)?
    var quitCalls: [(identifier: String, force: Bool)] = []
    var quitShouldSucceed = true
    var hideCalls: [String] = []
    var unhideCalls: [String] = []
    var hideOtherCalls: [String] = []
    var showAllCallCount = 0

    init(applications: [ServiceApplicationInfo], windowsByApp: [String: [ServiceWindowInfo]] = [:]) {
        self.applications = applications
        self.windowsByApp = windowsByApp
        self.launchResults = [:]
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        let data = ServiceApplicationListData(applications: applications)
        let summary = UnifiedToolOutput<ServiceApplicationListData>.Summary(
            brief: "Stub application list",
            status: .success,
            counts: ["applications": self.applications.count]
        )
        return UnifiedToolOutput(
            data: data,
            summary: summary,
            metadata: .init(duration: 0)
        )
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        if let pid = Self.parsePID(identifier),
           let match = applications.first(where: { $0.processIdentifier == pid }) {
            return match
        }

        if let match = applications.first(where: { $0.name == identifier || $0.bundleIdentifier == identifier }) {
            return match
        }
        throw PeekabooError.appNotFound(identifier)
    }

    private static func parsePID(_ identifier: String) -> pid_t? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let pidString: String = if trimmed.uppercased().hasPrefix("PID:") {
            String(trimmed.dropFirst(4))
        } else {
            trimmed
        }

        guard let rawPID = Int32(pidString), rawPID > 0 else { return nil }
        return pid_t(rawPID)
    }

    func listWindows(
        for appIdentifier: String,
        timeout: Float?
    ) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        let targetApp = self.applications.first {
            $0.name == appIdentifier || $0.bundleIdentifier == appIdentifier
        }
        let windows = self.windowsByApp[appIdentifier]
            ?? targetApp.flatMap { self.windowsByApp[$0.name] } ?? []
        let data = ServiceWindowListData(windows: windows, targetApplication: targetApp)
        let summary = UnifiedToolOutput<ServiceWindowListData>.Summary(
            brief: "Stub window list",
            status: .success,
            counts: ["windows": windows.count]
        )
        return UnifiedToolOutput(
            data: data,
            summary: summary,
            metadata: .init(duration: 0)
        )
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        guard let first = applications.first else {
            throw PeekabooError.appNotFound("frontmost")
        }
        return first
    }

    func isApplicationRunning(identifier: String) async -> Bool {
        self.applications.contains { $0.name == identifier || $0.bundleIdentifier == identifier }
    }

    func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
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

    func activateApplication(identifier: String) async throws {
        self.activateCalls.append(identifier)
        try await self.activateApplicationHandler?(identifier)
    }

    func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        self.quitCalls.append((identifier: identifier, force: force))
        return self.quitShouldSucceed
    }

    func hideApplication(identifier: String) async throws {
        self.hideCalls.append(identifier)
    }

    func unhideApplication(identifier: String) async throws {
        self.unhideCalls.append(identifier)
    }

    func hideOtherApplications(identifier: String) async throws {
        self.hideOtherCalls.append(identifier)
    }

    func showAllApplications() async throws {
        self.showAllCallCount += 1
    }
}

final class StubSnapshotManager: SnapshotManagerProtocol, @unchecked Sendable {
    let supportsImplicitLatestSnapshotInvalidation = true
    var copiesScreenshotArtifactsIntoStorage = false
    var effectiveImplicitLatestInvalidationWatermark: Date?
    private(set) var detectionResults: [String: ElementDetectionResult] = [:]
    private(set) var snapshotInfos: [String: SnapshotInfo] = [:]
    private(set) var storedElements: [String: [String: PeekabooCore.UIElement]] = [:]
    private(set) var storedAnnotatedScreenshots: [String: [String]] = [:]
    var mostRecentSnapshotId: String?
    var uiAutomationSnapshotError: PeekabooError?
    var invalidationError: (any Error)?
    var snapshotCreationDelay: Duration?
    var preservingInvalidationDelay: Duration?
    private(set) var invalidationCutoffs: [Date] = []
    private var pendingSnapshotIDs: Set<String> = []
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
                    role: element.type.rawValue,
                    title: element.label,
                    label: element.label,
                    value: element.value,
                    description: nil,
                    help: nil,
                    roleDescription: nil,
                    identifier: element.attributes["identifier"],
                    frame: element.bounds,
                    isActionable: true,
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

@available(macOS 14.0, *)
final class StubProcessService: ProcessServiceProtocol, @unchecked Sendable {
    struct LoadScriptCall {
        let path: String
    }

    struct ExecuteScriptCall {
        let script: PeekabooScript
        let failFast: Bool
        let verbose: Bool
    }

    struct ExecuteStepCall {
        let step: ScriptStep
        let snapshotId: String?
    }

    var loadScriptCalls: [LoadScriptCall] = []
    var executeScriptCalls: [ExecuteScriptCall] = []
    var executeStepCalls: [ExecuteStepCall] = []

    var scriptsByPath: [String: PeekabooScript] = [:]
    var loadScriptProvider: ((String) async throws -> PeekabooScript)?
    var executeScriptProvider: ((PeekabooScript, Bool, Bool) async throws -> [StepResult])?
    var executeStepProvider: ((ScriptStep, String?) async throws -> StepExecutionResult)?

    var nextScript: PeekabooScript?
    var nextExecuteScriptResults: [StepResult]?
    var nextStepResult: StepExecutionResult?

    func loadScript(from path: String) async throws -> PeekabooScript {
        self.loadScriptCalls.append(LoadScriptCall(path: path))

        if let provider = loadScriptProvider {
            return try await provider(path)
        }

        if let script = scriptsByPath[path] ?? scriptsByPath["*"] {
            return script
        }

        if let script = nextScript {
            return script
        }

        throw TestStubError.unimplemented(#function)
    }

    func executeScript(
        _ script: PeekabooScript,
        failFast: Bool,
        verbose: Bool
    ) async throws -> [StepResult] {
        self.executeScriptCalls.append(ExecuteScriptCall(script: script, failFast: failFast, verbose: verbose))

        if let provider = executeScriptProvider {
            return try await provider(script, failFast, verbose)
        }

        if let results = nextExecuteScriptResults {
            return results
        }

        return []
    }

    func executeStep(
        _ step: ScriptStep,
        snapshotId: String?
    ) async throws -> StepExecutionResult {
        self.executeStepCalls.append(ExecuteStepCall(step: step, snapshotId: snapshotId))

        if let provider = executeStepProvider {
            return try await provider(step, snapshotId)
        }

        if let result = nextStepResult {
            return result
        }

        throw TestStubError.unimplemented(#function)
    }
}

@MainActor
final class StubDockService: DockServiceProtocol {
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
    var restoreError: (any Error)?
    private(set) var restoreCallCount = 0

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.current
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        self.beforeMutation?()
        guard let primary = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided")
        }
        let result = ClipboardReadResult(
            utiIdentifier: primary.utiIdentifier,
            data: primary.data,
            textPreview: request.alsoText
        )
        self.current = result
        return result
    }

    func clear() {
        self.beforeMutation?()
        self.current = nil
    }

    func save(slot: String) throws {
        guard let current else {
            throw ClipboardServiceError.empty
        }
        self.slots[slot] = current
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
final class StubMenuService: MenuServiceProtocol {
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
    var dialogElements: DialogElements?
    var clickButtonResult: DialogActionResult?
    var handleFileDialogResult: DialogActionResult?
    var handleFileDialogDelay: TimeInterval?
    var dismissResult: DialogActionResult?
    var enterTextResult: DialogActionResult?

    private(set) var recordedButtonClicks: [(button: String, window: String?)] = []

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

    func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?
    ) async throws -> DialogActionResult {
        guard self.dialogElements != nil else {
            throw DialogError.noActiveDialog
        }
        if let result = enterTextResult {
            return result
        }
        throw DialogError.fieldNotFound
    }

    func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool,
        appName: String?
    ) async throws -> DialogActionResult {
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
}

@MainActor
final class StubWindowService: WindowManagementServiceProtocol {
    var windowsByApp: [String: [ServiceWindowInfo]]
    var focusCalls: [WindowTarget] = []

    init(windowsByApp: [String: [ServiceWindowInfo]]) {
        self.windowsByApp = windowsByApp
    }

    func closeWindow(target: WindowTarget) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func minimizeWindow(target: WindowTarget) async throws {
        throw TestStubError.unimplemented(#function)
    }

    func maximizeWindow(target: WindowTarget) async throws {
        throw TestStubError.unimplemented(#function)
    }

    @MainActor
    func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        try self.updateWindow(target: target) { info in
            let newBounds = CGRect(origin: position, size: info.bounds.size)
            return info.withBounds(newBounds)
        }
    }

    @MainActor
    func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        try self.updateWindow(target: target) { info in
            let newBounds = CGRect(origin: info.bounds.origin, size: size)
            return info.withBounds(newBounds)
        }
    }

    @MainActor
    func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        try self.updateWindow(target: target) { info in
            info.withBounds(bounds)
        }
    }

    @MainActor
    func focusWindow(target: WindowTarget) async throws {
        self.focusCalls.append(target)
    }

    @MainActor
    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        switch target {
        case let .application(app):
            return self.windowsByApp[app] ?? []
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

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    @MainActor
    private func updateWindow(
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
        ServiceWindowInfo(
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
            screenName: screenName
        )
    }
}

@MainActor
final class StubSpaceService: SpaceCommandSpaceService {
    let spaces: [SpaceInfo]
    let windowSpaces: [Int: [SpaceInfo]]
    var switchCalls: [CGSSpaceID] = []
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

    func moveWindowToCurrentSpace(windowID: CGWindowID) async throws {
        self.moveToCurrentCalls.append(windowID)
    }

    func moveWindowToSpace(windowID: CGWindowID, spaceID: CGSSpaceID) async throws {
        self.moveWindowCalls.append((windowID, spaceID))
    }

    func switchToSpace(_ spaceID: CGSSpaceID) async throws {
        self.switchCalls.append(spaceID)
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
        process: any ProcessServiceProtocol = StubProcessService(),
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
            process: process,
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
        process: any ProcessServiceProtocol = StubProcessService(),
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
            process: process,
            screens: screens,
            automation: automation,
            screenCapture: screenCapture
        )

        return AutomationTestContext(services: services, automation: automation, snapshots: snapshots)
    }
}
