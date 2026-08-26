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
 *     snapshotId: "ps1_0123456789abcdef0123456789abcdef"
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
private struct SyntheticClickDestination {
    let captureReceipt: DesktopOperationPlan.CaptureReceipt
    let validatesProcessIdentity: Bool

    var processIdentifier: pid_t? {
        self.captureReceipt.processIdentifier
    }

    var windowID: CGWindowID? {
        self.captureReceipt.exactWindow.flatMap { CGWindowID(exactly: $0.identity.windowID) }
    }
}

private struct ClickExecutionRequest: Sendable {
    let target: ClickTarget
    let clickType: ClickType
    let snapshotID: String?
    let automationTarget: UIAutomationTarget
    let validatesProcessIdentity: Bool
    let allowsAccessibilityValueDelivery: Bool
    let acquireLane: Bool
    let lanePreparation: @MainActor @Sendable () async -> Void
    let laneCompletion: @MainActor @Sendable (UIInputExecutionResult) async -> Void
}

typealias TabSelectionVerifier = @MainActor (AutomationElement, Int?) async throws -> Bool
typealias ExactWindowPixelFocusExecutor = @MainActor @Sendable (
    CGPoint,
    UIAutomationTarget.ExactWindow) async throws -> UIInputExecutionResult.Action

private func validatedClickWindowID(_ windowID: Int?) throws -> CGWindowID? {
    guard let windowID else { return nil }
    guard windowID > 0, let cgWindowID = CGWindowID(exactly: windowID) else {
        throw PeekabooError.invalidInput("Target window identifier is outside the valid UInt32 range")
    }
    return cgWindowID
}

private func isClickTargetProcessAlive(_ processIdentifier: pid_t) -> Bool {
    kill(processIdentifier, 0) == 0 || errno == EPERM
}

private func clickPostDispatchFailure(
    outcome: DesktopActionOutcome,
    message: String,
    cause: any Error) -> DesktopActionFailure
{
    DesktopActionFailure(
        outcome: outcome,
        message: message,
        hint: "Observe the target before retrying this click.",
        causeDescription: cause.localizedDescription) ?? .indeterminate(
        delivery: outcome.delivery,
        evidence: .completionUnknown,
        unitCount: outcome.dispatchState.unitCount,
        message: message,
        hint: "Observe the target before retrying this click.",
        causeDescription: cause.localizedDescription)
}

@MainActor
public final class ClickService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ClickService")
    private let snapshotManager: any SnapshotManagerProtocol
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let syntheticInputDriver: any SyntheticInputDriving
    private let automationElementResolver: any AutomationElementResolving
    private let exactWindowIdentityValidator: @Sendable (WindowMutationIdentity, CGRect) -> Bool
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let desktopOperationExecutor: DesktopOperationExecutor
    private let operationFinalizer: @MainActor () -> Void
    private let tabSelectionVerifier: TabSelectionVerifier
    private let exactWindowPixelFocusExecutor: ExactWindowPixelFocusExecutor

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
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver(),
        exactWindowIdentityValidator: @escaping @Sendable (WindowMutationIdentity, CGRect) -> Bool =
            SystemIdentityResolver.validateWindowMutationIdentity,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        desktopOperationExecutor: DesktopOperationExecutor = DesktopOperationExecutor(),
        operationFinalizer: @escaping @MainActor () -> Void = {},
        tabSelectionVerifier: @escaping TabSelectionVerifier = ClickService.verifyTabSelection,
        exactWindowPixelFocusExecutor: @escaping ExactWindowPixelFocusExecutor = { point, exactWindow in
            try await BackgroundInputDriver.focus(at: point, exactWindow: exactWindow)
        })
    {
        self.snapshotManager = snapshotManager ?? SnapshotManager()
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
        self.exactWindowIdentityValidator = exactWindowIdentityValidator
        self.processStartIdentityProvider = processStartIdentityProvider
        self.desktopOperationExecutor = desktopOperationExecutor
        self.operationFinalizer = operationFinalizer
        self.tabSelectionVerifier = tabSelectionVerifier
        self.exactWindowPixelFocusExecutor = exactWindowPixelFocusExecutor
    }

    private static func verifyTabSelection(_ element: AutomationElement, valueBefore: Int?) async throws -> Bool {
        guard element.subrole == "AXTabButton", valueBefore == 0 else { return false }
        try await Task.sleep(for: .milliseconds(50))
        return ActionInputDriver.tabPressDidNotSelect(
            subrole: element.subrole,
            valueBefore: valueBefore,
            valueAfter: element.intAttribute(AXAttributeNames.kAXValueAttribute))
    }

    // MARK: - Private Methods

    private func performActionClick(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        captureReceipt: DesktopOperationPlan.CaptureReceipt,
        validatesProcessIdentity: Bool,
        allowsAccessibilityValueDelivery: Bool) async throws -> UIInputExecutionResult.Action
    {
        let targetProcessIdentifier = captureReceipt.processIdentifier
        guard let element = try await self.resolveAutomationElement(
            target: target,
            snapshotId: snapshotId,
            targetProcessIdentifier: targetProcessIdentifier)
        else {
            throw ActionInputError.unsupported(.missingElement)
        }

        try self.requireCurrentTarget(
            captureReceipt,
            afterDispatch: false,
            validateProcessIdentity: validatesProcessIdentity)
        switch clickType {
        case .single:
            let valueBefore = element.intAttribute(AXAttributeNames.kAXValueAttribute)
            let result = try self.actionInputDriver.tryClick(
                element: element,
                allowAccessibilityValueFallback: allowsAccessibilityValueDelivery)
            if let focusedElement = result.focusedElement,
               let exactWindow = captureReceipt.exactWindow
            {
                do {
                    try Self.validateFocusedElement(focusedElement, exactWindow: exactWindow)
                } catch {
                    guard result.outcome.dispatchState.mutationDispatched else { throw error }
                    throw clickPostDispatchFailure(
                        outcome: result.outcome,
                        message: "Element focus was dispatched outside the exact target receipt",
                        cause: error)
                }
            }
            let tabPressDidNotSelect: Bool
            do {
                tabPressDidNotSelect = try await self.tabSelectionVerifier(element, valueBefore)
            } catch {
                guard result.outcome.dispatchState.mutationDispatched else { throw error }
                throw Self.unconfirmedTabPressFailure(result, cause: error)
            }
            if tabPressDidNotSelect {
                guard result.outcome.dispatchState.mutationDispatched else {
                    throw ActionInputError.unsupported(.actionUnsupported)
                }
                throw Self.unconfirmedTabPressFailure(result)
            }
            return result
        case .right:
            return try await self.actionInputDriver.tryRightClick(element: element)
        case .double:
            throw ActionInputError.unsupported(.actionUnsupported)
        case .middle, .triple:
            throw ActionInputError.unsupported(.actionUnsupported)
        case .longPress:
            throw ActionInputError.unsupported(.actionUnsupported)
        }
    }

    private static func validateFocusedElement(
        _ focusedElement: FocusedElementIdentity,
        exactWindow: UIAutomationTarget.ExactWindow) throws
    {
        guard focusedElement.processIdentifier == exactWindow.identity.ownerProcessIdentifier else {
            throw FocusedElementReceiptError.processMismatch
        }
        guard focusedElement.windowID == exactWindow.identity.windowID else {
            throw FocusedElementReceiptError.windowMismatch
        }
        guard exactWindow.bounds.contains(CGPoint(
            x: focusedElement.frame.midX,
            y: focusedElement.frame.midY))
        else {
            throw FocusedElementReceiptError.elementOutsideWindow
        }
    }

    private static func unconfirmedTabPressFailure(
        _ result: UIInputExecutionResult.Action,
        cause: (any Error)? = nil) -> DesktopActionFailure
    {
        .indeterminate(
            delivery: result.outcome.delivery,
            evidence: .completionUnknown,
            unitCount: result.outcome.dispatchState.unitCount ?? .one,
            message: "Accessibility tab press was accepted but selection could not be confirmed",
            hint: "Observe the target tab before taking another click action.",
            causeDescription: cause?.localizedDescription)
    }

    private func performSyntheticClick(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        destination: SyntheticClickDestination) async throws -> DesktopActionOutcome
    {
        switch target {
        case let .elementId(id):
            try await self.clickElementById(
                id: id,
                clickType: clickType,
                snapshotId: snapshotId,
                destination: destination)

        case let .coordinates(point):
            try await self.performClick(
                at: point,
                clickType: clickType,
                destination: destination)

        case let .query(query):
            try await self.clickElementByQuery(
                query: query,
                clickType: clickType,
                snapshotId: snapshotId,
                destination: destination)
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
            guard !element.isOCRSemanticEvidence else {
                throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
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
        requestedTargetWindowID: Int?,
        captureReceipt: DesktopOperationPlan.CaptureReceipt) async throws -> CGWindowID?
    {
        let requestedCGWindowID = try validatedClickWindowID(requestedTargetWindowID)
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

        guard isClickTargetProcessAlive(targetProcessIdentifier) else {
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
        let snapshotCGWindowID = try validatedClickWindowID(snapshotWindowID)
        if captureReceipt.exactWindow != nil {
            do {
                try DesktopOperationSnapshotReceiptValidator.validate(
                    context: detectionResult.metadata.windowContext,
                    receipt: captureReceipt,
                    validateCurrentIdentity: false,
                    processStartIdentityProvider: self.processStartIdentityProvider,
                    exactWindowIdentityValidator: self.exactWindowIdentityValidator)
            } catch {
                throw PeekabooError.snapshotStale(
                    "Exact-window click snapshot receipt or bounds no longer match the dispatch target")
            }
        }
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

    private func clickElementById(
        id: String,
        clickType: ClickType,
        snapshotId: String?,
        destination: SyntheticClickDestination) async throws -> DesktopActionOutcome
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
        guard !element.isOCRSemanticEvidence else {
            throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
        }
        try self.requireExactWindowForTargetedSynthesis(
            targetProcessIdentifier: destination.processIdentifier,
            targetWindowID: destination.windowID)
        let center = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        let adjusted = try await self.resolveAdjustedPoint(center, snapshotId: snapshotId)
        let outcome = try await self.performClick(
            at: adjusted,
            clickType: clickType,
            destination: destination)
        do {
            try await self.nudgeTextInputFocusIfNeeded(
                afterClickAt: adjusted,
                clickType: clickType,
                expectedIdentifier: element.attributes["identifier"],
                targetProcessIdentifier: destination.processIdentifier)
        } catch {
            throw clickPostDispatchFailure(
                outcome: outcome,
                message: "Click was dispatched, but post-click focus validation failed",
                cause: error)
        }
        self.logger.debug("Clicked element \(id) at (\(adjusted.x), \(adjusted.y))")
        return outcome
    }

    @MainActor
    private func clickElementByQuery(
        query: String,
        clickType: ClickType,
        snapshotId: String?,
        destination: SyntheticClickDestination) async throws -> DesktopActionOutcome
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
                targetProcessIdentifier: destination.processIdentifier)
            if let element, let frame = element.frame {
                found = true
                clickFrame = frame
                self.logger.debug("Found element via AX search matching query: \(query)")
            }
        }

        // Perform click if element found
        if found, let frame = clickFrame {
            try self.requireExactWindowForTargetedSynthesis(
                targetProcessIdentifier: destination.processIdentifier,
                targetWindowID: destination.windowID)
            let center = CGPoint(x: frame.midX, y: frame.midY)
            let adjusted = try await self.resolveAdjustedPoint(
                center,
                snapshotId: resolvedElement != nil ? snapshotId : nil)
            let outcome = try await self.performClick(
                at: adjusted,
                clickType: clickType,
                destination: destination)
            do {
                try await self.nudgeTextInputFocusIfNeeded(
                    afterClickAt: adjusted,
                    clickType: clickType,
                    expectedIdentifier: resolvedElement?.attributes["identifier"],
                    targetProcessIdentifier: destination.processIdentifier)
            } catch {
                throw clickPostDispatchFailure(
                    outcome: outcome,
                    message: "Click was dispatched, but post-click focus validation failed",
                    cause: error)
            }
            self.logger.debug("Clicked element matching '\(query)' at (\(adjusted.x), \(adjusted.y))")
            return outcome
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
            _ = try await self.performClick(
                at: candidate,
                clickType: .single,
                destination: SyntheticClickDestination(
                    captureReceipt: DesktopOperationPlan.CaptureReceipt(target: .foreground),
                    validatesProcessIdentity: false))
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

        for element in detectionResult.elements.all where element.isEnabled && !element.isOCRSemanticEvidence {
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
        destination: SyntheticClickDestination) async throws -> DesktopActionOutcome
    {
        self.logger.debug("Performing \(clickType) click at (\(point.x), \(point.y))")

        try self.requireCurrentTarget(
            destination.captureReceipt,
            afterDispatch: false,
            validateProcessIdentity: destination.validatesProcessIdentity,
            validateExactWindow: clickType != .longPress)
        switch clickType {
        case .single:
            return try await self.performSyntheticClick(
                at: point,
                button: .left,
                count: 1,
                destination: destination)
        case .right:
            return try await self.performSyntheticClick(
                at: point,
                button: .right,
                count: 1,
                destination: destination)
        case .double:
            return try await self.performSyntheticClick(
                at: point,
                button: .left,
                count: 2,
                destination: destination)
        case .middle:
            return try await self.performSyntheticClick(
                at: point,
                button: .middle,
                count: 1,
                destination: destination)
        case .triple:
            return try await self.performSyntheticClick(
                at: point,
                button: .left,
                count: 3,
                destination: destination)
        case .longPress:
            guard destination.processIdentifier == nil else {
                throw PeekabooError.serviceUnavailable(
                    "Long press requires foreground delivery")
            }
            try await self.performLongPress(at: point)
            return .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted)
        }
    }

    private func performSyntheticClick(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        destination: SyntheticClickDestination) async throws -> DesktopActionOutcome
    {
        if let targetProcessIdentifier = destination.processIdentifier {
            if let exactWindowReceipt = destination.captureReceipt.exactWindow {
                try await self.syntheticInputDriver.click(
                    at: point,
                    button: button,
                    count: count,
                    target: ExactWindowPointerTarget(
                        identity: exactWindowReceipt.identity,
                        bounds: exactWindowReceipt.bounds))
            } else {
                try await self.syntheticInputDriver.click(
                    at: point,
                    button: button,
                    count: count,
                    targetProcessIdentifier: targetProcessIdentifier,
                    targetWindowID: destination.windowID)
            }
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

extension ClickService {
    /// Establishes one exact-window focused-element receipt while the caller owns the process lane.
    ///
    /// This is intentionally separate from `clickOwned`: normal click resolution may press buttons
    /// or select rows, while a typing prelude may only write AXFocused on an editable element.
    func focusExactWindowPixelOwned(
        at point: CGPoint,
        exactWindow: UIAutomationTarget.ExactWindow) async throws
        -> UIAutomationActionResult<FocusedElementIdentity>
    {
        let targetIdentity = DesktopTargetIdentity(exactWindow: exactWindow)
        guard self.exactWindowIdentityValidator(exactWindow.identity, exactWindow.bounds) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Pixel-focus exact-window receipt is stale.")
                .attributed(to: targetIdentity.actionTargetReceipt)
        }

        let action = try await self.exactWindowPixelFocusExecutor(point, exactWindow)
        guard let focusedElement = action.focusedElement else {
            throw DesktopActionFailure.indeterminate(
                delivery: action.outcome.delivery,
                evidence: .completionUnknown,
                unitCount: action.outcome.dispatchState.unitCount,
                message: "Pixel focus completed without an exact focused-element receipt.",
                hint: "Observe the exact target before deciding whether to retry typing.")
                .attributed(to: targetIdentity.actionTargetReceipt)
        }
        do {
            try Self.validateFocusedElement(focusedElement, exactWindow: exactWindow)
            guard self.exactWindowIdentityValidator(exactWindow.identity, exactWindow.bounds) else {
                throw PeekabooError.snapshotStale("Pixel-focus exact-window receipt changed after dispatch")
            }
        } catch {
            throw clickPostDispatchFailure(
                outcome: action.outcome,
                message: "Pixel focus was dispatched, but its exact target could not be revalidated",
                cause: error)
                .attributed(to: targetIdentity.actionTargetReceipt)
        }
        return UIAutomationActionResult(
            payload: focusedElement,
            outcome: action.outcome,
            targetIdentity: targetIdentity)
    }

    func focusExactElementWithOutcome(
        target: ClickTarget,
        snapshotId: String,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<FocusedElementIdentity>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: expectedWindowIdentity,
            bounds: expectedWindowBounds)
        let captureReceipt = DesktopOperationPlan.CaptureReceipt(
            snapshotID: snapshotId,
            target: .exactWindow(exactWindow))
        var resolvedElement: AutomationElement?
        var expectedElementIdentity: FocusedElementIdentity?
        var focusedElementReceipt: FocusedElementIdentity?
        let plan = try DesktopOperationPlan(
            verb: .click,
            selector: .click(target),
            captureReceipt: captureReceipt,
            strategy: .actionOnly,
            prepare: {
                _ = try await self.validateSnapshotTarget(
                    target: target,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier,
                    requestedTargetWindowID: expectedWindowIdentity.windowID,
                    captureReceipt: captureReceipt)
                try self.requireCurrentTarget(
                    captureReceipt,
                    afterDispatch: false,
                    validateProcessIdentity: true)
                guard let element = try await self.resolveAutomationElement(
                    target: target,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: expectedWindowIdentity.ownerProcessIdentifier)
                else {
                    throw ActionInputError.unsupported(.missingElement)
                }
                guard let detection = try await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
                      let detectedElement = Self.resolveSnapshotTarget(target, in: detection),
                      let windowContext = detection.metadata.windowContext
                else {
                    throw ActionInputError.staleElement
                }
                let capturedElementIdentity = try FocusedElementReceiptResolver.receipt(
                    element: detectedElement,
                    context: windowContext)
                guard let identity = element.focusedElementIdentity else {
                    throw FocusedElementReceiptError.missingWindowIdentifier
                }
                try Self.validateFocusedElement(identity, exactWindow: exactWindow)
                try FocusedElementReceiptResolver.validate(identity, matches: capturedElementIdentity)
                resolvedElement = element
                expectedElementIdentity = capturedElementIdentity
            },
            action: DesktopOperationPlan.ActionRoute {
                guard let element = resolvedElement,
                      let expectedElementIdentity
                else {
                    throw PeekabooError.operationError(message: "Exact focus target was not prepared")
                }
                let result = try self.actionInputDriver.tryFocus(element: element)
                guard let focusedElement = result.focusedElement else {
                    throw FocusedElementReceiptError.focusNotConfirmed
                }
                try Self.validateFocusedElement(focusedElement, exactWindow: exactWindow)
                try FocusedElementReceiptResolver.validate(focusedElement, matches: expectedElementIdentity)
                focusedElementReceipt = focusedElement
                return result
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                throw PeekabooError.serviceUnavailable(
                    "Exact semantic focus never falls back to synthetic pointer input")
            },
            postvalidate: { result in
                do {
                    try self.requireCurrentTarget(
                        captureReceipt,
                        afterDispatch: true,
                        validateProcessIdentity: true)
                    guard let element = resolvedElement,
                          element.isFocused,
                          let actual = element.focusedElementIdentity,
                          let reported = focusedElementReceipt
                    else {
                        throw FocusedElementReceiptError.focusNotConfirmed
                    }
                    try Self.validateFocusedElement(actual, exactWindow: exactWindow)
                    try FocusedElementReceiptResolver.validate(actual, matches: reported)
                } catch {
                    guard result.outcome.dispatchState.mutationDispatched else {
                        throw error
                    }
                    throw clickPostDispatchFailure(
                        outcome: result.outcome,
                        message: "Element focus was dispatched, but its exact receipt could not be revalidated",
                        cause: error)
                }
            },
            finalize: self.operationFinalizer)
        let result = try await self.desktopOperationExecutor.execute(plan)
        guard let focusedElement = focusedElementReceipt else {
            throw FocusedElementReceiptError.focusNotConfirmed
        }
        let focusedTarget = try UIAutomationTarget.ExactWindow(
            identity: exactWindow.identity,
            bounds: exactWindow.bounds,
            focusedElement: focusedElement)
        return UIAutomationActionResult(
            payload: focusedElement,
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: focusedTarget))
    }

    fileprivate static func automationTarget(
        targetProcessIdentifier: pid_t?,
        expectedProcessIdentity: ApplicationProcessIdentity?,
        targetWindowID: Int?,
        expectedWindowIdentity: WindowMutationIdentity?,
        expectedWindowBounds: CGRect?) throws -> UIAutomationTarget
    {
        guard let targetWindowID else {
            guard expectedWindowIdentity == nil, expectedWindowBounds == nil else {
                throw PeekabooError.invalidInput(
                    "Exact-window click identity and bounds require a target window ID")
            }
            if let targetProcessIdentifier {
                return try .process(UIAutomationTarget.Process(
                    processIdentifier: targetProcessIdentifier,
                    identity: expectedProcessIdentity))
            }
            if let expectedProcessIdentity {
                return try .process(UIAutomationTarget.Process(
                    processIdentifier: expectedProcessIdentity.processIdentifier,
                    identity: expectedProcessIdentity))
            }
            return .foreground
        }
        guard let targetProcessIdentifier,
              let expectedWindowIdentity,
              let expectedWindowBounds
        else {
            throw PeekabooError.snapshotStale(
                "Exact-window click requires its capture-time process-generation receipt and bounds")
        }
        let exactWindow = try UIAutomationTarget.ExactWindow(
            processIdentifier: targetProcessIdentifier,
            windowID: targetWindowID,
            identity: expectedWindowIdentity,
            bounds: expectedWindowBounds)
        if let expectedProcessIdentity,
           expectedProcessIdentity != expectedWindowIdentity.processIdentity
        {
            throw PeekabooError.snapshotStale(
                "Process and exact-window receipts refer to different process generations")
        }
        return .exactWindow(exactWindow)
    }

    private func resolvedExactWindowReceipt(
        _ requested: DesktopOperationPlan.ExactWindowReceipt?,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        targetWindowID: CGWindowID?) async throws -> DesktopOperationPlan.ExactWindowReceipt?
    {
        if let requested {
            return requested
        }
        guard let targetWindowID, let targetProcessIdentifier else { return nil }
        guard let snapshotId,
              let detection = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
              detection.metadata.windowContext != nil
        else {
            throw PeekabooError.snapshotStale(
                "Exact-window click snapshot has no capture-time process-generation receipt and bounds")
        }
        do {
            let receipt = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotId,
                detectionResult: detection,
                additionalEvidence: [
                    .init(
                        processIdentifier: targetProcessIdentifier,
                        windowID: Int(targetWindowID)),
                ]).receipt
            guard let exactWindow = try receipt.requireIdentity().exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        } catch let error as DesktopTargetIdentityError {
            throw SnapshotTargetReceiptPreDispatchError(error)
        }
    }

    private func requireCurrentTarget(
        _ receipt: DesktopOperationPlan.CaptureReceipt,
        afterDispatch: Bool,
        validateProcessIdentity: Bool,
        validateExactWindow: Bool = true) throws
    {
        let mismatch = DesktopOperationSnapshotReceiptValidator.currentIdentityMismatch(
            receipt: receipt,
            validateProcessIdentity: validateProcessIdentity,
            validateExactWindow: validateExactWindow,
            processStartIdentityProvider: self.processStartIdentityProvider,
            exactWindowIdentityValidator: self.exactWindowIdentityValidator)
        switch mismatch {
        case .processGeneration:
            if afterDispatch {
                throw InputDeliveryIndeterminateError(
                    operation: .click,
                    emittedUnitCount: 1,
                    causeDescription: "The target process changed generation before completion validation")
            }
            throw PeekabooError.invalidInput(
                "Background click target process exited or changed process generation before final dispatch")
        case .exactWindow:
            if afterDispatch {
                throw InputDeliveryIndeterminateError(
                    operation: .click,
                    causeDescription: "The exact window changed before completion validation")
            }
            throw PeekabooError.snapshotStale(
                "Exact-window click identity changed before final dispatch; capture a fresh snapshot")
        case nil:
            return
        }
    }
}

extension ClickService {
    /// Perform a click operation.
    @discardableResult
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
    public func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t?,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil,
        targetWindowID: Int? = nil,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        expectedWindowBounds: CGRect? = nil) async throws -> UIInputExecutionResult
    {
        let automationTarget = try Self.automationTarget(
            targetProcessIdentifier: targetProcessIdentifier,
            expectedProcessIdentity: expectedProcessIdentity,
            targetWindowID: targetWindowID,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
        return try await self.click(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            automationTarget: automationTarget,
            validatesProcessIdentity: expectedProcessIdentity != nil)
    }

    func click(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        automationTarget: UIAutomationTarget,
        validatesProcessIdentity: Bool = false,
        allowsAccessibilityValueDelivery: Bool = true) async throws -> UIInputExecutionResult
    {
        try await self.executeClick(ClickExecutionRequest(
            target: target,
            clickType: clickType,
            snapshotID: snapshotId,
            automationTarget: automationTarget,
            validatesProcessIdentity: validatesProcessIdentity,
            allowsAccessibilityValueDelivery: allowsAccessibilityValueDelivery,
            acquireLane: true,
            lanePreparation: {},
            laneCompletion: { _ in }))
    }

    func clickWithLanePreparation(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        lanePreparation: @escaping @MainActor @Sendable () async -> Void,
        laneCompletion: @escaping @MainActor @Sendable (UIInputExecutionResult) async -> Void = { _ in })
        async throws -> UIInputExecutionResult
    {
        try await self.executeClick(ClickExecutionRequest(
            target: target,
            clickType: clickType,
            snapshotID: snapshotId,
            automationTarget: .foreground,
            validatesProcessIdentity: false,
            allowsAccessibilityValueDelivery: true,
            acquireLane: true,
            lanePreparation: lanePreparation,
            laneCompletion: laneCompletion))
    }

    func clickOwned(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws
        -> UIInputExecutionResult
    {
        try await self.clickOwned(
            target: target,
            clickType: clickType,
            snapshotId: snapshotId,
            automationTarget: .foreground,
            validatesProcessIdentity: false)
    }

    /// Executes a click while the caller retains the target's desktop-operation lane.
    ///
    /// Composite operations use this overload so exact-window preflight, dispatch, and
    /// postvalidation remain identical to a standalone click without recursively acquiring the
    /// same process lane.
    func clickOwned(
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        automationTarget: UIAutomationTarget,
        validatesProcessIdentity: Bool) async throws -> UIInputExecutionResult
    {
        try await self.executeClick(ClickExecutionRequest(
            target: target,
            clickType: clickType,
            snapshotID: snapshotId,
            automationTarget: automationTarget,
            validatesProcessIdentity: validatesProcessIdentity,
            allowsAccessibilityValueDelivery: true,
            acquireLane: false,
            lanePreparation: {},
            laneCompletion: { _ in }))
    }

    private func executeClick(_ request: ClickExecutionRequest) async throws -> UIInputExecutionResult {
        let target = request.target
        let clickType = request.clickType
        let snapshotID = request.snapshotID
        let targetProcessIdentifier = request.automationTarget.processIdentifier
        let validatesProcessIdentity = request.validatesProcessIdentity
        self.logger.debug("Click requested - target: \(String(describing: target)), type: \(clickType)")
        if targetProcessIdentifier != nil,
           request.automationTarget.exactWindow == nil,
           case .coordinates = target
        {
            throw PeekabooError.invalidInput(
                "Background coordinate clicks require an exact capture-time window receipt; " +
                    "PID-only coordinate routing is refused")
        }
        if targetProcessIdentifier != nil,
           request.automationTarget.exactWindow == nil,
           clickType.requiresStatelessVariantSupport
        {
            throw PeekabooError.invalidInput(
                "Background middle- and triple-clicks require an exact capture-time window receipt")
        }
        let requestedExactWindowReceipt = request.automationTarget.exactWindow
        let requestedCaptureReceipt = DesktopOperationPlan.CaptureReceipt(
            snapshotID: snapshotID,
            target: request.automationTarget)
        var bundleIdentifier: String?
        var strategy = self.inputPolicy.strategy(for: .click)
        var mutationReceipt: DesktopOperationPlan.CaptureReceipt?
        var syntheticDestination: SyntheticClickDestination?
        do {
            let plan = try DesktopOperationPlan(
                verb: .click,
                selector: .click(target),
                captureReceipt: requestedCaptureReceipt,
                strategy: strategy,
                prepare: {
                    bundleIdentifier = await self.bundleIdentifier(
                        snapshotId: snapshotID,
                        targetProcessIdentifier: targetProcessIdentifier)
                    strategy = self.inputPolicy.strategy(for: .click, bundleIdentifier: bundleIdentifier)
                    await request.lanePreparation()
                    let exactTargetWindowID = try await self.validateSnapshotTarget(
                        target: target,
                        snapshotId: snapshotID,
                        targetProcessIdentifier: targetProcessIdentifier,
                        requestedTargetWindowID: requestedExactWindowReceipt?.identity.windowID,
                        captureReceipt: requestedCaptureReceipt)
                    let exactWindowReceipt = try await self.resolvedExactWindowReceipt(
                        requestedExactWindowReceipt,
                        snapshotId: snapshotID,
                        targetProcessIdentifier: targetProcessIdentifier,
                        targetWindowID: exactTargetWindowID)
                    let preparedTarget: UIAutomationTarget = if let exactWindowReceipt {
                        try request.automationTarget.refined(to: exactWindowReceipt)
                    } else {
                        request.automationTarget
                    }
                    let preparedReceipt = DesktopOperationPlan.CaptureReceipt(
                        snapshotID: snapshotID,
                        target: preparedTarget)
                    try self.requireCurrentTarget(
                        preparedReceipt,
                        afterDispatch: false,
                        validateProcessIdentity: validatesProcessIdentity,
                        validateExactWindow: false)
                    mutationReceipt = preparedReceipt
                    syntheticDestination = SyntheticClickDestination(
                        captureReceipt: preparedReceipt,
                        validatesProcessIdentity: validatesProcessIdentity)
                },
                routing: {
                    DesktopOperationPlan.Routing(
                        strategy: strategy,
                        bundleIdentifier: bundleIdentifier)
                },
                action: DesktopOperationPlan.ActionRoute {
                    guard let mutationReceipt else {
                        throw PeekabooError.operationError(message: "Click target was not prepared")
                    }
                    do {
                        return try await self.performActionClick(
                            target: target,
                            clickType: clickType,
                            snapshotId: snapshotID,
                            captureReceipt: mutationReceipt,
                            validatesProcessIdentity: validatesProcessIdentity,
                            allowsAccessibilityValueDelivery: request.allowsAccessibilityValueDelivery)
                    } catch let error as ActionInputError
                        where strategy == .actionFirst &&
                        targetProcessIdentifier != nil &&
                        (error == .permissionDenied || error == .targetUnavailable)
                    {
                        throw ActionInputError.unsupported(.actionUnsupported)
                    }
                },
                synthesis: DesktopOperationPlan.SynthesisRoute {
                    guard let syntheticDestination else {
                        throw PeekabooError.operationError(message: "Click destination was not prepared")
                    }
                    return try await self.performSyntheticClick(
                        target: target,
                        clickType: clickType,
                        snapshotId: snapshotID,
                        destination: syntheticDestination)
                },
                postvalidate: { result in
                    do {
                        guard let mutationReceipt else {
                            throw PeekabooError.operationError(message: "Click target was not prepared")
                        }
                        try self.requireCurrentTarget(
                            mutationReceipt,
                            afterDispatch: true,
                            validateProcessIdentity: validatesProcessIdentity)
                    } catch {
                        throw clickPostDispatchFailure(
                            outcome: result.outcome,
                            message: "Click was dispatched, but final target identity validation failed",
                            cause: error)
                    }
                },
                success: request.laneCompletion,
                finalize: {
                    if request.acquireLane {
                        self.operationFinalizer()
                    }
                })
            let result = if request.acquireLane {
                try await self.desktopOperationExecutor.execute(plan)
            } else {
                try await self.desktopOperationExecutor.executeOwned(plan)
            }
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
}

// MARK: - Extensions for ClickType

// CustomStringConvertible conformance is now in PeekabooFoundation
