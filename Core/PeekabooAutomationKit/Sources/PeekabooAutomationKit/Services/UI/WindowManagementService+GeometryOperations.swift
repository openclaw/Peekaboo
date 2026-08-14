import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    public func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.moveWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            to: position)
    }

    public func moveWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws
    {
        _ = try await self.moveWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: position)
    }

    public func moveWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionOutcome?
    {
        try await self.moveWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: position).outcome
    }

    public func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await WindowManagementActionOutcome.perform(action: "move window") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                guard let capturedBounds = expectedIdentity.capturedBounds else {
                    throw PeekabooError.commandFailed("Window mutation receipt lacks capture-time bounds")
                }
                let window = try await self.element(for: target)
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
                guard capturedBounds.origin != position else {
                    return WindowManagementActionOutcome.confirmedNoChange
                }
                guard window.moveWindow(to: position) else {
                    throw OperationError.interactionFailed(
                        action: "move window",
                        reason: "Window move operation failed")
                }
                do {
                    _ = try await self.waitForRepinnedWindowMutation(
                        expectedIdentity,
                        expectedBounds: CGRect(origin: position, size: capturedBounds.size))
                } catch {
                    throw self.geometryVerificationFailure(
                        action: "move window",
                        expectedIdentity: expectedIdentity,
                        dispatchCount: 1,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                    dispatchCount: 1)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    public func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.resizeWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            to: size)
    }

    public func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws
    {
        _ = try await self.resizeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: size)
    }

    public func resizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionOutcome?
    {
        try await self.resizeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            to: size).outcome
    }

    public func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await WindowManagementActionOutcome.perform(action: "resize window") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                guard let capturedBounds = expectedIdentity.capturedBounds else {
                    throw PeekabooError.commandFailed("Window mutation receipt lacks capture-time bounds")
                }
                let resizeDescription = "target=\(target), size=(width: \(size.width), height: \(size.height))"
                self.logger.info("Starting resize window operation: \(resizeDescription)")
                let startTime = Date()

                let window = try await self.element(for: target)
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
                guard capturedBounds.size != size else {
                    return WindowManagementActionOutcome.confirmedNoChange
                }
                let success = window.resizeWindow(to: size)

                let elapsed = Date().timeIntervalSince(startTime)
                self.logger.info("Resize window operation completed in \(elapsed)s")

                guard success else {
                    throw OperationError.interactionFailed(
                        action: "resize window",
                        reason: "Window resize operation failed")
                }
                do {
                    _ = try await self.waitForRepinnedWindowMutation(
                        expectedIdentity,
                        expectedBounds: CGRect(origin: capturedBounds.origin, size: size))
                } catch {
                    throw self.geometryVerificationFailure(
                        action: "resize window",
                        expectedIdentity: expectedIdentity,
                        dispatchCount: 1,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                    dispatchCount: 1)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    public func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.setWindowBounds(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            bounds: bounds)
    }

    public func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws
    {
        _ = try await self.setWindowBoundsResult(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds)
    }

    public func setWindowBoundsWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionOutcome?
    {
        try await self.setWindowBoundsResult(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds).outcome
    }

    public func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await WindowManagementActionOutcome.perform(action: "set window bounds") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                let window = try await self.element(for: target)
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
                guard expectedIdentity.capturedBounds != bounds else {
                    return WindowManagementActionOutcome.confirmedNoChange
                }
                let dispatch = WindowGeometryDispatchAcceptance(
                    positionAccepted: window.setPosition(bounds.origin) == .success,
                    sizeAccepted: window.setSize(bounds.size) == .success)
                let dispatchCount = dispatch.dispatchCount
                guard dispatchCount > 0 else {
                    throw OperationError.interactionFailed(
                        action: "set window bounds",
                        reason: "Window bounds operation failed")
                }
                do {
                    _ = try await self.waitForRepinnedWindowMutation(expectedIdentity, expectedBounds: bounds)
                } catch {
                    throw self.geometryVerificationFailure(
                        action: "set window bounds",
                        expectedIdentity: expectedIdentity,
                        dispatchCount: dispatchCount,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                    dispatchCount: dispatchCount)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }
}
