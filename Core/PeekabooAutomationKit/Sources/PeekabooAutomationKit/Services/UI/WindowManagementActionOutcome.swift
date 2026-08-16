import CoreGraphics
import Foundation
import PeekabooFoundation

struct WindowGeometryDispatchAcceptance: Equatable {
    let positionAccepted: Bool
    let sizeAccepted: Bool

    var dispatchCount: Int {
        (self.positionAccepted ? 1 : 0) + (self.sizeAccepted ? 1 : 0)
    }
}

enum WindowManagementActionOutcome {
    static let backgroundActionDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)
    static let backgroundValueDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityValue,
        mode: .background)

    static func confirmedChange(
        delivery: DesktopActionOutcome.Delivery,
        dispatchCount: Int) -> DesktopActionOutcome
    {
        .confirmedChange(
            delivery: delivery,
            unitCount: self.dispatchUnitCount(dispatchCount))
    }

    static var confirmedNoChange: DesktopActionOutcome {
        .confirmedNoChange()
    }

    @MainActor
    static func perform(
        action: String,
        operation: @MainActor () async throws -> DesktopActionOutcome) async throws -> DesktopActionOutcome?
    {
        do {
            return try await operation()
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw self.refused(action: action, error: error)
        }
    }

    static func refused(
        action: String,
        error: any Error) -> DesktopActionFailure
    {
        let reason = self.refusalReason(for: error)
        return .refused(
            reason: reason,
            message: error.localizedDescription,
            hint: self.refusalHint(reason: reason, action: action),
            causeDescription: String(describing: error))
    }

    static func suspectedNoop(
        action: String,
        delivery: DesktopActionOutcome.Delivery,
        dispatchCount: Int,
        cause: (any Error)? = nil) -> DesktopActionFailure
    {
        .suspectedNoop(
            delivery: delivery,
            unitCount: self.dispatchUnitCount(dispatchCount),
            message: "The \(action) request was accepted, but the exact window remained in its prior state",
            hint: "Refresh the exact window receipt before retrying.",
            causeDescription: cause.map { String(describing: $0) })
    }

    static func dispatchedUnverified(
        action: String,
        delivery: DesktopActionOutcome.Delivery,
        dispatchCount: Int,
        cause: any Error) -> DesktopActionFailure
    {
        .dispatchedUnverified(
            delivery: delivery,
            evidence: .deliveryAccepted,
            unitCount: self.dispatchUnitCount(dispatchCount),
            message: "The \(action) request was accepted, but its exact result could not be verified",
            hint: "Observe the exact window before retrying.",
            causeDescription: String(describing: cause))
    }

    static func refusalReason(for error: any Error) -> DesktopActionOutcome.RefusalReason {
        if let error = error as? PeekabooError {
            switch error {
            case .permissionDeniedScreenRecording, .permissionDeniedAccessibility,
                 .permissionDeniedEventSynthesizing, .permissionDenied:
                return .permissionDenied
            case .invalidCoordinates, .invalidInput, .ambiguousAppIdentifier:
                return .invalidRequest
            case .appNotFound, .windowNotFound, .notFound, .commandFailed:
                return .targetUnavailable
            case .serviceUnavailable, .notImplemented:
                return .runtimeIncompatible
            default:
                return .operationUnsupported
            }
        }
        if let error = error as? any StandardizedError {
            switch error.code {
            case .screenRecordingPermissionDenied, .accessibilityPermissionDenied,
                 .eventSynthesizingPermissionDenied:
                return .permissionDenied
            case .applicationNotFound, .windowNotFound:
                return .targetUnavailable
            case .invalidInput, .invalidCoordinates, .invalidWindowIndex, .ambiguousAppIdentifier:
                return .invalidRequest
            default:
                return .operationUnsupported
            }
        }
        return .operationUnsupported
    }

    private static func refusalHint(
        reason: DesktopActionOutcome.RefusalReason,
        action: String) -> String
    {
        switch reason {
        case .permissionDenied:
            "Grant Accessibility permission before retrying \(action)."
        case .targetUnavailable:
            "Refresh the exact window receipt before retrying."
        case .transportSessionUnavailable:
            "Reconnect the transport session before retrying."
        case .requestCancelled:
            "Submit a new request only if the operation is still wanted."
        case .runtimeIncompatible:
            "Update the runtime host before retrying."
        case .invalidRequest:
            "Correct the window target or mutation receipt before retrying."
        case .foregroundConsentRequired:
            "Retry only with explicit foreground consent."
        case .operationUnsupported:
            "Use a window and host that support \(action)."
        }
    }

    private static func dispatchUnitCount(_ value: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let count = DesktopActionOutcome.DispatchUnitCount(value) else {
            preconditionFailure("Window mutation dispatch counts must be positive")
        }
        return count
    }
}

@MainActor
extension WindowManagementService {
    func geometryVerificationFailure(
        action: String,
        expectedIdentity: WindowMutationIdentity,
        dispatchCount: Int,
        cause: any Error) -> DesktopActionFailure
    {
        let current = self.windowIdentityService.getWindowServerInfo(
            windowID: CGWindowID(expectedIdentity.windowID))
        if let current,
           current.ownerPID == expectedIdentity.ownerProcessIdentifier,
           SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
           current.bounds == expectedIdentity.capturedBounds
        {
            return WindowManagementActionOutcome.suspectedNoop(
                action: action,
                delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                dispatchCount: dispatchCount,
                cause: cause)
        }
        return WindowManagementActionOutcome.dispatchedUnverified(
            action: action,
            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
            dispatchCount: dispatchCount,
            cause: cause)
    }
}
