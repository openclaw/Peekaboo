import AppKit
import AXorcist
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
        do {
            return try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
                try await self.performApplicationRelaunchWithOutcomeOwnedLane(request)
            }
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: request.expectedTargetIdentity.map(Self.applicationTargetReceipt))
        }
    }

    public func activateApplicationActionResult(
        request: ApplicationActivationRequest) async throws -> DesktopActionResult<Void>
    {
        do {
            return try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
                let dispatch = try await self.performApplicationActivationWithOwnedLane(request)
                let outcome: DesktopActionOutcome = if let dispatch {
                    .confirmedChange(delivery: dispatch.delivery, unitCount: dispatch.unitCount)
                } else {
                    .confirmedNoChange()
                }
                return DesktopActionResult(outcome: outcome)
            }
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: request.expectedIdentity.map(Self.applicationTargetReceipt))
        }
    }

    public func activateApplicationTargetedActionResult(
        request: ApplicationActivationRequest) async throws -> UIAutomationActionResult<Void>
    {
        let app = try await self.findApplication(identifier: request.identifier)
        guard let identity = request.expectedIdentity ?? app.processIdentity,
              app.processIdentity == identity
        else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(app.name)")
        }
        try self.validateApplicationQuitIdentity(identity, resolvedApplication: app)
        let result: DesktopActionResult<Void>
        do {
            result = try await self.activateApplicationActionResult(request: .init(
                identifier: "PID:\(identity.processIdentifier)",
                expectedIdentity: identity))
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: Self.applicationTargetReceipt(identity))
        }
        return try UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(processIdentity: identity))
    }

    public func quitApplicationActionResult(
        request: ApplicationQuitRequest) async throws -> DesktopActionResult<Bool>
    {
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

        do {
            return try await self.operationLaneCoordinator.run(scope: .process(expectedIdentity), access: .write) {
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
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: Self.applicationTargetReceipt(expectedIdentity))
        }
    }

    public func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.performApplicationVisibilityMutation(
            identifier: identifier,
            hidden: true,
            expectedIdentity: nil)
    }

    public func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.performApplicationVisibilityMutation(
            identifier: identifier,
            hidden: false,
            expectedIdentity: nil)
    }

    public func hideApplicationTargetedActionResult(identifier: String) async throws -> UIAutomationActionResult<Void> {
        let app = try await self.findApplication(identifier: identifier)
        guard let identity = app.processIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(app.name)")
        }
        return try await self.hideApplicationTargetedActionResult(request: .init(
            identifier: "PID:\(identity.processIdentifier)",
            expectedIdentity: identity))
    }

    public func hideApplicationTargetedActionResult(
        request: ApplicationHideRequest) async throws -> UIAutomationActionResult<Void>
    {
        let result: DesktopActionResult<Void>
        do {
            result = try await self.performApplicationVisibilityMutation(
                identifier: request.identifier,
                hidden: true,
                expectedIdentity: request.expectedIdentity)
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: Self.applicationTargetReceipt(request.expectedIdentity))
        }
        return try UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: DesktopTargetIdentity(processIdentity: request.expectedIdentity))
    }

    public func hideOtherApplicationsActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Hiding other applications except: \(identifier)")
            let app = try await self.findApplication(identifier: identifier)
            guard let processIdentity = app.processIdentity else {
                throw PeekabooError.commandFailed(
                    "Could not capture a stable process-generation identity for \(app.name)")
            }
            try self.validateApplicationQuitIdentity(processIdentity, resolvedApplication: app)
            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
                throw NotFoundError.application(identifier)
            }
            try Self.checkApplicationDispatchCancellation(operation: "hide other applications")

            let visibleOthers = NSWorkspace.shared.runningApplications.filter { candidate in
                candidate.processIdentifier != app.processIdentifier &&
                    candidate.activationPolicy == .regular &&
                    candidate.bundleIdentifier != "com.apple.finder" &&
                    !candidate.isHidden
            }
            guard !visibleOthers.isEmpty else {
                return DesktopActionResult(outcome: .confirmedNoChange())
            }
            try self.validateApplicationQuitIdentity(processIdentity, resolvedApplication: app)

            do {
                try Self.checkApplicationDispatchCancellation(operation: "Hide other applications")
                try AXApp(runningApp).element.performAction(Attribute<String>("AXHideOthers"))
                return DesktopActionResult(outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted))
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch {
                self.logger.debug("AX hide-others failed; hiding apps individually")
                let remainingVisible = visibleOthers.filter { !$0.isHidden }
                guard !remainingVisible.isEmpty else {
                    throw DesktopActionFailure.indeterminate(
                        delivery: .init(mechanism: .accessibilityAction, mode: .background),
                        evidence: .completionUnknown,
                        unitCount: .one,
                        message: "Hide-other-applications reached the requested state after ambiguous AX dispatch.",
                        hint: "Observe application visibility before retrying.",
                        causeDescription: String(describing: error))
                }
                var acceptedCount = 0
                for candidate in remainingVisible {
                    try Self.checkApplicationFallbackCancellation(
                        operation: "Hide other applications",
                        acceptedFallbackCount: acceptedCount)
                    if candidate.hide() {
                        acceptedCount += 1
                    }
                }
                return try Self.applicationVisibilityFallbackResult(
                    operation: "Hide-other-applications",
                    acceptedCount: acceptedCount,
                    snapshotCount: remainingVisible.count,
                    primaryError: error)
            }
        }
    }

    public func showAllApplicationsActionResult() async throws -> DesktopActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Showing all applications")
            let hiddenApps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && $0.isHidden
            }
            guard !hiddenApps.isEmpty else {
                return DesktopActionResult(outcome: .confirmedNoChange())
            }

            do {
                try Self.dispatchShowAllApplicationsAXAction {
                    try Element.systemWide().performAction(Attribute<String>("AXShowAll"))
                }
                return DesktopActionResult(outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted))
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch {
                self.logger.debug("AX show-all failed; unhiding apps individually")
                let remainingHidden = hiddenApps.filter(\.isHidden)
                guard !remainingHidden.isEmpty else {
                    throw DesktopActionFailure.indeterminate(
                        delivery: .init(mechanism: .accessibilityAction, mode: .background),
                        evidence: .completionUnknown,
                        unitCount: .one,
                        message: "Show-all-applications reached the requested state after ambiguous AX dispatch.",
                        hint: "Observe application visibility before retrying.",
                        causeDescription: String(describing: error))
                }
                var acceptedCount = 0
                for candidate in remainingHidden {
                    try Self.checkApplicationFallbackCancellation(
                        operation: "Show all applications",
                        acceptedFallbackCount: acceptedCount)
                    if candidate.unhide() {
                        acceptedCount += 1
                    }
                }
                return try Self.applicationVisibilityFallbackResult(
                    operation: "Show-all-applications",
                    acceptedCount: acceptedCount,
                    snapshotCount: remainingHidden.count,
                    primaryError: error)
            }
        }
    }

    static func dispatchShowAllApplicationsAXAction(
        checkCancellation: () throws -> Void = { try Task.checkCancellation() },
        submit: () throws -> Void) throws
    {
        try self.checkApplicationDispatchCancellation(
            operation: "Show all applications",
            checkCancellation)
        try submit()
    }

    static func applicationVisibilityFallbackResult(
        operation: String,
        acceptedCount: Int,
        snapshotCount: Int,
        primaryError: any Error) throws -> DesktopActionResult<Void>
    {
        precondition(snapshotCount > 0 && (0...snapshotCount).contains(acceptedCount))
        let fallbackSummary = "Fallback accepted \(acceptedCount) of \(snapshotCount) native requests."
        guard acceptedCount > 0 else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "\(operation) may have started, but no fallback request was accepted " +
                    "(\(acceptedCount) of \(snapshotCount)).",
                hint: "Observe application visibility before retrying.",
                causeDescription: "\(fallbackSummary) Accessibility failure: \(String(describing: primaryError))")
        }

        throw DesktopActionFailure.indeterminate(
            delivery: nil,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(acceptedCount + 1),
            message: "\(operation) has mixed unknown effects after accepting " +
                "\(acceptedCount) of \(snapshotCount) fallback requests.",
            hint: "Observe application visibility before retrying.",
            causeDescription: "\(fallbackSummary) Accessibility failure: \(String(describing: primaryError))")
    }

    static func applicationDelivery(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome.Delivery
    {
        DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: mode)
    }

    private static func applicationTargetReceipt(
        _ identity: ApplicationProcessIdentity) -> DesktopActionTargetReceipt
    {
        DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity)
    }

    static func checkApplicationDispatchCancellation(
        operation: String,
        _ checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws
    {
        do {
            try checkCancellation()
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "\(operation) was cancelled before native dispatch.",
                hint: "Submit a new request only if the application action is still wanted.")
        }
    }

    static func checkApplicationFallbackCancellation(
        operation: String,
        acceptedFallbackCount: Int = 0,
        _ checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws
    {
        precondition(acceptedFallbackCount >= 0)
        do {
            try checkCancellation()
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: acceptedFallbackCount == 0
                    ? .init(mechanism: .accessibilityAction, mode: .background)
                    : nil,
                evidence: .completionUnknown,
                unitCount: DesktopActionOutcome.DispatchUnitCount(acceptedFallbackCount + 1),
                message: "\(operation) was cancelled after AX delivery may have started and " +
                    "\(acceptedFallbackCount) fallback request(s) were accepted.",
                hint: "Observe application visibility before retrying.")
        }
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

    private func validateApplicationVisibilityIdentity(
        _ expectedIdentity: ApplicationProcessIdentity,
        resolvedApplication: ServiceApplicationInfo) throws
    {
        do {
            try self.validateApplicationQuitIdentity(
                expectedIdentity,
                resolvedApplication: resolvedApplication)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Application PID \(expectedIdentity.processIdentifier) disappeared or changed " +
                    "process generation before visibility dispatch.",
                hint: "Refresh the application inventory before retrying.",
                causeDescription: String(describing: error))
                .attributed(to: expectedIdentity)
        }
    }

    private func readApplicationHiddenState(
        _ application: NSRunningApplication,
        expectedIdentity: ApplicationProcessIdentity,
        operation: String) throws -> Bool
    {
        guard application.processIdentifier == expectedIdentity.processIdentifier,
              self.processStartIdentityProvider(application.processIdentifier) ==
              expectedIdentity.processStartIdentity
        else {
            throw PeekabooError.commandFailed(
                "\(operation) target changed process generation before its result observation")
        }
        let isHidden = try self.applicationHiddenProvider(application)
        guard self.processStartIdentityProvider(application.processIdentifier) ==
            expectedIdentity.processStartIdentity
        else {
            throw PeekabooError.commandFailed(
                "\(operation) target changed process generation during its result observation")
        }
        return isHidden
    }

    private func performApplicationVisibilityMutation(
        identifier: String,
        hidden requestedHiddenState: Bool,
        expectedIdentity: ApplicationProcessIdentity?) async throws -> DesktopActionResult<Void>
    {
        let app = try await self.findApplication(identifier: identifier)
        guard let processIdentity = expectedIdentity ?? app.processIdentity else {
            throw PeekabooError.commandFailed(
                "Could not capture a stable process-generation identity for \(app.name)")
        }
        guard app.processIdentity == processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The application visibility target changed process generation before dispatch.",
                hint: "Refresh the application inventory before retrying.")
                .attributed(to: processIdentity)
        }
        try self.validateApplicationVisibilityIdentity(processIdentity, resolvedApplication: app)

        return try await self.operationLaneCoordinator.run(scope: .process(processIdentity), access: .write) {
            try self.validateApplicationVisibilityIdentity(processIdentity, resolvedApplication: app)
            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else {
                throw NotFoundError.application(identifier)
            }
            try self.validateApplicationVisibilityIdentity(processIdentity, resolvedApplication: app)

            let isAlreadyRequestedState = try self.applicationHiddenProvider(runningApp) == requestedHiddenState
            try self.validateApplicationVisibilityIdentity(processIdentity, resolvedApplication: app)
            guard !isAlreadyRequestedState else {
                return DesktopActionResult(outcome: .confirmedNoChange())
            }
            try Self.checkApplicationDispatchCancellation(
                operation: requestedHiddenState ? "Hide application" : "Unhide application")
            try self.validateApplicationVisibilityIdentity(processIdentity, resolvedApplication: app)

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
                    if try self.readApplicationHiddenState(
                        runningApp,
                        expectedIdentity: processIdentity,
                        operation: operation) == requestedHiddenState
                    {
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

            let delivery: DesktopActionOutcome.Delivery?
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
                    if try self.readApplicationHiddenState(
                        runningApp,
                        expectedIdentity: processIdentity,
                        operation: operation) == requestedHiddenState
                    {
                        guard let dispatch else {
                            throw DesktopActionFailure.indeterminate(
                                delivery: delivery,
                                evidence: .completionUnknown,
                                unitCount: unitCount,
                                message: "\(operation) reached the requested state after an ambiguous dispatch.",
                                hint: "Observe the target before retrying.",
                                causeDescription: uncertainCauseDescription)
                        }
                        return DesktopActionResult(
                            outcome: .confirmedChange(
                                delivery: dispatch.delivery,
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
                if let failure = error as? DesktopActionFailure {
                    throw failure
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
