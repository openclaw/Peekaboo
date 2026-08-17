import CoreGraphics
import Foundation
import PeekabooFoundation

/// One validated destination for native UI input.
///
/// This is an in-process planning value, not a transport model. Public service overloads adapt
/// their legacy arguments into this target without changing Bridge or command wire contracts.
public enum UIAutomationTarget: Sendable, Equatable {
    /// Input follows the user's current foreground focus.
    case foreground

    /// Input is routed to a process without requiring one exact window.
    case process(Process)

    /// Input is pinned to one process generation and exact WindowServer window.
    case exactWindow(ExactWindow)

    public struct Process: Sendable, Codable, Equatable {
        public let processIdentifier: pid_t
        public let identity: ApplicationProcessIdentity?

        public init(
            processIdentifier: pid_t,
            identity: ApplicationProcessIdentity? = nil) throws
        {
            if let identity, identity.processIdentifier != processIdentifier {
                throw PeekabooError.invalidInput(
                    "Target PID does not match its process-generation receipt")
            }
            self.processIdentifier = processIdentifier
            self.identity = identity
        }
    }

    public struct ExactWindow: Sendable, Codable, Equatable {
        public let identity: WindowMutationIdentity
        public let bounds: CGRect
        public let focusedElement: FocusedElementIdentity?

        public init(
            processIdentifier: pid_t,
            windowID: Int,
            identity: WindowMutationIdentity,
            bounds: CGRect,
            focusedElement: FocusedElementIdentity? = nil) throws
        {
            guard identity.ownerProcessIdentifier == processIdentifier,
                  identity.windowID == windowID
            else {
                throw PeekabooError.snapshotStale(
                    "Exact-window identifiers do not match the capture-time process-generation receipt")
            }
            try self.init(
                identity: identity,
                bounds: bounds,
                focusedElement: focusedElement)
        }

        public init(
            identity: WindowMutationIdentity,
            bounds: CGRect,
            focusedElement: FocusedElementIdentity? = nil) throws
        {
            if let capturedBounds = identity.capturedBounds, capturedBounds != bounds {
                throw PeekabooError.snapshotStale(
                    "Exact-window receipt bounds do not match the captured window identity")
            }
            if let focusedElement,
               focusedElement.processIdentifier != identity.ownerProcessIdentifier ||
               focusedElement.windowID != identity.windowID
            {
                throw PeekabooError.invalidInput(
                    field: "target",
                    reason: "Focused-element receipt does not belong to the exact target window")
            }
            if let focusedElement {
                guard !focusedElement.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: "Focused-element receipt has no accessibility role")
                }
                guard !focusedElement.frame.isEmpty else {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: FocusedElementReceiptError.missingElementFrame.localizedDescription)
                }
                guard bounds.contains(CGPoint(x: focusedElement.frame.midX, y: focusedElement.frame.midY)) else {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: FocusedElementReceiptError.elementOutsideWindow.localizedDescription)
                }
            }
            self.identity = identity
            self.bounds = bounds
            self.focusedElement = focusedElement
        }

        public init(
            window: ServiceWindowInfo,
            focusedElement: FocusedElementIdentity? = nil) throws
        {
            guard let identity = window.mutationIdentity else {
                throw PeekabooError.invalidInput(
                    field: "target",
                    reason: "The selected window has no process-generation receipt; capture fresh UI state")
            }
            try self.init(
                processIdentifier: identity.ownerProcessIdentifier,
                windowID: window.windowID,
                identity: identity,
                bounds: window.bounds,
                focusedElement: focusedElement)
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.identity.hasSameStableReceipt(as: rhs.identity) &&
                lhs.bounds == rhs.bounds &&
                lhs.focusedElement == rhs.focusedElement
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.foreground, .foreground):
            true
        case let (.process(lhs), .process(rhs)):
            lhs == rhs
        case let (.exactWindow(lhs), .exactWindow(rhs)):
            lhs == rhs
        default:
            false
        }
    }

    public var processIdentifier: pid_t? {
        switch self {
        case .foreground:
            nil
        case let .process(target):
            target.processIdentifier
        case let .exactWindow(target):
            target.identity.ownerProcessIdentifier
        }
    }

    public var processIdentity: ApplicationProcessIdentity? {
        switch self {
        case .foreground:
            nil
        case let .process(target):
            target.identity
        case let .exactWindow(target):
            target.identity.processIdentity
        }
    }

    public var exactWindow: ExactWindow? {
        guard case let .exactWindow(target) = self else { return nil }
        return target
    }

    var keyboardDelivery: DesktopActionOutcome.Delivery {
        switch self {
        case .foreground:
            .init(mechanism: .globalEvents, mode: .foreground)
        case .process:
            .init(mechanism: .processTargetedEvents, mode: .background)
        case .exactWindow:
            .init(mechanism: .windowTargetedEvents, mode: .background)
        }
    }

    /// Select one background keyboard destination without reducing an exact receipt to a process.
    public static func backgroundKeyboard(
        process: Process,
        exactWindow: ExactWindow) throws -> UIAutomationTarget
    {
        guard process.identity != nil else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Background keyboard delivery requires a process-generation receipt")
        }
        return try UIAutomationTarget.process(process).refined(to: exactWindow)
    }

    public static func backgroundKeyboard(
        process: Process,
        eligibleWindows: [ExactWindow],
        requiresExplicitExactWindow: Bool = false) throws -> UIAutomationTarget
    {
        guard let processIdentity = process.identity else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Background keyboard delivery requires a process-generation receipt")
        }
        if requiresExplicitExactWindow {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Background raw key presses require an explicit exact-window or snapshot receipt")
        }

        guard eligibleWindows.allSatisfy({ $0.identity.processIdentity == processIdentity }) else {
            throw PeekabooError.snapshotStale(
                "Eligible keyboard windows do not belong to the selected process generation")
        }
        let uniqueWindows = eligibleWindows.reduce(into: [ExactWindow]()) { result, candidate in
            if !result.contains(where: { $0.identity.hasSameStableReceipt(as: candidate.identity) }) {
                result.append(candidate)
            }
        }
        if uniqueWindows.isEmpty {
            return .process(process)
        }
        guard uniqueWindows.count == 1, let exactWindow = uniqueWindows.first else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "The selected process has multiple eligible windows; add a window selector or fresh snapshot")
        }
        return try self.backgroundKeyboard(process: process, exactWindow: exactWindow)
    }

    public func pinningFocusedElement(_ focusedElement: FocusedElementIdentity) throws -> UIAutomationTarget {
        guard let exactWindow = self.exactWindow else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "Focused-element keyboard pinning requires an exact-window receipt")
        }
        return try .exactWindow(ExactWindow(
            identity: exactWindow.identity,
            bounds: exactWindow.bounds,
            focusedElement: focusedElement))
    }

    @MainActor
    public func pinningCurrentFocusedElement(
        using automation: any UIAutomationServiceProtocol) async throws -> UIAutomationTarget
    {
        guard let exactWindow = self.exactWindow else { return self }
        if exactWindow.focusedElement != nil {
            return self
        }
        guard let focusedElementService = automation as? any TargetedFocusedElementServiceProtocol else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: "The automation host cannot read exact focused-element receipts")
        }
        guard let focus = await focusedElementService.getFocusedElement(
            targetProcessIdentifier: exactWindow.identity.ownerProcessIdentifier)
        else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: FocusedElementReceiptError.noFocusedElement.localizedDescription + " " +
                    BackgroundKeyboardFocusRemediation.message)
        }
        guard focus.processId == Int(exactWindow.identity.ownerProcessIdentifier) else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: FocusedElementReceiptError.processMismatch.localizedDescription + " " +
                    BackgroundKeyboardFocusRemediation.message)
        }
        guard focus.windowID != nil else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: FocusedElementReceiptError.missingWindowIdentifier.localizedDescription)
        }
        guard !focus.frame.isEmpty else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: FocusedElementReceiptError.missingElementFrame.localizedDescription)
        }
        guard let focusedElement = FocusedElementIdentity(focus),
              focusedElement.windowID == exactWindow.identity.windowID
        else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: FocusedElementReceiptError.windowMismatch.localizedDescription + " " +
                    BackgroundKeyboardFocusRemediation.message)
        }
        guard exactWindow.bounds.contains(CGPoint(x: focusedElement.frame.midX, y: focusedElement.frame.midY)) else {
            throw PeekabooError.invalidInput(
                field: "target",
                reason: FocusedElementReceiptError.elementOutsideWindow.localizedDescription)
        }
        return try self.pinningFocusedElement(focusedElement)
    }

    func refined(to exactWindow: ExactWindow) throws -> UIAutomationTarget {
        if let processIdentifier = self.processIdentifier,
           processIdentifier != exactWindow.identity.ownerProcessIdentifier
        {
            throw PeekabooError.snapshotStale(
                "Process and exact-window receipts refer to different process generations")
        }
        if let processIdentity = self.processIdentity,
           processIdentity != exactWindow.identity.processIdentity
        {
            throw PeekabooError.snapshotStale(
                "Process and exact-window receipts refer to different process generations")
        }
        if let currentExactWindow = self.exactWindow,
           currentExactWindow != exactWindow
        {
            throw PeekabooError.snapshotStale(
                "Exact-window receipts refer to different window identities")
        }
        return .exactWindow(exactWindow)
    }
}

/// Exact-window keyboard capability and route-receipt validation.
///
/// Outcome-state interpretation stays with `DesktopActionFailure` and
/// `DesktopActionSequenceAccumulator`; this gate only proves that the exact route survived dispatch.
@MainActor
public enum ExactWindowKeyboardRuntime {
    public static func requireOutcomeProvider(
        automation: any UIAutomationServiceProtocol,
        operation: String) throws -> any UIAutomationActionOutcomeProviding
    {
        guard let exactService = automation as? any ExactWindowTargetedKeyboardServiceProtocol,
              exactService.supportsExactWindowTargetedKeyboard
        else {
            let reason = (automation as? any ExactWindowTargetedKeyboardServiceProtocol)?
                .exactWindowTargetedKeyboardUnavailableReason
            throw PeekabooError.serviceUnavailable(
                reason ?? "\(operation) requires atomic exact-window keyboard delivery")
        }
        guard let outcomeProvider = automation as? any UIAutomationActionOutcomeProviding else {
            throw PeekabooError.serviceUnavailable(
                "\(operation) requires exact-window typed outcome receipts")
        }
        return outcomeProvider
    }

    public static func validateRouteReceipt<Payload>(
        _ result: UIAutomationActionResult<Payload>,
        operation: String) throws -> UIAutomationActionResult<Payload>
    {
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .completionUnknown,
                message: "\(operation) returned without its required exact-window route receipt.",
                hint: "Observe the target before any retry and update the runtime host.")
        }
        let expectedDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        guard !outcome.dispatchState.mutationDispatched || outcome.delivery == expectedDelivery else {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) returned a contradictory exact-window route receipt.",
                hint: "Observe the target before any retry and update the runtime host.")
        }
        return result
    }
}
