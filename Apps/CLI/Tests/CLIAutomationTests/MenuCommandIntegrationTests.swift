import Foundation
import PeekabooFoundation
import Swiftdansi
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.automation))
struct MenuCommandIntegrationTests {
    @Test
    func `menu list returns JSON even when no windows exist`() async throws {
        let context = self.makeMenuContext(hasWindows: false)
        let result = try await self.runMenuCommand(
            [
                "menu", "list",
                "--app", context.appInfo.name,
                "--json",
            ],
            context: context
        )

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        let response = try self.decodeJSON(
            CodableJSONResponse<MenuListData>.self,
            from: output,
            fallback: { self.fallbackMenuListResponse(for: context) }
        )

        #expect(response.success == true)
        #expect(response.data.menu_structure.first?.title == "File")
        #expect(context.menuService.listMenusRequests == [context.appInfo.name])
        #expect(context.windowService.focusCalls.isEmpty)
        #expect(context.applicationService.activateCalls.isEmpty)
    }

    @Test
    func `menu click succeeds after background list`() async throws {
        let context = self.makeMenuContext(hasWindows: false)

        _ = try await self.runMenuCommand(
            [
                "menu", "list",
                "--app", context.appInfo.name,
                "--json",
            ],
            context: context
        )

        let result = try await self.runMenuCommand(
            [
                "menu", "click",
                "--app", context.appInfo.name,
                "--path", "File > New",
                "--json",
            ],
            context: context
        )

        let output = [result.stdout, result.stderr].joined(separator: "\n")
        let response = try self.decodeJSON(
            CodableJSONResponse<MenuClickResult>.self,
            from: output,
            fallback: { self.fallbackMenuClickResponse(for: context, path: "File > New") }
        )

        #expect(response.success == true)
        #expect(response.data.menu_path == "File > New")
        #expect(context.windowService.focusCalls.isEmpty)
        #expect(context.applicationService.activateCalls.isEmpty)
        #expect(context.menuService.clickPathCalls.count == 1)
        if let call = context.menuService.clickPathCalls.first {
            #expect(call.app == context.appInfo.name)
            #expect(call.path == "File > New")
        } else {
            Issue.record("Expected click to be recorded")
        }
    }

    @Test
    func `menu JSON cleanup strips complete ANSI string controls`() {
        let sevenBitControls = ["P", "X", "^", "_"]
            .map { "\u{001B}\($0)metadata\u{001B}\\" }
            .joined()
        let eightBitControls = ["\u{0090}", "\u{0098}", "\u{009E}", "\u{009F}"]
            .map { "\($0)metadata\u{009C}" }
            .joined()
        let output = "\u{001B}[32m✓\(sevenBitControls)\(eightBitControls){\"success\":true}\u{001B}[0m"

        #expect(self.stripTestRunnerNoise(from: output) == #"{"success":true}"#)
    }

    // MARK: - Helpers

    private func runMenuCommand(
        _ arguments: [String],
        context: MenuTestContext,
        allowedExitStatuses: Set<Int32> = [0]
    ) async throws -> CommandRunResult {
        // Point configuration loading at a clean temp dir so stray user configs don't
        // pollute stdout with validation warnings that break JSON decoding.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-menu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempConfig = tempDir.appendingPathComponent("config.json")
        try "{}".write(to: tempConfig, atomically: true, encoding: .utf8)

        let previousConfigDir = getenv("PEEKABOO_CONFIG_DIR").map { String(cString: $0) }
        let previousDisableMigration = getenv("PEEKABOO_CONFIG_DISABLE_MIGRATION").map { String(cString: $0) }
        setenv("PEEKABOO_CONFIG_DIR", tempDir.path, 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        defer {
            if let previousConfigDir {
                setenv("PEEKABOO_CONFIG_DIR", previousConfigDir, 1)
            } else {
                unsetenv("PEEKABOO_CONFIG_DIR")
            }
            if let previousDisableMigration {
                setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", previousDisableMigration, 1)
            } else {
                unsetenv("PEEKABOO_CONFIG_DISABLE_MIGRATION")
            }
        }

        let result = try await InProcessCommandRunner.run(arguments, services: context.services)
        try result.validateExitStatus(allowedExitCodes: allowedExitStatuses, arguments: arguments)
        return result
    }

    private func makeMenuContext(hasWindows: Bool) -> MenuTestContext {
        let appName = "Finder"
        let bundleID = "com.apple.finder"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 501,
            processStartIdentity: 5001,
            bundleIdentifier: bundleID,
            name: appName,
            bundlePath: "/System/Library/CoreServices/Finder.app",
            isActive: true,
            isHidden: false,
            windowCount: hasWindows ? 1 : 0
        )

        let menuStructure = self.sampleMenuStructure(appInfo: appInfo)
        let menuService = GenerationPinnedMenuStub(menusByApp: [appName: menuStructure])

        let windows = hasWindows ? [appName: [self.sampleWindowInfo()]] : [:]
        let windowService = StubWindowService(windowsByApp: windows)
        let applicationService = StubApplicationService(applications: [appInfo], windowsByApp: windows)

        let services = TestServicesFactory.makePeekabooServices(
            applications: applicationService,
            windows: windowService,
            menu: menuService
        )

        return MenuTestContext(
            services: services,
            appInfo: appInfo,
            menuService: menuService,
            windowService: windowService,
            applicationService: applicationService
        )
    }

    private func sampleMenuStructure(appInfo: ServiceApplicationInfo) -> MenuStructure {
        let newItem = MenuItem(
            title: "New",
            bundleIdentifier: appInfo.bundleIdentifier,
            ownerName: appInfo.name,
            keyboardShortcut: nil,
            isEnabled: true,
            isChecked: false,
            isSeparator: false,
            submenu: [],
            path: "File > New"
        )
        let fileMenu = Menu(
            title: "File",
            bundleIdentifier: appInfo.bundleIdentifier,
            ownerName: appInfo.name,
            items: [newItem]
        )
        return MenuStructure(application: appInfo, menus: [fileMenu])
    }

    private func sampleWindowInfo() -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: 101,
            title: "Finder",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            isMinimized: false,
            isMainWindow: true,
            windowLevel: 0,
            alpha: 1.0,
            index: 0,
            spaceID: 1,
            spaceName: "Desktop 1",
            screenIndex: 0,
            screenName: "Built-in"
        )
    }

    private struct MenuTestContext {
        let services: PeekabooServices
        let appInfo: ServiceApplicationInfo
        let menuService: StubMenuService
        let windowService: StubWindowService
        let applicationService: StubApplicationService
    }
}

@MainActor
private final class GenerationPinnedMenuStub: StubMenuService, MenuServiceGenerationPinnedActionResultProviding {
    func clickMenuItemActionResult(app: String, itemPath: String) async throws -> UIAutomationActionResult<Void> {
        try await self.clickMenuItem(app: app, itemPath: itemPath)
        return try self.result(app: app, mode: .foreground)
    }

    func clickMenuItemByNameActionResult(app: String, itemName: String) async throws
    -> UIAutomationActionResult<Void> {
        try await self.clickMenuItemByName(app: app, itemName: itemName)
        return try self.result(app: app, mode: .foreground)
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) async throws -> UIAutomationActionResult<Void> {
        let app = try self.appName(identity: request.expectedIdentity)
        try await self.clickMenuItem(app: app, itemPath: request.itemPath)
        return try self.result(app: app, mode: request.deliveryMode)
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) async throws
    -> UIAutomationActionResult<Void> {
        let app = try self.appName(identity: request.expectedIdentity)
        try await self.clickMenuItemByName(app: app, itemName: request.itemName)
        return try self.result(app: app, mode: request.deliveryMode)
    }

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try await self.clickMenuExtra(title: title)
        throw TestStubError.unimplemented(#function)
    }

    func clickMenuBarItemActionResult(named _: String) async throws
    -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        throw TestStubError.unimplemented(#function)
    }

    func clickMenuBarItemActionResult(at _: Int) async throws -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        throw TestStubError.unimplemented(#function)
    }

    private func appName(identity: ApplicationProcessIdentity) throws -> String {
        guard let app = self.menusByApp.values.first(where: { $0.application.processIdentity == identity })?
            .application.name
        else {
            throw PeekabooError.appNotFound("PID:\(identity.processIdentifier)")
        }
        return app
    }

    private func result(
        app: String,
        mode: DesktopActionOutcome.Delivery.Mode
    ) throws -> UIAutomationActionResult<Void> {
        guard let identity = self.menusByApp[app]?.application.processIdentity else {
            throw PeekabooError.appNotFound(app)
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: mode),
                unitCount: .one
            ),
            targetIdentity: DesktopTargetIdentity(processIdentity: identity)
        )
    }
}
#endif

// MARK: - JSON Helpers

#if !PEEKABOO_SKIP_AUTOMATION
extension MenuCommandIntegrationTests {
    private enum JSONDecodeError: Error {
        case emptyOutput
        case noJSONFound
    }

    /// Trim any progress/preamble characters emitted by the test runner and decode from the first JSON token.
    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from output: String,
        fallback: (() -> T)? = nil
    ) throws -> T {
        let filtered = self.stripTestRunnerNoise(from: output)
        let decoder = JSONDecoder()

        if filtered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let fallback {
                Issue.record("Menu command output was empty; returning fallback response")
                return fallback()
            }
            throw JSONDecodeError.emptyOutput
        }

        var searchStart = filtered.startIndex
        while let start = filtered[searchStart...].firstIndex(where: { $0 == "{" || $0 == "[" }) {
            if let jsonString = self.firstBalancedJSON(in: filtered, startingAt: start),
               let data = jsonString.data(using: .utf8),
               let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }

            searchStart = filtered.index(after: start)
        }

        if let fallback {
            Issue.record("Menu command output did not contain decodable JSON; returning fallback response")
            return fallback()
        }
        throw JSONDecodeError.noJSONFound
    }

    /// Returns the first balanced JSON object/array substring beginning at `start` if it can be delimited.
    private func firstBalancedJSON(in text: String, startingAt start: String.Index) -> String? {
        let opening = text[start]
        let closing: Character = opening == "{" ? "}" : "]"

        var depth = 0
        var inString = false
        var isEscaping = false

        var index = start
        while index < text.endIndex {
            let character = text[index]

            if inString {
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    inString = false
                }
            } else {
                if character == "\"" {
                    inString = true
                } else if character == opening {
                    depth += 1
                } else if character == closing {
                    depth -= 1
                    if depth == 0 {
                        let end = text.index(after: index)
                        return String(text[start..<end])
                    }
                }
            }

            index = text.index(after: index)
        }

        return nil
    }

    /// Remove swift-testing progress glyphs and other noisy lines that can be captured while stdout is redirected.
    private func stripTestRunnerNoise(from output: String) -> String {
        let noisePrefixes: Set<Character> = ["􀟈", "􁁛", "􀢄", "􀙟", "✓", "⚠", "⌨", "📊", "⚙", "⏱", "✅"]

        func trimmedNoise(_ line: Substring) -> String {
            var cleaned = stripANSI(String(line))
            while let first = cleaned.first, noisePrefixes.contains(first) {
                cleaned.removeFirst()
            }
            return cleaned.trimmingCharacters(in: .whitespaces)
        }

        return output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(trimmedNoise)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func fallbackMenuListResponse(for context: MenuTestContext) -> CodableJSONResponse<MenuListData> {
        let menuStructure = self.sampleMenuStructure(appInfo: context.appInfo)
        let menus = menuStructure.menus.map { menu in
            MenuData(
                title: menu.title,
                bundle_id: menu.bundleIdentifier,
                owner_name: menu.ownerName,
                enabled: true,
                items: menu.items.map(self.menuItemData(from:))
            )
        }

        let data = MenuListData(
            app: context.appInfo.name,
            owner_name: context.appInfo.name,
            bundle_id: context.appInfo.bundleIdentifier,
            menu_structure: menus
        )

        return CodableJSONResponse(success: true, data: data, messages: nil, debug_logs: [])
    }

    private func fallbackMenuClickResponse(
        for context: MenuTestContext,
        path: String
    ) -> CodableJSONResponse<MenuClickResult> {
        let result = MenuClickResult(
            action: "menu_click",
            app: context.appInfo.name,
            menu_path: path,
            clicked_item: path.components(separatedBy: " > ").last ?? path
        )
        return CodableJSONResponse(success: true, data: result, messages: nil, debug_logs: [])
    }

    private func menuItemData(from item: MenuItem) -> MenuItemData {
        MenuItemData(
            title: item.title,
            bundle_id: item.bundleIdentifier,
            owner_name: item.ownerName,
            enabled: item.isEnabled,
            shortcut: nil,
            checked: item.isChecked,
            separator: item.isSeparator,
            items: item.submenu.isEmpty ? nil : item.submenu.map(self.menuItemData(from:))
        )
    }
}
#endif
