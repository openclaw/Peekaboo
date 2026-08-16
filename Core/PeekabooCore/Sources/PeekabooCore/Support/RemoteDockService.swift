import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteDockService: DockServiceProtocol, DockServiceActionResultProviding {
    private let client: PeekabooBridgeClient

    public init(client: PeekabooBridgeClient) {
        self.client = client
    }

    public func listDockItems(includeAll: Bool) async throws -> [DockItem] {
        try await self.client.listDockItems(includeAll: includeAll)
    }

    public func launchFromDock(appName: String) async throws {
        try await self.client.launchDockItem(appName: appName)
    }

    public func launchFromDockActionResult(appName: String) async throws -> UIAutomationActionResult<Void> {
        try await self.client.launchDockItemResult(appName: appName)
    }

    public func addToDock(path _: String, persistent _: Bool) async throws {
        throw PeekabooError.operationError(message: "addToDock not available via XPC")
    }

    public func removeFromDock(appName _: String) async throws {
        throw PeekabooError.operationError(message: "removeFromDock not available via XPC")
    }

    public func rightClickDockItem(appName: String, menuItem: String?) async throws {
        try await self.client.rightClickDockItem(appName: appName, menuItem: menuItem)
    }

    public func rightClickDockItemActionResult(
        appName: String,
        menuItem: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.client.rightClickDockItemResult(appName: appName, menuItem: menuItem)
    }

    public func hideDock() async throws {
        _ = try await self.hideDockActionResult()
    }

    public func hideDockActionResult() async throws -> DesktopActionResult<Void> {
        try await self.client.hideDockResult()
    }

    public func showDock() async throws {
        _ = try await self.showDockActionResult()
    }

    public func showDockActionResult() async throws -> DesktopActionResult<Void> {
        try await self.client.showDockResult()
    }

    public func isDockAutoHidden() async -> Bool {
        await (try? self.client.isDockHidden()) ?? false
    }

    public func findDockItem(name: String) async throws -> DockItem {
        try await self.client.findDockItem(name: name)
    }
}
