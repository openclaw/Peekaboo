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
        try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            guard let capturedBounds = expectedIdentity.capturedBounds else {
                throw PeekabooError.commandFailed("Window mutation receipt lacks capture-time bounds")
            }
            let window = try await self.element(for: target)
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
            let success = window.moveWindow(to: position)

            if !success {
                throw OperationError.interactionFailed(
                    action: "move window",
                    reason: "Window move operation failed")
            }
            _ = try await self.waitForRepinnedWindowMutation(
                expectedIdentity,
                expectedBounds: CGRect(origin: position, size: capturedBounds.size))
        }
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
            let success = window.resizeWindow(to: size)

            let elapsed = Date().timeIntervalSince(startTime)
            self.logger.info("Resize window operation completed in \(elapsed)s")

            if !success {
                throw OperationError.interactionFailed(
                    action: "resize window",
                    reason: "Window resize operation failed")
            }
            _ = try await self.waitForRepinnedWindowMutation(
                expectedIdentity,
                expectedBounds: CGRect(origin: capturedBounds.origin, size: size))
        }
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
        try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            let window = try await self.element(for: target)
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
            let success = window.setWindowBounds(bounds)

            if !success {
                throw OperationError.interactionFailed(
                    action: "set window bounds",
                    reason: "Window bounds operation failed")
            }
            _ = try await self.waitForRepinnedWindowMutation(expectedIdentity, expectedBounds: bounds)
        }
    }
}
