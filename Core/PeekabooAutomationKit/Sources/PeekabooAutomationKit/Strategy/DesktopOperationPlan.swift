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

    struct ExactWindowReceipt: Equatable, Sendable {
        let identity: WindowMutationIdentity
        let bounds: CGRect

        init(identity: WindowMutationIdentity, bounds: CGRect) throws {
            if let capturedBounds = identity.capturedBounds, capturedBounds != bounds {
                throw PeekabooError.snapshotStale(
                    "Exact-window receipt bounds do not match the captured window identity")
            }
            self.identity = identity
            self.bounds = bounds
        }
    }

    struct CaptureReceipt: Equatable, Sendable {
        let snapshotID: String?
        let bundleIdentifier: String?
        let processIdentifier: pid_t?
        let processIdentity: ApplicationProcessIdentity?
        let exactWindow: ExactWindowReceipt?
        let coordinateContext: CaptureCoordinateContext?

        init(
            snapshotID: String? = nil,
            bundleIdentifier: String? = nil,
            processIdentifier: pid_t? = nil,
            processIdentity: ApplicationProcessIdentity? = nil,
            exactWindow: ExactWindowReceipt? = nil,
            coordinateContext: CaptureCoordinateContext? = nil) throws
        {
            let exactProcessIdentity = exactWindow.map {
                ApplicationProcessIdentity(
                    processIdentifier: $0.identity.ownerProcessIdentifier,
                    processStartIdentity: $0.identity.ownerProcessStartIdentity)
            }
            if let processIdentity, let exactProcessIdentity, processIdentity != exactProcessIdentity {
                throw PeekabooError.snapshotStale(
                    "Process and exact-window receipts refer to different process generations")
            }
            let resolvedProcessIdentity = processIdentity ?? exactProcessIdentity
            let resolvedProcessIdentifier = processIdentifier ?? resolvedProcessIdentity?.processIdentifier
            if let resolvedProcessIdentity,
               let resolvedProcessIdentifier,
               resolvedProcessIdentity.processIdentifier != resolvedProcessIdentifier
            {
                throw PeekabooError.invalidInput(
                    "Target PID does not match its process-generation receipt")
            }

            self.snapshotID = snapshotID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            self.bundleIdentifier = bundleIdentifier
            self.processIdentifier = resolvedProcessIdentifier
            self.processIdentity = resolvedProcessIdentity
            self.exactWindow = exactWindow
            self.coordinateContext = coordinateContext
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

    init(
        verb: UIInputVerb,
        selector: Selector,
        captureReceipt: CaptureReceipt,
        deliveryIntent: DeliveryIntent,
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
        if deliveryIntent == .background,
           case .coordinates = normalizedSelector,
           captureReceipt.exactWindow == nil
        {
            throw PeekabooError.invalidInput(
                "Background coordinates require an exact capture-time window receipt")
        }

        self.verb = verb
        self.selector = normalizedSelector
        self.captureReceipt = captureReceipt
        self.deliveryIntent = deliveryIntent
        self.laneScope = Self.laneScope(
            deliveryIntent: deliveryIntent,
            captureReceipt: captureReceipt)
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

    private static func laneScope(
        deliveryIntent: DeliveryIntent,
        captureReceipt: CaptureReceipt) -> DesktopOperationScope
    {
        guard deliveryIntent == .background, let identity = captureReceipt.processIdentity else {
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
