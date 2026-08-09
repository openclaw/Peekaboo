import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
/// Import the necessary types from the menu command
private struct MenuListData: Codable {
    let app: String
    let bundle_id: String?
    let menu_structure: [MenuData]
}

private struct MenuData: Codable {
    let title: String
    let enabled: Bool
    let items: [MenuItemData]?
}

private struct MenuItemData: Codable {
    let title: String
    let enabled: Bool
    let key_equivalent: String?
    let submenu: [MenuItemData]?
}

@Suite(.serialized, .tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct MenuCommandTests {
    @Test
    func `Menu command exists`() {
        let config = MenuCommand.commandDescription
        #expect(config.commandName == "menu")
        #expect(config.abstract.contains("menu bar"))
    }

    @Test
    func `Menu command has expected subcommands`() {
        let subcommands = MenuCommand.commandDescription.subcommands
        #expect(subcommands.count == 2)

        var names: [String] = [] // Key-path map here trips SILGen; keep the explicit loop.
        names.reserveCapacity(subcommands.count)
        for descriptor in subcommands {
            guard let name = descriptor.commandDescription.commandName else { continue }
            names.append(name)
        }
        #expect(names.contains("click"))
        #expect(names.contains("list"))
    }

    @Test
    func `Menu click command help`() async throws {
        let result = try await self.runMenuCommand(["menu", "click", "--help"])
        #expect(result.exitStatus == 0)
        let output = self.output(from: result)
        #expect(output.contains("Click a menu item"))
        #expect(output.contains("--app"))
        #expect(output.contains("--path"))
        #expect(output.contains("--item"))
    }

    @Test
    func `Menu click requires app and path/item`() async throws {
        // Test missing app
        let missingApp = try await self.runMenuCommand(["menu", "click", "--path", "File > New"])
        #expect(missingApp.exitStatus != 0)

        // Test missing path/item
        let missingPath = try await self.runMenuCommand(["menu", "click", "--app", "Finder"])
        #expect(missingPath.exitStatus != 0)
    }

    @Test
    func `Menu path parsing`() {
        // Test simple path
        let path1 = "File > New"
        let components1 = path1.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(components1 == ["File", "New"])

        // Test complex path
        let path2 = "Window > Bring All to Front"
        let components2 = path2.split(separator: ">").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(components2 == ["Window", "Bring All to Front"])
    }

    @Test
    func `Menu list command help`() async throws {
        let result = try await self.runMenuCommand(["menu", "list", "--help"])
        #expect(result.exitStatus == 0)
        let output = self.output(from: result)
        #expect(output.contains("List all menu items"))
        #expect(output.contains("--app"))
        #expect(output.contains("--include-disabled"))
    }

    @Test
    func `Menu error codes`() {
        #expect(ErrorCode.MENU_BAR_NOT_FOUND.rawValue == "MENU_BAR_NOT_FOUND")
        #expect(ErrorCode.MENU_ITEM_NOT_FOUND.rawValue == "MENU_ITEM_NOT_FOUND")
    }

    @Test
    func `Menu click executes menu service`() async throws {
        let args = [
            "menu", "click",
            "--app", "Finder",
            "--item", "Open",
            "--json",
        ]
        let (result, context) = try await self.runMenuCommandWithContext(args)
        #expect(result.exitStatus == 0)
        let calls = await self.menuState(context.menuService) { $0.clickItemCalls }
        #expect(calls.contains { $0.app == "Finder" && $0.item == "Open" })
    }

    @Test
    func `Menu click path executes menu service`() async throws {
        let args = [
            "menu", "click",
            "--app", "Finder",
            "--path", "File > Save",
            "--json",
        ]
        let (result, context) = try await self.runMenuCommandWithContext(args)
        #expect(result.exitStatus == 0)
        let pathCalls = await self.menuState(context.menuService) { $0.clickPathCalls }
        #expect(pathCalls.contains { $0.app == "Finder" && $0.path == "File > Save" })
    }

    private func runMenuCommand(
        _ args: [String],
        configure: (@MainActor (StubMenuService, StubApplicationService) -> Void)? = nil
    ) async throws -> CommandRunResult {
        let (result, _) = try await self.runMenuCommandWithContext(args, configure: configure)
        return result
    }

    private func runMenuCommandWithContext(
        _ args: [String],
        configure: (@MainActor (StubMenuService, StubApplicationService) -> Void)? = nil
    ) async throws -> (CommandRunResult, MenuHarnessContext) {
        let context = await MainActor.run { self.makeMenuContext() }
        if let configure {
            await MainActor.run {
                configure(context.menuService, context.applicationService)
            }
        }
        let result = try await InProcessCommandRunner.run(args, services: context.services)
        return (result, context)
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func menuState<T: Sendable>(
        _ service: StubMenuService,
        _ operation: @MainActor (StubMenuService) -> T
    ) async -> T {
        await MainActor.run {
            operation(service)
        }
    }

    @MainActor
    private func makeMenuContext() -> MenuHarnessContext {
        let data = Self.defaultMenuData()
        let menuService = StubMenuService(menusByApp: data.menusByApp, menuExtras: data.extras)
        let applicationService = StubApplicationService(applications: [data.appInfo])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applicationService,
            menu: menuService
        )
        return MenuHarnessContext(services: services, menuService: menuService, applicationService: applicationService)
    }

    @MainActor
    private static func defaultMenuData()
    -> (appInfo: ServiceApplicationInfo, menusByApp: [String: MenuStructure], extras: [MenuExtraInfo]) {
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 101,
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            bundlePath: "/System/Library/CoreServices/Finder.app",
            isActive: true,
            isHidden: false,
            windowCount: 1
        )

        let fileMenu = Menu(
            title: "File",
            items: [
                MenuItem(title: "New", path: "File > New"),
                MenuItem(title: "Open", path: "File > Open"),
                MenuItem(title: "Save", path: "File > Save"),
            ],
            isEnabled: true
        )

        let viewMenu = Menu(
            title: "View",
            items: [
                MenuItem(title: "Show Path Bar", path: "View > Show Path Bar"),
            ],
            isEnabled: true
        )

        let menuStructure = MenuStructure(application: appInfo, menus: [fileMenu, viewMenu])
        let extras = [MenuExtraInfo(title: "WiFi", position: CGPoint(x: 0, y: 0), isVisible: true)]

        return (appInfo, ["Finder": menuStructure], extras)
    }

    private struct MenuHarnessContext {
        let services: PeekabooServices
        let menuService: StubMenuService
        let applicationService: StubApplicationService
    }
}

// MARK: - Menu Command Integration Tests (removed real CLI coverage)

#endif
