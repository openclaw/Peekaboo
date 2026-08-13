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

    public struct Process: Sendable, Equatable {
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

    public struct ExactWindow: Sendable, Equatable {
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
            self.identity = identity
            self.bounds = bounds
            self.focusedElement = focusedElement
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
