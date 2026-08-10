import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct AppCommandLaunchFlowTests {
    @Test
    func `Launch without --open stays background through runtime host`() async throws {
        let service = self.makeLaunchService(name: "Finder", bundleIdentifier: "com.apple.finder")

        var command = AppCommand.LaunchSubcommand()
        command.app = "Finder"
        let runtime = self.makeRuntime(applicationService: service)
        try await command.run(using: runtime)

        let request = try #require(service.launchRequests.first)
        #expect(request.applicationIdentifier == "Finder")
        #expect(request.openURLs.isEmpty)
        #expect(!request.activates)
    }

    @Test
    func `Launch activates only with foreground`() async throws {
        let service = self.makeLaunchService(name: "Finder", bundleIdentifier: "com.apple.finder")
        var command = AppCommand.LaunchSubcommand()
        command.app = "Finder"
        command.foreground = true

        try await command.run(using: self.makeRuntime(applicationService: service))

        #expect(service.launchRequests.first?.activates == true)
    }

    @Test
    func `Launch forwards new-instance without opting into foreground`() async throws {
        let service = self.makeLaunchService(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        var command = AppCommand.LaunchSubcommand()
        command.app = "TextEdit"
        command.newInstance = true
        command.waitUntilReady = true
        command.waitForWindow = true

        try await command.run(using: self.makeRuntime(applicationService: service))

        let request = try #require(service.launchRequests.first)
        #expect(request.createsNewInstance)
        #expect(request.waitUntilReady)
        #expect(request.waitForWindow)
        #expect(!request.activates)
    }

    @Test
    func `Launch with --open documents skips focus through runtime host`() async throws {
        let service = self.makeLaunchService(name: "Preview", bundleIdentifier: "com.apple.Preview")

        var command = AppCommand.LaunchSubcommand()
        command.app = "Preview"
        command.noFocus = true
        command.openTargets = ["~/Desktop/file1.pdf", "https://example.com"]
        let runtime = self.makeRuntime(applicationService: service)
        try await command.run(using: runtime)

        let request = try #require(service.launchRequests.first)
        #expect(!request.activates)
        #expect(request.openURLs.count == 2)
        #expect(request.openURLs[0].path.hasSuffix("/Desktop/file1.pdf"))
        #expect(request.openURLs[1].absoluteString == "https://example.com")
    }

    @Test
    func `Launch without open preserves no focus and invalidates selected and discovered snapshots`() async throws {
        let service = self.makeLaunchService(name: "Notes", bundleIdentifier: "com.apple.Notes")
        let snapshots = try await SnapshotInvalidationFixture.start()
        defer { Task { await snapshots.host.stop() } }

        var command = AppCommand.LaunchSubcommand()
        command.app = "Notes"
        command.noFocus = true
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(
                applications: service,
                snapshots: snapshots.selected
            ),
            snapshotInvalidationRemoteSocketPaths: [snapshots.discoveredSocketPath]
        )
        try await command.run(using: runtime)

        let request = try #require(service.launchRequests.first)
        #expect(!request.activates)
        #expect(await snapshots.selected.getMostRecentSnapshot() == nil)
        #expect(await snapshots.discovered.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Bundle identifier takes precedence over positional name`() async throws {
        let service = self.makeLaunchService(name: "Calculator", bundleIdentifier: "com.apple.calculator")
        var command = AppCommand.LaunchSubcommand()
        command.app = "Calculator"
        command.bundleId = "com.apple.calculator"
        command.noFocus = true

        try await command.run(using: self.makeRuntime(applicationService: service))

        #expect(service.launchRequests.first?.applicationIdentifier == nil)
        #expect(service.launchRequests.first?.applicationBundleIdentifier == "com.apple.calculator")
    }

    @Test
    func `Launch resolves a relative app path in the caller directory`() async throws {
        let service = self.makeLaunchService(name: "Fixture", bundleIdentifier: "com.example.fixture")
        var command = AppCommand.LaunchSubcommand()
        command.app = "./Build/Fixture.app"

        try await command.run(using: self.makeRuntime(applicationService: service))

        #expect(
            service.launchRequests.first?.applicationIdentifier ==
                ApplicationIdentifierResolver.resolve("./Build/Fixture.app")
        )
    }

    @Test
    func `Application identifier resolution preserves names and absolutizes paths`() {
        #expect(ApplicationIdentifierResolver.resolve("Calculator", cwd: "/tmp/workspace") == "Calculator")
        #expect(
            ApplicationIdentifierResolver.resolve("./Build/Foo.app", cwd: "/tmp/workspace") ==
                "/tmp/workspace/Build/Foo.app"
        )
        #expect(ApplicationIdentifierResolver.resolve("/Applications/Foo.app", cwd: "/tmp/workspace") ==
            "/Applications/Foo.app")
    }

    @Test
    func `Switch to app activates through application service`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: "com.apple.finder",
            name: "Finder"
        )
        let applicationService = RecordingApplicationService(applications: [application])

        var command = AppCommand.SwitchSubcommand()
        command.to = "Finder"
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        )
        try await command.run(using: runtime)

        #expect(applicationService.activateCalls == ["Finder"])
    }

    @Test
    func `Switch cycle uses automation hotkey service`() async throws {
        let automation = RecordingHotkeyAutomationService()

        var command = AppCommand.SwitchSubcommand()
        command.cycle = true
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(
                applications: RecordingApplicationService(applications: []),
                automation: automation
            )
        )
        try await command.run(using: runtime)

        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,tab"])
        #expect(automation.hotkeyCalls.map(\.holdDuration) == [0])
    }

    @Test
    func `Quit command uses application service target PID`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.notes",
            name: "Notes"
        )
        let applicationService = RecordingApplicationService(applications: [application])

        var command = AppCommand.QuitSubcommand()
        command.app = "Notes"
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        )
        try await command.run(using: runtime)

        #expect(applicationService.quitCalls == [.init(identifier: "PID:123", force: false)])
        #expect(applicationService.quitRequests == [ApplicationQuitRequest(
            identifier: "PID:123",
            expectedIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 1001
            )
        )])
    }

    @Test
    func `Quit rejects the selected daemon before terminating it`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 321,
            processStartIdentity: 3001,
            bundleIdentifier: "boo.peekaboo.peekaboo",
            name: "Peekaboo daemon"
        )
        let applicationService = RecordingApplicationService(applications: [application])

        var command = AppCommand.QuitSubcommand()
        command.app = "Peekaboo daemon"
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService),
            selectedRemoteHostProcessIdentifier: 321
        )

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }
        #expect(applicationService.findCalls == ["Peekaboo daemon"])
        #expect(applicationService.quitCalls.isEmpty)
        #expect(applicationService.quitRequests.isEmpty)
    }

    @Test
    func `Quit all keeps accessory apps out of termination set`() async throws {
        let regularApplication = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.editor",
            name: "Editor",
            activationPolicy: .regular
        )
        let accessoryApplication = ServiceApplicationInfo(
            processIdentifier: 456,
            processStartIdentity: 4001,
            bundleIdentifier: "com.example.menu",
            name: "Menu Extra",
            activationPolicy: .accessory
        )
        let applicationService = RecordingApplicationService(applications: [
            accessoryApplication,
            regularApplication,
        ])

        var command = AppCommand.QuitSubcommand()
        command.all = true
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        )
        try await command.run(using: runtime)

        #expect(applicationService.quitCalls == [.init(identifier: "PID:123", force: false)])
        #expect(applicationService.quitRequests == [ApplicationQuitRequest(
            identifier: "PID:123",
            expectedIdentity: ApplicationProcessIdentity(
                processIdentifier: 123,
                processStartIdentity: 1001
            )
        )])
    }

    @Test
    func `Relaunch command quits and launches through runtime host`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.app",
            name: "Example"
        )
        let relaunched = ServiceApplicationInfo(
            processIdentifier: 456,
            processStartIdentity: 2001,
            bundleIdentifier: "com.example.app",
            name: "Example",
            isActive: true,
            isFinishedLaunching: true
        )
        let applicationService = RecordingApplicationService(
            applications: [application],
            launchResponse: relaunched
        )

        var command = AppCommand.RelaunchSubcommand()
        command.app = "Example"
        command.wait = .milliseconds(0)
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        )
        try await command.run(using: runtime)

        #expect(applicationService.quitCalls == [.init(identifier: "PID:123", force: false)])
        let relaunchRequest = try #require(applicationService.relaunchRequests.first)
        #expect(relaunchRequest.targetIdentifier == "PID:123")
        #expect(relaunchRequest.expectedTargetIdentity == ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 1001
        ))
        #expect(relaunchRequest.waitSeconds == 0)
        let request = try #require(applicationService.launchRequests.first)
        #expect(request.applicationIdentifier == nil)
        #expect(request.applicationBundleIdentifier == "com.example.app")
        #expect(!request.activates)
    }

    @Test
    func `Relaunch activates only with foreground`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.app",
            name: "Example"
        )
        let applicationService = RecordingApplicationService(
            applications: [application],
            launchResponse: application
        )
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Example"
        command.wait = .milliseconds(0)
        command.foreground = true

        try await command.run(using: CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        ))

        #expect(applicationService.launchRequests.first?.activates == true)
    }

    @Test
    func `Relaunch rejects an unsafe host before lifecycle calls`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            bundleIdentifier: "boo.peekaboo.mac",
            name: "Peekaboo"
        )
        let applicationService = RecordingApplicationService(applications: [application])
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Peekaboo"
        command.wait = .milliseconds(0)
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService),
            applicationRelaunchAllowed: false
        )

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }
        #expect(applicationService.findCalls.isEmpty)
        #expect(applicationService.quitCalls.isEmpty)
        #expect(applicationService.launchRequests.isEmpty)
    }

    @Test
    func `Relaunch rejects the selected daemon before quitting it`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 321,
            bundleIdentifier: "boo.peekaboo.peekaboo",
            name: "Peekaboo daemon"
        )
        let applicationService = RecordingApplicationService(applications: [application])
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Peekaboo daemon"
        command.wait = .milliseconds(0)
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService),
            selectedRemoteHostProcessIdentifier: 321
        )

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }
        #expect(applicationService.findCalls == ["Peekaboo daemon"])
        #expect(applicationService.quitCalls.isEmpty)
        #expect(applicationService.launchRequests.isEmpty)
    }

    private func makeLaunchService(name: String, bundleIdentifier: String) -> RecordingApplicationService {
        let app = ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: bundleIdentifier,
            name: name,
            isFinishedLaunching: true
        )
        return RecordingApplicationService(applications: [app], launchResponse: app)
    }

    private func makeRuntime(applicationService: RecordingApplicationService) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        )
    }
}

@MainActor
private final class ServicesWithApplicationStub: PeekabooServiceProviding {
    private let base = PeekabooServices(snapshotManager: InMemorySnapshotManager())
    private let stubApplications: any ApplicationServiceProtocol
    private let stubAutomation: any UIAutomationServiceProtocol
    private let stubScreenCapture: any ScreenCaptureServiceProtocol
    private let stubSnapshots: any SnapshotManagerProtocol

    init(
        applications: any ApplicationServiceProtocol,
        automation: (any UIAutomationServiceProtocol)? = nil,
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        snapshots: (any SnapshotManagerProtocol)? = nil
    ) {
        self.stubApplications = applications
        self.stubAutomation = automation ?? self.base.automation
        self.stubScreenCapture = screenCapture ?? self.base.screenCapture
        self.stubSnapshots = snapshots ?? self.base.snapshots
    }

    func ensureVisualizerConnection() {
        self.base.ensureVisualizerConnection()
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.stubScreenCapture
    }

    var applications: any ApplicationServiceProtocol {
        self.stubApplications
    }

    var automation: any UIAutomationServiceProtocol {
        self.stubAutomation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.stubSnapshots
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

@MainActor
private struct SnapshotInvalidationFixture {
    let selected: InMemorySnapshotManager
    let discovered: InMemorySnapshotManager
    let discoveredSocketPath: String
    let host: PeekabooBridgeHost

    static func start() async throws -> Self {
        let selected = InMemorySnapshotManager()
        let discovered = InMemorySnapshotManager()
        _ = try await selected.createSnapshot()
        _ = try await discovered.createSnapshot()

        let discoveredSocketPath = "/tmp/peekaboo-open-snapshots-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: PeekabooServices(snapshotManager: discovered),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true
                )
            }
        )
        let host = PeekabooBridgeHost(
            socketPath: discoveredSocketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2
        )
        try await host.startChecked()

        return Self(
            selected: selected,
            discovered: discovered,
            discoveredSocketPath: discoveredSocketPath,
            host: host
        )
    }
}

private final class RecordingHotkeyAutomationService: MockAutomationService {
    struct HotkeyCall {
        let keys: String
        let holdDuration: Int
    }

    private(set) var hotkeyCalls: [HotkeyCall] = []

    override func hotkey(keys: String, holdDuration: Int) async throws {
        self.hotkeyCalls.append(.init(keys: keys, holdDuration: holdDuration))
    }
}

@MainActor
private final class RecordingApplicationService: ApplicationServiceProtocol {
    let supportsApplicationLaunchOptions = true
    let supportsApplicationRelaunch = true

    private let applications: [ServiceApplicationInfo]
    private let launchResponse: ServiceApplicationInfo?
    private var runningPIDs: Set<Int32>
    private(set) var activateCalls: [String] = []
    private(set) var launchRequests: [ApplicationLaunchRequest] = []
    private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
    private(set) var quitCalls: [QuitCall] = []
    private(set) var quitRequests: [ApplicationQuitRequest] = []
    private(set) var findCalls: [String] = []
    private(set) var listCallCount = 0

    init(applications: [ServiceApplicationInfo], launchResponse: ServiceApplicationInfo? = nil) {
        self.applications = applications
        self.launchResponse = launchResponse
        self.runningPIDs = Set(applications.map(\.processIdentifier))
    }

    struct QuitCall: Equatable {
        let identifier: String
        let force: Bool
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        self.listCallCount += 1
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.applications),
            summary: .init(brief: "Stub application list", status: .success),
            metadata: .init(duration: 0)
        )
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.findCalls.append(identifier)
        if let pid = Self.parsePID(identifier),
           let match = applications
               .first(where: { $0.processIdentifier == pid && self.runningPIDs.contains(pid) }) {
            return match
        }
        if let match = applications.first(where: {
            self.runningPIDs.contains($0.processIdentifier) &&
                ($0.name == identifier || $0.bundleIdentifier == identifier)
        }) {
            return match
        }
        throw PeekabooError.appNotFound(identifier)
    }

    func activateApplication(identifier: String) async throws {
        self.activateCalls.append(identifier)
    }

    func listWindows(
        for _: String,
        timeout _: Float?
    ) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: [], targetApplication: nil),
            summary: .init(brief: "Stub window list", status: .success),
            metadata: .init(duration: 0)
        )
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        guard let first = applications.first else {
            throw PeekabooError.appNotFound("frontmost")
        }
        return first
    }

    func isApplicationRunning(identifier: String) async -> Bool {
        await (try? self.findApplication(identifier: identifier)) != nil
    }

    func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        try await self.launchApplication(request: ApplicationLaunchRequest(applicationIdentifier: identifier))
    }

    func launchApplication(request: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        self.launchRequests.append(request)
        if let launchResponse {
            self.runningPIDs.insert(launchResponse.processIdentifier)
            return launchResponse
        }
        guard let identifier = request.applicationIdentifier else {
            throw PeekabooError.appNotFound("default handler")
        }
        return try await self.findApplication(identifier: identifier)
    }

    func relaunchApplication(request: ApplicationRelaunchRequest) async throws -> ServiceApplicationInfo {
        self.relaunchRequests.append(request)
        guard request.expectedTargetIdentity != nil else {
            throw PeekabooError.commandFailed("Relaunch request did not include a process-generation identity")
        }
        guard try await self.quitApplication(request: ApplicationQuitRequest(
            identifier: request.targetIdentifier,
            force: request.force,
            expectedIdentity: request.expectedTargetIdentity
        ))
        else {
            throw PeekabooError.commandFailed("Application refused to quit")
        }
        return try await self.launchApplication(request: request.launchRequest)
    }

    func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        self.quitCalls.append(.init(identifier: identifier, force: force))
        let app = try await findApplication(identifier: identifier)
        self.runningPIDs.remove(app.processIdentifier)
        return true
    }

    func quitApplication(request: ApplicationQuitRequest) async throws -> Bool {
        self.quitRequests.append(request)
        guard let expectedIdentity = request.expectedIdentity else {
            throw PeekabooError.commandFailed("Quit request did not include a process-generation identity")
        }
        let app = try await self.findApplication(identifier: request.identifier)
        guard app.processIdentity == expectedIdentity else {
            throw PeekabooError.commandFailed("Quit request process generation did not match the selected application")
        }
        return try await self.quitApplication(identifier: request.identifier, force: request.force)
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}

    private static func parsePID(_ identifier: String) -> Int32? {
        guard identifier.uppercased().hasPrefix("PID:") else { return nil }
        return Int32(identifier.dropFirst(4))
    }
}

@MainActor
private final class DeniedScreenCaptureService: ScreenCaptureServiceProtocol {
    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference
    ) async throws -> CaptureResult {
        throw CaptureError.screenRecordingPermissionDenied
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference
    ) async throws -> CaptureResult {
        throw CaptureError.screenRecordingPermissionDenied
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference
    ) async throws -> CaptureResult {
        throw CaptureError.screenRecordingPermissionDenied
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference
    ) async throws -> CaptureResult {
        throw CaptureError.screenRecordingPermissionDenied
    }

    func hasScreenRecordingPermission() async -> Bool {
        false
    }
}
