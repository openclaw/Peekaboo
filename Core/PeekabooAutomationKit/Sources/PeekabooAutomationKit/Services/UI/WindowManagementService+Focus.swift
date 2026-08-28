import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    public func focusWindow(target: WindowTarget) async throws {
        _ = try await self.focusWindowActionResult(target: target)
    }

    public func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        let pinned = try await self.pinnedWindowMutation(for: target)
        return try await self.focusWindowActionResult(
            target: pinned.target,
            expectedIdentity: pinned.identity)
    }

    public func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        let result = try await self.focusWindowProofActionResult(target: target, expectedIdentity: expectedIdentity)
        return UIAutomationActionResult(
            payload: (),
            outcome: result.outcome,
            targetIdentity: result.targetIdentity,
            selectedLeafEvidence: result.selectedLeafEvidence)
    }

    public func focusWindowProofActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<ServiceWindowInfo>
    {
        try await self.focusWindowProofActionResult(
            target: target,
            expectedIdentity: expectedIdentity,
            validateBeforeDispatch: {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            },
            dispatch: { options, onDispatch in
                let focusService = FocusManagementService(
                    applications: self.applicationService,
                    operationLaneCoordinator: self.operationLaneCoordinator)
                try await focusService.focusWindowWithOwnedLane(
                    windowID: CGWindowID(expectedIdentity.windowID),
                    options: options,
                    expectedIdentity: expectedIdentity,
                    onDispatch: onDispatch)
            },
            readback: WindowFocusReadback(catalog: self.cgInfoLookup))
    }

    func focusWindowProofActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        validateBeforeDispatch: () throws -> Void,
        dispatch: (
            _ options: FocusManagementService.FocusOptions,
            _ onDispatch: @escaping (FocusDispatchRecord) -> Void) async throws -> Void,
        readback: WindowFocusReadback) async throws -> UIAutomationActionResult<ServiceWindowInfo>
    {
        guard case let .windowId(windowID) = target,
              windowID == expectedIdentity.windowID,
              let bounds = expectedIdentity.capturedBounds
        else {
            throw PeekabooError.commandFailed(
                "Exact focus target contradicts its process-generation receipt")
        }
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: expectedIdentity, bounds: bounds)
        let targetIdentity = DesktopTargetIdentity(exactWindow: exactWindow)
        let targetReceipt = expectedIdentity.actionTargetReceipt
        var sequence = DesktopActionSequenceAccumulator()

        do {
            return try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
                self.logger.info("Attempting to focus window with target: \(target)")
                self.logger.debug("WindowManagementService.focusWindow called with target: \(target)")
                try validateBeforeDispatch()
                // Settlement may wait, but an ambiguous mutation must never trigger another raise.
                try await dispatch(.init(retryCount: 1)) { record in
                    sequence.record(record.sequenceStep)
                }
                let window = try await readback.capture(expectedIdentity: expectedIdentity)
                let outcome = FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
                return UIAutomationActionResult(
                    payload: window,
                    outcome: outcome,
                    targetIdentity: targetIdentity)
            }
        } catch let failure as DesktopActionFailure {
            throw self.focusFailure(
                failure,
                sequence: sequence,
                targetReceipt: targetReceipt)
        } catch is CancellationError {
            if let failure = sequence.cancellationFailure(
                fallbackRoute: .local,
                message: "Window focus was cancelled after dispatch may have begun.",
                hint: "Observe the exact window before retrying focus.",
                causeDescription: "Focus task cancelled")
            {
                throw failure.attributed(to: targetReceipt)
            }
            throw CancellationError()
        } catch {
            let failure = WindowManagementActionOutcome.refused(action: "focus window", error: error)
            throw self.focusFailure(
                failure,
                sequence: sequence,
                targetReceipt: targetReceipt)
        }
    }

    private func focusFailure(
        _ failure: DesktopActionFailure,
        sequence: DesktopActionSequenceAccumulator,
        targetReceipt: DesktopActionTargetReceipt) -> DesktopActionFailure
    {
        sequence.failure(
            combining: failure,
            message: "Window focus did not complete with a verified exact target.",
            hint: "Observe the exact window before retrying focus.")
            .attributed(to: targetReceipt)
    }
}
