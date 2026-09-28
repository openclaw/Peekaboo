import ApplicationServices
import CoreGraphics
import Foundation
import os
import PeekabooFoundation

enum PinnedWindowGeometryValue: Equatable, Sendable {
    case position(CGPoint)
    case size(CGSize)
}

struct PinnedWindowGeometryDispatch: Sendable {
    enum State: Equatable, Sendable {
        case notDispatched
        case accepted
        case completionUnknown
    }

    let state: State
    let identityRemainedPinned: Bool

    static let notDispatched = Self(state: .notDispatched, identityRemainedPinned: false)

    init(state: State, identityRemainedPinned: Bool) {
        self.state = state
        self.identityRemainedPinned = identityRemainedPinned
    }

    init(nativeResult: AXError, identityRemainedPinned: Bool) {
        self.state = if nativeResult == .success {
            .accepted
        } else if ActionInputDriver.nativeMutationFailureMayHaveDispatched(ActionInputDriver.classify(nativeResult)) {
            .completionUnknown
        } else {
            .notDispatched
        }
        self.identityRemainedPinned = identityRemainedPinned
    }
}

struct PinnedWindowGeometryAdmission: Sendable {
    let deadline: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    init(deadline: ContinuousClock.Instant, now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.deadline = deadline
        self.now = now
    }

    func cancel() {
        self.cancelled.withLock { $0 = true }
    }

    func check() throws {
        try self.cancelled.withLock { cancelled in
            if cancelled {
                throw CancellationError()
            }
            guard self.now() < self.deadline else {
                throw PeekabooError.timeout("Window geometry exceeded its shared deadline")
            }
        }
    }

    var remainingSeconds: TimeInterval? {
        self.cancelled.withLock { cancelled in
            guard !cancelled else { return nil }
            let duration = self.now().duration(to: self.deadline).components
            let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
            return seconds > 0 ? seconds : nil
        }
    }

    /// This is the last admission point. Cancellation after it must drain and account for the native call.
    func claimWrite() -> Bool {
        self.remainingSeconds != nil
    }
}

struct PinnedWindowGeometryFailure: Error {
    let mutation: DesktopActionMutationDisposition
    let cause: any Error
}

@MainActor
struct PinnedWindowGeometryOperations {
    let dispatch: (
        WindowMutationIdentity,
        PinnedWindowGeometryValue,
        PinnedWindowGeometryAdmission) async throws -> PinnedWindowGeometryDispatch
    let repin: (WindowMutationIdentity, CGRect, ContinuousClock.Instant) async throws -> WindowMutationIdentity
    let validateNoChange: (WindowMutationIdentity, PinnedWindowGeometryAdmission) async throws -> Bool
    var now: @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
}

@MainActor
func completePinnedWindowGeometry(
    expectedIdentity: WindowMutationIdentity,
    bounds: CGRect,
    operations: PinnedWindowGeometryOperations,
    timeout: Duration = .seconds(2)) async throws -> DesktopActionMutationDisposition
{
    let admission = PinnedWindowGeometryAdmission(
        deadline: operations.now().advanced(by: timeout),
        now: operations.now)
    return try await withTaskCancellationHandler {
        var progress = DesktopActionSequenceAccumulator()
        do {
            try admission.check()
            guard let originalBounds = expectedIdentity.capturedBounds else {
                throw PeekabooError.commandFailed("Window geometry receipt lacks capture-time bounds")
            }
            var steps: [(PinnedWindowGeometryValue, CGRect)] = []
            if originalBounds.origin != bounds.origin {
                steps.append((.position(bounds.origin), CGRect(origin: bounds.origin, size: originalBounds.size)))
            }
            if originalBounds.size != bounds.size {
                steps.append((.size(bounds.size), bounds))
            }
            if steps.isEmpty {
                let valid = try await operations.validateNoChange(expectedIdentity, admission)
                try admission.check()
                guard valid else {
                    throw PeekabooError.windowNotFound(criteria: "The exact unchanged window could not be verified")
                }
            }
            var identity = expectedIdentity
            for (value, expectedBounds) in steps {
                try admission.check()
                let dispatch = try await operations.dispatch(identity, value, admission)
                switch dispatch.state {
                case .notDispatched:
                    try admission.check()
                    throw OperationError.interactionFailed(
                        action: "window geometry",
                        reason: "The native geometry write was not admitted")
                case .accepted:
                    progress.record(.dispatched(
                        route: .local,
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        unitCount: .one))
                case .completionUnknown:
                    progress.record(.mayHaveDispatched(
                        route: .local,
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        unitCount: .one))
                    throw PeekabooError.commandFailed("The native geometry write's completion is unknown")
                }
                guard dispatch.identityRemainedPinned else {
                    throw PeekabooError.commandFailed("Window identity changed during geometry dispatch")
                }
                try admission.check()
                // AX acceptance can precede layout. Never issue a dependent write against an unsettled frame.
                identity = try await operations.repin(identity, expectedBounds, admission.deadline)
                guard identity.windowID == expectedIdentity.windowID,
                      identity.processIdentity == expectedIdentity.processIdentity,
                      let observed = identity.capturedBounds,
                      WindowMutationGeometryPostcondition.boundsMatch(observed, expectedBounds)
                else {
                    throw PeekabooError.commandFailed("Geometry readback did not preserve the exact expected target")
                }
                try admission.check()
            }
            return progress.mutationDisposition
        } catch {
            throw PinnedWindowGeometryFailure(mutation: progress.mutationDisposition, cause: error)
        }
    } onCancel: {
        admission.cancel()
    }
}
