import Foundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
private enum MenuHarnessConfig {
    @preconcurrency
    nonisolated static func runLocalHarnessEnabled() -> Bool {
        guard let raw = ProcessInfo.processInfo.environment["RUN_MENU_HARNESS_TESTS"]?.lowercased() else {
            return false
        }
        return raw == "true" || raw == "1" || raw == "yes"
    }
}

/// Generic response structure for tests
struct MenuTestResponse: Codable {
    let success: Bool
    let data: MenuExtractionData?
    let error: String?
}

struct MenuExtractionData: Codable {
    let app: String?
    let menu_structure: [[String: Any]]?
    let apps: [[String: Any]]?

    enum CodingKeys: String, CodingKey {
        case app
        case menu_structure
        case apps
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.app = try container.decodeIfPresent(String.self, forKey: .app)

        // Decode as generic JSON
        if let menuStructure = try? container.decode([[String: AnyCodable]].self, forKey: .menu_structure) {
            self.menu_structure = menuStructure.map { dict in
                dict.mapValues { $0.value }
            }
        } else {
            self.menu_structure = nil
        }

        if let appsArray = try? container.decode([[String: AnyCodable]].self, forKey: .apps) {
            self.apps = appsArray.map { dict in
                dict.mapValues { $0.value }
            }
        } else {
            self.apps = nil
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(self.app, forKey: .app)
        // For encoding, we'd need to convert back to AnyCodable
    }
}

/// Helper for decoding arbitrary JSON
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            var values: [Any] = []
            values.reserveCapacity(array.count)
            for element in array {
                values.append(element.value)
            }
            self.value = values
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            self.value = NSNull()
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        // Simplified encoding
        if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else {
            try container.encodeNil()
        }
    }
}

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationActions),
    .disabled("Requires local testing with RUN_LOCAL_TESTS")
)
struct MenuExtractionTests {
    @Test
    func `Extract menu structure without clicking`() async throws {
        // This test requires a running application
        #if !os(Linux)
        guard ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] != nil else { return }

        // Test with Calculator app
        let output = try await runPeekabooCommand(["menu", "list", "--app", "Calculator", "--json"])
        let data = try #require(output.data(using: .utf8))
        let json = try JSONDecoder().decode(MenuTestResponse.self, from: data)

        #expect(json.success == true)

        // Verify we got menu data
        if let menuData = json.data {
            #expect(menuData.app == "Calculator")

            // Check for menu structure
            if let menuStructure = menuData.menu_structure {
                #expect(!menuStructure.isEmpty)

                // Verify common Calculator menus exist
                let menuTitles = menuStructure.compactMap { $0["title"] as? String }
                #expect(menuTitles.contains("Calculator"))
                #expect(menuTitles.contains("Edit"))
                #expect(menuTitles.contains("View"))
                #expect(menuTitles.contains("Window"))
                #expect(menuTitles.contains("Help"))

                // Check View menu has items
                if let viewMenu = menuStructure.first(where: { $0["title"] as? String == "View" }) {
                    #expect(viewMenu["enabled"] as? Bool == true)

                    if let items = viewMenu["items"] as? [[String: Any]] {
                        let itemTitles = items.compactMap { $0["title"] as? String }

                        // Calculator should have these view options
                        #expect(itemTitles.contains("Basic"))
                        #expect(itemTitles.contains("Scientific"))
                        #expect(itemTitles.contains("Programmer"))
                    }
                }
            }
        }
        #endif
    }

    @Test
    func `Menu extraction includes keyboard shortcuts`() async throws {
        #if !os(Linux)
        guard ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] != nil else { return }

        // Test with TextEdit which has well-known shortcuts
        let output = try await runPeekabooCommand(["menu", "list", "--app", "TextEdit", "--json"])
        let data = try #require(output.data(using: .utf8))
        let json = try JSONDecoder().decode(MenuTestResponse.self, from: data)

        #expect(json.success == true)

        if let menuStructure = json.data?.menu_structure {
            // Find File menu
            if let fileMenu = menuStructure.first(where: { $0["title"] as? String == "File" }),
               let items = fileMenu["items"] as? [[String: Any]] {
                if let newItem = items.first(where: { $0["title"] as? String == "New" }) {
                    #expect(newItem["shortcut"] as? String == "⌘N")
                }

                if let saveItem = items.first(where: { ($0["title"] as? String)?.contains("Save") == true }) {
                    let shortcut = saveItem["shortcut"] as? String
                    #expect(shortcut == "⌘S" || shortcut == nil)
                }
            }
        }
        #endif
    }

    @Test
    func `Menu extraction handles nested submenus`() async throws {
        #if !os(Linux)
        guard ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] != nil else { return }

        // Finder has nested menus like View > Sort By > Name
        let output = try await runPeekabooCommand(["menu", "list", "--app", "Finder", "--json"])
        let data = try #require(output.data(using: .utf8))
        let json = try JSONDecoder().decode(MenuTestResponse.self, from: data)

        #expect(json.success == true)

        if let menuData = json.data {
            if let menuStructure = menuData.menu_structure {
                // Find View menu
                if let viewMenu = menuStructure.first(where: { $0["title"] as? String == "View" }),
                   let items = viewMenu["items"] as? [[String: Any]] {
                    // Look for submenu items
                    var hasSubmenu = false
                    for item in items {
                        if let subItems = item["items"] as? [[String: Any]], !subItems.isEmpty {
                            hasSubmenu = true
                            break
                        }
                    }

                    #expect(hasSubmenu, "Finder View menu should have submenus")
                }
            }
        }
        #endif
    }

    @Test
    func `Menu extraction properly handles disabled items`() async throws {
        #if !os(Linux)
        guard ProcessInfo.processInfo.environment["RUN_LOCAL_TESTS"] != nil else { return }

        let output = try await runPeekabooCommand(["menu", "list", "--app", "Finder", "--json"])
        let data = try #require(output.data(using: .utf8))
        let json = try JSONDecoder().decode(MenuTestResponse.self, from: data)

        #expect(json.success == true)

        if let menuData = json.data {
            if let menuStructure = menuData.menu_structure {
                var foundDisabledItem = false

                for menu in menuStructure {
                    if let items = menu["items"] as? [[String: Any]] {
                        for item in items {
                            if let enabled = item["enabled"] as? Bool, !enabled {
                                foundDisabledItem = true
                                break
                            }
                        }
                    }
                    if foundDisabledItem {
                        break
                    }
                }

                #expect(foundDisabledItem, "Should find at least one disabled menu item")
            }
        }
        #endif
    }
}

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: MenuHarnessConfig.runLocalHarnessEnabled())
)
struct MenuDialogLocalHarnessTests {
    private static let repositoryRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            url.deleteLastPathComponent()
        }
        return url
    }()

    @Test(
        .timeLimit(.minutes(2))
    )
    func `TextEdit menu list and click succeed via CLI`() async throws {
        try self.ensureAppLaunched("TextEdit")
        try await self.ensureUntitledTextEditDocument()

        let listResponse: CodableJSONResponse<MenuListData> = try self.runJSONCommand(
            ["menu", "list", "--app", "TextEdit", "--json"]
        )
        #expect(listResponse.success == true)
        #expect(
            listResponse.data.menu_structure.contains { $0.title == "File" },
            "File menu should be present for TextEdit"
        )

        let clickResponse = try self.runMenuClick(appName: "TextEdit", path: "File > New")
        #expect(clickResponse.success == true)
        #expect(clickResponse.data.menu_path == "File > New")
    }

    @Test(
        .timeLimit(.minutes(2))
    )
    func `Calculator menu list + Scientific toggle`() throws {
        try self.ensureAppLaunched("Calculator")

        let listResponse: CodableJSONResponse<MenuListData> = try self.runJSONCommand(
            ["menu", "list", "--app", "Calculator", "--json"]
        )
        #expect(listResponse.success == true)
        #expect(
            listResponse.data.menu_structure.contains { $0.title == "View" },
            "View menu should exist for Calculator"
        )

        let clickResponse = try self.runMenuClick(appName: "Calculator", path: "View > Scientific")
        #expect(clickResponse.success == true)
        #expect(clickResponse.data.menu_path == "View > Scientific")
    }

    @Test(
        .timeLimit(.minutes(2))
    )
    func `Menu click survives window churn`() async throws {
        try self.ensureAppLaunched("TextEdit")
        try await self.ensureUntitledTextEditDocument()

        for iteration in 0..<3 {
            _ = try self.runCLI(
                [
                    "window", "set-bounds",
                    "--app", "TextEdit",
                    "--x", "\(120 + iteration * 40)",
                    "--y", "\(100 + iteration * 30)",
                    "--width", "720",
                    "--height", "520",
                    "--json",
                ]
            )
            _ = try self.runCLI(
                [
                    "window", "list",
                    "--app", "TextEdit",
                    "--json",
                ]
            )
        }

        let clickResponse = try self.runMenuClick(appName: "TextEdit", path: "File > New")
        #expect(clickResponse.success == true)
    }

    @Test(
        .timeLimit(.minutes(2))
    )
    func `TextEdit Save dialog lists buttons via CLI`() async throws {
        try self.ensureAppLaunched("TextEdit")
        try await self.ensureUntitledTextEditDocument()
        try await self.triggerSavePanel()

        let dialogResponse: CodableJSONResponse<DialogListPayload> = try self.runJSONCommand(
            [
                "dialog", "list",
                "--app", "TextEdit",
                "--window-title", "Save",
                "--json",
            ]
        )

        #expect(dialogResponse.success == true)
        #expect(dialogResponse.data.buttons.contains("Save"))

        try self.assertCLIBinaryFresh()

        _ = try self.runCLI(
            [
                "dialog", "click",
                "--app", "TextEdit",
                "--button", "Cancel",
                "--json",
            ]
        )
    }

    @Test(
        .timeLimit(.minutes(3))
    )
    func `Menu stress loop runs for 45 seconds without stale window errors`() async throws {
        try await self.runMenuStressLoop(
            appName: "TextEdit",
            menuPath: "File > New",
            verification: { response in
                #expect(
                    response.data.menu_path == "File > New",
                    "TextEdit stress iteration must land on File > New"
                )
            }
        )

        try await self.runMenuStressLoop(
            appName: "Calculator",
            menuPath: "View > Scientific",
            verification: { response in
                #expect(
                    response.data.menu_path == "View > Scientific",
                    "Calculator stress iteration must toggle Scientific mode"
                )
            }
        )
    }

    // MARK: - Helpers

    private func ensureAppLaunched(_ appName: String) throws {
        _ = try self.runCLI(
            [
                "app", "launch",
                appName,
                "--wait-ready",
            ]
        )
        _ = try self.runCLI(
            [
                "window", "focus",
                "--app", appName,
                "--json",
            ]
        )
    }

    private func runMenuClick(
        appName: String,
        path: String
    ) throws -> CodableJSONResponse<MenuClickResult> {
        try self.runJSONCommand(
            [
                "menu", "click",
                "--app", appName,
                "--path", path,
                "--json",
            ]
        )
    }

    private func runJSONCommand<T: Decodable>(_ arguments: [String]) throws -> T {
        let result = try self.runCLI(arguments)
        return try ExternalCommandRunner.decodeJSONResponse(from: result, as: T.self)
    }

    private func ensureUntitledTextEditDocument() async throws {
        let response = try self.runMenuClick(appName: "TextEdit", path: "File > New")
        #expect(response.success == true)
        try await Task.sleep(nanoseconds: 500_000_000)
    }

    private func triggerSavePanel() async throws {
        _ = try self.runCLI(
            [
                "hotkey",
                "--keys", "cmd,s",
            ]
        )
        try await Task.sleep(nanoseconds: 1_000_000_000)
    }

    private func runMenuStressLoop(
        appName: String,
        menuPath: String,
        duration: TimeInterval = 45,
        verification: (CodableJSONResponse<MenuClickResult>) -> Void
    ) async throws {
        try self.ensureAppLaunched(appName)
        let start = Date()
        var iteration = 0

        while Date().timeIntervalSince(start) < duration {
            iteration += 1
            let listResponse: CodableJSONResponse<MenuListData> = try self.runJSONCommand(
                [
                    "menu", "list",
                    "--app", appName,
                    "--json",
                ]
            )
            #expect(listResponse.success == true, "Iteration \(iteration) failed to list menus for \(appName)")

            let clickResponse = try self.runMenuClick(appName: appName, path: menuPath)
            #expect(clickResponse.success == true, "Iteration \(iteration) failed to click \(menuPath)")
            verification(clickResponse)

            if iteration.isMultiple(of: 3) {
                _ = try self.runCLI(
                    [
                        "window", "set-bounds",
                        "--app", appName,
                        "--x", "\(150 + iteration * 5)",
                        "--y", "\(180 + iteration * 3)",
                        "--width", "700",
                        "--height", "500",
                        "--json",
                    ]
                )
            }

            if iteration.isMultiple(of: 2) {
                _ = try self.runCLI(
                    [
                        "window", "list",
                        "--app", appName,
                        "--json",
                    ]
                )
            }

            try await Task.sleep(nanoseconds: 200_000_000) // keep loop responsive (<60s cap)
        }
    }

    @discardableResult
    private func runCLI(_ arguments: [String]) throws -> CommandRunResult {
        let finalArguments = arguments.contains("--no-remote") ? arguments : arguments + ["--no-remote"]
        return try ExternalCommandRunner.runPeekabooCLI(finalArguments)
    }

    private func assertCLIBinaryFresh(maxAge: TimeInterval = 600) throws {
        let binaryURL = Self.repositoryRoot.appendingPathComponent("peekaboo")
        let attributes = try FileManager.default.attributesOfItem(atPath: binaryURL.path)
        guard let modifiedDate = attributes[.modificationDate] as? Date else {
            return
        }
        let age = Date().timeIntervalSince(modifiedDate)
        let freshnessMessage =
            "Peekaboo binary at \(binaryURL.path) is older than \(Int(maxAge)) seconds. " +
            "Rebuild the debug CLI to refresh it."
        #expect(age < maxAge, Comment(rawValue: freshnessMessage))
    }

    private struct DialogListPayload: Codable {
        struct TextField: Codable {
            let title: String
            let value: String
            let placeholder: String
        }

        let title: String
        let role: String
        let buttons: [String]
        let textFields: [TextField]
        let textElements: [String]
    }
}

// MARK: - Test Helpers

private func runPeekabooCommand(_ args: [String]) async throws -> String {
    let result = try await InProcessCommandRunner.runShared(args)
    return result.combinedOutput
}
#endif
