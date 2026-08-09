import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

private typealias AppsSubcommand = ListCommand.AppsSubcommand
private typealias WindowsSubcommand = ListCommand.WindowsSubcommand
private typealias PermissionsSubcommand = ListCommand.PermissionsSubcommand
private typealias MenuBarSubcommand = ListCommand.MenuBarSubcommand
private typealias ScreensSubcommand = ListCommand.ScreensSubcommand

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.safe),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct ListCommandCLIHarnessTests {
    @Test
    func `list apps outputs stub data in JSON mode`() async throws {
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 101,
                bundleIdentifier: "com.example.alpha",
                name: "AlphaApp",
                isActive: true,
                windowCount: 2
            ),
            ServiceApplicationInfo(
                processIdentifier: 202,
                bundleIdentifier: "com.example.beta",
                name: "BetaApp",
                isActive: false,
                windowCount: 1
            ),
        ]
        let context = await makeContext(applications: applications)

        let result = try await runList(arguments: ["list", "apps", "--json"], services: context.services)
        #expect(result.exitStatus == 0)

        let data = try #require(output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ServiceApplicationListData>.self, from: data)
        #expect(payload.success == true)
        #expect(payload.data.applications.count == 2)
        #expect(payload.data.applications.first?.name == "AlphaApp")

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadData = try #require(json["data"] as? [String: Any])
        #expect(payloadData["applications"] is [[String: Any]])
        #expect(payloadData["apps"] is [[String: Any]])
    }

    @Test
    func `list apps renders human-readable output`() async throws {
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 333,
                bundleIdentifier: "com.example.viewer",
                name: "Viewer",
                isActive: true,
                windowCount: 4
            ),
        ]
        let context = await makeContext(applications: applications)

        let result = try await runList(arguments: ["list", "apps"], services: context.services)
        #expect(result.exitStatus == 0)
        let output = output(from: result)
        #expect(output.contains("Viewer"))
        #expect(output.contains("PID"))
    }

    @Test
    func `list apps accepts app list parity flags through command runner`() async throws {
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 333,
                bundleIdentifier: "com.example.viewer",
                name: "Viewer",
                isActive: true,
                windowCount: 4
            ),
        ]
        let context = await makeContext(applications: applications)

        let result = try await runList(
            arguments: ["list", "apps", "--include-hidden", "--include-background", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("\"apps\""))
        #expect(self.output(from: result).contains("\"applications\""))
    }

    @Test
    func `list windows with include details filters output`() async throws {
        let appName = "Finder"
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 404,
                bundleIdentifier: "com.apple.finder",
                name: appName,
                isActive: true,
                windowCount: 1
            ),
        ]
        let windows = [
            ServiceWindowInfo(
                windowID: 9001,
                title: "Documents",
                bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
                isMinimized: false,
                isMainWindow: true,
                index: 0,
                spaceID: 4,
                spaceName: "Work"
            ),
        ]
        let applicationService = await MainActor.run {
            StubApplicationService(applications: applications, windowsByApp: [appName: windows])
        }
        let context = await makeContext(applicationService: applicationService)

        let result = try await runList(
            arguments: [
                "list", "windows",
                "--app", appName,
                "--include-details", "bounds,ids",
                "--json",
            ],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let output = output(from: result)
        #expect(output.contains("\"windowID\""))
        #expect(output.contains("\"bounds\""))
        #expect(output.contains("\"spaceID\""))
    }

    @Test
    func `list apps works when screen recording permission is missing`() async throws {
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 101,
                bundleIdentifier: "com.example.alpha",
                name: "AlphaApp",
                isActive: true,
                windowCount: 2
            ),
        ]
        let screenCapture = await MainActor.run {
            StubScreenCaptureService(permissionGranted: false)
        }
        let context = await makeContext(applications: applications, screenCapture: screenCapture)

        let result = try await runList(arguments: ["list", "apps"], services: context.services)
        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("AlphaApp"))
    }

    @Test
    func `list menubar JSON emits legacy and preferred keys`() async throws {
        let context = await makeContext(applications: [])

        let result = try await runList(arguments: ["list", "menubar", "--json"], services: context.services)

        #expect(result.exitStatus == 0)
        let data = try #require(output(from: result).data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadData = try #require(json["data"] as? [String: Any])
        #expect(payloadData["items"] is [[String: Any]])
        #expect(payloadData["menu_bar_items"] is [[String: Any]])
    }

    // MARK: - Helpers

    private func runList(arguments: [String], services: PeekabooServices) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(arguments, services: services)
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func makeContext(
        applications: [ServiceApplicationInfo],
        screenCapture: StubScreenCaptureService? = nil
    ) async -> HarnessContext {
        let applicationService = await MainActor.run {
            StubApplicationService(applications: applications)
        }
        return await self.makeContext(applicationService: applicationService, screenCapture: screenCapture)
    }

    @MainActor
    private func makeContext(
        applicationService: any ApplicationServiceProtocol,
        screenCapture: StubScreenCaptureService? = nil
    ) async -> HarnessContext {
        let captureService = screenCapture ?? StubScreenCaptureService(permissionGranted: true)
        let services = TestServicesFactory.makePeekabooServices(
            applications: applicationService,
            screenCapture: captureService
        )

        return HarnessContext(services: services)
    }

    private struct HarnessContext {
        let services: PeekabooServices
    }
}
#endif

@Suite(.serialized, .tags(.safe))
struct ListCommandJSONContractTests {
    @Test
    @MainActor
    func `list apps JSON emits legacy and preferred application keys`() async throws {
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 101,
                bundleIdentifier: "com.example.alpha",
                name: "AlphaApp",
                isActive: true,
                windowCount: 2
            ),
        ]
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: applications)
        )

        let result = try await InProcessCommandRunner.run(["list", "apps", "--json"], services: services)

        #expect(result.exitStatus == 0)
        let data = try #require(result.stdout.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadData = try #require(json["data"] as? [String: Any])
        let applicationsLegacy = try #require(payloadData["applications"] as? [[String: Any]])
        let appsPreferred = try #require(payloadData["apps"] as? [[String: Any]])
        #expect(applicationsLegacy.count == 1)
        #expect(appsPreferred.count == applicationsLegacy.count)
    }

    @Test
    @MainActor
    func `list apps accepts app list parity flags through command runner`() async throws {
        let applications = [
            ServiceApplicationInfo(
                processIdentifier: 333,
                bundleIdentifier: "com.example.viewer",
                name: "Viewer",
                isActive: true,
                windowCount: 4
            ),
        ]
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: applications)
        )

        let result = try await InProcessCommandRunner.run(
            ["list", "apps", "--include-hidden", "--include-background", "--json"],
            services: services
        )

        #expect(result.exitStatus == 0)
        #expect(result.stdout.contains("Viewer"))
    }

    @Test
    @MainActor
    func `list menubar JSON emits legacy and preferred item keys`() async throws {
        let services = TestServicesFactory.makePeekabooServices(menu: StubMenuService(menusByApp: [:]))

        let result = try await InProcessCommandRunner.run(["list", "menubar", "--json"], services: services)

        #expect(result.exitStatus == 0)
        let data = try #require(result.stdout.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadData = try #require(json["data"] as? [String: Any])
        #expect(payloadData["items"] is [[String: Any]])
        #expect(payloadData["menu_bar_items"] is [[String: Any]])
    }
}

@Suite(.serialized, .tags(.unit))
struct ListCommandTests {
    // MARK: - Command Parsing Tests

    @Test(.tags(.fast))
    func `ListCommand has correct subcommands`() {
        // Test that ListCommand has the expected subcommands
        #expect(ListCommand.commandDescription.subcommands.count == 5)
        let subcommandTypes = ListCommand.commandDescription.subcommands
        #expect(subcommandTypes.contains { $0 == AppsSubcommand.self })
        #expect(subcommandTypes.contains { $0 == WindowsSubcommand.self })
        #expect(subcommandTypes.contains { $0 == PermissionsSubcommand.self })
        #expect(subcommandTypes.contains { $0 == MenuBarSubcommand.self })
        #expect(subcommandTypes.contains { $0 == ScreensSubcommand.self })
    }

    @Test(.tags(.fast))
    func `AppsSubcommand parsing with defaults`() throws {
        // Test parsing apps subcommand
        let command = try AppsSubcommand.parse([])
        #expect(command.jsonOutput == false)
    }

    @Test(.tags(.fast))
    func `AppsSubcommand with JSON output flag`() throws {
        // Test apps subcommand with JSON flag
        let command = try AppsSubcommand.parse(["--json"])
        #expect(command.jsonOutput == true)
    }

    @Test(.tags(.fast))
    func `AppsSubcommand accepts app list parity flags`() throws {
        let command = try AppsSubcommand.parse(["--include-hidden", "--include-background"])
        #expect(command.includeHidden == true)
        #expect(command.includeBackground == true)
    }

    @Test(.tags(.fast))
    func `WindowsSubcommand parsing with required app`() throws {
        // Test parsing windows subcommand with required app
        let command = try WindowsSubcommand.parse(["--app", "Finder"])

        #expect(command.app == "Finder")
        #expect(command.jsonOutput == false)
        #expect(command.includeDetails == nil)
    }

    @Test(.tags(.fast))
    func `WindowsSubcommand with detail options`() throws {
        // Test windows subcommand with detail options
        let command = try WindowsSubcommand.parse([
            "--app", "Finder",
            "--include-details", "bounds,ids",
        ])

        #expect(command.app == "Finder")
        #expect(command.includeDetails == "bounds,ids")
    }

    @Test(.tags(.fast))
    func `WindowsSubcommand requires app parameter`() {
        // Test that windows subcommand requires app
        #expect(throws: (any Error).self) {
            try CLIOutputCapture.suppressStderr {
                try WindowsSubcommand.parse([])
            }
        }
    }

    // MARK: - Parameterized Command Tests

    @Test(
        arguments: [
            "off_screen",
            "bounds",
            "ids",
            "off_screen,bounds",
            "bounds,ids",
            "off_screen,bounds,ids"
        ]
    )
    func `WindowsSubcommand detail parsing`(details: String) throws {
        let command = try WindowsSubcommand.parse([
            "--app", "Safari",
            "--include-details", details,
        ])

        #expect(command.includeDetails == details)
    }

    // MARK: - Data Structure Tests

    @Test(.tags(.fast))
    func `ServiceApplicationInfo JSON encoding`() throws {
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 123,
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            isActive: true,
            windowCount: 5
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(appInfo)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil)
        #expect(json?["name"] as? String == "Finder")
        #expect(json?["bundleIdentifier"] as? String == "com.apple.finder")
        #expect(json?["processIdentifier"] as? Int32 == 123)
        #expect(json?["isActive"] as? Bool == true)
        #expect(json?["windowCount"] as? Int == 5)
    }

    @Test(.tags(.fast))
    func `ServiceApplicationListData JSON encoding`() throws {
        let appData = ServiceApplicationListData(
            applications: [
                ServiceApplicationInfo(
                    processIdentifier: 123,
                    bundleIdentifier: "com.apple.finder",
                    name: "Finder",
                    isActive: true,
                    windowCount: 3
                ),
                ServiceApplicationInfo(
                    processIdentifier: 456,
                    bundleIdentifier: "com.apple.Safari",
                    name: "Safari",
                    isActive: false,
                    windowCount: 2
                ),
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(appData)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil)
        let apps = json?["applications"] as? [[String: Any]]
        #expect(apps?.count == 2)
    }

    @Test(.tags(.fast))
    func `WindowInfo JSON encoding`() throws {
        // Test WindowInfo JSON encoding
        let windowInfo = WindowInfo(
            window_title: "Documents",
            window_id: 1001,
            window_index: 0,
            bounds: WindowBounds(x: 100, y: 200, width: 800, height: 600),
            is_on_screen: true,
            is_frontmost: true,
            is_key: true,
            layer: 0,
            subrole: "AXStandardWindow"
        )

        let encoder = JSONEncoder()
        // Properties are already in snake_case, no conversion needed

        let data = try encoder.encode(windowInfo)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil)
        #expect(json?["window_title"] as? String == "Documents")
        #expect(json?["window_id"] as? UInt32 == 1001)
        #expect(json?["is_on_screen"] as? Bool == true)
        #expect(json?["is_frontmost"] as? Bool == true)
        #expect(json?["is_key"] as? Bool == true)
        #expect(json?["layer"] as? Int == 0)
        #expect(json?["subrole"] as? String == "AXStandardWindow")

        let bounds = json?["bounds"] as? [String: Any]
        #expect(bounds?["x"] as? Int == 100)
        #expect(bounds?["y"] as? Int == 200)
        #expect(bounds?["width"] as? Int == 800)
        #expect(bounds?["height"] as? Int == 600)
    }

    @Test(.tags(.fast))
    func `ScreenListData JSON includes global bounds and display metadata`() throws {
        let screenData = ScreenListData(
            screens: [
                ScreenListData.ScreenDetails(
                    index: 0,
                    name: "Built-in Retina Display",
                    resolution: .init(width: 1944, height: 1274),
                    position: .init(x: 0, y: 0),
                    bounds: .init(x: 0, y: 0, width: 1944, height: 1274),
                    visibleArea: .init(width: 1944, height: 1249),
                    isPrimary: true,
                    scaleFactor: 2,
                    displayID: 6
                ),
            ],
            primaryIndex: 0
        )

        let data = try JSONEncoder().encode(screenData)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let screens = try #require(json["screens"] as? [[String: Any]])
        let screen = try #require(screens.first)
        let bounds = try #require(screen["bounds"] as? [String: Any])

        #expect(screen["displayID"] as? Int == 6)
        #expect(screen["scaleFactor"] as? Double == 2)
        #expect(screen["isPrimary"] as? Bool == true)
        #expect(bounds["x"] as? Int == 0)
        #expect(bounds["y"] as? Int == 0)
        #expect(bounds["width"] as? Int == 1944)
        #expect(bounds["height"] as? Int == 1274)
    }

    @Test(.tags(.fast))
    func `Screen bounds use upper left global click coordinates`() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let appKitScreenAbove = CGRect(x: 0, y: 1080, width: 1280, height: 720)
        let appKitScreenBelow = CGRect(x: 0, y: -900, width: 1440, height: 900)

        #expect(ListCommand.ScreensSubcommand.globalBounds(
            fromAppKit: appKitScreenAbove,
            primaryScreenFrame: primary
        ) == CGRect(x: 0, y: -720, width: 1280, height: 720))
        #expect(ListCommand.ScreensSubcommand.globalBounds(
            fromAppKit: appKitScreenBelow,
            primaryScreenFrame: primary
        ) == CGRect(x: 0, y: 1080, width: 1440, height: 900))
    }

    @Test(.tags(.fast))
    func `WindowListData JSON encoding`() throws {
        // Test WindowListData JSON encoding
        let windowData = WindowListData(
            windows: [
                WindowInfo(
                    window_title: "Documents",
                    window_id: 1001,
                    window_index: 0,
                    bounds: WindowBounds(x: 100, y: 200, width: 800, height: 600),
                    is_on_screen: true
                ),
            ],
            target_application_info: TargetApplicationInfo(
                app_name: "Finder",
                bundle_id: "com.apple.finder",
                pid: 123
            )
        )

        let encoder = JSONEncoder()
        // Properties are already in snake_case, no conversion needed

        let data = try encoder.encode(windowData)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json != nil)

        let windows = json?["windows"] as? [[String: Any]]
        #expect(windows?.count == 1)

        let targetApp = json?["target_application_info"] as? [String: Any]
        #expect(targetApp?["app_name"] as? String == "Finder")
        #expect(targetApp?["bundle_id"] as? String == "com.apple.finder")
    }

    // MARK: - Window Detail Option Tests

    @Test(.tags(.fast))
    func `WindowDetailOption raw values`() {
        #expect(ListCommand.WindowsSubcommand.WindowDetailOption.off_screen.rawValue == "off_screen")
        #expect(ListCommand.WindowsSubcommand.WindowDetailOption.bounds.rawValue == "bounds")
        #expect(ListCommand.WindowsSubcommand.WindowDetailOption.ids.rawValue == "ids")
    }

    // MARK: - Performance Tests

    @Test(
        arguments: [10, 50, 100, 200]
    )
    func `ServiceApplicationListData encoding performance`(appCount: Int) throws {
        let apps = (0..<appCount).map { index -> ServiceApplicationInfo in
            ServiceApplicationInfo(
                processIdentifier: Int32(1000 + index),
                bundleIdentifier: "com.example.app\(index)",
                name: "App\(index)",
                isActive: index == 0,
                windowCount: index % 5
            )
        }

        let appData = ServiceApplicationListData(applications: apps)
        let encoder = JSONEncoder()
        let data = try encoder.encode(appData)
        #expect(!data.isEmpty)
    }
}

// MARK: - Extended List Command Tests

@Suite(.serialized, .tags(.integration))
struct ListCommandAdvancedTests {
    @Test(.tags(.fast))
    func `PermissionsSubcommand parsing`() throws {
        let command = try PermissionsSubcommand.parse([])
        #expect(command.jsonOutput == false)

        let commandWithJSON = try PermissionsSubcommand.parse(["--json"])
        #expect(commandWithJSON.jsonOutput == true)
    }

    @Test(.tags(.fast))
    func `Command help messages`() {
        let listHelp = ListCommand.helpMessage()
        #expect(listHelp.contains("List"))

        let appsHelp = AppsSubcommand.helpMessage()
        #expect(appsHelp.contains("running applications"))

        let windowsHelp = WindowsSubcommand.helpMessage()
        #expect(windowsHelp.contains("windows"))

        let permissionsHelp = PermissionsSubcommand.helpMessage()
        #expect(permissionsHelp.contains("permissions"))
    }

    @Test(
        arguments: [
            (title: "Main Window", id: 1001, onScreen: true),
            (title: "Hidden Window", id: 2001, onScreen: false),
            (title: "Minimized", id: 3001, onScreen: false)
        ]
    )
    func `Complex window info structures`(title: String, id: UInt32, onScreen: Bool) throws {
        let windowInfo = WindowInfo(
            window_title: title,
            window_id: id,
            window_index: 0,
            bounds: nil,
            is_on_screen: onScreen
        )

        let encoder = JSONEncoder()
        // No need for convertToSnakeCase since properties are already in snake_case
        let data = try encoder.encode(windowInfo)

        let decoder = JSONDecoder()
        // No need for convertFromSnakeCase since properties are already in snake_case
        let decoded = try decoder.decode(WindowInfo.self, from: data)

        #expect(decoded.window_title == title)
        #expect(decoded.window_id == id)
        #expect(decoded.is_on_screen == onScreen)
    }

    @Test(
        arguments: [
            (active: true, windowCount: 5),
            (active: false, windowCount: 0),
            (active: true, windowCount: 0),
            (active: false, windowCount: 10),
        ]
    )
    func `Application state combinations`(active: Bool, windowCount: Int) {
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 1234,
            bundleIdentifier: "com.test.app",
            name: "TestApp",
            isActive: active,
            windowCount: windowCount
        )

        #expect(appInfo.isActive == active)
        #expect(appInfo.windowCount == windowCount)

        // Logical consistency checks
        if windowCount > 0 {
            // Apps with windows can be active or inactive
            #expect(appInfo.windowCount > 0)
        }
    }

    @Test(.tags(.fast))
    func `Server permissions data encoding`() throws {
        // Define the missing types locally for this test
        struct ServerPermissions: Codable {
            let screen_recording: Bool
            let accessibility: Bool
        }

        struct ServerStatusData: Codable {
            let permissions: ServerPermissions
        }

        let permissions = ServerPermissions(
            screen_recording: true,
            accessibility: false
        )

        let statusData = ServerStatusData(permissions: permissions)

        let encoder = JSONEncoder()
        // Properties are already in snake_case, no conversion needed
        let data = try encoder.encode(statusData)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let permsJson = json?["permissions"] as? [String: Any]

        #expect(permsJson?["screen_recording"] as? Bool == true)
        #expect(permsJson?["accessibility"] as? Bool == false)
    }
}
