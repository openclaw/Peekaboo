import AppKit
@preconcurrency import AXorcist
import Foundation
import os.log
import PeekabooFoundation

struct CachedDetachedAXObservationContext: Sendable {
    let windowID: Int?
    let windowTitle: String?
    let windowBounds: CGRect?
    let isDialog: Bool
}

struct DetachedAXObservationOutcome: Sendable {
    let elements: [DetectedElement]
    let windowID: Int?
    let windowTitle: String?
    let windowBounds: CGRect?
    let isDialog: Bool
    let truncationInfo: DetectionTruncationInfo?
    let usedCache: Bool
}

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
    typealias DetachedAXObservationRunner = @MainActor @Sendable (
        DetachedAXObservationRequest) async throws -> DetachedAXObservationResult

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ElementDetectionService")
    private let snapshotManager: (any SnapshotManagerProtocol)?
    private let windowIdentityService = WindowIdentityService()
    private let windowResolver: ElementDetectionWindowResolver
    private let axTreeCache: ElementDetectionCache
    private let detachedAXObservationRunner: DetachedAXObservationRunner
    private let webFocusFallback = WebFocusFallback()
    private let menuBarElementCollector = MenuBarElementCollector()
    private let axTreeCollector = AXTreeCollector()

    public convenience init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        applicationService: ApplicationService? = nil)
    {
        self.init(
            snapshotManager: snapshotManager,
            applicationService: applicationService,
            axTreeCache: ElementDetectionCache(),
            detachedAXObservationRunner: { request in
                try await ElementDetectionTimeoutRunner.runDetached(
                    targetProcessIdentifier: request.processIdentifier,
                    targetProcessStartIdentity: request.expectedProcessStartIdentity,
                    seconds: request.timing.hardTimeoutSeconds)
                {
                    try DetachedAXObservationWorker.inspect(request)
                }
            })
    }

    init(
        snapshotManager: (any SnapshotManagerProtocol)?,
        applicationService: ApplicationService?,
        axTreeCache: ElementDetectionCache,
        detachedAXObservationRunner: @escaping DetachedAXObservationRunner)
    {
        self.snapshotManager = snapshotManager
        self.windowResolver =
            ElementDetectionWindowResolver(applicationService: applicationService ?? ApplicationService())
        self.axTreeCache = axTreeCache
        self.detachedAXObservationRunner = detachedAXObservationRunner
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
            windowContext: windowContext,
            preservesRequestedApplicationIdentity: true)
    }

    /// Inspect UI elements via the accessibility tree without a screenshot.
    public func inspectElements(
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        try await self.inspectElements(
            snapshotId: snapshotId,
            windowContext: windowContext,
            preservesRequestedApplicationIdentity: false)
    }

    private func inspectElements(
        snapshotId: String?,
        windowContext: WindowContext?,
        preservesRequestedApplicationIdentity: Bool) async throws -> ElementDetectionResult
    {
        self.logger.info("Starting accessibility tree inspection")

        let effectiveSnapshotId = snapshotId ?? UUID().uuidString

        let targetApp = try await self.windowResolver.resolveApplication(windowContext: windowContext)
        let applicationIdentity = Self.applicationIdentity(
            targetApp,
            requested: windowContext,
            preservesRequestedIdentity: preservesRequestedApplicationIdentity)
        if windowContext?.shouldFocusWebContent != true {
            return try await self.inspectReadOnlyElements(
                targetApp: targetApp,
                snapshotId: effectiveSnapshotId,
                windowContext: windowContext,
                applicationIdentity: applicationIdentity)
        }

        let windowResolution = try await self.windowResolver.resolveWindow(for: targetApp, context: windowContext)
        let windowName = windowResolution.window.title() ?? "Untitled"
        self.logger.debug("Found \(windowResolution.windowTypeDescription): \(windowName)")

        let resolvedWindowID = self.windowIdentityService.getWindowID(from: windowResolution.window).map { Int($0) } ??
            windowContext?.windowID

        var elementIdMap: [String: DetectedElement] = [:]
        let allowWebFocus = windowContext?.shouldFocusWebContent ?? false
        let includeMenuBarElements = windowContext?.includeMenuBarElements ?? true
        let budget = AXTraversalBudget.normalizedForTraversal(windowContext?.traversalBudget)
        let canReuseAXTree = Self.shouldUseAXTreeCache(
            budget: budget,
            requiresFreshAccessibilityTree: windowContext?.requiresFreshAccessibilityTree == true)
        let resolvedWindowBounds = windowContext?.windowBounds ?? windowResolution.window.frame()
        let resolvedWindowMutationIdentity = try Self.validatedExactWindowReceipt(
            windowID: windowContext?.windowID,
            processIdentifier: targetApp.processIdentifier,
            capturedBounds: windowContext?.windowBounds,
            receipt: windowContext?.windowMutationIdentity,
            requiresActionCapability: windowContext?.shouldFocusWebContent == true)
        let resolvedWindowContext = WindowContext(
            applicationName: applicationIdentity.name,
            applicationBundleId: applicationIdentity.bundleIdentifier,
            applicationBundlePath: applicationIdentity.bundlePath,
            applicationExecutablePath: applicationIdentity.executablePath,
            applicationProcessId: windowContext?.applicationProcessId ?? targetApp.processIdentifier,
            windowTitle: windowName,
            windowID: resolvedWindowID,
            windowBounds: resolvedWindowBounds,
            windowMutationIdentity: resolvedWindowMutationIdentity,
            shouldFocusWebContent: windowContext?.shouldFocusWebContent,
            includeMenuBarElements: windowContext?.includeMenuBarElements,
            traversalBudget: budget,
            requiresFreshAccessibilityTree: windowContext?.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: windowContext?.accessibilityTimeoutSeconds)

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
        let cacheKey = canReuseAXTree
            ? self.axTreeCache.key(
                windowID: resolvedWindowID,
                processID: targetApp.processIdentifier,
                allowWebFocus: allowWebFocus,
                includeMenuBarElements: includeMenuBarElements)
            : nil
        // Snapshot storage and the short-lived AX tree use separate caches. Tie them to the same
        // mutation boundary so a fresh screenshot cannot be paired with pre-mutation element values.
        let invalidatedThrough = self.snapshotManager?.effectiveImplicitLatestInvalidationWatermark
        if let cacheKey,
           let cached = self.axTreeCache.result(
               for: cacheKey,
               invalidatedThrough: invalidatedThrough)
        {
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
                    includeMenuBarElements: includeMenuBarElements,
                    budget: budget,
                    timeoutSeconds: Self.normalizedAccessibilityTimeout(
                        windowContext?.accessibilityTimeoutSeconds)),
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

    func invalidateCache() {
        self.axTreeCache.removeAll()
    }

    static func normalizedAccessibilityTimeout(_ requested: TimeInterval?) -> TimeInterval {
        guard let requested, requested.isFinite else { return 20 }
        return max(requested, 0.05)
    }

    static func shouldUseAXTreeCache(
        budget: AXTraversalBudget,
        requiresFreshAccessibilityTree: Bool) -> Bool
    {
        !requiresFreshAccessibilityTree && budget == AXTraversalBudget()
    }

    func cachedOrRunDetachedAXObservation(
        cacheKey: ElementDetectionCache.Key?,
        invalidatedThrough: Date?,
        cachedContext: CachedDetachedAXObservationContext,
        makeRequest: () throws -> DetachedAXObservationRequest) async throws -> DetachedAXObservationOutcome
    {
        if let cacheKey,
           let cached = self.axTreeCache.result(
               for: cacheKey,
               invalidatedThrough: invalidatedThrough)
        {
            return DetachedAXObservationOutcome(
                elements: cached.elements,
                windowID: cachedContext.windowID,
                windowTitle: cachedContext.windowTitle,
                windowBounds: cachedContext.windowBounds,
                isDialog: cachedContext.isDialog,
                truncationInfo: cached.truncationInfo,
                usedCache: true)
        }

        let detachedResult = try await self.detachedAXObservationRunner(makeRequest())
        if let cacheKey {
            self.axTreeCache.store(
                detachedResult.elements,
                truncationInfo: detachedResult.truncationInfo,
                for: cacheKey)
        }
        return DetachedAXObservationOutcome(
            elements: detachedResult.elements,
            windowID: detachedResult.windowID,
            windowTitle: detachedResult.windowTitle,
            windowBounds: detachedResult.windowBounds,
            isDialog: detachedResult.isDialog,
            truncationInfo: detachedResult.truncationInfo,
            usedCache: false)
    }

    private func inspectReadOnlyElements(
        targetApp: NSRunningApplication,
        snapshotId: String,
        windowContext: WindowContext?,
        applicationIdentity: ResolvedApplicationIdentity) async throws -> ElementDetectionResult
    {
        let processIdentifier = targetApp.processIdentifier
        let context = try Self.readOnlyWindowContext(
            targetApp: targetApp,
            requested: windowContext,
            applicationIdentity: applicationIdentity)
        if let requestedWindowID = context?.windowID {
            guard requestedWindowID > 0,
                  let cgWindowID = CGWindowID(exactly: requestedWindowID),
                  SystemIdentityResolver.windowOwnerProcessIdentifier(cgWindowID) == processIdentifier
            else {
                let identifier = targetApp.localizedName ?? targetApp.bundleIdentifier ?? "PID:\(processIdentifier)"
                throw PeekabooError.windowNotFound(
                    criteria: "window id \(requestedWindowID) owned by \(identifier)")
            }
        }

        let includeMenuBarElements = context?.includeMenuBarElements ?? true
        let budget = AXTraversalBudget.normalizedForTraversal(context?.traversalBudget)
        let canReuseAXTree = Self.shouldUseAXTreeCache(
            budget: budget,
            requiresFreshAccessibilityTree: context?.requiresFreshAccessibilityTree == true)
        let preliminaryContext = WindowContext(
            applicationName: applicationIdentity.name,
            applicationBundleId: applicationIdentity.bundleIdentifier,
            applicationBundlePath: applicationIdentity.bundlePath,
            applicationExecutablePath: applicationIdentity.executablePath,
            applicationProcessId: processIdentifier,
            windowTitle: context?.windowTitle,
            windowID: context?.windowID,
            windowBounds: context?.windowBounds,
            windowMutationIdentity: context?.windowMutationIdentity,
            shouldFocusWebContent: false,
            includeMenuBarElements: includeMenuBarElements,
            traversalBudget: budget,
            requiresFreshAccessibilityTree: context?.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: context?.accessibilityTimeoutSeconds)
        if let gameBridgeResult = GameBridgeDetectionService.tryDetect(
            windowContext: preliminaryContext,
            snapshotId: snapshotId)
        {
            return gameBridgeResult
        }

        let cacheKey = canReuseAXTree
            ? self.axTreeCache.key(
                windowID: context?.windowID,
                processID: processIdentifier,
                allowWebFocus: false,
                includeMenuBarElements: includeMenuBarElements)
            : nil
        let invalidatedThrough = self.snapshotManager?.effectiveImplicitLatestInvalidationWatermark
        let timeoutSeconds = Self.normalizedAccessibilityTimeout(context?.accessibilityTimeoutSeconds)
        let outcome = try await self.cachedOrRunDetachedAXObservation(
            cacheKey: cacheKey,
            invalidatedThrough: invalidatedThrough,
            cachedContext: CachedDetachedAXObservationContext(
                windowID: context?.windowID,
                windowTitle: context?.windowTitle,
                windowBounds: context?.windowBounds,
                isDialog: false))
        {
            let expectedProcessStartIdentity = context?.windowMutationIdentity?.ownerProcessStartIdentity ??
                SystemIdentityResolver.processStartIdentity(processIdentifier)
            guard let expectedProcessStartIdentity else {
                throw PeekabooError.snapshotStale(
                    "Could not capture the target process generation before detached AX observation")
            }
            return DetachedAXObservationRequest(
                processIdentifier: processIdentifier,
                expectedProcessStartIdentity: expectedProcessStartIdentity,
                windowID: context?.windowID,
                windowTitle: context?.windowTitle,
                expectedWindowBounds: context?.windowBounds,
                windowMutationIdentity: context?.windowMutationIdentity,
                includeMenuBarElements: includeMenuBarElements,
                appIsActive: targetApp.isActive,
                traversalBudget: budget,
                timing: DetachedAXObservationTiming(hardTimeoutSeconds: timeoutSeconds))
        }

        let resolvedContext = WindowContext(
            applicationName: applicationIdentity.name,
            applicationBundleId: applicationIdentity.bundleIdentifier,
            applicationBundlePath: applicationIdentity.bundlePath,
            applicationExecutablePath: applicationIdentity.executablePath,
            applicationProcessId: processIdentifier,
            windowTitle: outcome.windowTitle,
            windowID: outcome.windowID,
            windowBounds: context?.windowBounds ?? outcome.windowBounds,
            windowMutationIdentity: context?.windowMutationIdentity,
            shouldFocusWebContent: false,
            includeMenuBarElements: includeMenuBarElements,
            traversalBudget: budget,
            requiresFreshAccessibilityTree: outcome.usedCache ? false :
                context?.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: outcome.usedCache ? context?.accessibilityTimeoutSeconds : timeoutSeconds)

        if !outcome.usedCache {
            self.logger.info("Detected \(outcome.elements.count) elements on detached AX lane")
        }
        return ElementDetectionResultBuilder.makeResult(
            snapshotId: snapshotId,
            elements: outcome.elements,
            usedCache: outcome.usedCache,
            windowContext: resolvedContext,
            isDialog: outcome.isDialog,
            truncationInfo: outcome.truncationInfo)
    }

    private static func readOnlyWindowContext(
        targetApp: NSRunningApplication,
        requested: WindowContext?,
        applicationIdentity: ResolvedApplicationIdentity) throws -> WindowContext?
    {
        if let requestedWindowID = requested?.windowID {
            let actionableReceipt = try Self.resolveActionableWindowReceipt(
                windowID: requestedWindowID,
                processIdentifier: targetApp.processIdentifier,
                capturedBounds: requested?.windowBounds,
                receipt: requested?.windowMutationIdentity)
            guard let windowID = CGWindowID(exactly: requestedWindowID),
                  let liveWindow = SystemIdentityResolver.windowIdentity(windowID),
                  liveWindow.ownerProcessIdentifier == targetApp.processIdentifier,
                  liveWindow.bounds == actionableReceipt.bounds
            else {
                throw PeekabooError.snapshotStale(
                    "Exact observation window changed before its process-generation receipt was captured")
            }
            return WindowContext(
                applicationName: applicationIdentity.name,
                applicationBundleId: applicationIdentity.bundleIdentifier,
                applicationBundlePath: applicationIdentity.bundlePath,
                applicationExecutablePath: applicationIdentity.executablePath,
                applicationProcessId: targetApp.processIdentifier,
                windowTitle: requested?.windowTitle ?? liveWindow.title,
                windowID: requestedWindowID,
                windowBounds: actionableReceipt.bounds,
                windowMutationIdentity: actionableReceipt.identity,
                shouldFocusWebContent: requested?.shouldFocusWebContent,
                includeMenuBarElements: requested?.includeMenuBarElements,
                traversalBudget: requested?.traversalBudget,
                requiresFreshAccessibilityTree: requested?.requiresFreshAccessibilityTree ?? false,
                accessibilityTimeoutSeconds: requested?.accessibilityTimeoutSeconds)
        }
        let windows = SystemIdentityResolver.windowIdentities(
            ownerProcessIdentifier: targetApp.processIdentifier)
            .enumerated()
            .map { index, identity in ObservationTargetResolver.serviceWindowInfo(identity, index: index) }
        let applicationIdentifier = targetApp.localizedName ?? targetApp.bundleIdentifier ??
            "PID:\(targetApp.processIdentifier)"
        guard let window = try Self.selectReadOnlyWindow(
            requestedTitle: requested?.windowTitle,
            windows: windows,
            applicationIdentifier: applicationIdentifier)
        else {
            return requested
        }
        let actionableReceipt = try Self.resolveActionableWindowReceipt(
            windowID: window.windowID,
            processIdentifier: targetApp.processIdentifier,
            capturedBounds: window.bounds,
            receipt: window.mutationIdentity)
        return WindowContext(
            applicationName: applicationIdentity.name,
            applicationBundleId: applicationIdentity.bundleIdentifier,
            applicationBundlePath: applicationIdentity.bundlePath,
            applicationExecutablePath: applicationIdentity.executablePath,
            applicationProcessId: targetApp.processIdentifier,
            windowTitle: window.title,
            windowID: window.windowID,
            windowBounds: actionableReceipt.bounds,
            windowMutationIdentity: actionableReceipt.identity,
            shouldFocusWebContent: requested?.shouldFocusWebContent,
            includeMenuBarElements: requested?.includeMenuBarElements,
            traversalBudget: requested?.traversalBudget,
            requiresFreshAccessibilityTree: requested?.requiresFreshAccessibilityTree ?? false,
            accessibilityTimeoutSeconds: requested?.accessibilityTimeoutSeconds)
    }

    struct ResolvedApplicationIdentity: Sendable {
        let name: String
        let bundleIdentifier: String?
        let bundlePath: String?
        let executablePath: String?
    }

    private static func applicationIdentity(
        _ application: NSRunningApplication,
        requested: WindowContext?,
        preservesRequestedIdentity: Bool) -> ResolvedApplicationIdentity
    {
        let canonicalName = application.localizedName ?? application.bundleIdentifier ??
            "PID:\(application.processIdentifier)"
        return self.projectedApplicationIdentity(
            canonical: ResolvedApplicationIdentity(
                name: canonicalName,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: application.bundleURL?.standardizedFileURL.path,
                executablePath: application.executableURL?.standardizedFileURL.path),
            requested: requested,
            preservesRequestedIdentity: preservesRequestedIdentity)
    }

    nonisolated static func projectedApplicationIdentity(
        canonical: ResolvedApplicationIdentity,
        requested: WindowContext?,
        preservesRequestedIdentity: Bool) -> ResolvedApplicationIdentity
    {
        guard preservesRequestedIdentity else {
            return canonical
        }
        return ResolvedApplicationIdentity(
            name: requested?.applicationName ?? canonical.name,
            bundleIdentifier: requested?.applicationBundleId ?? canonical.bundleIdentifier,
            bundlePath: requested?.applicationBundlePath == nil ? nil : canonical.bundlePath,
            executablePath: requested?.applicationExecutablePath == nil ? nil : canonical.executablePath)
    }

    nonisolated struct ActionableWindowReceipt: Equatable {
        let identity: WindowMutationIdentity
        let bounds: CGRect
    }

    nonisolated static func resolveActionableWindowReceipt(
        windowID: Int,
        processIdentifier: pid_t,
        capturedBounds: CGRect?,
        receipt: WindowMutationIdentity?,
        receiptProvider: (CGWindowID) -> WindowMutationIdentity? = {
            SystemIdentityResolver.windowMutationIdentity(windowID: $0)
        },
        validator: (WindowMutationIdentity, CGRect) -> Bool = {
            SystemIdentityResolver.validateWindowMutationIdentity($0, expectedBounds: $1)
        }) throws -> ActionableWindowReceipt
    {
        guard windowID > 0, let cgWindowID = CGWindowID(exactly: windowID) else {
            throw PeekabooError.snapshotStale("Exact AX observation window identifier is invalid")
        }
        guard let candidate = receipt ?? receiptProvider(cgWindowID),
              let bounds = capturedBounds ?? candidate.capturedBounds,
              candidate.ownerProcessStartIdentity > 0,
              candidate.capturedBounds == bounds,
              let identity = try Self.validatedExactWindowReceipt(
                  windowID: windowID,
                  processIdentifier: processIdentifier,
                  capturedBounds: bounds,
                  receipt: candidate,
                  requiresActionCapability: true,
                  validator: validator)
        else {
            throw PeekabooError.snapshotStale(
                "AX-only observation could not capture an exact process-generation, window, and bounds receipt")
        }
        return ActionableWindowReceipt(identity: identity, bounds: bounds)
    }

    nonisolated static func validatedExactWindowReceipt(
        windowID: Int?,
        processIdentifier: pid_t,
        capturedBounds: CGRect?,
        receipt: WindowMutationIdentity?,
        requiresActionCapability: Bool,
        validator: (WindowMutationIdentity, CGRect) -> Bool = {
            SystemIdentityResolver.validateWindowMutationIdentity($0, expectedBounds: $1)
        }) throws -> WindowMutationIdentity?
    {
        guard let windowID else {
            guard receipt == nil else {
                throw PeekabooError.snapshotStale(
                    "Window receipt was provided without an exact capture-time window identifier")
            }
            return nil
        }
        guard let receipt else {
            if requiresActionCapability {
                throw PeekabooError.snapshotStale(
                    "Exact action-capable detection requires a capture-time process-generation receipt")
            }
            return nil
        }
        guard let capturedBounds,
              receipt.windowID == windowID,
              receipt.ownerProcessIdentifier == processIdentifier,
              validator(receipt, capturedBounds)
        else {
            throw PeekabooError.snapshotStale(
                "Exact capture-time window receipt changed before AX traversal")
        }
        return receipt
    }

    nonisolated static func selectReadOnlyWindow(
        requestedTitle: String?,
        windows: [ServiceWindowInfo],
        applicationIdentifier: String) throws -> ServiceWindowInfo?
    {
        guard let requestedTitle else {
            return ObservationTargetResolver.bestWindow(from: windows)
        }

        let exactMatches = windows.filter {
            $0.title.localizedCaseInsensitiveCompare(requestedTitle) == .orderedSame
        }
        if exactMatches.count == 1 {
            return exactMatches[0]
        }
        if exactMatches.count > 1 {
            throw PeekabooError.windowNotFound(
                criteria: Self.ambiguousWindowTitleCriteria(
                    requestedTitle,
                    applicationIdentifier: applicationIdentifier,
                    matches: exactMatches))
        }

        if !requestedTitle.isEmpty {
            let partialMatches = windows.filter {
                $0.title.localizedCaseInsensitiveContains(requestedTitle)
            }
            if partialMatches.count == 1 {
                return partialMatches[0]
            }
            if partialMatches.count > 1 {
                throw PeekabooError.windowNotFound(
                    criteria: Self.ambiguousWindowTitleCriteria(
                        requestedTitle,
                        applicationIdentifier: applicationIdentifier,
                        matches: partialMatches))
            }
        }

        throw PeekabooError.windowNotFound(
            criteria: "window title '\(requestedTitle)' in \(applicationIdentifier)")
    }

    private nonisolated static func ambiguousWindowTitleCriteria(
        _ requestedTitle: String,
        applicationIdentifier: String,
        matches: [ServiceWindowInfo]) -> String
    {
        let matchSummary = matches.map { "id=\($0.windowID) '\($0.title)'" }.joined(separator: ", ")
        return "window title '\(requestedTitle)' is ambiguous in \(applicationIdentifier); matches: \(matchSummary)"
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
                includeMenuBarElements: timeoutRequest.includeMenuBarElements,
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
    private struct ElementCollection: Sendable {
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

            if Self.shouldCollectMenuBarElements(
                requested: request.includeMenuBarElements,
                appIsActive: request.appIsActive), let menuBar = request.appElement.menuBar()
            {
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
            guard await ElementDetectionWebFocusRetryDelay.wait() else {
                break
            }
        } while true

        return ElementCollection(
            elements: detectedElements,
            truncationInfo: truncationInfo)
    }

    static func shouldCollectMenuBarElements(requested: Bool, appIsActive: Bool) -> Bool {
        requested && appIsActive
    }
}

@_spi(Testing) public enum ElementDetectionWebFocusRetryDelay {
    @_spi(Testing) public static func wait(nanoseconds: UInt64 = 150_000_000) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: nanoseconds)
        } catch {
            return false
        }
        return !Task.isCancelled
    }
}

private struct ElementCollectionRequest: Sendable {
    let window: Element
    let appElement: Element
    let appIsActive: Bool
    let allowWebFocus: Bool
    let includeMenuBarElements: Bool
    let deadline: Date
    let budget: AXTraversalBudget?
}

private struct ElementCollectionTimeoutRequest: Sendable {
    let window: Element
    let appElement: Element
    let appIsActive: Bool
    let allowWebFocus: Bool
    let includeMenuBarElements: Bool
    let budget: AXTraversalBudget?
    let timeoutSeconds: TimeInterval
}
