import CoreGraphics
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooFoundation

@MainActor
public final class RemoteMenuService: MenuServiceProtocol, MenuServiceGenerationPinnedActionResultProviding,
    MenuServiceExactLeafActionResultProviding
{
    private let client: PeekabooBridgeClient

    public init(client: PeekabooBridgeClient) {
        self.client = client
    }

    public func listMenus(for appIdentifier: String) async throws -> MenuStructure {
        try await self.client.listMenus(appIdentifier: appIdentifier)
    }

    public func listFrontmostMenus() async throws -> MenuStructure {
        try await self.client.listFrontmostMenus()
    }

    public func clickMenuItem(app: String, itemPath: String) async throws {
        try await self.client.clickMenuItem(appIdentifier: app, itemPath: itemPath)
    }

    public func clickMenuItemActionResult(
        app: String,
        itemPath: String) async throws -> UIAutomationActionResult<Void>
    {
        try await self.client.clickMenuItemResult(appIdentifier: app, itemPath: itemPath)
    }

    public func clickMenuItemActionResult(
        request: MenuItemActionRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.client.clickMenuItemResult(request: request)
    }

    public func clickMenuItemByName(app: String, itemName: String) async throws {
        try await self.client.clickMenuItemByName(appIdentifier: app, itemName: itemName)
    }

    public func clickMenuItemByNameActionResult(
        app: String,
        itemName: String) async throws -> UIAutomationActionResult<Void>
    {
        try await self.client.clickMenuItemByNameResult(appIdentifier: app, itemName: itemName)
    }

    public func clickMenuItemByNameActionResult(
        request: MenuItemByNameActionRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.client.clickMenuItemByNameResult(request: request)
    }

    public func clickMenuExtra(title: String) async throws {
        try await self.client.clickMenuExtra(title: title)
    }

    public func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try await self.client.clickMenuExtraResult(title: title)
    }

    public func isMenuExtraMenuOpen(title: String, ownerPID: pid_t?) async throws -> Bool {
        try await (self.menuExtraOpenMenuFrame(title: title, ownerPID: ownerPID)) != nil
    }

    public func menuExtraOpenMenuFrame(title: String, ownerPID: pid_t?) async throws -> CGRect? {
        try await self.client.menuExtraOpenMenuFrame(title: title, ownerPID: ownerPID)
    }

    public func listMenuExtras() async throws -> [MenuExtraInfo] {
        try await self.client.listMenuExtras()
    }

    public func listMenuBarItems(includeRaw: Bool) async throws -> [MenuBarItemInfo] {
        try await self.client.listMenuBarItems(includeRaw: includeRaw)
    }

    public func clickMenuBarItem(named name: String) async throws -> ClickResult {
        try await self.client.clickMenuBarItem(named: name)
    }

    public func clickMenuBarItemActionResult(named name: String) async throws -> UIAutomationActionResult<ClickResult> {
        try await self.client.clickMenuBarItemResult(named: name)
    }

    public func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        try await self.client.clickMenuBarItem(at: index)
    }

    public func clickMenuBarItemActionResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult> {
        try await self.client.clickMenuBarItemResult(at: index)
    }

    public func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        try await self.client.clickMenuBarItemResult(request: request)
    }
}
