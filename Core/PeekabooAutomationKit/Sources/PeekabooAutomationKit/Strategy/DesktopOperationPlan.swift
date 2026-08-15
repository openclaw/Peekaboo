import CoreGraphics
import Foundation
import PeekabooFoundation

/// One fully planned native desktop-input operation.
///
/// This is intentionally an AutomationKit-internal execution model. Public v4 service methods
/// remain compatibility adapters, while Bridge and tool protocols keep their existing contracts.
@MainActor
struct DesktopOperationPlan {
    enum Selector: Equatable {
        case focused
        case elementID(String)
        case elementReference(String)
        case query(String)
        case coordinates(CGPoint)

        static func click(_ target: ClickTarget) -> Self {
            switch target {
            case let .elementId(id): .elementID(id)
            case let .query(query): .query(query)
            case let .coordinates(point): .coordinates(point)
            }
        }

        static func element(_ target: String?) -> Self {
            guard let target = target?.trimmingCharacters(in: .whitespacesAndNewlines), !target.isEmpty else {
                return .focused
            }
            return .elementReference(target)
        }
    }

    typealias ExactWindowReceipt = UIAutomationTarget.ExactWindow

    struct CaptureReceipt: Equatable, Sendable {
        let snapshotID: String?
        let bundleIdentifier: String?
        let target: UIAutomationTarget
        let coordinateContext: CaptureCoordinateContext?

        var processIdentifier: pid_t? {
            self.target.processIdentifier
        }

        var processIdentity: ApplicationProcessIdentity? {
            self.target.processIdentity
        }

        var exactWindow: ExactWindowReceipt? {
            self.target.exactWindow
        }

        init(
            snapshotID: String? = nil,
            bundleIdentifier: String? = nil,
            target: UIAutomationTarget,
            coordinateContext: CaptureCoordinateContext? = nil)
        {
            self.snapshotID = snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.bundleIdentifier = bundleIdentifier
            self.target = target
            self.coordinateContext = coordinateContext
        }

        init(snapshotReceipt: SnapshotTargetReceipt) throws {
            let identity = try snapshotReceipt.requireIdentity()
            self.init(
                snapshotID: snapshotReceipt.snapshotID,
                bundleIdentifier: snapshotReceipt.applicationBundleIdentifier,
                target: identity.target,
                coordinateContext: snapshotReceipt.coordinateContext)
        }
    }

    enum DeliveryIntent: Equatable, Sendable {
        case background
        case foreground
    }

    struct ActionRoute {
        let preflight: @MainActor () async throws -> Void
        let execute: @MainActor () async throws -> UIInputExecutionResult.Action

        init(
            preflight: @escaping @MainActor () async throws -> Void = {},
            execute: @escaping @MainActor () async throws -> UIInputExecutionResult.Action)
        {
            self.preflight = preflight
            self.execute = execute
        }
    }

    struct SynthesisRoute {
        let preflight: @MainActor () async throws -> Void
        let execute: @MainActor () async throws -> DesktopActionOutcome

        init(
            preflight: @escaping @MainActor () async throws -> Void = {},
            execute: @escaping @MainActor () async throws -> DesktopActionOutcome)
        {
            self.preflight = preflight
            self.execute = execute
        }
    }

    struct Routing {
        let strategy: UIInputStrategy
        let bundleIdentifier: String?
    }

    let verb: UIInputVerb
    let selector: Selector
    let captureReceipt: CaptureReceipt
    let deliveryIntent: DeliveryIntent
    let laneScope: DesktopOperationScope
    let prepare: @MainActor () async throws -> Void
    let routing: @MainActor () -> Routing
    let action: ActionRoute?
    let synthesis: SynthesisRoute
    let postvalidate: @MainActor (UIInputExecutionResult) async throws -> Void
    let success: @MainActor (UIInputExecutionResult) async -> Void
    let finalize: @MainActor () async -> Void

    func targetIdentity() throws -> DesktopTargetIdentity? {
        switch self.captureReceipt.target {
        case .foreground:
            return nil
        case let .process(process):
            guard let identity = process.identity else { return nil }
            return try DesktopTargetIdentity(processIdentity: identity)
        case let .exactWindow(window):
            return DesktopTargetIdentity(exactWindow: window)
        }
    }

    init(
        verb: UIInputVerb,
        selector: Selector,
        captureReceipt: CaptureReceipt,
        strategy: UIInputStrategy,
        prepare: @escaping @MainActor () async throws -> Void = {},
        routing: (@MainActor () -> Routing)? = nil,
        action: ActionRoute?,
        synthesis: SynthesisRoute,
        postvalidate: @escaping @MainActor (UIInputExecutionResult) async throws -> Void = { _ in },
        success: @escaping @MainActor (UIInputExecutionResult) async -> Void = { _ in },
        finalize: @escaping @MainActor () async -> Void = {}) throws
    {
        let normalizedSelector = try Self.normalized(selector)
        if captureReceipt.target != .foreground,
           case .coordinates = normalizedSelector,
           captureReceipt.exactWindow == nil
        {
            throw PeekabooError.invalidInput(
                "Background coordinates require an exact capture-time window receipt")
        }

        self.verb = verb
        self.selector = normalizedSelector
        self.captureReceipt = captureReceipt
        self.deliveryIntent = captureReceipt.target == .foreground ? .foreground : .background
        self.laneScope = Self.laneScope(captureReceipt.target)
        self.prepare = prepare
        self.routing = routing ?? {
            Routing(strategy: strategy, bundleIdentifier: captureReceipt.bundleIdentifier)
        }
        self.action = action
        self.synthesis = synthesis
        self.postvalidate = postvalidate
        self.success = success
        self.finalize = finalize
    }

    private static func normalized(_ selector: Selector) throws -> Selector {
        switch selector {
        case .focused, .coordinates:
            return selector
        case let .elementID(id):
            guard let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw PeekabooError.invalidInput("Element target is required")
            }
            return .elementID(normalized)
        case let .elementReference(reference):
            guard let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw PeekabooError.invalidInput("Element target is required")
            }
            return .elementReference(normalized)
        case let .query(query):
            guard let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                throw PeekabooError.invalidInput("Element query is required")
            }
            return .query(normalized)
        }
    }

    private static func laneScope(_ target: UIAutomationTarget) -> DesktopOperationScope {
        guard let identity = target.processIdentity else {
            return .global
        }
        // Preserve the shipped process-scoped semantics for exact-window keyboard and pointer input.
        return .process(identity)
    }
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
