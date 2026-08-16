import CoreGraphics
import Foundation
import PeekabooFoundation

enum SpaceWindowMutationDispatcher {
    struct Backend {
        let destinationExists: (CGSSpaceID) -> Bool
        let validateIdentity: (WindowMutationIdentity) -> Bool
        let spaceIDsForWindow: () -> [CGSSpaceID]
        let removeWindows: ([CGSSpaceID]) -> Void
        let addWindow: (CGSSpaceID) -> Void
    }

    struct SwitchBackend {
        let destinationExists: (CGSSpaceID) -> Bool
        let validateIdentity: (WindowMutationIdentity) -> Bool
        let spaceIDsForWindow: () -> [CGSSpaceID]
        let activeSpaceID: () -> CGSSpaceID
        let setCurrentSpace: (CGSSpaceID) -> Void
        let settle: () async throws -> Void
    }

    private static let moveDelivery = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .background)
    private static let switchDelivery = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .foreground)

    static func moveWindow(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        targetSpaceID: CGSSpaceID,
        backend: Backend) throws -> UIAutomationActionResult<Void>
    {
        let exactTarget = try self.exactTarget(windowID: windowID, expectedIdentity: expectedIdentity)
        let targetReceipt = exactTarget.receipt

        guard backend.destinationExists(targetSpaceID) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move destination no longer exists.",
                hint: "Refresh the Space inventory before retrying.")
                .attributed(to: targetReceipt)
        }

        var memberships = self.uniqueSpaceIDs(backend.spaceIDsForWindow())
        guard backend.validateIdentity(expectedIdentity) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move target changed before dispatch.",
                hint: "Refresh the window inventory before retrying.")
                .attributed(to: targetReceipt)
        }

        var dispatchedUnitCount = 0
        if !memberships.contains(targetSpaceID) {
            try self.checkCancellation(
                operation: "Space move",
                delivery: self.moveDelivery,
                dispatchedUnitCount: dispatchedUnitCount,
                targetReceipt: targetReceipt)
            backend.addWindow(targetSpaceID)
            dispatchedUnitCount += 1

            guard backend.validateIdentity(expectedIdentity) else {
                throw self.postDispatchIdentityFailure(
                    operation: "Space move",
                    unitCount: dispatchedUnitCount,
                    targetReceipt: targetReceipt)
            }

            memberships = self.uniqueSpaceIDs(backend.spaceIDsForWindow())
            guard memberships.contains(targetSpaceID) else {
                throw DesktopActionFailure.suspectedNoop(
                    delivery: self.moveDelivery,
                    unitCount: self.dispatchUnitCount(dispatchedUnitCount),
                    message: "Space move destination could not be established.",
                    hint: "Refresh the Space inventory and exact window before retrying.")
                    .attributed(to: targetReceipt)
            }
        }

        guard backend.destinationExists(targetSpaceID) else {
            throw self.failureBeforeDestructiveRemoval(
                message: "Space move destination disappeared after it was established.",
                dispatchedUnitCount: dispatchedUnitCount,
                targetReceipt: targetReceipt)
        }
        guard backend.validateIdentity(expectedIdentity) else {
            if dispatchedUnitCount == 0 {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Space move target changed before dispatch.",
                    hint: "Refresh the window inventory before retrying.")
                    .attributed(to: targetReceipt)
            }
            throw self.postDispatchIdentityFailure(
                operation: "Space move",
                unitCount: dispatchedUnitCount,
                targetReceipt: targetReceipt)
        }

        try self.checkCancellation(
            operation: "Space move",
            delivery: self.moveDelivery,
            dispatchedUnitCount: dispatchedUnitCount,
            targetReceipt: targetReceipt)
        let removalMemberships = self.uniqueSpaceIDs(backend.spaceIDsForWindow())
        guard backend.destinationExists(targetSpaceID), removalMemberships.contains(targetSpaceID) else {
            throw self.failureBeforeDestructiveRemoval(
                message: "Space move destination disappeared immediately before prior memberships were removed.",
                dispatchedUnitCount: dispatchedUnitCount,
                targetReceipt: targetReceipt)
        }
        let sourceSpaceIDs = removalMemberships.filter { $0 != targetSpaceID }
        if !sourceSpaceIDs.isEmpty {
            try self.checkCancellation(
                operation: "Space move",
                delivery: self.moveDelivery,
                dispatchedUnitCount: dispatchedUnitCount,
                targetReceipt: targetReceipt)
            backend.removeWindows(sourceSpaceIDs)
            dispatchedUnitCount += 1
        }

        guard backend.validateIdentity(expectedIdentity) else {
            if dispatchedUnitCount == 0 {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Space move target changed before completion was verified.",
                    hint: "Refresh the window inventory before retrying.")
                    .attributed(to: targetReceipt)
            }
            throw self.postDispatchIdentityFailure(
                operation: "Space move",
                unitCount: dispatchedUnitCount,
                targetReceipt: targetReceipt)
        }

        let finalMemberships = self.uniqueSpaceIDs(backend.spaceIDsForWindow())
        guard finalMemberships == [targetSpaceID] else {
            if dispatchedUnitCount == 0 {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Space membership changed before the exact move could be verified.",
                    hint: "Refresh the Space inventory before retrying.")
                    .attributed(to: targetReceipt)
            }
            if finalMemberships.contains(targetSpaceID) {
                throw DesktopActionFailure.partial(
                    delivery: self.moveDelivery,
                    unitCount: self.dispatchUnitCount(dispatchedUnitCount),
                    message: "The destination Space was established, but prior memberships remain.",
                    hint: "Observe the exact window's Space memberships before retrying cleanup.")
                    .attributed(to: targetReceipt)
            }
            throw DesktopActionFailure.indeterminate(
                delivery: self.moveDelivery,
                evidence: .completionUnknown,
                unitCount: self.dispatchUnitCount(dispatchedUnitCount),
                message: "Space move completion could not be verified.",
                hint: "Observe the exact window's Space memberships before retrying.")
                .attributed(to: targetReceipt)
        }

        let outcome: DesktopActionOutcome = if dispatchedUnitCount == 0 {
            .confirmedNoChange()
        } else {
            .confirmedChange(
                delivery: self.moveDelivery,
                unitCount: self.dispatchUnitCount(dispatchedUnitCount))
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactTarget.window))
    }

    static func switchToWindowSpace(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity,
        backend: SwitchBackend) async throws -> UIAutomationActionResult<Void>
    {
        let exactTarget = try self.exactTarget(windowID: windowID, expectedIdentity: expectedIdentity)
        let targetReceipt = exactTarget.receipt
        let memberships = self.uniqueSpaceIDs(backend.spaceIDsForWindow())
        guard !memberships.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Exact window is not attached to any Space.",
                hint: "Refresh the window and Space inventory before retrying.")
                .attributed(to: targetReceipt)
        }

        let activeSpaceID = backend.activeSpaceID()
        let targetSpaceID = memberships.contains(activeSpaceID) ? activeSpaceID : memberships[0]
        guard backend.destinationExists(targetSpaceID) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Exact window's destination Space no longer exists.",
                hint: "Refresh the Space inventory before retrying.")
                .attributed(to: targetReceipt)
        }
        guard backend.validateIdentity(expectedIdentity),
              self.uniqueSpaceIDs(backend.spaceIDsForWindow()).contains(targetSpaceID),
              backend.validateIdentity(expectedIdentity)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Exact window or its Space membership changed before switching.",
                hint: "Refresh the window and Space inventory before retrying.")
                .attributed(to: targetReceipt)
        }

        if backend.activeSpaceID() == targetSpaceID {
            return UIAutomationActionResult(
                payload: (),
                outcome: .confirmedNoChange(),
                targetIdentity: DesktopTargetIdentity(exactWindow: exactTarget.window))
        }

        guard backend.destinationExists(targetSpaceID),
              self.uniqueSpaceIDs(backend.spaceIDsForWindow()).contains(targetSpaceID)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Exact window's destination Space or membership changed at the switch boundary.",
                hint: "Refresh the window and Space inventories before retrying.")
                .attributed(to: targetReceipt)
        }
        // Identity is the final fallible check before the private CGS dispatch.
        guard backend.validateIdentity(expectedIdentity) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Exact window changed at the Space-switch boundary.",
                hint: "Refresh the window inventory before retrying.")
                .attributed(to: targetReceipt)
        }
        try self.checkCancellation(
            operation: "Space switch",
            delivery: self.switchDelivery,
            dispatchedUnitCount: 0,
            targetReceipt: targetReceipt)
        backend.setCurrentSpace(targetSpaceID)

        do {
            try await backend.settle()
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: self.switchDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Space switch was dispatched, but post-dispatch settling failed.",
                hint: "Observe the active Space before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: targetReceipt)
        }

        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: self.switchDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(exactWindow: exactTarget.window))
    }

    private static func exactTarget(
        windowID: CGWindowID,
        expectedIdentity: WindowMutationIdentity) throws -> (
        window: UIAutomationTarget.ExactWindow,
        receipt: DesktopActionTargetReceipt)
    {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: expectedIdentity.ownerProcessIdentifier,
            processStartIdentity: expectedIdentity.ownerProcessStartIdentity,
            windowID: expectedIdentity.windowID)
        guard expectedIdentity.windowID == Int(windowID),
              let capturedBounds = expectedIdentity.capturedBounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space operation requires one exact window identity with immutable bounds.",
                hint: "Refresh the window inventory before retrying.")
                .attributed(to: receipt)
        }

        do {
            return try (
                UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity,
                    bounds: capturedBounds),
                receipt)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space operation received an invalid exact-window receipt.",
                hint: "Refresh the window inventory before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: receipt)
        }
    }

    private static func uniqueSpaceIDs(_ spaceIDs: [CGSSpaceID]) -> [CGSSpaceID] {
        var seen: Set<CGSSpaceID> = []
        return spaceIDs.filter { seen.insert($0).inserted }
    }

    private static func dispatchUnitCount(_ value: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let count = DesktopActionOutcome.DispatchUnitCount(value) else {
            preconditionFailure("A dispatched Space operation must contain at least one unit")
        }
        return count
    }

    private static func checkCancellation(
        operation: String,
        delivery: DesktopActionOutcome.Delivery,
        dispatchedUnitCount: Int,
        targetReceipt: DesktopActionTargetReceipt) throws
    {
        do {
            try Task.checkCancellation()
        } catch {
            guard dispatchedUnitCount > 0 else { throw CancellationError() }
            throw DesktopActionFailure.indeterminate(
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: self.dispatchUnitCount(dispatchedUnitCount),
                message: "\(operation) was cancelled after dispatch began.",
                hint: "Observe the exact window and Space state before retrying.",
                causeDescription: "Task cancelled")
                .attributed(to: targetReceipt)
        }
    }

    private static func postDispatchIdentityFailure(
        operation: String,
        unitCount: Int,
        targetReceipt: DesktopActionTargetReceipt) -> DesktopActionFailure
    {
        DesktopActionFailure.indeterminate(
            delivery: self.moveDelivery,
            evidence: .completionUnknown,
            unitCount: self.dispatchUnitCount(unitCount),
            message: "\(operation) target changed after dispatch began.",
            hint: "Observe the exact window and its Space memberships before retrying.")
            .attributed(to: targetReceipt)
    }

    private static func failureBeforeDestructiveRemoval(
        message: String,
        dispatchedUnitCount: Int,
        targetReceipt: DesktopActionTargetReceipt) -> DesktopActionFailure
    {
        if dispatchedUnitCount == 0 {
            return DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: message,
                hint: "Refresh the Space inventory before retrying.")
                .attributed(to: targetReceipt)
        }
        return DesktopActionFailure.indeterminate(
            delivery: self.moveDelivery,
            evidence: .completionUnknown,
            unitCount: self.dispatchUnitCount(dispatchedUnitCount),
            message: message,
            hint: "Observe the exact window and its Space memberships before retrying.")
            .attributed(to: targetReceipt)
    }
}
