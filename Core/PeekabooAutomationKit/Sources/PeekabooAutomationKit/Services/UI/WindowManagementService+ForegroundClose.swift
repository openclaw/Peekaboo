import AppKit
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    func closeWindowWithForegroundFallbackResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: expectedIdentity.ownerProcessIdentifier,
            processStartIdentity: expectedIdentity.ownerProcessStartIdentity,
            windowID: expectedIdentity.windowID)
        var sequence = DesktopActionSequenceAccumulator()

        do {
            let outcome = try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                let trackedWindowID = expectedIdentity.windowID
                let exactTarget = WindowTarget.windowId(trackedWindowID)
                try Task.checkCancellation()
                let windowServerInfo = self.windowIdentityService
                    .getWindowServerInfo(windowID: CGWindowID(trackedWindowID))
                guard hasSufficientMetadataForPinnedClose(
                    hasWindowServerMetadata: windowServerInfo != nil,
                    expectedMinimized: expectedIdentity.isMinimized == true)
                else {
                    throw PeekabooError.windowNotFound(criteria: "windowId \(trackedWindowID)")
                }

                let backgroundAttempt = if expectedIdentity.isMinimized == true {
                    PinnedWindowCloseAttemptResult(dispatchCount: 0, disappeared: false)
                } else {
                    try await self.attemptPinnedBackgroundClose(expectedIdentity)
                }
                if backgroundAttempt.dispatched {
                    let backgroundOutcome = backgroundAttempt.disappeared
                        ? WindowManagementActionOutcome.confirmedChange(
                            delivery: WindowManagementActionOutcome.backgroundActionDelivery,
                            dispatchCount: backgroundAttempt.dispatchCount)
                        : DesktopActionOutcome.suspectedNoop(
                            delivery: WindowManagementActionOutcome.backgroundActionDelivery,
                            unitCount: Self.windowDispatchUnitCount(backgroundAttempt.dispatchCount))
                    if backgroundAttempt.disappeared {
                        return backgroundOutcome
                    }
                    sequence.record(.outcome(backgroundOutcome))
                }

                self.logger.warning(
                    "Background close left window; foreground fallback. id=\(trackedWindowID, privacy: .public)")

                do {
                    try Task.checkCancellation()
                    let focusIdentity = try await prepareForegroundCloseIdentity(
                        expectedIdentity: expectedIdentity,
                        restoreMinimized: {
                            try await self.restorePinnedMinimizedWindow(
                                expectedIdentity,
                                onDispatchAccepted: {
                                    ForegroundCloseRecoveryAccounting.recordAcceptedDispatch(in: &sequence)
                                })
                        })
                    let window = try await self.element(for: exactTarget)
                    try self.validatePinnedWindowElement(window, expectedIdentity: focusIdentity)
                    let focusService = FocusManagementService(
                        applications: self.applicationService,
                        operationLaneCoordinator: self.operationLaneCoordinator)
                    try await focusService.focusWindowWithOwnedLane(
                        windowID: CGWindowID(trackedWindowID),
                        options: foregroundCloseFocusOptions(),
                        expectedIdentity: focusIdentity,
                        onDispatch: { record in
                            sequence.record(record.sequenceStep)
                        })
                    try await self.requirePinnedForegroundCloseReadiness(
                        focusIdentity,
                        focusSucceeded: true)

                    try await self.dispatchForegroundCloseHotkey(
                        keys: ["cmd", "w"],
                        sequence: &sequence)
                    if try await self.pinnedWindowDisappeared(expectedIdentity) {
                        return try Self.confirmedCloseOutcome(sequence)
                    }

                    // Cmd-W may surface a sheet or move key status to a sibling. Re-prove the exact
                    // target immediately before the broader Cmd-Shift-W fallback.
                    try await self.requirePinnedForegroundCloseReadiness(
                        focusIdentity,
                        focusSucceeded: true)
                    try await self.dispatchForegroundCloseHotkey(
                        keys: ["cmd", "shift", "w"],
                        sequence: &sequence)
                    if try await self.pinnedWindowDisappeared(expectedIdentity) {
                        return try Self.confirmedCloseOutcome(sequence)
                    }

                    let resolution = sequence.successResolution()
                    guard let delivery = resolution.outcome?.delivery else {
                        throw OperationError.interactionFailed(
                            action: "close window",
                            reason: "Foreground close completed without canonical delivery evidence")
                    }
                    throw DesktopActionFailure.dispatchedUnverified(
                        delivery: delivery,
                        evidence: .deliveryAccepted,
                        unitCount: resolution.mutationDisposition.unitCount,
                        message: "Foreground close was dispatched, but the exact window remained visible.",
                        hint: "Observe the exact window before retrying.")
                } catch is CancellationError
                    where !sequence.mutationDisposition.mutationDispatched
                {
                    throw CancellationError()
                } catch {
                    if ForegroundCloseRecoveryAccounting.shouldRecover(
                        wasMinimized: expectedIdentity.isMinimized == true,
                        sequence: sequence)
                    {
                        do {
                            _ = try await self.restorePinnedMinimizedWindow(
                                expectedIdentity,
                                onDispatchAccepted: {
                                    ForegroundCloseRecoveryAccounting.recordAcceptedDispatch(in: &sequence)
                                })
                        } catch {
                            // The acceptance callback records a definite recovery unit before repin.
                        }
                    }
                    throw error
                }
            }
            return DesktopActionResult(outcome: outcome)
        } catch let failure as DesktopActionFailure {
            throw Self.compositeCloseFailure(
                failure,
                sequence: sequence,
                targetReceipt: targetReceipt)
        } catch is CancellationError {
            if let failure = sequence.cancellationFailure(
                fallbackRoute: .local,
                message: "Window close was cancelled after dispatch may have begun.",
                hint: "Observe the exact window before retrying close.",
                causeDescription: "Close task cancelled")
            {
                throw failure.attributed(to: targetReceipt)
            }
            throw CancellationError()
        } catch {
            let failure = WindowManagementActionOutcome.refused(action: "close window", error: error)
            throw sequence.failure(
                combining: failure,
                message: "Window close did not complete with a verified exact result.",
                hint: "Observe the exact window before retrying close.")
                .attributed(to: targetReceipt)
        }
    }

    private func dispatchForegroundCloseHotkey(
        keys: [String],
        sequence: inout DesktopActionSequenceAccumulator) async throws
    {
        try Task.checkCancellation()
        do {
            try InputDriver.hotkey(keys: keys, holdDuration: 0.05)
            sequence.record(.dispatched(
                route: .local,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: .one))
        } catch {
            sequence.record(.mayHaveDispatched(
                route: .local,
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                unitCount: .one))
            throw error
        }
    }

    private static func confirmedCloseOutcome(
        _ sequence: DesktopActionSequenceAccumulator) throws -> DesktopActionOutcome
    {
        let resolution = sequence.successResolution()
        guard case .definite = resolution.mutationDisposition,
              let delivery = resolution.outcome?.delivery,
              let unitCount = resolution.mutationDisposition.unitCount
        else {
            throw PeekabooError.commandFailed(
                "Verified window close completed without exact dispatch accounting")
        }
        return .confirmedChange(delivery: delivery, unitCount: unitCount)
    }

    private static func compositeCloseFailure(
        _ failure: DesktopActionFailure,
        sequence: DesktopActionSequenceAccumulator,
        targetReceipt: DesktopActionTargetReceipt) -> DesktopActionFailure
    {
        let resolution = sequence.successResolution()
        if failure.outcome.delivery == resolution.outcome?.delivery,
           failure.outcome.dispatchState.unitCount == resolution.mutationDisposition.unitCount
        {
            return failure.attributed(to: targetReceipt)
        }
        return sequence.failure(
            combining: failure,
            message: "Window close did not complete with a verified exact result.",
            hint: "Observe the exact window before retrying close.")
            .attributed(to: targetReceipt)
    }

    private static func windowDispatchUnitCount(
        _ count: Int) -> DesktopActionOutcome.DispatchUnitCount
    {
        guard let count = DesktopActionOutcome.DispatchUnitCount(count) else {
            preconditionFailure("A window dispatch count must be positive")
        }
        return count
    }
}

func foregroundCloseFocusOptions() -> FocusManagementService.FocusOptions {
    .init(switchSpace: true)
}

@MainActor
func prepareForegroundCloseIdentity(
    expectedIdentity: WindowMutationIdentity,
    restoreMinimized: @MainActor () async throws -> WindowMutationIdentity) async throws -> WindowMutationIdentity
{
    guard expectedIdentity.isMinimized == true else { return expectedIdentity }
    return try await restoreMinimized()
}

enum ForegroundCloseRecoveryAccounting {
    static func shouldRecover(
        wasMinimized: Bool,
        sequence: DesktopActionSequenceAccumulator) -> Bool
    {
        wasMinimized && sequence.mutationDisposition.mutationDispatched
    }

    static func recordAcceptedDispatch(in sequence: inout DesktopActionSequenceAccumulator) {
        sequence.record(.dispatched(
            route: .local,
            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
            unitCount: .one))
    }
}
