import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteWindowManagementService: WindowManagementServiceProtocol,
    WindowMutationInventoryProviding,
    WindowManagementActionOutcomeProviding,
    WindowManagementActionResultProviding,
    WindowManagementPinnedFocusActionResultProviding
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
        try await self.closeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: false).outcome
    }

    public func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        try self.requirePinnedWindowMutationSupport()
        guard allowForegroundFallback || self.supportsBackgroundClose else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Remote host does not support AX-only background window close; " +
                    "update the host or use --no-remote")
        }
        return try await self.client.closeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.minimizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func minimizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func restoreWindow(target: WindowTarget) async throws {
        try self.requireWindowRestoreSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.restoreWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.restoreWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func restoreWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.restoreWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        try self.requireWindowRestoreSupport()
        return try await self.client.restoreWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        try self.requirePinnedWindowMutationSupport()
        let pinned = try await self.client.resolvedPinnedWindowMutation(target: target)
        try await self.client.maximizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func maximizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity)
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
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.moveWindowResult(
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
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.resizeWindowResult(
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
        try self.requirePinnedWindowMutationSupport()
        return try await self.client.setWindowBoundsResult(
            target: target,
            expectedIdentity: expectedIdentity,
            bounds: bounds)
    }

    public func focusWindow(target: WindowTarget) async throws {
        _ = try await self.focusWindowActionResult(target: target)
    }

    public func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.client.focusWindowResult(target: target)
    }

    public func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        try await self.client.focusWindowResult(
            target: target,
            expectedIdentity: expectedIdentity)
    }

    public func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        try await self.client.listWindows(target: target)
    }

    public func windowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        try await self.client.listWindowMutationInventory(target: target)
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
