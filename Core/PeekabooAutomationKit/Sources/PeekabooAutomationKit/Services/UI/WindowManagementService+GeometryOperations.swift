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
                return try await self.completeWindowGeometry(
                    action: "move window",
                    expectedIdentity: expectedIdentity,
                    bounds: CGRect(origin: position, size: capturedBounds.size))
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
                return try await self.completeWindowGeometry(
                    action: "resize window",
                    expectedIdentity: expectedIdentity,
                    bounds: CGRect(origin: capturedBounds.origin, size: size))
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
                return try await self.completeWindowGeometry(
                    action: "set window bounds",
                    expectedIdentity: expectedIdentity,
                    bounds: bounds)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }
}
