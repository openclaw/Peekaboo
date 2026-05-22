import AppKit
@preconcurrency import AXorcist
import Foundation
import os.log
import PeekabooFoundation

/**
 * AI-powered UI element detection service for screenshot analysis.
 *
 * Combines computer vision with accessibility APIs to detect and classify interactive
 * UI elements in screenshots. Provides element identification, bounds calculation,
 * and accessibility correlation for automation targeting.
 *
 * ## Detection Capabilities
 * - Button, text field, image, and static text recognition
 * - Element bounds and coordinate mapping
 * - Accessibility attribute extraction
 * - Snapshot ID propagation for callers that persist results
 *
 * ## Usage Example
 * ```swift
 * let detectionService = ElementDetectionService()
 *
 * let result = try await detectionService.detectElements(
 *     in: screenshotData,
 *     snapshotId: "snapshot_123",
 *     windowContext: WindowContext(applicationName: "Safari")
 * )
 *
 * print("Detected \(result.elements.all.count) elements")
 * ```
 *
 * - Note: Core component of UIAutomationService's element recognition pipeline
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class ElementDetectionService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ElementDetectionService")
    private let windowIdentityService = WindowIdentityService()
    private let windowResolver: ElementDetectionWindowResolver
    private let axTreeCache = ElementDetectionCache()
    private let webFocusFallback = WebFocusFallback()
    private let menuBarElementCollector = MenuBarElementCollector()
    private let axTreeCollector = AXTreeCollector()

    public init(
        snapshotManager _: (any SnapshotManagerProtocol)? = nil,
        applicationService: ApplicationService? = nil)
    {
        self
            .windowResolver =
            ElementDetectionWindowResolver(applicationService: applicationService ?? ApplicationService())
    }

    /// Detect UI elements in a screenshot
    public func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        self.logger.info("Starting element detection")
        return try await self.inspectElements(
            snapshotId: snapshotId,
            windowContext: windowContext)
    }

    /// Inspect UI elements via the accessibility tree without a screenshot.
    public func inspectElements(
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        self.logger.info("Starting accessibility tree inspection")

        let effectiveSnapshotId = snapshotId ?? UUID().uuidString

        let targetApp = try await self.windowResolver.resolveApplication(windowContext: windowContext)
        let windowResolution = try await self.windowResolver.resolveWindow(for: targetApp, context: windowContext)
        let windowName = windowResolution.window.title() ?? "Untitled"
        self.logger.debug("Found \(windowResolution.windowTypeDescription): \(windowName)")

        let resolvedWindowID = self.windowIdentityService.getWindowID(from: windowResolution.window).map { Int($0) } ??
            windowContext?.windowID

        var elementIdMap: [String: DetectedElement] = [:]
        let allowWebFocus = windowContext?.shouldFocusWebContent ?? true
        let budget = AXTraversalBudget.normalizedForTraversal(windowContext?.traversalBudget)
        let usesDefaultBudget = budget == AXTraversalBudget()
        let resolvedWindowBounds = windowContext?.windowBounds ?? windowResolution.window.frame()
        let resolvedWindowContext = WindowContext(
            applicationName: windowContext?.applicationName ?? targetApp.localizedName,
            applicationBundleId: windowContext?.applicationBundleId ?? targetApp.bundleIdentifier,
            applicationProcessId: windowContext?.applicationProcessId ?? targetApp.processIdentifier,
            windowTitle: windowName,
            windowID: resolvedWindowID,
            windowBounds: resolvedWindowBounds,
            shouldFocusWebContent: windowContext?.shouldFocusWebContent,
            traversalBudget: budget)

        // GameBridge: check if this is a known game-bridge app (SDL/GPU-rendered)
        // before attempting AX tree traversal, which won't find elements in GPU windows.
        if let gameBridgeResult = GameBridgeDetectionService.tryDetect(
            windowContext: resolvedWindowContext,
            snapshotId: effectiveSnapshotId)
        {
            self.logger.info("GameBridge: detected \(gameBridgeResult.elements.all.count) elements from manifest")
            return gameBridgeResult
        }

        let detectedElements: [DetectedElement]
        let usedCache: Bool
        let truncationInfo: DetectionTruncationInfo?
        let cacheKey = usesDefaultBudget
            ? self.axTreeCache.key(
                windowID: resolvedWindowID,
                processID: targetApp.processIdentifier,
                allowWebFocus: allowWebFocus)
            : nil
        if let cacheKey, let cached = self.axTreeCache.result(for: cacheKey) {
            self.logger.debug("Using cached AX tree for window \(cacheKey.windowID)")
            detectedElements = cached.elements
            usedCache = true
            truncationInfo = cached.truncationInfo
        } else {
            let collection = try await self.collectElementsWithTimeout(
                ElementCollectionTimeoutRequest(
                    window: windowResolution.window,
                    appElement: windowResolution.appElement,
                    appIsActive: targetApp.isActive,
                    allowWebFocus: allowWebFocus,
                    budget: budget),
                elementIdMap: &elementIdMap)
            detectedElements = collection.elements
            truncationInfo = collection.truncationInfo
            if let cacheKey {
                self.axTreeCache.store(
                    detectedElements,
                    truncationInfo: collection.truncationInfo,
                    for: cacheKey)
            }
            usedCache = false
        }

        // Note: Parent-child relationships are not directly supported in the protocol's DetectedElement struct

        self.logger.info("Detected \(detectedElements.count) elements")

        return ElementDetectionResultBuilder.makeResult(
            snapshotId: effectiveSnapshotId,
            elements: detectedElements,
            usedCache: usedCache,
            windowContext: resolvedWindowContext,
            isDialog: windowResolution.isDialog,
            truncationInfo: truncationInfo)
    }
}

extension ElementDetectionService {
    private func collectElementsWithTimeout(
        _ timeoutRequest: ElementCollectionTimeoutRequest,
        elementIdMap: inout [String: DetectedElement]) async throws -> (
        elements: [DetectedElement],
        truncationInfo: DetectionTruncationInfo?)
    {
        let (elements, map, truncationInfo) = try await ElementDetectionTimeoutRunner.run(
            seconds: timeoutRequest.timeoutSeconds)
        {
            let deadline = Date().addingTimeInterval(timeoutRequest.timeoutSeconds)
            var localMap: [String: DetectedElement] = [:]
            let request = ElementCollectionRequest(
                window: timeoutRequest.window,
                appElement: timeoutRequest.appElement,
                appIsActive: timeoutRequest.appIsActive,
                allowWebFocus: timeoutRequest.allowWebFocus,
                deadline: deadline,
                budget: timeoutRequest.budget)
            let collection = await self.collectElements(
                request,
                elementIdMap: &localMap)
            return (collection.elements, localMap, collection.truncationInfo)
        }
        elementIdMap = map
        return (elements, truncationInfo)
    }
}

extension ElementDetectionService {
    private struct ElementCollection {
        let elements: [DetectedElement]
        let truncationInfo: DetectionTruncationInfo?
    }

    private func collectElements(
        _ request: ElementCollectionRequest,
        elementIdMap: inout [String: DetectedElement]) async -> ElementCollection
    {
        var detectedElements: [DetectedElement] = []
        var attempt = 0
        var truncationInfo: DetectionTruncationInfo?

        repeat {
            elementIdMap.removeAll(keepingCapacity: true)
            detectedElements.removeAll(keepingCapacity: true)

            let collection = self.axTreeCollector.collect(
                window: request.window,
                deadline: request.deadline,
                budget: request.budget)
            detectedElements = collection.elements
            elementIdMap = collection.elementIdMap
            truncationInfo = collection.truncationInfo

            if request.appIsActive, let menuBar = request.appElement.menuBar() {
                let menuBarTruncation = self.menuBarElementCollector.appendMenuBar(
                    menuBar,
                    elements: &detectedElements,
                    elementIdMap: &elementIdMap,
                    budget: request.budget)
                truncationInfo = DetectionTruncationInfo.merge(truncationInfo, menuBarTruncation)
            }

            let hasTextField = detectedElements.contains(where: { $0.type == .textField })

            // Web focus fallback walks the AX tree looking for AXWebArea. Only pay that cost when
            // the first pass is sparse enough to suggest hidden Chromium/Tauri content.
            guard AXTraversalPolicy.shouldAttemptWebFocusFallback(
                attempt: attempt,
                allowWebFocus: request.allowWebFocus,
                detectedElementCount: detectedElements.count,
                hasTextField: hasTextField),
                self.webFocusFallback.focusIfNeeded(window: request.window, appElement: request.appElement)
            else {
                break
            }

            attempt += 1
            try? await Task.sleep(nanoseconds: 150_000_000)
        } while true

        return ElementCollection(
            elements: detectedElements,
            truncationInfo: truncationInfo)
    }
}

private struct ElementCollectionRequest {
    let window: Element
    let appElement: Element
    let appIsActive: Bool
    let allowWebFocus: Bool
    let deadline: Date
    let budget: AXTraversalBudget?
}

private struct ElementCollectionTimeoutRequest {
    let window: Element
    let appElement: Element
    let appIsActive: Bool
    let allowWebFocus: Bool
    let budget: AXTraversalBudget?
    let timeoutSeconds = 20.0
}
