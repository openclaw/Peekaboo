import CoreGraphics
import Foundation
import PeekabooFoundation

/// Canonical stable identity for a process or exact window target.
///
/// Snapshot lifecycle and coordinate authority intentionally live in `SnapshotTargetReceipt`.
public struct DesktopTargetIdentity: Equatable, Sendable {
    public struct Evidence: Equatable, Sendable {
        public let processIdentifier: Int32?
        public let processIdentity: ApplicationProcessIdentity?
        public let windowID: Int?
        public let windowIdentity: WindowMutationIdentity?
        public let windowBounds: CGRect?
        public let focusedElement: FocusedElementIdentity?

        public init(
            processIdentifier: Int32? = nil,
            processIdentity: ApplicationProcessIdentity? = nil,
            windowID: Int? = nil,
            windowIdentity: WindowMutationIdentity? = nil,
            windowBounds: CGRect? = nil,
            focusedElement: FocusedElementIdentity? = nil)
        {
            self.processIdentifier = processIdentifier
            self.processIdentity = processIdentity
            self.windowID = windowID
            self.windowIdentity = windowIdentity
            self.windowBounds = windowBounds
            self.focusedElement = focusedElement
        }

        public init(target: DesktopTargetIdentity) {
            switch target.target {
            case .foreground:
                preconditionFailure("DesktopTargetIdentity cannot contain a foreground target")
            case let .process(process):
                self.init(
                    processIdentifier: process.processIdentifier,
                    processIdentity: process.identity)
            case let .exactWindow(window):
                self.init(
                    processIdentifier: window.identity.ownerProcessIdentifier,
                    processIdentity: window.identity.processIdentity,
                    windowID: window.identity.windowID,
                    windowIdentity: window.identity,
                    windowBounds: window.bounds,
                    focusedElement: window.focusedElement)
            }
        }
    }

    public let target: UIAutomationTarget

    public var processIdentity: ApplicationProcessIdentity {
        guard let processIdentity = self.target.processIdentity else {
            preconditionFailure("A stable desktop target always contains a process identity")
        }
        return processIdentity
    }

    public var exactWindow: UIAutomationTarget.ExactWindow? {
        self.target.exactWindow
    }

    public init(processIdentity: ApplicationProcessIdentity) throws {
        guard processIdentity.processIdentifier > 0 else {
            throw DesktopTargetIdentityError.invalidProcessIdentifier
        }
        self.target = try .process(UIAutomationTarget.Process(
            processIdentifier: processIdentity.processIdentifier,
            identity: processIdentity))
    }

    public init(exactWindow: UIAutomationTarget.ExactWindow) {
        self.target = .exactWindow(exactWindow)
    }

    public func coalescing(_ other: DesktopTargetIdentity) throws -> DesktopTargetIdentity {
        guard let result = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve([
            Evidence(target: self),
            Evidence(target: other),
        ]) else {
            preconditionFailure("Coalescing two stable targets cannot produce missing evidence")
        }
        return result
    }
}

public enum DesktopTargetIdentityError: LocalizedError, Equatable, Sendable {
    case invalidProcessIdentifier
    case invalidWindowIdentifier
    case contradictoryProcessIdentifier
    case contradictoryProcessGeneration
    case contradictoryWindowIdentifier
    case contradictoryWindowIdentity
    case contradictoryWindowBounds
    case contradictoryFocusedElement
    case invalidFocusedElement
    case missingProcessGeneration
    case incompleteExactWindow
    case invalidatedSnapshotReceipt
    case invalidSnapshotIdentifier
    case snapshotSourceMismatch
    case coordinateReferenceMismatch
    case coordinateWindowMismatch
    case coordinateBoundsMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidProcessIdentifier:
            "Target PID must be positive."
        case .invalidWindowIdentifier:
            "Target window ID must be between 1 and \(UInt32.max)."
        case .contradictoryProcessIdentifier:
            "Target receipt sources identify different processes."
        case .contradictoryProcessGeneration:
            "Target receipt sources identify different process generations."
        case .contradictoryWindowIdentifier:
            "Target receipt sources identify different windows."
        case .contradictoryWindowIdentity:
            "Target receipt sources contain contradictory exact-window identities."
        case .contradictoryWindowBounds:
            "Target receipt sources contain contradictory exact-window bounds."
        case .contradictoryFocusedElement:
            "Target receipt sources contain contradictory focused-element identities."
        case .invalidFocusedElement:
            "Target receipt contains an invalid focused-element identity."
        case .missingProcessGeneration:
            "Target receipt has no process-generation identity."
        case .incompleteExactWindow:
            "Target receipt has incomplete exact-window identity or bounds evidence."
        case .invalidatedSnapshotReceipt:
            "Snapshot target receipt was invalidated by contradictory or removed metadata."
        case .invalidSnapshotIdentifier:
            "Snapshot identifier must not be empty."
        case .snapshotSourceMismatch:
            "Snapshot receipt sources refer to a different snapshot identifier."
        case .coordinateReferenceMismatch:
            "Capture coordinate reference does not identify the selected snapshot."
        case .coordinateWindowMismatch:
            "Capture coordinate metadata identifies a different exact window."
        case .coordinateBoundsMismatch:
            "Capture coordinate source bounds do not match the exact-window receipt."
        }
    }
}

/// A structural snapshot-receipt refusal proven before desktop mutation dispatch.
///
/// Only receipt-planning owners construct this wrapper. Callers may therefore release a mutation
/// lease for this error without weakening fail-closed handling for live drift or post-dispatch failures.
public struct SnapshotTargetReceiptPreDispatchError: LocalizedError, Equatable, Sendable {
    public let receiptError: DesktopTargetIdentityError

    init(_ receiptError: DesktopTargetIdentityError) {
        self.receiptError = receiptError
    }

    public var errorDescription: String? {
        switch self.receiptError {
        case .incompleteExactWindow:
            "Snapshot target receipt is incomplete: exact-window identity and immutable captured bounds are required."
        case .missingProcessGeneration:
            "Snapshot target receipt has no capture-time process-generation receipt."
        default:
            "Snapshot target receipt is invalid: \(self.receiptError.localizedDescription)"
        }
    }
}

/// Snapshot lifecycle plus optional stable target identity. Coordinate authority is admitted separately.
public struct SnapshotTargetReceipt: Equatable, Sendable {
    public enum TargetEvidence: Equatable, Sendable {
        case missing
        case available(DesktopTargetIdentity)
        case invalidated
    }

    public struct CoordinateAuthority: Equatable, Sendable {
        public let snapshotID: String
        public let target: UIAutomationTarget.ExactWindow
        public let sourceBounds: CGRect
        public let context: CaptureCoordinateContext

        public init(
            snapshotID: String,
            target: UIAutomationTarget.ExactWindow,
            sourceBounds: CGRect,
            context: CaptureCoordinateContext)
        {
            self.snapshotID = snapshotID
            self.target = target
            self.sourceBounds = sourceBounds
            self.context = context
        }
    }

    public let snapshotID: String
    public let targetEvidence: TargetEvidence
    public let applicationBundleIdentifier: String?
    public let applicationName: String?
    public let coordinateContext: CaptureCoordinateContext?

    public init(
        snapshotID: String,
        evidence: [DesktopTargetIdentity.Evidence],
        targetReceiptInvalidated: Bool = false,
        applicationBundleIdentifier: String? = nil,
        applicationName: String? = nil,
        coordinateContext: CaptureCoordinateContext? = nil) throws
    {
        guard !snapshotID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DesktopTargetIdentityError.invalidSnapshotIdentifier
        }
        self.snapshotID = snapshotID
        if targetReceiptInvalidated {
            self.targetEvidence = .invalidated
        } else if let identity = try DesktopTargetPlanning.DesktopTargetIdentityCoalescer.resolve(evidence) {
            self.targetEvidence = .available(identity)
        } else {
            self.targetEvidence = .missing
        }
        self.applicationBundleIdentifier = applicationBundleIdentifier
        self.applicationName = applicationName
        self.coordinateContext = coordinateContext
    }

    public var identity: DesktopTargetIdentity? {
        guard case let .available(identity) = self.targetEvidence else { return nil }
        return identity
    }

    public func requireIdentity() throws -> DesktopTargetIdentity {
        switch self.targetEvidence {
        case .missing:
            throw DesktopTargetIdentityError.missingProcessGeneration
        case let .available(identity):
            return identity
        case .invalidated:
            throw DesktopTargetIdentityError.invalidatedSnapshotReceipt
        }
    }

    public func requireCoordinateAuthority() throws -> CoordinateAuthority {
        let identity = try self.requireIdentity()
        guard let exactWindow = identity.exactWindow else {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        guard let context = self.coordinateContext,
              context.referenceID == self.snapshotID
        else {
            throw DesktopTargetIdentityError.coordinateReferenceMismatch
        }
        guard let coordinateWindow = context.window,
              coordinateWindow.windowID == exactWindow.identity.windowID
        else {
            throw DesktopTargetIdentityError.coordinateWindowMismatch
        }
        guard let sourceBounds = context.viewport?.sourceLogicalBounds ?? context.logicalBounds,
              sourceBounds == exactWindow.bounds
        else {
            throw DesktopTargetIdentityError.coordinateBoundsMismatch
        }
        return CoordinateAuthority(
            snapshotID: self.snapshotID,
            target: exactWindow,
            sourceBounds: sourceBounds,
            context: context)
    }
}

/// Namespace for pure target-planning components. Mutation planners are added by the follow-up slice.
public enum DesktopTargetPlanning {
    public enum DesktopTargetIdentityCoalescer {
        public static func exactWindow(
            from window: ServiceWindowInfo) throws -> UIAutomationTarget.ExactWindow
        {
            guard let identity = try self.resolve([
                .init(
                    windowID: window.windowID,
                    windowIdentity: window.mutationIdentity,
                    windowBounds: window.bounds),
            ]),
                let exactWindow = identity.exactWindow
            else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        }

        public static func coalesce(
            _ identities: [DesktopTargetIdentity?]) throws -> DesktopTargetIdentity?
        {
            try self.resolve(identities.compactMap { $0.map(DesktopTargetIdentity.Evidence.init(target:)) })
        }

        public static func resolve(
            _ evidence: [DesktopTargetIdentity.Evidence]) throws -> DesktopTargetIdentity?
        {
            var processIdentifier: Int32?
            var processIdentity: ApplicationProcessIdentity?
            var windowID: Int?
            var windowIdentity: WindowMutationIdentity?
            var windowBounds: CGRect?
            var focusedElement: FocusedElementIdentity?
            var hasAnyEvidence = false

            for fragment in evidence {
                hasAnyEvidence = hasAnyEvidence || fragment.processIdentifier != nil ||
                    fragment.processIdentity != nil || fragment.windowID != nil || fragment.windowIdentity != nil ||
                    fragment.windowBounds != nil || fragment.focusedElement != nil

                if let incomingProcessIdentifier = fragment.processIdentifier {
                    try self.requireValidProcessIdentifier(incomingProcessIdentifier)
                }
                try self.merge(fragment.processIdentifier, into: &processIdentifier) {
                    .contradictoryProcessIdentifier
                }
                try self.merge(fragment.processIdentity, into: &processIdentity) {
                    .contradictoryProcessGeneration
                }
                if let incomingWindowID = fragment.windowID {
                    try self.requireValidWindowIdentifier(incomingWindowID)
                }
                try self.merge(fragment.windowID, into: &windowID) {
                    .contradictoryWindowIdentifier
                }
                try self.merge(fragment.windowBounds, into: &windowBounds) {
                    .contradictoryWindowBounds
                }
                try self.merge(fragment.focusedElement, into: &focusedElement) {
                    .contradictoryFocusedElement
                }
                if let incomingWindowIdentity = fragment.windowIdentity {
                    try self.requireValidWindowIdentifier(incomingWindowIdentity.windowID)
                    if let currentWindowIdentity = windowIdentity,
                       !currentWindowIdentity.hasSameStableReceipt(as: incomingWindowIdentity)
                    {
                        throw DesktopTargetIdentityError.contradictoryWindowIdentity
                    }
                    windowIdentity = windowIdentity ?? incomingWindowIdentity
                }
            }

            guard hasAnyEvidence else { return nil }

            if let processIdentity {
                if let processIdentifier, processIdentifier != processIdentity.processIdentifier {
                    throw DesktopTargetIdentityError.contradictoryProcessIdentifier
                }
                processIdentifier = processIdentity.processIdentifier
            }
            if let windowIdentity {
                if let processIdentifier,
                   processIdentifier != windowIdentity.ownerProcessIdentifier
                {
                    throw DesktopTargetIdentityError.contradictoryProcessIdentifier
                }
                if let processIdentity,
                   processIdentity != windowIdentity.processIdentity
                {
                    throw DesktopTargetIdentityError.contradictoryProcessGeneration
                }
                if let windowID, windowID != windowIdentity.windowID {
                    throw DesktopTargetIdentityError.contradictoryWindowIdentifier
                }
                processIdentifier = windowIdentity.ownerProcessIdentifier
                processIdentity = windowIdentity.processIdentity
                windowID = windowIdentity.windowID
            }

            guard let resolvedProcessIdentity = processIdentity else {
                throw DesktopTargetIdentityError.missingProcessGeneration
            }
            guard resolvedProcessIdentity.processIdentifier > 0 else {
                throw DesktopTargetIdentityError.invalidProcessIdentifier
            }
            guard resolvedProcessIdentity.processStartIdentity > 0 else {
                throw DesktopTargetIdentityError.missingProcessGeneration
            }

            let hasWindowEvidence = windowID != nil || windowIdentity != nil || windowBounds != nil ||
                focusedElement != nil
            guard hasWindowEvidence else {
                return try DesktopTargetIdentity(processIdentity: resolvedProcessIdentity)
            }
            guard let windowIdentity,
                  let windowID,
                  let windowBounds,
                  let capturedBounds = windowIdentity.capturedBounds,
                  !windowBounds.isEmpty,
                  !capturedBounds.isEmpty
            else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            guard windowIdentity.windowID == windowID else {
                throw DesktopTargetIdentityError.contradictoryWindowIdentifier
            }
            guard capturedBounds == windowBounds else {
                throw DesktopTargetIdentityError.contradictoryWindowBounds
            }
            try self.validateFocusedElement(
                focusedElement,
                processIdentity: resolvedProcessIdentity,
                windowID: windowID,
                windowBounds: windowBounds)
            let exactWindow = try UIAutomationTarget.ExactWindow(
                processIdentifier: resolvedProcessIdentity.processIdentifier,
                windowID: windowID,
                identity: windowIdentity,
                bounds: windowBounds,
                focusedElement: focusedElement)
            let process = try UIAutomationTarget.Process(
                processIdentifier: resolvedProcessIdentity.processIdentifier,
                identity: resolvedProcessIdentity)
            let refined = try UIAutomationTarget.process(process).refined(to: exactWindow)
            guard let refinedWindow = refined.exactWindow else {
                preconditionFailure("Exact-window refinement must retain the exact target")
            }
            return DesktopTargetIdentity(exactWindow: refinedWindow)
        }

        private static func merge<Value: Equatable>(
            _ incoming: Value?,
            into current: inout Value?,
            conflict: () -> DesktopTargetIdentityError) throws
        {
            guard let incoming else { return }
            if let current, current != incoming {
                throw conflict()
            }
            current = current ?? incoming
        }

        private static func requireValidWindowIdentifier(_ windowID: Int) throws {
            guard windowID > 0, UInt32(exactly: windowID) != nil else {
                throw DesktopTargetIdentityError.invalidWindowIdentifier
            }
        }

        private static func requireValidProcessIdentifier(_ processIdentifier: Int32) throws {
            guard processIdentifier > 0 else {
                throw DesktopTargetIdentityError.invalidProcessIdentifier
            }
        }

        private static func validateFocusedElement(
            _ focusedElement: FocusedElementIdentity?,
            processIdentity: ApplicationProcessIdentity,
            windowID: Int,
            windowBounds: CGRect) throws
        {
            guard let focusedElement else { return }
            guard focusedElement.processIdentifier == processIdentity.processIdentifier,
                  focusedElement.windowID == windowID
            else {
                throw DesktopTargetIdentityError.contradictoryFocusedElement
            }
            guard !focusedElement.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !focusedElement.frame.isEmpty,
                  windowBounds.contains(CGPoint(
                      x: focusedElement.frame.midX,
                      y: focusedElement.frame.midY))
            else {
                throw DesktopTargetIdentityError.invalidFocusedElement
            }
        }
    }
}
