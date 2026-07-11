import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Darwin
import Foundation
import os.log
import PeekabooFoundation

/**
 * Specialized click service providing precise mouse interaction capabilities.
 *
 * Handles all types of click operations with intelligent targeting, snapshot integration,
 * and multiple targeting modes. Supports element-based clicking via snapshot cache,
 * coordinate-based clicking, and query-based element discovery.
 *
 * ## Click Types
 * - Single, double, right-click, and middle-click
 * - Coordinate-based and element-based targeting
 * - Query-based element discovery and interaction
 *
 * ## Usage Example
 * ```swift
 * let clickService = ClickService(snapshotManager: snapshotManager)
 *
 * // Click by element ID
 * try await clickService.click(
 *     target: .elementId(detectedElement.id),
 *     clickType: .single,
 *     snapshotId: "snapshot_123"
 * )
 *
 * // Click by coordinates
 * try await clickService.click(
 *     target: .coordinates(CGPoint(x: 100, y: 200)),
 *     clickType: .right,
 *     snapshotId: nil
 * )
 * ```
 *
 * - Note: Part of UIAutomationService's specialized service architecture
 * - Since: PeekabooCore 1.0.0
 */
@MainActor
public final class ClickService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ClickService")
    private let snapshotManager: any SnapshotManagerProtocol
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let syntheticInputDriver: any SyntheticInputDriving
    private let automationElementResolver: any AutomationElementResolving

    public convenience init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior)
    {
        self.init(
            snapshotManager: snapshotManager,
            inputPolicy: inputPolicy,
            actionInputDriver: ActionInputDriver(),
            syntheticInputDriver: SyntheticInputDriver(),
            automationElementResolver: AutomationElementResolver())
    }

    init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        syntheticInputDriver: any SyntheticInputDriving = SyntheticInputDriver(),
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver())
    {
        self.snapshotManager = snapshotManager ?? SnapshotManager()
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
    }

    /// Perform a click operation
    @discardableResult
    @MainActor
    public func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws
        -> UIInputExecutionResult
    {
        try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            targetProcessIdentifier: nil,
            targetWindowID: nil)
    }

    /// Perform a click, optionally delivering synthetic fallback events directly to a target process.
    @discardableResult
    @MainActor
    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        targetWindowID: Int? = nil) async throws -> UIInputExecutionResult
    {
        self.logger.debug("Click requested - target: \(String(describing: target)), type: \(clickType)")
        if targetProcessIdentifier != nil, clickType == .double {
            // AX exposes no double-press action and pid-routed mouse events cannot be positioned,
            // so a background double-click can never be delivered faithfully. Fail up front
            // instead of silently mis-clicking (or reporting a success that never happened).
            throw PeekabooError.serviceUnavailable(BackgroundInputDriver.doubleClickUnsupportedMessage)
        }
        let bundleIdentifier = await self.bundleIdentifier(
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
        let strategy = self.inputPolicy.strategy(for: .click, bundleIdentifier: bundleIdentifier)

        do {
            let exactTargetWindowID = try await self.validateSnapshotTarget(
                target: target,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                requestedTargetWindowID: targetWindowID)
            let result = try await UIInputDispatcher.run(
                verb: .click,
                strategy: strategy,
                bundleIdentifier: bundleIdentifier,
                action: {
                    do {
                        return try await self.performActionClick(
                            target: target,
                            clickType: clickType,
                            snapshotId: snapshotId,
                            targetProcessIdentifier: targetProcessIdentifier)
                    } catch let error as ActionInputError
                        where strategy == .actionFirst &&
                        targetProcessIdentifier != nil &&
                        (error == .permissionDenied || error == .targetUnavailable)
                    {
                        throw ActionInputError.unsupported(.actionUnsupported)
                    }
                },
                synth: {
                    try await self.performSyntheticClick(
                        target: target,
                        clickType: clickType,
                        snapshotId: snapshotId,
                        targetProcessIdentifier: targetProcessIdentifier,
                        targetWindowID: exactTargetWindowID)
                })
            self.logger.debug("Click completed via \(result.path.rawValue, privacy: .public)")
            return result
        } catch let error as ActionInputError
            where targetProcessIdentifier != nil && strategy == .actionOnly && error == .permissionDenied
        {
            self.logger.error("Click failed: \(error.localizedDescription)")
            throw PeekabooError.permissionDeniedAccessibility
        } catch {
            self.logger.error("Click failed: \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Private Methods

    private func performActionClick(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?) async throws -> ActionInputResult
    {
        guard let element = try await self.resolveAutomationElement(
            target: target,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
        else {
            throw ActionInputError.unsupported(.missingElement)
        }

        switch clickType {
        case .single:
            if targetProcessIdentifier != nil {
                return try self.actionInputDriver.tryPerformAction(
                    element: element,
                    actionName: AXActionNames.kAXPressAction)
            }
            return try self.actionInputDriver.tryClick(element: element)
        case .right:
            return try await self.actionInputDriver.tryRightClick(element: element)
        case .double:
            throw ActionInputError.unsupported(.actionUnsupported)
        case .longPress:
            throw ActionInputError.unsupported(.actionUnsupported)
        }
    }

    private func performSyntheticClick(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) async throws
    {
        switch target {
        case let .elementId(id):
            try await self.clickElementById(
                id: id,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)

        case let .coordinates(point):
            try await self.performClick(
                at: point,
                clickType: clickType,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)

        case let .query(query):
            try await self.clickElementByQuery(
                query: query,
                clickType: clickType,
                snapshotId: snapshotId,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        }
    }

    private func resolveAutomationElement(
        target: ClickTarget,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?) async throws -> AutomationElement?
    {
        switch target {
        case .coordinates:
            return nil

        case let .elementId(id):
            guard let snapshotId else {
                return nil
            }
            guard let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId)
            else {
                throw ActionInputError.staleElement
            }
            guard let element = detectionResult.elements.findById(id) else {
                throw ActionInputError.unsupported(.missingElement)
            }
            try self.requireExactWindowForTargetedAction(
                element: element,
                windowContext: detectionResult.metadata.windowContext,
                targetProcessIdentifier: targetProcessIdentifier)
            let adjustedElement = try await self.adjustedDetectedElement(
                element,
                snapshotId: snapshotId)
            guard let resolved = self.automationElementResolver.resolve(
                detectedElement: adjustedElement,
                windowContext: detectionResult.metadata.windowContext,
                targetProcessIdentifier: targetProcessIdentifier)
            else {
                throw ActionInputError.unsupported(.missingElement)
            }
            return resolved

        case let .query(query):
            var detectionResult: ElementDetectionResult?
            if let snapshotId {
                guard let loadedResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId)
                else {
                    throw ActionInputError.staleElement
                }
                detectionResult = loadedResult
                if let element = Self.resolveTargetElement(query: query, in: loadedResult) {
                    try self.requireExactWindowForTargetedAction(
                        element: element,
                        windowContext: loadedResult.metadata.windowContext,
                        targetProcessIdentifier: targetProcessIdentifier)
                    let adjustedElement = try await self.adjustedDetectedElement(
                        element,
                        snapshotId: snapshotId)
                    guard let resolved = self.automationElementResolver.resolve(
                        detectedElement: adjustedElement,
                        windowContext: loadedResult.metadata.windowContext,
                        targetProcessIdentifier: targetProcessIdentifier)
                    else {
                        throw ActionInputError.unsupported(.missingElement)
                    }
                    return resolved
                }
            }

            return self.resolveLiveQueryElement(
                query,
                snapshotId: snapshotId,
                detectionResult: detectionResult,
                targetProcessIdentifier: targetProcessIdentifier)
        }
    }

    private func requireExactWindowForTargetedAction(
        element: DetectedElement,
        windowContext: WindowContext?,
        targetProcessIdentifier: pid_t?) throws
    {
        guard targetProcessIdentifier != nil else {
            return
        }
        if Self.isApplicationRootElement(element) {
            guard windowContext?.windowID == nil else {
                throw PeekabooError.invalidInput(
                    "Application menu actions cannot be pinned to a document window")
            }
            return
        }
        guard windowContext?.windowID == nil else { return }
        throw ActionInputError.staleElement
    }

    private static func isApplicationRootElement(_ element: DetectedElement) -> Bool {
        DetectedElementRootPolicy.requiresApplicationRoot(element)
    }

    private func adjustedDetectedElement(
        _ element: DetectedElement,
        snapshotId: String) async throws -> DetectedElement
    {
        let center = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        let adjustedCenter = try await self.resolveAdjustedPoint(center, snapshotId: snapshotId)
        let delta = CGPoint(x: adjustedCenter.x - center.x, y: adjustedCenter.y - center.y)
        guard delta != .zero else { return element }

        return DetectedElement(
            id: element.id,
            type: element.type,
            label: element.label,
            value: element.value,
            bounds: element.bounds.offsetBy(dx: delta.x, dy: delta.y),
            isEnabled: element.isEnabled,
            isSelected: element.isSelected,
            attributes: element.attributes)
    }

    private func bundleIdentifier(snapshotId: String?, targetProcessIdentifier: pid_t?) async -> String? {
        if let targetProcessIdentifier {
            return NSRunningApplication(processIdentifier: targetProcessIdentifier)?.bundleIdentifier
        }

        if let snapshotId,
           let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
           let bundleIdentifier = detectionResult.metadata.windowContext?.applicationBundleId
        {
            return bundleIdentifier
        }

        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func validateSnapshotTarget(
        target: ClickTarget,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        requestedTargetWindowID: Int?) async throws -> CGWindowID?
    {
        let requestedCGWindowID = try Self.validatedCGWindowID(requestedTargetWindowID)
        guard let targetProcessIdentifier else { return nil }
        if case .coordinates = target {
            return requestedCGWindowID
        }
        guard let snapshotId else {
            if requestedCGWindowID != nil {
                throw PeekabooError.invalidInput(
                    "Exact-window element and query clicks require a snapshot captured from that window")
            }
            return nil
        }
        guard let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
            throw ActionInputError.staleElement
        }
        guard let snapshotProcessIdentifier = detectionResult.metadata.windowContext?.applicationProcessId else {
            throw PeekabooError.invalidInput(
                "Snapshot does not identify its target process; capture a fresh target snapshot")
        }

        guard snapshotProcessIdentifier == targetProcessIdentifier else {
            throw PeekabooError.invalidInput(
                "Snapshot PID \(snapshotProcessIdentifier) does not match background target PID " +
                    "\(targetProcessIdentifier); capture a fresh target snapshot")
        }

        guard Self.isProcessAlive(targetProcessIdentifier) else {
            throw PeekabooError.appNotFound("PID:\(targetProcessIdentifier)")
        }
        if let targetApplication = NSRunningApplication(processIdentifier: targetProcessIdentifier),
           let snapshotBundleIdentifier = detectionResult.metadata.windowContext?.applicationBundleId,
           let targetBundleIdentifier = targetApplication.bundleIdentifier,
           snapshotBundleIdentifier != targetBundleIdentifier
        {
            throw PeekabooError.invalidInput(
                "Snapshot bundle \(snapshotBundleIdentifier) does not match background target bundle " +
                    "\(targetBundleIdentifier); capture a fresh target snapshot")
        }

        let snapshotWindowID = detectionResult.metadata.windowContext?.windowID
        let snapshotCGWindowID = try Self.validatedCGWindowID(snapshotWindowID)
        if let requestedTargetWindowID, let requestedCGWindowID {
            guard let snapshotWindowID, let snapshotCGWindowID else {
                throw PeekabooError.invalidInput(
                    "Snapshot does not identify its target window; capture a fresh target snapshot")
            }
            guard snapshotCGWindowID == requestedCGWindowID else {
                throw PeekabooError.invalidInput(
                    "Snapshot window \(snapshotWindowID) does not match background target window " +
                        "\(requestedTargetWindowID); capture a fresh target snapshot")
            }
        }
        let exactTargetWindowID = requestedCGWindowID ?? snapshotCGWindowID
        if exactTargetWindowID != nil,
           let element = Self.resolveSnapshotTarget(target, in: detectionResult),
           Self.isApplicationRootElement(element)
        {
            throw PeekabooError.invalidInput(
                "Application menu actions cannot be pinned to a document window")
        }
        return exactTargetWindowID
    }

    private static func resolveSnapshotTarget(
        _ target: ClickTarget,
        in detectionResult: ElementDetectionResult) -> DetectedElement?
    {
        switch target {
        case let .elementId(id):
            detectionResult.elements.findById(id)
        case let .query(query):
            Self.resolveTargetElement(query: query, in: detectionResult)
        case .coordinates:
            nil
        }
    }

    private static func validatedCGWindowID(_ windowID: Int?) throws -> CGWindowID? {
        guard let windowID else { return nil }
        guard windowID > 0, let cgWindowID = CGWindowID(exactly: windowID) else {
            throw PeekabooError.invalidInput("Target window identifier is outside the valid UInt32 range")
        }
        return cgWindowID
    }

    private static func isProcessAlive(_ processIdentifier: pid_t) -> Bool {
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func clickElementById(
        id: String,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) async throws
    {
        guard let snapshotId else {
            throw NotFoundError.element(id)
        }
        guard let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
            throw ActionInputError.staleElement
        }
        guard let element = detectionResult.elements.findById(id) else {
            throw NotFoundError.element(id)
        }
        try self.requireExactWindowForTargetedSynthesis(
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID)
        let center = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        let adjusted = try await self.resolveAdjustedPoint(center, snapshotId: snapshotId)
        try await self.performClick(
            at: adjusted,
            clickType: clickType,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID)
        try await self.nudgeTextInputFocusIfNeeded(
            afterClickAt: adjusted,
            clickType: clickType,
            expectedIdentifier: element.attributes["identifier"],
            targetProcessIdentifier: targetProcessIdentifier)
        self.logger.debug("Clicked element \(id) at (\(adjusted.x), \(adjusted.y))")
    }

    @MainActor
    private func clickElementByQuery(
        query: String,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) async throws
    {
        // First try to find in snapshot data if available (much faster)
        var found = false
        var clickFrame: CGRect?
        var resolvedElement: DetectedElement?
        var detectionResult: ElementDetectionResult?

        if let snapshotId {
            guard let loadedResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
                throw ActionInputError.staleElement
            }
            detectionResult = loadedResult
            if let match = Self.resolveTargetElement(query: query, in: loadedResult) {
                found = true
                clickFrame = match.bounds
                resolvedElement = match
                self.logger.debug("Found element in snapshot matching query: \(query)")
            }
        }

        // Explicit snapshots stay pinned to their captured window; snapshotless lookup may use the app at the pointer.
        if !found {
            let element = self.resolveLiveQueryElement(
                query,
                snapshotId: snapshotId,
                detectionResult: detectionResult,
                targetProcessIdentifier: targetProcessIdentifier)
            if let element, let frame = element.frame {
                found = true
                clickFrame = frame
                self.logger.debug("Found element via AX search matching query: \(query)")
            }
        }

        // Perform click if element found
        if found, let frame = clickFrame {
            try self.requireExactWindowForTargetedSynthesis(
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let adjusted = try await self.resolveAdjustedPoint(
                center,
                snapshotId: resolvedElement != nil ? snapshotId : nil)
            try await self.performClick(
                at: adjusted,
                clickType: clickType,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
            try await self.nudgeTextInputFocusIfNeeded(
                afterClickAt: adjusted,
                clickType: clickType,
                expectedIdentifier: resolvedElement?.attributes["identifier"],
                targetProcessIdentifier: targetProcessIdentifier)
            self.logger.debug("Clicked element matching '\(query)' at (\(adjusted.x), \(adjusted.y))")
        } else {
            throw NotFoundError.element(query)
        }
    }

    private func resolveAdjustedPoint(_ point: CGPoint, snapshotId: String?) async throws -> CGPoint {
        try await WindowMovementTracking.adjustPoint(
            point,
            snapshotId: snapshotId,
            snapshots: self.snapshotManager)
    }

    private func requireExactWindowForTargetedSynthesis(
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) throws
    {
        guard targetProcessIdentifier != nil, targetWindowID == nil else { return }
        throw ActionInputError.staleElement
    }

    private func resolveLiveQueryElement(
        _ query: String,
        snapshotId: String?,
        detectionResult: ElementDetectionResult?,
        targetProcessIdentifier: pid_t?) -> AutomationElement?
    {
        if snapshotId != nil {
            guard let windowContext = detectionResult?.metadata.windowContext,
                  windowContext.windowID != nil
            else {
                return nil
            }
            return self.automationElementResolver.resolve(
                query: query,
                windowContext: windowContext,
                targetProcessIdentifier: targetProcessIdentifier,
                requireTextInput: false)
        }

        return self.findElementByQuery(
            query,
            targetProcessIdentifier: targetProcessIdentifier).map(AutomationElement.init)
    }

    private func nudgeTextInputFocusIfNeeded(
        afterClickAt point: CGPoint,
        clickType: ClickType,
        expectedIdentifier: String?,
        targetProcessIdentifier: pid_t?) async throws
    {
        guard clickType == .single else { return }
        guard targetProcessIdentifier == nil else { return }

        let normalizedExpectedIdentifier = expectedIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        // If we're already focused on a text input, don't introduce extra clicks.
        if self.isFocusedTextInput(expectedIdentifier: normalizedExpectedIdentifier) {
            return
        }

        // SwiftUI can report text input frames with a stable vertical offset (commonly ~28-32px).
        // Retry a handful of small Y nudges to land inside the actual editable region.
        let nudges: [CGFloat] = [-29, -24, -34, -20]

        for dy in nudges {
            let candidate = CGPoint(x: point.x, y: point.y + dy)
            try await self.performClick(
                at: candidate,
                clickType: .single,
                targetProcessIdentifier: nil,
                targetWindowID: nil)
            try await Task.sleep(nanoseconds: 60_000_000) // 60ms

            if self.isFocusedTextInput(expectedIdentifier: normalizedExpectedIdentifier) {
                return
            }
        }
    }

    private func isFocusedTextInput(expectedIdentifier: String?) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let appElement = AXApp(frontApp).element
        guard let focused = appElement.focusedUIElement() else { return false }

        let role = focused.role()?.lowercased() ?? ""
        let isTextInput = role.contains("textfield") || role.contains("searchfield") || role.contains("textarea")
        guard isTextInput else { return false }

        guard let expectedIdentifier, !expectedIdentifier.isEmpty else { return true }
        return focused.identifier()?.lowercased() == expectedIdentifier
    }

    @MainActor
    static func resolveTargetElement(query: String, in detectionResult: ElementDetectionResult) -> DetectedElement? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryLower = trimmed.lowercased()
        guard !queryLower.isEmpty else { return nil }

        var bestMatch: DetectedElement?
        var bestScore = Int.min

        for element in detectionResult.elements.all where element.isEnabled {
            let label = element.label?.lowercased()
            let value = element.value?.lowercased()
            let identifier = element.attributes["identifier"]?.lowercased()
            let title = element.attributes["title"]?.lowercased()
            let description = element.attributes["description"]?.lowercased()
            let role = element.attributes["role"]?.lowercased()

            let candidates = [label, value, identifier, title, description, role].compactMap(\.self)
            guard candidates.contains(where: { $0.contains(queryLower) }) else { continue }

            var score = 0
            if identifier == queryLower {
                score += 400
            }
            if label == queryLower {
                score += 350
            }
            if title == queryLower {
                score += 300
            }
            if value == queryLower {
                score += 200
            }

            if identifier?.contains(queryLower) == true {
                score += 200
            }
            if label?.contains(queryLower) == true {
                score += 160
            }
            if title?.contains(queryLower) == true {
                score += 120
            }
            if value?.contains(queryLower) == true {
                score += 80
            }
            if description?.contains(queryLower) == true {
                score += 50
            }

            if element.type.rawValue.lowercased() == queryLower {
                score += 40
            }
            if element.type == .button {
                score += 20
            }

            if score > bestScore {
                bestScore = score
                bestMatch = element
            } else if score == bestScore, let currentBest = bestMatch {
                // Deterministic tie-break: prefer lower (smaller y) matches.
                // This helps when SwiftUI reports multiple nodes with the same identifier.
                if element.bounds.origin.y < currentBest.bounds.origin.y {
                    bestMatch = element
                }
            }
        }

        return bestMatch
    }

    /// Find element by query string
    @MainActor
    private func findElementByQuery(_ query: String, targetProcessIdentifier: pid_t?) -> Element? {
        let queryLower = query.lowercased()

        guard let app = Self.querySearchApplication(
            targetProcessIdentifier: targetProcessIdentifier,
            applicationAtMouse: { MouseLocationUtilities.findApplicationAtMouseLocation() })
        else {
            return nil
        }

        let axApp = AXApp(app)
        let appElement = axApp.element

        // Search recursively
        return self.searchElement(in: appElement, matching: queryLower)
    }

    @MainActor
    static func querySearchApplication(
        targetProcessIdentifier: pid_t?,
        applicationAtMouse: () -> NSRunningApplication?) -> NSRunningApplication?
    {
        if let targetProcessIdentifier {
            return NSRunningApplication(processIdentifier: targetProcessIdentifier)
        }
        return applicationAtMouse()
    }

    @MainActor
    private func searchElement(in element: Element, matching query: String) -> Element? {
        // Check current element
        let title = element.title()?.lowercased() ?? ""
        let label = element.label()?.lowercased() ?? ""
        let value = element.stringValue()?.lowercased() ?? ""
        let roleDescription = element.roleDescription()?.lowercased() ?? ""

        if title.contains(query) || label.contains(query) ||
            value.contains(query) || roleDescription.contains(query)
        {
            return element
        }

        // Search children
        if let children = element.children() {
            for child in children {
                if let found = searchElement(in: child, matching: query) {
                    return found
                }
            }
        }

        return nil
    }

    /// Perform actual click at coordinates using AXorcist InputDriver.
    private func performClick(
        at point: CGPoint,
        clickType: ClickType,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) async throws
    {
        self.logger.debug("Performing \(clickType) click at (\(point.x), \(point.y))")

        switch clickType {
        case .single:
            try await self.performSyntheticClick(
                at: point,
                button: .left,
                count: 1,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        case .right:
            try await self.performSyntheticClick(
                at: point,
                button: .right,
                count: 1,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        case .double:
            try await self.performSyntheticClick(
                at: point,
                button: .left,
                count: 2,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        case .longPress:
            guard targetProcessIdentifier == nil else {
                throw PeekabooError.serviceUnavailable(
                    "Long press requires foreground delivery")
            }
            try await self.performLongPress(at: point)
        }
    }

    private func performSyntheticClick(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) async throws
    {
        if let targetProcessIdentifier {
            try await self.syntheticInputDriver.click(
                at: point,
                button: button,
                count: count,
                targetProcessIdentifier: targetProcessIdentifier,
                targetWindowID: targetWindowID)
        } else {
            try self.syntheticInputDriver.click(at: point, button: button, count: count)
        }
    }

    private func performLongPress(at point: CGPoint) async throws {
        try self.syntheticInputDriver.move(to: point)
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
        try await self.syntheticInputDriver.pressHold(at: point, button: .left, duration: 1.2)
    }
}

// MARK: - Extensions for ClickType

// CustomStringConvertible conformance is now in PeekabooFoundation
