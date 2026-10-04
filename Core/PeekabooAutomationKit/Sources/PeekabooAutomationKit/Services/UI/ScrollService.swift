import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

private func scrollPostDispatchFailure(
    outcome: DesktopActionOutcome,
    cause: any Error) -> DesktopActionFailure
{
    DesktopActionFailure(
        outcome: outcome,
        message: "Scroll was dispatched, but final target identity validation failed",
        hint: "Observe the target before retrying this scroll.",
        causeDescription: cause.localizedDescription) ?? .indeterminate(
        delivery: outcome.delivery,
        evidence: .completionUnknown,
        unitCount: outcome.dispatchState.unitCount,
        message: "Scroll completion is indeterminate after target identity drift",
        hint: "Observe the target before retrying this scroll.",
        causeDescription: cause.localizedDescription)
}

/// Service for handling scroll operations
@MainActor
public final class ScrollService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ScrollService")
    private let snapshotManager: any SnapshotManagerProtocol
    private let clickService: ClickService
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let syntheticInputDriver: any SyntheticInputDriving
    private let automationElementResolver: any AutomationElementResolving
    private let windowRoutedPointerDriver: WindowRoutedPointerDriver
    private let backgroundWheelCapability: @MainActor (pid_t) -> Bool
    private let exactWindowIdentityValidator: @Sendable (WindowMutationIdentity, CGRect) -> Bool
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    private let desktopOperationExecutor: DesktopOperationExecutor
    private let operationFinalizer: @MainActor () -> Void

    public convenience init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        clickService: ClickService? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior)
    {
        self.init(
            snapshotManager: snapshotManager,
            clickService: clickService,
            inputPolicy: inputPolicy,
            actionInputDriver: ActionInputDriver(),
            syntheticInputDriver: SyntheticInputDriver(),
            automationElementResolver: AutomationElementResolver())
    }

    init(
        snapshotManager: (any SnapshotManagerProtocol)? = nil,
        clickService: ClickService? = nil,
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        syntheticInputDriver: any SyntheticInputDriving = SyntheticInputDriver(),
        automationElementResolver: any AutomationElementResolving = AutomationElementResolver(),
        windowRoutedPointerDriver: WindowRoutedPointerDriver = WindowRoutedPointerDriver(),
        backgroundWheelCapability: @escaping @MainActor (pid_t) -> Bool =
            WindowRoutedApplicationClassifier.supportsBackgroundWheelScroll,
        exactWindowIdentityValidator: @escaping @Sendable (WindowMutationIdentity, CGRect) -> Bool =
            SystemIdentityResolver.validateWindowMutationIdentity,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        desktopOperationExecutor: DesktopOperationExecutor = DesktopOperationExecutor(),
        operationFinalizer: @escaping @MainActor () -> Void = {})
    {
        let manager = snapshotManager ?? SnapshotManager()
        self.snapshotManager = manager
        self.clickService = clickService ?? ClickService(
            snapshotManager: manager,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver,
            desktopOperationExecutor: desktopOperationExecutor,
            operationFinalizer: operationFinalizer)
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
        self.windowRoutedPointerDriver = windowRoutedPointerDriver
        self.backgroundWheelCapability = backgroundWheelCapability
        self.exactWindowIdentityValidator = exactWindowIdentityValidator
        self.processStartIdentityProvider = processStartIdentityProvider
        self.desktopOperationExecutor = desktopOperationExecutor
        self.operationFinalizer = operationFinalizer
    }

    /// Perform scroll operation
    @discardableResult
    @MainActor
    public func scroll(_ request: ScrollRequest) async throws -> UIInputExecutionResult {
        try await self.scrollWithLanePreparation(request).payload
    }

    func scrollWithLanePreparation(
        _ request: ScrollRequest,
        lanePreparation: @escaping @MainActor () async -> Void = {},
        laneCompletion: @escaping @MainActor (UIInputExecutionResult) async -> Void = { _ in }) async throws
        -> UIAutomationActionResult<UIInputExecutionResult>
    {
        try request.validatePointSelector()
        try ScrollRequest.validateAmount(request.amount, smooth: request.smooth)
        self.logRequest(request)
        var bundleIdentifier: String?
        var preparedElement: AutomationElement?
        var preparedDetectedElement: DetectedElement?
        var preparedCoordinateTarget: ScrollCoordinateTarget?
        let strategy: UIInputStrategy = request.foreground ? .synthOnly : .actionOnly
        let captureReceipt: DesktopOperationPlan.CaptureReceipt
        if request.foreground {
            captureReceipt = DesktopOperationPlan.CaptureReceipt(
                snapshotID: request.snapshotId,
                target: .foreground)
        } else {
            guard let snapshotID = request.snapshotId,
                  request.point != nil || request.target?.trimmingCharacters(in: .whitespacesAndNewlines)
                      .isEmpty == false
            else {
                throw PeekabooError.snapshotStale(
                    "background scroll requires a target from a fresh exact-window snapshot")
            }
            let detectionResult = try await self.snapshotManager.getDetectionResult(snapshotId: snapshotID)
            captureReceipt = try DesktopOperationSnapshotReceiptValidator.captureReceipt(
                snapshotID: snapshotID,
                detectionResult: detectionResult,
                requireExactWindow: true,
                processStartIdentityProvider: self.processStartIdentityProvider,
                exactWindowIdentityValidator: self.exactWindowIdentityValidator)
            try Self.validateExpectedWindow(request.expectedWindow, captureReceipt: captureReceipt)
            if let point = request.point {
                try Self.validateCoordinateAuthority(
                    point: point,
                    snapshotID: snapshotID,
                    detectionResult: detectionResult)
            }
        }

        do {
            let plan = try DesktopOperationPlan(
                verb: .scroll,
                selector: request.point.map { .coordinates($0) } ?? .element(request.target),
                captureReceipt: captureReceipt,
                strategy: strategy,
                prepare: {
                    if request.foreground {
                        bundleIdentifier = await self.bundleIdentifier(snapshotId: request.snapshotId)
                    } else {
                        guard let snapshotID = captureReceipt.snapshotID else {
                            throw PeekabooError.snapshotStale("background scroll snapshot receipt was lost")
                        }
                        let detectionResult = try await self.validatedDetectionResult(
                            snapshotID: snapshotID, receipt: captureReceipt)
                        if let point = request.point, let exactWindow = captureReceipt.exactWindow {
                            let coordinateTarget = try self.resolveCoordinateTarget(
                                at: point,
                                target: exactWindow)
                            preparedCoordinateTarget = coordinateTarget
                            if case let .semanticOwner(element, _, _) = coordinateTarget {
                                preparedElement = element
                            }
                        } else {
                            let preparedTarget = try self.resolveActionScrollTarget(request, in: detectionResult)
                            preparedElement = preparedTarget.element
                            preparedDetectedElement = preparedTarget.detected
                        }
                        bundleIdentifier = captureReceipt.bundleIdentifier
                    }
                    await lanePreparation()
                },
                routing: {
                    DesktopOperationPlan.Routing(
                        strategy: strategy,
                        bundleIdentifier: bundleIdentifier)
                },
                action: DesktopOperationPlan.ActionRoute {
                    guard let snapshotID = captureReceipt.snapshotID
                    else {
                        throw ActionInputError.unsupported(.missingElement)
                    }
                    let detectionResult = try await self.validatedDetectionResult(
                        snapshotID: snapshotID, receipt: captureReceipt)
                    if let point = request.point, let exactWindow = captureReceipt.exactWindow {
                        let current = try self.resolveCoordinateTarget(
                            at: point,
                            target: exactWindow)
                        try Self.validateCoordinateTarget(
                            current, prepared: preparedCoordinateTarget, target: exactWindow)
                        if case .pixelOnly = current {
                            // Pixel authority names a window and point, never an invented AX receiver.
                            try Self.validateCoordinateAuthority(
                                point: point,
                                snapshotID: snapshotID,
                                detectionResult: detectionResult)
                            return try await self.performWindowRoutedScroll(
                                request, at: point, target: exactWindow, element: nil)
                        }
                    }
                    guard let preparedElement else {
                        throw ActionInputError.unsupported(.missingElement)
                    }
                    do {
                        return try self.actionInputDriver.tryScroll(
                            element: preparedElement,
                            direction: request.direction,
                            pages: Self.actionScrollPages(amount: request.amount, strategy: strategy),
                            scrollBarScope: request.point == nil ? .targetDescendants : .explicitOwner)
                    } catch let error as ActionInputError {
                        guard case .unsupported = error,
                              let exactWindow = captureReceipt.exactWindow,
                              let point = Self.windowRoutedWheelPoint(
                                  request: request,
                                  detectedElement: preparedDetectedElement,
                                  coordinateTarget: preparedCoordinateTarget,
                                  screenshotPath: detectionResult.screenshotPath)
                        else {
                            throw error
                        }
                        return try await self.performWindowRoutedScroll(
                            request, at: point, target: exactWindow, element: preparedElement, unavailableError: error)
                    }
                },
                synthesis: DesktopOperationPlan.SynthesisRoute {
                    let unitCount = try await self.performSyntheticScroll(request)
                    return Self.syntheticScrollOutcome(unitCount: unitCount)
                },
                postvalidate: { result in
                    guard !request.foreground, let snapshotID = captureReceipt.snapshotID else { return }
                    do {
                        _ = try await self.validatedDetectionResult(snapshotID: snapshotID, receipt: captureReceipt)
                    } catch {
                        throw scrollPostDispatchFailure(outcome: result.outcome, cause: error)
                    }
                },
                success: laneCompletion,
                finalize: self.operationFinalizer)
            let result = try await self.desktopOperationExecutor.executeWithTargetIdentity(plan)
            self.logger.debug("Scroll completed via \(result.payload.path.rawValue, privacy: .public)")
            return result
        } catch let error as ActionInputError
            where !request.foreground && error.allowsSynthesisFallback
        {
            throw Self.unsupportedBackgroundFailure(for: error, target: captureReceipt.exactWindow)
        }
    }

    private func resolveCoordinateTarget(
        at point: CGPoint,
        target: UIAutomationTarget.ExactWindow) throws -> ScrollCoordinateTarget
    {
        do {
            return try self.automationElementResolver.resolveScrollTarget(at: point, target: target)
        } catch let error as PeekabooError {
            guard case .snapshotStale = error else { throw error }
            throw Self.staleCoordinateTargetFailure(error.localizedDescription, target: target)
        }
    }

    private static func validateCoordinateTarget(
        _ current: ScrollCoordinateTarget,
        prepared: ScrollCoordinateTarget?,
        target: UIAutomationTarget.ExactWindow) throws
    {
        switch (prepared, current) {
        case let (.semanticOwner(previous, previousRole, previousBounds)?, .semanticOwner(element, role, bounds))
            where previous.element == element.element && previousRole == role && previousBounds == bounds:
            return
        case (.pixelOnly?, .pixelOnly):
            return
        default:
            throw self.staleCoordinateTargetFailure(
                "The owning scroller changed before coordinate scroll", target: target)
        }
    }

    private func performWindowRoutedScroll(
        _ request: ScrollRequest,
        at point: CGPoint,
        target: UIAutomationTarget.ExactWindow,
        element: AutomationElement?,
        unavailableError: ActionInputError = .unsupported(.actionUnsupported)) async throws
        -> UIInputExecutionResult.Action
    {
        guard self.backgroundWheelCapability(target.identity.ownerProcessIdentifier),
              let targetWindowID = CGWindowID(exactly: target.identity.windowID)
        else {
            throw unavailableError
        }
        let outcome = try await self.windowRoutedPointerDriver.scroll(
            at: point,
            direction: request.direction,
            ticks: Self.actionScrollPages(amount: request.amount, strategy: .actionOnly),
            targetProcessIdentifier: target.identity.ownerProcessIdentifier,
            targetWindowID: targetWindowID,
            expectedWindowIdentity: target.identity,
            expectedWindowBounds: target.bounds)
        return UIInputExecutionResult.Action(
            outcome: outcome,
            actionName: "WindowRoutedWheel",
            anchorPoint: point,
            elementRole: element?.role)
    }

    private static func staleCoordinateTargetFailure(
        _ message: String,
        target: UIAutomationTarget.ExactWindow) -> DesktopActionFailure
    {
        DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: message,
            hint: "Capture the exact window again before retrying coordinate scroll.",
            standardErrorCode: .snapshotStale)
            .attributed(to: DesktopTargetIdentity(exactWindow: target).actionTargetReceipt)
    }

    private func validatedDetectionResult(
        snapshotID: String,
        receipt: DesktopOperationPlan.CaptureReceipt) async throws -> ElementDetectionResult
    {
        guard let detection = try await self.snapshotManager.getDetectionResult(snapshotId: snapshotID) else {
            throw PeekabooError.snapshotStale("background scroll snapshot is no longer available")
        }
        try DesktopOperationSnapshotReceiptValidator.validate(
            detectionResult: detection,
            receipt: receipt,
            processStartIdentityProvider: self.processStartIdentityProvider,
            exactWindowIdentityValidator: self.exactWindowIdentityValidator)
        return detection
    }

    private nonisolated static func validateCoordinateAuthority(
        point: CGPoint,
        snapshotID: String,
        detectionResult: ElementDetectionResult?) throws
    {
        let authority: SnapshotTargetReceipt.CoordinateAuthority
        do {
            guard let detectionResult,
                  !detectionResult.screenshotPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw DesktopTargetIdentityError.coordinateReferenceMismatch
            }
            authority = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotID,
                detectionResult: detectionResult).receipt.requireCoordinateAuthority()
            let imageSize = authority.context.deliveredImageSize
            guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0 else {
                throw DesktopTargetIdentityError.coordinateReferenceMismatch
            }
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Coordinate scroll requires a fresh pixel-backed exact-window snapshot.",
                hint: "Capture the exact window with see and use its coordinate reference.",
                standardErrorCode: .snapshotStale)
        }
        guard authority.target.bounds.contains(point) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Scroll coordinates are outside the captured target window.",
                standardErrorCode: .invalidInput)
        }
    }

    private nonisolated static func windowRoutedWheelPoint(
        request: ScrollRequest,
        detectedElement: DetectedElement?,
        coordinateTarget: ScrollCoordinateTarget?,
        screenshotPath: String) -> CGPoint?
    {
        if let point = request.point, case let .semanticOwner(_, role, _)? = coordinateTarget {
            guard !screenshotPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["AXGroup", "AXWebArea", "AXScrollArea"].contains(role)
            else { return nil }
            return point
        }
        guard let detectedElement,
              self.supportsWindowRoutedWheelTarget(detectedElement, screenshotPath: screenshotPath)
        else { return nil }
        return CGPoint(x: detectedElement.bounds.midX, y: detectedElement.bounds.midY)
    }

    private func logRequest(_ request: ScrollRequest) {
        let description =
            "Scroll requested - direction: \(request.direction), amount: \(request.amount), " +
            "smooth: \(request.smooth)"
        self.logger.debug("\(description, privacy: .public)")
    }

    nonisolated static func requiresSyntheticScrollSemantics(_ request: ScrollRequest) -> Bool {
        request.foreground
    }

    private nonisolated static func unsupportedBackgroundFailure(
        for error: ActionInputError,
        target: UIAutomationTarget.ExactWindow?) -> DesktopActionFailure
    {
        DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "Background scroll has no supported route for the observed target.",
            hint: "Observe again and select a scrollable control or eligible WebKit content element.",
            causeDescription: error.localizedDescription)
            .attributed(to: target.map { DesktopTargetIdentity(exactWindow: $0).actionTargetReceipt })
    }

    private nonisolated static func validateExpectedWindow(
        _ expectedWindow: UIAutomationTarget.ExactWindow?,
        captureReceipt: DesktopOperationPlan.CaptureReceipt) throws
    {
        guard let expectedWindow else { return }
        guard let resolvedWindow = captureReceipt.exactWindow,
              resolvedWindow.identity.hasSameStableReceipt(as: expectedWindow.identity),
              resolvedWindow.bounds == expectedWindow.bounds
        else {
            throw PeekabooError.snapshotStale(
                "background scroll snapshot does not match its capture-owned exact-window receipt")
        }
    }

    nonisolated static func supportsWindowRoutedWheelTarget(
        _ element: DetectedElement,
        screenshotPath: String) -> Bool
    {
        guard !screenshotPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              element.bounds.width > 0,
              element.bounds.height > 0,
              element.isOCRSemanticEvidence == false
        else {
            return false
        }
        let role = element.attributes["role"]?.lowercased()
        return element.type == .group || role == "axgroup" || role == "axwebarea" || role == "axscrollarea"
    }

    private func resolveActionScrollTarget(
        _ request: ScrollRequest,
        in detectionResult: ElementDetectionResult) throws -> (detected: DetectedElement, element: AutomationElement)
    {
        guard let target = request.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            throw ActionInputError.unsupported(.actionUnsupported)
        }
        if let detected = detectionResult.elements.findById(target) ??
            Self.findDetectedElement(matching: target, in: detectionResult)
        {
            guard !detected.isOCRSemanticEvidence else {
                throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
            }
            guard let element = self.automationElementResolver.resolve(
                detectedElement: detected,
                windowContext: detectionResult.metadata.windowContext)
            else {
                throw ActionInputError.unsupported(.missingElement)
            }
            return (detected, element)
        }
        throw NotFoundError.element(target)
    }

    nonisolated static func actionScrollPages(amount: Int, strategy: UIInputStrategy) -> Int {
        switch strategy {
        case .actionFirst, .actionOnly:
            max(1, abs(amount))
        case .synthFirst, .synthOnly:
            0
        }
    }

    private nonisolated static func syntheticScrollOutcome(unitCount: Int) -> DesktopActionOutcome {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(unitCount) else {
            return .confirmedNoChange()
        }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
    }

    private static func findDetectedElement(matching query: String, in detectionResult: ElementDetectionResult)
        -> DetectedElement?
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }

        return detectionResult.elements.all.first { element in
            guard !element.isOCRSemanticEvidence else { return false }
            return [
                element.label,
                element.value,
                element.attributes["title"],
                element.attributes["description"],
                element.attributes["identifier"],
                element.attributes["placeholder"],
            ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .contains { $0 == query || $0.contains(query) }
        }
    }

    private func performSyntheticScroll(_ request: ScrollRequest) async throws -> Int {
        let scrollPoint = try await self.resolveScrollPoint(request)
        let (deltaX, deltaY) = self.getScrollDeltas(for: request.direction)
        let context = ScrollExecutionContext(
            startingPoint: scrollPoint,
            deltas: (deltaX, deltaY),
            amount: request.amount,
            smooth: request.smooth,
            delay: request.delay)

        return try await self.performScroll(context)
    }

    private func bundleIdentifier(snapshotId: String?) async -> String? {
        if let snapshotId,
           let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
           let bundleIdentifier = detectionResult.metadata.windowContext?.applicationBundleId
        {
            return bundleIdentifier
        }

        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func resolveScrollPoint(_ request: ScrollRequest) async throws -> CGPoint {
        guard let target = request.target else {
            let location = self.getCurrentMouseLocation()
            self.logger.debug(
                "Scrolling at current location: (\(location.x, privacy: .public), \(location.y, privacy: .public))")
            return location
        }

        if let sessionPoint = try await self.lookupElementCenter(target: target, snapshotId: request.snapshotId) {
            try await self.moveMouseToPoint(sessionPoint)
            return sessionPoint
        }

        guard let frame = try await self.findElementFrame(query: target, snapshotId: request.snapshotId) else {
            throw NotFoundError.element(target)
        }

        let point = CGPoint(x: frame.midX, y: frame.midY)
        try await self.moveMouseToPoint(point)
        self.logger.debug(
            "Scrolling on element at (\(point.x, privacy: .public), \(point.y, privacy: .public))")
        return point
    }

    private func lookupElementCenter(target: String, snapshotId: String?) async throws -> CGPoint? {
        guard let snapshotId else { return nil }
        guard let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
            throw ActionInputError.staleElement
        }
        guard let element = detectionResult.elements.findById(target) else { return nil }
        guard !element.isOCRSemanticEvidence else {
            throw PeekabooError.invalidInput(OCRSemanticEvidencePolicy.interactionRefusalMessage)
        }

        let point = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        return try await WindowMovementTracking.adjustPoint(
            point,
            snapshotId: snapshotId,
            snapshots: self.snapshotManager)
    }

    private func performScroll(_ context: ScrollExecutionContext) async throws -> Int {
        let absoluteAmount = abs(context.amount)
        let (tickCount, tickSize) = self.tickConfiguration(amount: absoluteAmount, smooth: context.smooth)
        self.logger.debug("Scrolling \(tickCount, privacy: .public) ticks of size \(tickSize, privacy: .public)")

        for tick in 0..<tickCount {
            try self.postScrollTick(context: context, tickSize: tickSize)
            try await self.sleepBetweenTicks(context: context)
            if tick % 10 == 0 {
                self.logger.debug("Scroll progress: \(tick)/\(tickCount)")
            }
        }
        return tickCount
    }

    private func postScrollTick(context: ScrollExecutionContext, tickSize: Int) throws {
        try self.syntheticInputDriver.scroll(
            deltaX: Double(context.deltas.deltaX * tickSize),
            deltaY: Double(context.deltas.deltaY * tickSize),
            at: context.startingPoint)
    }

    private func sleepBetweenTicks(context: ScrollExecutionContext) async throws {
        if context.delay > 0 {
            try await Task.sleep(for: .milliseconds(context.delay))
        } else if context.smooth {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func tickConfiguration(amount: Int, smooth: Bool) -> (count: Int, size: Int) {
        if smooth {
            return (amount * 10, 1)
        }

        return (amount, 10)
    }

    // MARK: - Private Methods

    private func getScrollDeltas(for direction: PeekabooFoundation.ScrollDirection) -> (deltaX: Int, deltaY: Int) {
        switch direction {
        case .up:
            (0, 5)
        case .down:
            (0, -5)
        case .left:
            (5, 0)
        case .right:
            (-5, 0)
        }
    }

    @MainActor
    private func findElementFrame(query: String, snapshotId: String?) async throws -> CGRect? {
        // Search in snapshot first
        if let snapshotId {
            guard let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId) else {
                throw ActionInputError.staleElement
            }
            let queryLower = query.lowercased()

            for element in detectionResult.elements.all {
                let identifierMatch = element.attributes["identifier"]?.lowercased().contains(queryLower) ?? false
                let matches = element.label?.lowercased().contains(queryLower) ?? false ||
                    element.value?.lowercased().contains(queryLower) ?? false ||
                    identifierMatch

                if matches {
                    return element.bounds
                }
            }
            return nil
        }

        // Fall back to AX search
        if let element = findScrollableElement(matching: query) {
            return element.frame()
        }

        return nil
    }

    @MainActor
    private func findScrollableElement(matching query: String) -> Element? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let appElement = AXApp(frontApp).element

        return self.searchScrollableElement(in: appElement, matching: query.lowercased())
    }

    @MainActor
    private func searchScrollableElement(in element: Element, matching query: String) -> Element? {
        // Check current element
        let title = element.title()?.lowercased() ?? ""
        let label = element.label()?.lowercased() ?? ""
        let roleDescription = element.roleDescription()?.lowercased() ?? ""

        if title.contains(query) || label.contains(query) || roleDescription.contains(query) {
            // Check if scrollable
            let role = element.role()?.lowercased() ?? ""
            if role.contains("scroll") || role.contains("list") || role.contains("table") ||
                role.contains("outline") || role.contains("text")
            {
                return element
            }
        }

        // Search children
        if let children = element.children() {
            for child in children {
                if let found = searchScrollableElement(in: child, matching: query) {
                    return found
                }
            }
        }

        return nil
    }

    private func getCurrentMouseLocation() -> CGPoint {
        self.syntheticInputDriver.currentLocation() ?? .zero
    }

    private func moveMouseToPoint(_ point: CGPoint) async throws {
        try self.syntheticInputDriver.move(to: point)
        // Small delay after move
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms
    }
}

#if DEBUG
extension ScrollService {
    /// Test hook to inspect computed scroll deltas without sending events.
    public func deltasForTesting(direction: PeekabooFoundation.ScrollDirection) -> (Int, Int) {
        self.getScrollDeltas(for: direction)
    }
}
#endif

private struct ScrollExecutionContext {
    let startingPoint: CGPoint
    let deltas: (deltaX: Int, deltaY: Int)
    let amount: Int
    let smooth: Bool
    let delay: Int
}

// MARK: - Extensions

// CustomStringConvertible conformance is now in PeekabooFoundation
