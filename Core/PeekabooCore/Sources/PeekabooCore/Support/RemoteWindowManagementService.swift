import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteWindowManagementService: WindowManagementServiceProtocol,
    WindowManagementActionOutcomeProviding
{
    private let client: PeekabooBridgeClient
    private let supportsBackgroundClose: Bool
    private nonisolated let supportsPinnedWindowMutations: Bool
    private nonisolated let supportsWindowRestore: Bool

    public init(
        client: PeekabooBridgeClient,
        supportsBackgroundClose: Bool = false,
        supportsPinnedWindowMutations: Bool = false,
        supportsWindowRestore: Bool = false)
    {
        self.client = client
        self.supportsBackgroundClose = supportsBackgroundClose
        self.supportsPinnedWindowMutations = supportsPinnedWindowMutations
        self.supportsWindowRestore = supportsWindowRestore
    }

    public func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    public func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        try self.requirePinnedWindowMutationSupport()
        if !allowForegroundFallback, !self.supportsBackgroundClose {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host does not support AX-only background window close; " +
                    "update the host or use --no-remote")
        }
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.closeWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        try self.requirePinnedWindowMutationSupport()
        try await self.client.closeWindow(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func closeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try self.requirePinnedWindowMutationSupport()
        guard self.supportsBackgroundClose else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host does not support AX-only background window close; " +
                    "update the host or use --no-remote")
        }
        return try await self.client.closeWindowWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity)
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.minimizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.minimizeWindowWithOutcome(target: target, expectedIdentity: expectedIdentity)
    }

    public func minimizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.minimizeWindowWithOutcome(target: target, expectedIdentity: expectedIdentity)
    }

    public func restoreWindow(target: WindowTarget) async throws {
        try self.requireWindowRestoreSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.restoreWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.restoreWindowWithOutcome(target: target, expectedIdentity: expectedIdentity)
    }

    public func restoreWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try self.requireWindowRestoreSupport()
        return try await self.client.restoreWindowWithOutcome(target: target, expectedIdentity: expectedIdentity)
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.maximizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.maximizeWindowWithOutcome(target: target, expectedIdentity: expectedIdentity)
    }

    public func maximizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.maximizeWindowWithOutcome(target: target, expectedIdentity: expectedIdentity)
    }

    public func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.moveWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            to: position)
    }

    public func moveWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws
    {
        _ = try await self.moveWindowWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity,
            to: position)
    }

    public func moveWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionOutcome?
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.moveWindowWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity,
            to: position)
    }

    public func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.resizeWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            to: size)
    }

    public func resizeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws
    {
        _ = try await self.resizeWindowWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity,
            to: size)
    }

    public func resizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionOutcome?
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.resizeWindowWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity,
            to: size)
    }

    public func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.setWindowBounds(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            bounds: bounds)
    }

    public func setWindowBounds(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws
    {
        _ = try await self.setWindowBoundsWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds)
    }

    public func setWindowBoundsWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionOutcome?
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.setWindowBoundsWithOutcome(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds)
    }

    public func focusWindow(target: WindowTarget) async throws {
        try await self.client.focusWindow(target: target)
    }

    public func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        try await self.client.listWindows(target: target)
    }

    public func getFocusedWindow() async throws -> ServiceWindowInfo? {
        try await self.client.getFocusedWindow()
    }

    private nonisolated func requirePinnedWindowMutationSupport() throws {
        guard self.supportsPinnedWindowMutations else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host lacks window-instance-pinned mutations; update the host")
        }
    }

    private nonisolated func requireWindowRestoreSupport() throws {
        guard self.supportsPinnedWindowMutations, self.supportsWindowRestore else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host lacks receipt-pinned background window restore; update the host")
        }
    }
}
