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
    func `Launch refuses new-instance without foreground before service dispatch`() async throws {
        let service = self.makeLaunchService(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        var command = AppCommand.LaunchSubcommand()
        command.app = "TextEdit"
        command.newInstance = true
        command.waitUntilReady = true
        command.waitForWindow = true

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: service))
        }

        #expect(service.launchRequests.isEmpty)
    }

    @Test
    func `Launch forwards new-instance with foreground consent`() async throws {
        let service = self.makeLaunchService(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit")
        var command = AppCommand.LaunchSubcommand()
        command.app = "TextEdit"
        command.newInstance = true
        command.waitUntilReady = true
        command.waitForWindow = true
        command.foreground = true

        try await command.run(using: self.makeRuntime(applicationService: service))

        let request = try #require(service.launchRequests.first)
        #expect(request.createsNewInstance)
        #expect(request.waitUntilReady)
        #expect(request.waitForWindow)
        #expect(request.activates)
    }

    @Test
    func `Launch refuses open targets without foreground before service dispatch`() async throws {
        let service = self.makeLaunchService(name: "Preview", bundleIdentifier: "com.apple.Preview")

        var command = AppCommand.LaunchSubcommand()
        command.app = "Preview"
        command.noFocus = true
        command.openTargets = ["~/Desktop/file1.pdf", "https://example.com"]
        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: service))
        }

        #expect(service.launchRequests.isEmpty)
    }

    @Test
    func `Launch forwards open targets with foreground consent`() async throws {
        let service = self.makeLaunchService(name: "Preview", bundleIdentifier: "com.apple.Preview")
        var command = AppCommand.LaunchSubcommand()
        command.app = "Preview"
        command.openTargets = ["~/Desktop/file1.pdf", "https://example.com"]
        command.foreground = true

        try await command.run(using: self.makeRuntime(applicationService: service))

        let request = try #require(service.launchRequests.first)
        #expect(request.activates)
        #expect(request.openURLs.count == 2)
        #expect(request.openURLs[0].path.hasSuffix("/Desktop/file1.pdf"))
        #expect(request.openURLs[1].absoluteString == "https://example.com")
    }

    @Test
    func `Background no-op launch preserves selected and discovered snapshots`() async throws {
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
        #expect(await snapshots.selected.getMostRecentSnapshot() != nil)
        #expect(await snapshots.discovered.getMostRecentSnapshot() != nil)
    }

    @Test
    func `Launch rejects mixed positional and bundle identifier selectors`() async throws {
        let service = self.makeLaunchService(name: "Calculator", bundleIdentifier: "com.apple.calculator")
        var command = AppCommand.LaunchSubcommand()
        command.app = "Calculator"
        command.bundleId = "com.apple.calculator"
        command.noFocus = true

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: service))
        }

        #expect(service.launchRequests.isEmpty)
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
            processStartIdentity: 1001,
            bundleIdentifier: "com.apple.finder",
            name: "Finder"
        )
        let applicationService = RecordingApplicationService(applications: [application])

        var command = AppCommand.SwitchSubcommand()
        command.to = "Finder"
        command.foreground = true
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService)
        )
        try await command.run(using: runtime)

        #expect(applicationService.activateCalls == ["PID:42"])
        #expect(applicationService.activationRequests.first?.expectedIdentity?.processIdentifier == 42)
        #expect(applicationService.activationRequests.first?.expectedIdentity?.processStartIdentity == 1001)
    }

    @Test
    func `Switch refuses without foreground consent before application lookup`() async {
        let applicationService = self.makeLaunchService(
            name: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        var command = AppCommand.SwitchSubcommand()
        command.to = "Finder"

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: applicationService))
        }

        #expect(applicationService.findCalls.isEmpty)
        #expect(applicationService.activateCalls.isEmpty)
    }

    @Test
    func `Switch rejects target plus cycle before global input`() async {
        let automation = RecordingHotkeyAutomationService()
        let applicationService = self.makeLaunchService(
            name: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        var command = AppCommand.SwitchSubcommand()
        command.to = "Finder"
        command.cycle = true
        command.foreground = true

        await #expect(throws: ExitCode.self) {
            try await command.run(using: CommandRuntime(
                configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
                services: ServicesWithApplicationStub(
                    applications: applicationService,
                    automation: automation
                )
            ))
        }

        #expect(applicationService.findCalls.isEmpty)
        #expect(applicationService.activateCalls.isEmpty)
        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `Switch rejects verify plus cycle before global input`() async {
        let automation = RecordingHotkeyAutomationService()
        var command = AppCommand.SwitchSubcommand()
        command.cycle = true
        command.verify = true
        command.foreground = true

        await #expect(throws: ExitCode.self) {
            try await command.run(using: CommandRuntime(
                configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
                services: ServicesWithApplicationStub(
                    applications: RecordingApplicationService(applications: []),
                    automation: automation
                )
            ))
        }

        #expect(automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `Focus refuses without foreground consent before application lookup`() async {
        let applicationService = self.makeLaunchService(
            name: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        var command = AppCommand.FocusSubcommand()
        command.app = "Finder"

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: applicationService))
        }

        #expect(applicationService.findCalls.isEmpty)
        #expect(applicationService.activateCalls.isEmpty)
    }

    @Test
    func `Focus dispatches exact activation with foreground consent`() async throws {
        let applicationService = self.makeLaunchService(
            name: "Finder",
            bundleIdentifier: "com.apple.finder"
        )
        var command = AppCommand.FocusSubcommand()
        command.app = "Finder"
        command.foreground = true

        try await command.run(using: self.makeRuntime(applicationService: applicationService))

        #expect(applicationService.findCalls == ["PID:42"])
        #expect(applicationService.activateCalls == ["PID:42"])
    }

    @Test
    func `Unhide without activate consent refuses before service lookup`() async {
        let service = self.makeLaunchService(name: "Finder", bundleIdentifier: "com.apple.finder")
        var command = AppCommand.UnhideSubcommand()
        command.app = "Finder"

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: service))
        }

        #expect(service.findCalls.isEmpty)
        #expect(service.activateCalls.isEmpty)
    }

    @Test
    func `Unhide with activate consent uses exact foreground activation`() async throws {
        let service = self.makeLaunchService(name: "Finder", bundleIdentifier: "com.apple.finder")
        var command = AppCommand.UnhideSubcommand()
        command.app = "Finder"
        command.activate = true

        try await command.run(using: self.makeRuntime(applicationService: service))

        #expect(service.findCalls == ["PID:42"])
        #expect(service.activateCalls == ["PID:42"])
        #expect(service.activationRequests.first?.expectedIdentity?.processIdentifier == 42)
        #expect(service.activationRequests.first?.expectedIdentity?.processStartIdentity == 1001)
    }

    @Test
    func `Switch cycle uses automation hotkey service`() async throws {
        let automation = RecordingHotkeyAutomationService()

        var command = AppCommand.SwitchSubcommand()
        command.cycle = true
        command.foreground = true
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
        #expect(applicationService.findCalls == ["PID:321"])
        #expect(applicationService.quitCalls.isEmpty)
        #expect(applicationService.quitRequests.isEmpty)
    }

    @Test
    func `Quit all targets only applications with known regular metadata`() async throws {
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
        let prohibitedApplication = ServiceApplicationInfo(
            processIdentifier: 789,
            processStartIdentity: 7001,
            bundleIdentifier: "com.example.daemon",
            name: "System Helper",
            activationPolicy: .prohibited
        )
        let incompleteApplication = ServiceApplicationInfo(
            processIdentifier: 900,
            processStartIdentity: 8001,
            bundleIdentifier: nil,
            name: "Incomplete Helper",
            isHiddenKnown: false,
            activationPolicy: nil,
            metadataWarnings: ["metadata unavailable"]
        )
        let applicationService = RecordingApplicationService(applications: [
            accessoryApplication,
            prohibitedApplication,
            incompleteApplication,
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
        command.foreground = true
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
        #expect(request.activates)
    }

    @Test
    func `Relaunch without foreground refuses before service lookup`() async {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.app",
            name: "Example"
        )
        let applicationService = RecordingApplicationService(applications: [application])
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Example"
        command.wait = .milliseconds(0)

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: applicationService))
        }

        #expect(applicationService.findCalls.isEmpty)
        #expect(applicationService.relaunchRequests.isEmpty)
    }

    @Test
    func `Relaunch rejects mixed textual and PID selectors before service lookup`() async {
        let applicationService = self.makeLaunchService(
            name: "Example",
            bundleIdentifier: "com.example.app"
        )
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Example"
        command.pid = 456
        command.foreground = true

        await #expect(throws: ExitCode.self) {
            try await command.run(using: self.makeRuntime(applicationService: applicationService))
        }

        #expect(applicationService.findCalls.isEmpty)
        #expect(applicationService.relaunchRequests.isEmpty)
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
    func `Relaunch prefers the selected exact bundle path over bundle lookup`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 1001,
            bundleIdentifier: "com.example.app",
            name: "Example",
            bundlePath: "/tmp/Exact Example.app"
        )
        let applicationService = RecordingApplicationService(
            applications: [application],
            launchResponse: application
        )
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Example"
        command.wait = .milliseconds(0)
        command.foreground = true

        try await command.run(using: self.makeRuntime(applicationService: applicationService))

        let request = try #require(applicationService.relaunchRequests.first?.launchRequest)
        #expect(request.applicationIdentifier == "/tmp/Exact Example.app")
        #expect(request.applicationBundleIdentifier == nil)
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
        command.foreground = true
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
            processStartIdentity: 3001,
            bundleIdentifier: "boo.peekaboo.peekaboo",
            name: "Peekaboo daemon"
        )
        let applicationService = RecordingApplicationService(applications: [application])
        var command = AppCommand.RelaunchSubcommand()
        command.app = "Peekaboo daemon"
        command.wait = .milliseconds(0)
        command.foreground = true
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: ServicesWithApplicationStub(applications: applicationService),
            selectedRemoteHostProcessIdentifier: 321
        )

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }
        #expect(applicationService.findCalls == ["PID:321"])
        #expect(applicationService.quitCalls.isEmpty)
        #expect(applicationService.launchRequests.isEmpty)
    }

    private func makeLaunchService(name: String, bundleIdentifier: String) -> RecordingApplicationService {
        let app = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 1001,
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
struct MenuCommandTargetConsentTests {
    @Test(arguments: ["path", "item"])
    func `Targetless background click refuses before lookup or dispatch`(_ selectionKind: String) async {
        let fixture = self.makeFixture()
        var command = MenuCommand.ClickSubcommand()
        if selectionKind == "path" {
            command.path = "File > Close"
        } else {
            command.item = "Close"
        }
        let tracker = InteractionMutationTracker()
        let runtime = self.makeRuntime(fixture: fixture, tracker: tracker)

        await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }

        #expect(fixture.applications.frontmostCallCount == 0)
        #expect(fixture.menu.operationCallCount == 0)
        #expect(!tracker.hasPendingDurableMutation)
    }

    @Test
    func `Explicit inactive app preserves generation-pinned background menu dispatch`() async throws {
        let fixture = self.makeFixture()
        var command = MenuCommand.ClickSubcommand()
        command.target.app = "Finder"
        command.item = "Close"

        try await command.run(using: self.makeRuntime(fixture: fixture))

        #expect(fixture.applications.frontmostCallCount == 0)
        let click = try #require(fixture.menu.clickedItems.first)
        #expect(fixture.menu.clickedItems.count == 1)
        #expect(click.app == "Finder")
        #expect(click.item == "Close")
        #expect(fixture.menu.requestedDeliveryModes == [.background])
        #expect(fixture.applications.activateCalls.isEmpty)
    }

    @Test
    func `Explicit foreground preserves intentional frontmost menu dispatch`() async throws {
        let fixture = self.makeFixture()
        var command = MenuCommand.ClickSubcommand()
        command.item = "Close"
        command.foreground = true
        command.focusOptions.noAutoFocus = true

        try await command.run(using: self.makeRuntime(fixture: fixture))

        #expect(fixture.applications.frontmostCallCount == 1)
        let click = try #require(fixture.menu.clickedItems.first)
        #expect(fixture.menu.clickedItems.count == 1)
        #expect(click.app == "Finder")
        #expect(click.item == "Close")
        #expect(fixture.menu.requestedDeliveryModes == [.foreground])
    }

    private func makeFixture() -> MenuConsentFixture {
        let app = ServiceApplicationInfo(
            processIdentifier: 101,
            processStartIdentity: 1,
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            isActive: false
        )
        return MenuConsentFixture(
            applications: RecordingApplicationService(applications: [app]),
            menu: RecordingMenuConsentService(application: app)
        )
    }

    private func makeRuntime(
        fixture: MenuConsentFixture,
        tracker: InteractionMutationTracker = InteractionMutationTracker()
    ) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: false, logLevel: nil),
            services: ServicesWithApplicationStub(
                applications: fixture.applications,
                menu: fixture.menu
            ),
            interactionMutationTracker: tracker
        )
    }
}

@MainActor
private struct MenuConsentFixture {
    let applications: RecordingApplicationService
    let menu: RecordingMenuConsentService
}

@MainActor
private final class ServicesWithApplicationStub: PeekabooServiceProviding {
    private let base = PeekabooServices(snapshotManager: InMemorySnapshotManager())
    private let stubApplications: any ApplicationServiceProtocol
    private let stubAutomation: any UIAutomationServiceProtocol
    private let stubScreenCapture: any ScreenCaptureServiceProtocol
    private let stubSnapshots: any SnapshotManagerProtocol
    private let stubMenu: any MenuServiceProtocol

    init(
        applications: any ApplicationServiceProtocol,
        automation: (any UIAutomationServiceProtocol)? = nil,
        screenCapture: (any ScreenCaptureServiceProtocol)? = nil,
        snapshots: (any SnapshotManagerProtocol)? = nil,
        menu: (any MenuServiceProtocol)? = nil
    ) {
        self.stubApplications = applications
        self.stubAutomation = automation ?? self.base.automation
        self.stubScreenCapture = screenCapture ?? self.base.screenCapture
        self.stubSnapshots = snapshots ?? self.base.snapshots
        self.stubMenu = menu ?? self.base.menu
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
        self.stubMenu
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
private final class RecordingApplicationService: ApplicationServiceActionResultProviding,
ApplicationMutationInventoryProviding {
    let supportsApplicationLaunchOptions = true
    let supportsApplicationRelaunch = true
    let supportsProcessGenerationPinnedApplicationActivation = true

    private let applications: [ServiceApplicationInfo]
    private let launchResponse: ServiceApplicationInfo?
    private var runningPIDs: Set<Int32>
    private(set) var activateCalls: [String] = []
    private(set) var activationRequests: [ApplicationActivationRequest] = []
    private(set) var launchRequests: [ApplicationLaunchRequest] = []
    private(set) var relaunchRequests: [ApplicationRelaunchRequest] = []
    private(set) var quitCalls: [QuitCall] = []
    private(set) var quitRequests: [ApplicationQuitRequest] = []
    private(set) var findCalls: [String] = []
    private(set) var listCallCount = 0
    private(set) var frontmostCallCount = 0

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

    func applicationMutationInventory() async throws
    -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo> {
        .complete(self.applications.filter { self.runningPIDs.contains($0.processIdentifier) })
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

    func activateApplication(request: ApplicationActivationRequest) async throws {
        self.activationRequests.append(request)
        self.activateCalls.append(request.identifier)
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
        self.frontmostCallCount += 1
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

    func launchApplicationActionResult(
        request: ApplicationLaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        let application = try await self.launchApplication(request: request)
        let outcome: DesktopActionOutcome = request.isSafeBackgroundNoOp
            ? .confirmedNoChange()
            : .dispatchedUnverified(
                delivery: Self.applicationDelivery(mode: request.activates ? .foreground : .background),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
        return DesktopActionResult(payload: application, outcome: outcome)
    }

    func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        let application = try await self.relaunchApplication(request: request)
        return DesktopActionResult(
            payload: application,
            outcome: .dispatchedUnverified(
                delivery: Self.applicationDelivery(
                    mode: request.launchRequest.activates ? .foreground : .background
                ),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
        )
    }

    func activateApplicationActionResult(
        request: ApplicationActivationRequest
    ) async throws -> DesktopActionResult<Void> {
        try await self.activateApplication(request: request)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: Self.applicationDelivery(mode: .foreground),
            unitCount: .one
        ))
    }

    func quitApplicationActionResult(
        request: ApplicationQuitRequest
    ) async throws -> DesktopActionResult<Bool> {
        let terminated = try await self.quitApplication(request: request)
        let delivery = Self.applicationDelivery(mode: .background)
        let outcome: DesktopActionOutcome = terminated
            ? .confirmedChange(delivery: delivery, unitCount: .one)
            : .suspectedNoop(delivery: delivery, unitCount: .one)
        return DesktopActionResult(payload: terminated, outcome: outcome)
    }

    func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideApplication(identifier: identifier)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: Self.applicationDelivery(mode: .background),
            unitCount: .one
        ))
    }

    func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.unhideApplication(identifier: identifier)
        return DesktopActionResult(outcome: .confirmedChange(
            delivery: Self.applicationDelivery(mode: .background),
            unitCount: .one
        ))
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}

    private static func parsePID(_ identifier: String) -> Int32? {
        guard identifier.uppercased().hasPrefix("PID:") else { return nil }
        return Int32(identifier.dropFirst(4))
    }

    private static func applicationDelivery(
        mode: DesktopActionOutcome.Delivery.Mode
    ) -> DesktopActionOutcome.Delivery {
        DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: mode)
    }
}

@MainActor
private final class RecordingMenuConsentService: MenuServiceGenerationPinnedActionResultProviding {
    private let application: ServiceApplicationInfo
    private(set) var clickedItems: [(app: String, item: String)] = []
    private(set) var requestedDeliveryModes: [DesktopActionOutcome.Delivery.Mode] = []
    private(set) var operationCallCount = 0

    init(application: ServiceApplicationInfo) {
        self.application = application
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        self.operationCallCount += 1
        return MenuStructure(application: self.application, menus: [])
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        self.operationCallCount += 1
        return MenuStructure(application: self.application, menus: [])
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {
        self.operationCallCount += 1
    }

    func clickMenuItemByName(app: String, itemName: String) async throws {
        self.operationCallCount += 1
        self.clickedItems.append((app, itemName))
    }

    func clickMenuItemActionResult(app: String, itemPath: String) async throws -> UIAutomationActionResult<Void> {
        try await self.clickMenuItem(app: app, itemPath: itemPath)
        return try self.actionResult(mode: .foreground)
    }

    func clickMenuItemByNameActionResult(app: String, itemName: String) async throws
    -> UIAutomationActionResult<Void> {
        try await self.clickMenuItemByName(app: app, itemName: itemName)
        return try self.actionResult(mode: .foreground)
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) throws -> UIAutomationActionResult<Void> {
        self.operationCallCount += 1
        self.clickedItems.append((self.application.name, request.itemPath))
        self.requestedDeliveryModes.append(request.deliveryMode)
        return try self.actionResult(mode: request.deliveryMode)
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) throws
    -> UIAutomationActionResult<Void> {
        self.operationCallCount += 1
        self.clickedItems.append((self.application.name, request.itemName))
        self.requestedDeliveryModes.append(request.deliveryMode)
        return try self.actionResult(mode: request.deliveryMode)
    }

    func clickMenuExtra(title _: String) async throws {
        self.operationCallCount += 1
    }

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try await self.clickMenuExtra(title: title)
        return try self.actionResult(mode: .foreground)
    }

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        self.operationCallCount += 1
        return false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        self.operationCallCount += 1
        return nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        self.operationCallCount += 1
        return []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        self.operationCallCount += 1
        return []
    }

    func clickMenuBarItem(named _: String) async throws -> PeekabooCore.ClickResult {
        self.operationCallCount += 1
        return PeekabooCore.ClickResult(elementDescription: "unused", location: nil)
    }

    func clickMenuBarItemActionResult(named name: String) async throws
    -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        try await UIAutomationActionResult(
            payload: self.clickMenuBarItem(named: name),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: self.processTarget()
        )
    }

    func clickMenuBarItem(at _: Int) async throws -> PeekabooCore.ClickResult {
        self.operationCallCount += 1
        return PeekabooCore.ClickResult(elementDescription: "unused", location: nil)
    }

    func clickMenuBarItemActionResult(at index: Int) async throws
    -> UIAutomationActionResult<PeekabooCore.ClickResult> {
        try await UIAutomationActionResult(
            payload: self.clickMenuBarItem(at: index),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: self.processTarget()
        )
    }

    private func actionResult(mode: DesktopActionOutcome.Delivery.Mode) throws -> UIAutomationActionResult<Void> {
        try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: mode),
                unitCount: .one
            ),
            targetIdentity: self.processTarget()
        )
    }

    private func processTarget() throws -> DesktopTargetIdentity {
        guard let identity = self.application.processIdentity else {
            throw PeekabooError.serviceUnavailable("Missing fixture process identity")
        }
        return try DesktopTargetIdentity(processIdentity: identity)
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
