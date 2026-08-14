import AppKit
import Foundation
import PeekabooFoundation

@MainActor
extension ApplicationService {
    public func launchApplicationActionResult(
        request: ApplicationLaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        let access: DesktopOperationAccess = request.activates ? .write : .read
        return try await self.operationLaneCoordinator.run(scope: .global, access: access) {
            let preparedLaunch = try self.prepareApplicationLaunch(request)
            return try await self.performApplicationLaunchWithOutcomeOwnedLane(preparedLaunch)
        }
    }

    public func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest) async throws -> DesktopActionResult<ServiceApplicationInfo>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.performApplicationRelaunchWithOutcomeOwnedLane(request)
        }
    }

    public func activateApplicationActionResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let dispatch = try await self.performApplicationActivationWithOwnedLane(request)
            let outcome: DesktopActionOutcome = if let dispatch {
                .confirmedChange(delivery: dispatch.delivery, unitCount: dispatch.unitCount)
            } else {
                .confirmedNoChange()
            }
            return DesktopActionResult(outcome: outcome)
        }
    }

    public func quitApplicationActionResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Quitting application: \(request.identifier) (force: \(request.force))")
            let app = try await self.findApplication(identifier: request.identifier)
            let expectedIdentity: ApplicationProcessIdentity
            if let requestedIdentity = request.expectedIdentity {
                expectedIdentity = requestedIdentity
            } else if let resolvedIdentity = app.processIdentity {
                expectedIdentity = resolvedIdentity
            } else {
                throw PeekabooError.commandFailed(
                    "Could not capture a stable process-generation identity for \(app.name)")
            }
            try self.validateApplicationQuitIdentity(expectedIdentity, resolvedApplication: app)

            let attempt = try await self.quitApplicationWithOwnedLane(
                request: request,
                resolvedApplication: app,
                expectedIdentity: expectedIdentity)
            guard attempt.requestAccepted else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The quit request was not accepted for \(app.name).",
                    hint: "Refresh the application inventory before retrying.")
            }
            let delivery = Self.applicationDelivery(mode: .background)
            let outcome: DesktopActionOutcome = attempt.terminated
                ? .confirmedChange(delivery: delivery, unitCount: .one)
                : .suspectedNoop(delivery: delivery, unitCount: .one)
            return DesktopActionResult(payload: attempt.terminated, outcome: outcome)
        }
    }

    public func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.performApplicationVisibilityMutation(identifier: identifier, hidden: true)
    }

    public func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.performApplicationVisibilityMutation(identifier: identifier, hidden: false)
    }

    static func applicationDelivery(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome.Delivery
    {
        DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: mode)
    }

    static func postDispatchFailure(
        operation: String,
        mode: DesktopActionOutcome.Delivery.Mode,
        error: any Error,
        evidence: DesktopActionOutcome.DispatchedUnverifiedEvidence = .operationStillRunning,
        unitCount: DesktopActionOutcome.DispatchUnitCount = .one) -> DesktopActionFailure
    {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        return .dispatchedUnverified(
            delivery: self.applicationDelivery(mode: mode),
            evidence: evidence,
            unitCount: unitCount,
            message: "\(operation) was dispatched, but completion could not be confirmed.",
            hint: "Observe the target state before retrying.",
            causeDescription: String(describing: error))
    }

    static func postDispatchFailure(
        operation: String,
        dispatch: ApplicationActionDispatch,
        error: any Error,
        evidence: DesktopActionOutcome.DispatchedUnverifiedEvidence = .operationStillRunning) -> DesktopActionFailure
    {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        return .dispatchedUnverified(
            delivery: dispatch.delivery,
            evidence: evidence,
            unitCount: dispatch.unitCount,
            message: "\(operation) was dispatched, but completion could not be confirmed.",
            hint: "Observe the target state before retrying.",
            causeDescription: String(describing: error))
    }

    static func uncertainDispatchFailure(
        operation: String,
        mode: DesktopActionOutcome.Delivery.Mode,
        error: any Error) -> DesktopActionFailure
    {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        return .indeterminate(
            delivery: self.applicationDelivery(mode: mode),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "\(operation) may have been dispatched, but completion is unknown.",
            hint: "Observe the target state before retrying.",
            causeDescription: String(describing: error))
    }

    private func performApplicationVisibilityMutation(
        identifier: String,
        hidden requestedHiddenState: Bool) async throws -> DesktopActionResult<Void>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let app = try await self.findApplication(identifier: identifier)
            guard let processIdentity = app.processIdentity else {
                throw PeekabooError.commandFailed(
                    "Could not capture a stable process-generation identity for \(app.name)")
            }
            try self.validateApplicationQuitIdentity(processIdentity, resolvedApplication: app)
            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
                throw NotFoundError.application(identifier)
            }

            let isAlreadyRequestedState = try self.applicationHiddenProvider(runningApp) == requestedHiddenState
            guard !isAlreadyRequestedState else {
                return DesktopActionResult(outcome: .confirmedNoChange())
            }

            let attempt: ApplicationVisibilityAttempt
            do {
                attempt = try self.requestApplicationVisibility(runningApp, hidden: requestedHiddenState)
            } catch {
                throw Self.uncertainDispatchFailure(
                    operation: requestedHiddenState ? "Hide application" : "Unhide application",
                    mode: .background,
                    error: error)
            }

            let operation = requestedHiddenState ? "Hide application" : "Unhide application"
            if case .rejected = attempt {
                do {
                    if try self.applicationHiddenProvider(runningApp) == requestedHiddenState {
                        return DesktopActionResult(outcome: .confirmedNoChange())
                    }
                } catch {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "The application visibility request was not accepted for \(app.name).",
                        hint: "Refresh the application inventory before retrying.",
                        causeDescription: String(describing: error))
                }
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The application visibility request was not accepted for \(app.name).",
                    hint: "Refresh the application inventory before retrying.")
            }

            let delivery: DesktopActionOutcome.Delivery
            let unitCount: DesktopActionOutcome.DispatchUnitCount?
            let dispatch: ApplicationActionDispatch?
            let uncertainCauseDescription: String?
            switch attempt {
            case let .accepted(acceptedDispatch):
                delivery = acceptedDispatch.delivery
                unitCount = acceptedDispatch.unitCount
                dispatch = acceptedDispatch
                uncertainCauseDescription = nil
            case let .mayHaveDispatched(attemptDelivery, attemptUnitCount, causeDescription):
                delivery = attemptDelivery
                unitCount = attemptUnitCount
                dispatch = nil
                uncertainCauseDescription = causeDescription
            case .rejected:
                preconditionFailure("Rejected visibility attempts return before verification")
            }

            let deadline = Date().addingTimeInterval(self.applicationVisibilityTimeout)
            do {
                repeat {
                    if try self.applicationHiddenProvider(runningApp) == requestedHiddenState {
                        return DesktopActionResult(
                            outcome: .confirmedChange(
                                delivery: delivery,
                                unitCount: unitCount))
                    }
                    guard Date() < deadline else { break }
                    try await self.applicationVisibilitySleepHandler(.milliseconds(50))
                } while true
            } catch {
                if let dispatch {
                    throw Self.postDispatchFailure(
                        operation: operation,
                        dispatch: dispatch,
                        error: error,
                        evidence: .deliveryAccepted)
                }
                throw DesktopActionFailure.indeterminate(
                    delivery: delivery,
                    evidence: .completionUnknown,
                    unitCount: unitCount,
                    message: "\(operation) may have been dispatched, but completion is unknown.",
                    hint: "Observe the target state before retrying.",
                    causeDescription: String(describing: error))
            }

            guard let dispatch else {
                throw DesktopActionFailure.indeterminate(
                    delivery: delivery,
                    evidence: .completionUnknown,
                    unitCount: unitCount,
                    message: "\(operation) may have been dispatched, but completion is unknown.",
                    hint: "Observe the target state before retrying.",
                    causeDescription: uncertainCauseDescription)
            }
            throw DesktopActionFailure.suspectedNoop(
                delivery: dispatch.delivery,
                unitCount: dispatch.unitCount,
                message: "\(operation) was accepted, but the requested visibility did not change.",
                hint: "Refresh the application inventory before retrying.")
        }
    }
}
