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
        guard case let .windowId(windowID) = target,
              windowID == expectedIdentity.windowID,
              let bounds = expectedIdentity.capturedBounds
        else {
            throw PeekabooError.commandFailed(
                "Exact focus target contradicts its process-generation receipt")
        }
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: expectedIdentity, bounds: bounds)
        let targetIdentity = DesktopTargetIdentity(exactWindow: exactWindow)
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: expectedIdentity.ownerProcessIdentifier,
            processStartIdentity: expectedIdentity.ownerProcessStartIdentity,
            windowID: expectedIdentity.windowID)
        var sequence = DesktopActionSequenceAccumulator()

        do {
            try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
                self.logger.info("Attempting to focus window with target: \(target)")
                self.logger.debug("WindowManagementService.focusWindow called with target: \(target)")
                try self.validatePinnedWindowMutation(
                    target: target,
                    expectedIdentity: expectedIdentity)
                let focusService = FocusManagementService(
                    applications: self.applicationService,
                    operationLaneCoordinator: self.operationLaneCoordinator)
                try await focusService.focusWindowWithOwnedLane(
                    windowID: CGWindowID(expectedIdentity.windowID),
                    expectedIdentity: expectedIdentity,
                    onDispatch: { record in
                        sequence.record(record.sequenceStep)
                    })
                guard SystemIdentityResolver.validateWindowMutationIdentity(
                    expectedIdentity,
                    expectedBounds: bounds)
                else {
                    throw PeekabooError.commandFailed(
                        "Window \(expectedIdentity.windowID) changed identity during focus")
                }
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

        let outcome = FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
        return UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: targetIdentity)
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
