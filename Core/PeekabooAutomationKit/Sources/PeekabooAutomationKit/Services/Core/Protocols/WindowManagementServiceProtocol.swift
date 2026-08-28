import CoreGraphics
import Foundation
import PeekabooFoundation

/// Protocol defining window management operations
public protocol WindowManagementServiceProtocol: Sendable {
    /// Close a window
    /// - Parameters:
    ///   - target: Window targeting options
    func closeWindow(target: WindowTarget) async throws

    /// Close a window, optionally escalating from AX to focused/global input fallbacks.
    /// Background callers must leave `allowForegroundFallback` false.
    func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws

    /// Close only while the exact window owner and owner process generation match the selection receipt.
    func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws

    /// Minimize a window
    /// - Parameters:
    ///   - target: Window targeting options
    func minimizeWindow(target: WindowTarget) async throws

    func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws

    /// Restore a minimized window without activating or focusing its application.
    func restoreWindow(target: WindowTarget) async throws

    func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws

    /// Fill a window's current screen using background-safe geometry.
    /// - Parameters:
    ///   - target: Window targeting options
    func maximizeWindow(target: WindowTarget) async throws

    func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws

    /// Move a window to specific coordinates
    /// - Parameters:
    ///   - target: Window targeting options
    ///   - position: New position for the window
    func moveWindow(target: WindowTarget, to position: CGPoint) async throws

    func moveWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws

    /// Resize a window
    /// - Parameters:
    ///   - target: Window targeting options
    ///   - size: New size for the window
    func resizeWindow(target: WindowTarget, to size: CGSize) async throws

    func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws

    /// Set window bounds (position and size)
    /// - Parameters:
    ///   - target: Window targeting options
    ///   - bounds: New bounds for the window
    func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws

    func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws

    /// Focus/activate a window
    /// - Parameters:
    ///   - target: Window targeting options
    func focusWindow(target: WindowTarget) async throws

    /// List all windows matching the target
    /// - Parameters:
    ///   - target: Window targeting options
    /// - Returns: Array of window information
    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo]

    /// Get the currently focused window
    /// - Returns: Window information if a window is focused
    func getFocusedWindow() async throws -> ServiceWindowInfo?
}

extension WindowManagementServiceProtocol {
    /// Returns window rows together with explicit completeness evidence.
    ///
    /// Legacy conformers expose rows only, so broad selectors cannot infer uniqueness from them. An
    /// exact window-ID lookup may still use those rows as direct identity proof.
    public func mutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        if let provider = self as? any WindowMutationInventoryProviding {
            return try await provider.windowMutationInventory(target: target)
        }
        return try await .partial(
            self.listWindows(target: target),
            warnings: ["Window mutation inventory completeness was not reported by this service."])
    }

    public func requireWindowMutationResultProvider(operation: String) throws {
        guard self is any WindowManagementActionResultProviding ||
            self is any WindowManagementActionOutcomeProviding
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "\(operation) requires a canonical exact-window result provider.",
                hint: "Update the runtime host or use the legacy non-result API explicitly.")
        }
    }

    public func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        guard allowForegroundFallback else {
            throw PeekabooError.operationError(
                message: "This window service does not implement AX-only background close")
        }
        try await self.closeWindow(target: target)
    }

    public func closeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func minimizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func restoreWindow(target _: WindowTarget) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func restoreWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func maximizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func moveWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func resizeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    public func setWindowBounds(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws
    {
        throw Self.unsupportedPinnedWindowMutation()
    }

    private static func unsupportedPinnedWindowMutation() -> PeekabooError {
        PeekabooError.serviceUnavailable(
            "This window service does not support process-generation-pinned mutations; update the runtime host")
    }
}

/// Additive inventory capability for mutation planners that must prove catalog completeness.
public protocol WindowMutationInventoryProviding: WindowManagementServiceProtocol {
    func windowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
}

/// Additive capability for exact-window mutations that can report their canonical execution outcome.
///
/// Existing conformers and callers use this compatibility surface from Peekaboo 4.1.0. New services
/// should also adopt ``WindowManagementActionResultProviding`` to return the shared result carrier.
public protocol WindowManagementActionOutcomeProviding: WindowManagementServiceProtocol {
    /// Close the exact window through the background-only Accessibility route.
    func closeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?

    func minimizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?

    func restoreWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?

    func maximizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?

    func moveWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionOutcome?

    func resizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionOutcome?

    func setWindowBoundsWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionOutcome?
}

/// Additive capability for exact-window mutations that return the shared action-result carrier.
///
/// Requirement names intentionally differ from the public `*Result` adapters below. Keeping the
/// capability witnesses distinct prevents an adapter default from satisfying this protocol and
/// recursively redispatching to itself.
public protocol WindowManagementActionResultProviding: WindowManagementServiceProtocol {
    func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>

    func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>

    func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>

    func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>

    func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>

    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>

    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
}

/// Additive capability for window focus that retains its canonical outcome and exact target.
///
/// Focus predates the shared result carrier and is intentionally separate from
/// ``WindowManagementActionResultProviding`` so existing conformers remain source compatible.
public protocol WindowManagementFocusActionResultProviding: WindowManagementServiceProtocol {
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void>
}

/// Additive capability for focus that dispatches only while the original exact-window receipt matches.
public protocol WindowManagementPinnedFocusActionResultProviding: WindowManagementFocusActionResultProviding {
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
}

/// Additive focus capability that captures exact foreground evidence before releasing the mutation lane.
/// Existing 4.x focus APIs retain their void payload; providers without this capability still require readback.
public protocol WindowManagementFocusProofProviding: WindowManagementPinnedFocusActionResultProviding {
    func focusWindowProofActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<ServiceWindowInfo>
}

extension WindowManagementServiceProtocol {
    /// Validates a result-aware exact-window mutation and retains its caller-held target receipt.
    ///
    /// The legacy pinned void APIs remain available explicitly. This adapter is only for callers
    /// that require a canonical result and exact target after dispatch.
    public func validatedWindowMutationResult(
        _ result: DesktopActionResult<Void>,
        expectedIdentity: WindowMutationIdentity,
        operation: String) throws -> UIAutomationActionResult<Void>
    {
        try self.validatedWindowMutationResult(
            UIAutomationActionResult(result),
            expectedIdentity: expectedIdentity,
            operation: operation)
    }

    public func validatedWindowMutationResult(
        _ result: UIAutomationActionResult<Void>,
        expectedIdentity: WindowMutationIdentity,
        operation: String) throws -> UIAutomationActionResult<Void>
    {
        let receipt = expectedIdentity.actionTargetReceipt
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "\(operation) returned without a canonical outcome.",
                hint: "Observe the exact window before retrying and update the runtime host.")
                .attributed(to: receipt)
        }
        if !outcome.isAccepted(by: .confirmedOrDispatched) {
            guard let failure = DesktopActionFailure(
                outcome: outcome,
                message: "\(operation) did not return a successful outcome.",
                hint: "Follow the canonical escalation metadata before deciding whether to retry.")
            else { preconditionFailure("Non-success window state must construct a failure") }
            throw failure.attributed(to: receipt)
        }

        let expectedTarget: DesktopTargetIdentity
        do {
            guard let bounds = expectedIdentity.capturedBounds else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            expectedTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: expectedIdentity,
                bounds: bounds))
        } catch {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) caller held an incomplete exact-window target.",
                hint: "Observe the selected window before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: receipt)
        }

        if let returnedTarget = result.targetIdentity {
            guard let exactWindow = returnedTarget.exactWindow,
                  exactWindow.identity.hasSameStableReceipt(as: expectedIdentity),
                  exactWindow.bounds == expectedIdentity.capturedBounds
            else {
                throw DesktopActionFailure.indeterminate(
                    route: outcome.route,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "\(operation) returned a mismatched exact-window target.",
                    hint: "Observe the selected window before retrying and update the runtime host.")
                    .attributed(to: receipt)
            }
            return UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: returnedTarget)
        }

        try self.requireWindowMutationResultProvider(operation: operation)
        return UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: expectedTarget)
    }
}

extension WindowManagementServiceProtocol {
    public func focusWindowResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        if let results = self as? any WindowManagementFocusActionResultProviding {
            return try await results.focusWindowActionResult(target: target)
        }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "This window service cannot return a canonical focus outcome and exact target.",
            hint: "Update the runtime host or use the legacy void focus API explicitly.")
    }

    public func focusWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        guard let results = self as? any WindowManagementPinnedFocusActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "This window service cannot bind focus to an exact process-generation receipt.",
                hint: "Update the runtime host before retrying exact focus.")
        }
        return try await results.focusWindowActionResult(
            target: target,
            expectedIdentity: expectedIdentity)
    }

    public func closeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.closeWindowActionResult(
                target: target,
                expectedIdentity: expectedIdentity,
                allowForegroundFallback: allowForegroundFallback)
        }
        if !allowForegroundFallback,
           let outcomes = self as? any WindowManagementActionOutcomeProviding
        {
            return try await DesktopActionResult(
                outcome: outcomes.closeWindowWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity))
        }
        try await self.closeWindow(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
        return DesktopActionResult(outcome: nil)
    }

    public func minimizeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.minimizeWindowActionResult(
                target: target,
                expectedIdentity: expectedIdentity)
        }
        if let outcomes = self as? any WindowManagementActionOutcomeProviding {
            return try await DesktopActionResult(
                outcome: outcomes.minimizeWindowWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity))
        }
        try await self.minimizeWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: nil)
    }

    public func restoreWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.restoreWindowActionResult(
                target: target,
                expectedIdentity: expectedIdentity)
        }
        if let outcomes = self as? any WindowManagementActionOutcomeProviding {
            return try await DesktopActionResult(
                outcome: outcomes.restoreWindowWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity))
        }
        try await self.restoreWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: nil)
    }

    public func maximizeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.maximizeWindowActionResult(
                target: target,
                expectedIdentity: expectedIdentity)
        }
        if let outcomes = self as? any WindowManagementActionOutcomeProviding {
            return try await DesktopActionResult(
                outcome: outcomes.maximizeWindowWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity))
        }
        try await self.maximizeWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: nil)
    }

    public func moveWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.moveWindowActionResult(
                target: target,
                expectedIdentity: expectedIdentity,
                to: position)
        }
        if let outcomes = self as? any WindowManagementActionOutcomeProviding {
            return try await DesktopActionResult(
                outcome: outcomes.moveWindowWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    to: position))
        }
        try await self.moveWindow(target: target, expectedIdentity: expectedIdentity, to: position)
        return DesktopActionResult(outcome: nil)
    }

    public func resizeWindowResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.resizeWindowActionResult(
                target: target,
                expectedIdentity: expectedIdentity,
                to: size)
        }
        if let outcomes = self as? any WindowManagementActionOutcomeProviding {
            return try await DesktopActionResult(
                outcome: outcomes.resizeWindowWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    to: size))
        }
        try await self.resizeWindow(target: target, expectedIdentity: expectedIdentity, to: size)
        return DesktopActionResult(outcome: nil)
    }

    public func setWindowBoundsResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
    {
        if let results = self as? any WindowManagementActionResultProviding {
            return try await results.setWindowBoundsActionResult(
                target: target,
                expectedIdentity: expectedIdentity,
                bounds: bounds)
        }
        if let outcomes = self as? any WindowManagementActionOutcomeProviding {
            return try await DesktopActionResult(
                outcome: outcomes.setWindowBoundsWithOutcome(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    bounds: bounds))
        }
        try await self.setWindowBounds(target: target, expectedIdentity: expectedIdentity, bounds: bounds)
        return DesktopActionResult(outcome: nil)
    }
}

/// Options for targeting a window
public enum WindowTarget: Sendable, CustomStringConvertible, Codable, Equatable, Hashable {
    /// Target by application name or bundle ID
    case application(String)

    /// Target by window title (substring match)
    case title(String)

    /// Target by application and window index
    case index(app: String, index: Int)

    /// Target by application and window title (more efficient than title alone)
    case applicationAndTitle(app: String, title: String)

    /// Target the frontmost window
    case frontmost

    /// Target a specific window ID
    case windowId(Int)

    private enum CodingKeys: String, CodingKey { case kind, app, index, title, windowId }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "application":
            self = try .application(container.decode(String.self, forKey: .app))
        case "title":
            self = try .title(container.decode(String.self, forKey: .title))
        case "index":
            let app = try container.decode(String.self, forKey: .app)
            let index = try container.decode(Int.self, forKey: .index)
            self = .index(app: app, index: index)
        case "applicationAndTitle":
            let app = try container.decode(String.self, forKey: .app)
            let title = try container.decode(String.self, forKey: .title)
            self = .applicationAndTitle(app: app, title: title)
        case "frontmost":
            self = .frontmost
        case "windowId":
            self = try .windowId(container.decode(Int.self, forKey: .windowId))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown WindowTarget kind: \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .application(app):
            try container.encode("application", forKey: .kind)
            try container.encode(app, forKey: .app)
        case let .title(title):
            try container.encode("title", forKey: .kind)
            try container.encode(title, forKey: .title)
        case let .index(app, index):
            try container.encode("index", forKey: .kind)
            try container.encode(app, forKey: .app)
            try container.encode(index, forKey: .index)
        case let .applicationAndTitle(app, title):
            try container.encode("applicationAndTitle", forKey: .kind)
            try container.encode(app, forKey: .app)
            try container.encode(title, forKey: .title)
        case .frontmost:
            try container.encode("frontmost", forKey: .kind)
        case let .windowId(id):
            try container.encode("windowId", forKey: .kind)
            try container.encode(id, forKey: .windowId)
        }
    }

    public var description: String {
        switch self {
        case let .application(app):
            "application(\(app))"
        case let .title(title):
            "title(\(title))"
        case let .index(app, index):
            "index(app: \(app), index: \(index))"
        case let .applicationAndTitle(app, title):
            "applicationAndTitle(app: \(app), title: \(title))"
        case .frontmost:
            "frontmost"
        case let .windowId(id):
            "windowId(\(id))"
        }
    }
}
