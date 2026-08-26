import Commander
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@MainActor
struct DockCommandForegroundConsentTests {
    @Test
    func `dock launch refuses before dispatch without foreground consent`() async {
        let dock = RecordingDockService()
        var command = DockCommand.LaunchSubcommand()
        command.app = "Finder"

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(dock: dock))
        }

        #expect(dock.launchRequests.isEmpty)
    }

    @Test
    func `dock right-click refuses before dispatch without foreground consent`() async {
        let dock = RecordingDockService()
        var command = DockCommand.RightClickSubcommand()
        command.app = "Finder"

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(dock: dock))
        }

        #expect(dock.rightClickRequests.isEmpty)
    }

    @Test
    func `dock visibility refuses before dispatch without foreground consent`() async {
        let dock = RecordingDockService()
        var hide = DockCommand.HideSubcommand()
        var show = DockCommand.ShowSubcommand()

        await #expect(throws: ExitCode.self) {
            try await hide.run(using: self.makeRuntime(dock: dock))
        }
        await #expect(throws: ExitCode.self) {
            try await show.run(using: self.makeRuntime(dock: dock))
        }

        #expect(dock.hideRequestCount == 0)
        #expect(dock.showRequestCount == 0)
    }

    @Test
    func `explicit foreground consent dispatches Dock mutations`() async throws {
        let dock = RecordingDockService()
        var launch = DockCommand.LaunchSubcommand()
        launch.app = "Finder"
        launch.foreground = true
        try await launch.run(using: self.makeRuntime(dock: dock))

        var rightClick = DockCommand.RightClickSubcommand()
        rightClick.app = "Finder"
        rightClick.select = "New Window"
        rightClick.foreground = true
        try await rightClick.run(using: self.makeRuntime(dock: dock))

        var hide = DockCommand.HideSubcommand()
        hide.foreground = true
        try await hide.run(using: self.makeRuntime(dock: dock))

        var show = DockCommand.ShowSubcommand()
        show.foreground = true
        try await show.run(using: self.makeRuntime(dock: dock))

        #expect(dock.launchRequests == ["Finder"])
        #expect(dock.rightClickRequests.count == 1)
        #expect(dock.rightClickRequests.first?.appName == "Finder")
        #expect(dock.rightClickRequests.first?.menuItem == "New Window")
        #expect(dock.hideRequestCount == 1)
        #expect(dock.showRequestCount == 1)
    }

    private func makeRuntime(dock: RecordingDockService) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: ServicesWithDockStub(dock: dock)
        )
    }
}

@MainActor
private final class RecordingDockService: DockServiceProtocol {
    private(set) var launchRequests: [String] = []
    private(set) var rightClickRequests: [(appName: String, menuItem: String?)] = []
    private(set) var hideRequestCount = 0
    private(set) var showRequestCount = 0

    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        [self.finderItem]
    }

    func launchFromDock(appName: String) async throws {
        self.launchRequests.append(appName)
    }

    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}

    func rightClickDockItem(appName: String, menuItem: String?) async throws {
        self.rightClickRequests.append((appName, menuItem))
    }

    func hideDock() async throws {
        self.hideRequestCount += 1
    }

    func showDock() async throws {
        self.showRequestCount += 1
    }

    func isDockAutoHidden() async -> Bool {
        false
    }

    func findDockItem(name _: String) async throws -> DockItem {
        self.finderItem
    }

    private var finderItem: DockItem {
        DockItem(
            index: 0,
            title: "Finder",
            itemType: .application,
            isRunning: true,
            bundleIdentifier: "com.apple.finder",
            position: nil,
            size: nil
        )
    }
}

@MainActor
private final class ServicesWithDockStub: PeekabooServiceProviding {
    private let base = PeekabooServices()
    private let stubDock: any DockServiceProtocol

    init(dock: any DockServiceProtocol) {
        self.stubDock = dock
    }

    func ensureVisualizerConnection() {
        self.base.ensureVisualizerConnection()
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.stubDock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var files: any FileServiceProtocol {
        self.base.files
    }

    var clipboard: any ClipboardServiceProtocol {
        self.base.clipboard
    }

    var configuration: PeekabooCore.ConfigurationManager {
        self.base.configuration
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var audioInput: AudioInputService {
        self.base.audioInput
    }

    var screens: any ScreenServiceProtocol {
        self.base.screens
    }

    var browser: any BrowserMCPClientProviding {
        self.base.browser
    }

    var agent: (any AgentServiceProtocol)? {
        self.base.agent
    }
}
