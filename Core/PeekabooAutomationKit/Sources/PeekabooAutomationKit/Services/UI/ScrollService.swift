import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Service for handling scroll operations
@MainActor
public final class ScrollService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ScrollService")
    private let snapshotManager: any SnapshotManagerProtocol
    private let clickService: ClickService
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let syntheticInputDriver: any SyntheticInputDriving
    private let automationElementResolver: AutomationElementResolver

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
        automationElementResolver: AutomationElementResolver = AutomationElementResolver())
    {
        let manager = snapshotManager ?? SnapshotManager()
        self.snapshotManager = manager
        self.clickService = clickService ?? ClickService(
            snapshotManager: manager,
            inputPolicy: inputPolicy,
            actionInputDriver: actionInputDriver,
            syntheticInputDriver: syntheticInputDriver,
            automationElementResolver: automationElementResolver)
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.syntheticInputDriver = syntheticInputDriver
        self.automationElementResolver = automationElementResolver
    }

    /// Perform scroll operation
    @discardableResult
    @MainActor
    public func scroll(_ request: ScrollRequest) async throws -> UIInputExecutionResult {
        let description =
            "Scroll requested - direction: \(request.direction), amount: \(request.amount), " +
            "smooth: \(request.smooth)"
        self.logger.debug("\(description, privacy: .public)")
        let bundleIdentifier = await self.bundleIdentifier(snapshotId: request.snapshotId)
        let strategy = self.inputPolicy.strategy(for: .scroll, bundleIdentifier: bundleIdentifier)

        do {
            let action: (() async throws -> ActionInputResult)? = if Self.requiresSyntheticScrollSemantics(request) {
                {
                    throw ActionInputError.unsupported(.actionUnsupported)
                }
            } else {
                {
                    try await self.performActionScroll(request, strategy: strategy)
                }
            }
            let result = try await UIInputDispatcher.run(
                verb: .scroll,
                strategy: strategy,
                bundleIdentifier: bundleIdentifier,
                action: action,
                synth: {
                    try await self.performSyntheticScroll(request)
                })
            self.logger.debug("Scroll completed via \(result.path.rawValue, privacy: .public)")
            return result
        } catch {
            throw error
        }
    }

    nonisolated static func requiresSyntheticScrollSemantics(_ request: ScrollRequest) -> Bool {
        request.smooth || request.delay > 0
    }

    private func performActionScroll(
        _ request: ScrollRequest,
        strategy: UIInputStrategy) async throws -> ActionInputResult
    {
        let detectionResult: ElementDetectionResult?
        if let snapshotId = request.snapshotId {
            detectionResult = try await self.snapshotManager.getDetectionResult(snapshotId: snapshotId)
            if detectionResult == nil {
                throw ActionInputError.staleElement
            }
        } else {
            detectionResult = nil
        }

        guard let target = request.target?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty
        else {
            throw ActionInputError.unsupported(.actionUnsupported)
        }
        let pages = Self.actionScrollPages(amount: request.amount, strategy: strategy)

        if let detectionResult {
            if let detected = detectionResult.elements.findById(target) ??
                Self.findDetectedElement(matching: target, in: detectionResult)
            {
                guard let element = self.automationElementResolver.resolve(
                    detectedElement: detected,
                    windowContext: detectionResult.metadata.windowContext)
                else {
                    throw ActionInputError.unsupported(.missingElement)
                }

                return try self.actionInputDriver.tryScroll(
                    element: element,
                    direction: request.direction,
                    pages: pages)
            }

            throw NotFoundError.element(target)
        }

        if let element = self.automationElementResolver.resolve(query: target, windowContext: nil) {
            return try self.actionInputDriver.tryScroll(
                element: element,
                direction: request.direction,
                pages: pages)
        }

        throw ActionInputError.unsupported(.missingElement)
    }

    nonisolated static func actionScrollPages(amount: Int, strategy: UIInputStrategy) -> Int {
        switch strategy {
        case .actionFirst, .actionOnly:
            max(1, abs(amount))
        case .synthFirst, .synthOnly:
            0
        }
    }

    private static func findDetectedElement(matching query: String, in detectionResult: ElementDetectionResult)
        -> DetectedElement?
    {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return nil }

        return detectionResult.elements.all.first { element in
            [
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

    private func performSyntheticScroll(_ request: ScrollRequest) async throws {
        let scrollPoint = try await self.resolveScrollPoint(request)
        let (deltaX, deltaY) = self.getScrollDeltas(for: request.direction)
        let context = ScrollExecutionContext(
            startingPoint: scrollPoint,
            deltas: (deltaX, deltaY),
            amount: request.amount,
            smooth: request.smooth,
            delay: request.delay)

        try await self.performScroll(context)
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
        guard let snapshotId,
              let detectionResult = try? await self.snapshotManager.getDetectionResult(snapshotId: snapshotId),
              let element = detectionResult.elements.findById(target)
        else {
            return nil
        }

        let point = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
        return try await WindowMovementTracking.adjustPoint(
            point,
            snapshotId: snapshotId,
            snapshots: self.snapshotManager)
    }

    private func performScroll(_ context: ScrollExecutionContext) async throws {
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
    }

    private func postScrollTick(context: ScrollExecutionContext, tickSize: Int) throws {
        try self.syntheticInputDriver.scroll(
            deltaX: Double(context.deltas.deltaX * tickSize),
            deltaY: Double(context.deltas.deltaY * tickSize),
            at: context.startingPoint)
    }

    private func sleepBetweenTicks(context: ScrollExecutionContext) async throws {
        if context.delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(context.delay) * 1_000_000)
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
        if let snapshotId,
           let detectionResult = try? await snapshotManager.getDetectionResult(snapshotId: snapshotId)
        {
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
