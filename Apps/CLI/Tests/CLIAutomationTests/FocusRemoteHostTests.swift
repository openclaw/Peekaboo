import Commander
import CoreGraphics
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct FocusRemoteHostTests {
    @Test
    func `remote focus executes only on selected host and retains target`() async throws {
        let expectedIdentity = try #require(Self.window.mutationIdentity)
        let applications = StubApplicationService(applications: [Self.application])
        let windows = RemoteFocusWindowService(windowsByApp: ["Safari": [Self.window]])
        let services = RemoteFocusTestServices(base: TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        ))

        let result = try await ensureFocused(
            windowID: CGWindowID(Self.window.windowID),
            applicationName: "Safari",
            options: Self.options,
            services: services
        )

        #expect(windows.pinnedFocusCalls.map(\.target.description) == ["windowId(77)"])
        #expect(windows.pinnedFocusCalls.first?.identity.hasSameStableReceipt(
            as: expectedIdentity
        ) == true)
        #expect(windows.unpinnedFocusCallCount == 0)
        #expect(windows.listTargets.map(\.description) == ["windowId(77)"])
        #expect(applications.activateCalls.isEmpty)
        #expect(result.outcome?.delivery?.mechanism == .composite)
        #expect(result.targetIdentity?.exactWindow?.identity.windowID == 77)
    }

    @Test
    func `remote direct ID reuse rejects original receipt without reacquiring`() async throws {
        let expectedIdentity = try #require(Self.window.mutationIdentity)
        let applications = StubApplicationService(applications: [Self.application])
        let windows = RemoteFocusWindowService(windowsByApp: ["Safari": [Self.window]])
        windows.rejectPinnedFocusAsReused = true
        let services = RemoteFocusTestServices(base: TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        ))

        await #expect(throws: PeekabooError.self) {
            try await ensureFocused(
                windowID: CGWindowID(Self.window.windowID),
                applicationName: "Safari",
                options: Self.options,
                services: services
            )
        }
        #expect(windows.pinnedFocusCalls.map(\.target.description) == ["windowId(77)"])
        #expect(windows.pinnedFocusCalls.first?.identity.hasSameStableReceipt(as: expectedIdentity) == true)
        #expect(windows.unpinnedFocusCallCount == 0)
        #expect(windows.listTargets.map(\.description) == ["windowId(77)"])
        #expect(applications.activateCalls.isEmpty)
    }

    @Test
    func `remote broad selection forwards selected exact receipt`() async throws {
        let expectedIdentity = try #require(Self.window.mutationIdentity)
        let windows = RemoteFocusWindowService(windowsByApp: ["Safari": [Self.window]])
        let services = RemoteFocusTestServices(base: TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [Self.application]),
            windows: windows
        ))

        let result = try await ensureFocused(
            applicationName: "Safari",
            options: Self.options,
            services: services
        )

        #expect(windows.listTargets.map(\.description) == ["application(Safari)"])
        #expect(windows.pinnedFocusCalls.map(\.target.description) == ["windowId(77)"])
        #expect(windows.pinnedFocusCalls.first?.identity.hasSameStableReceipt(
            as: expectedIdentity
        ) == true)
        #expect(windows.unpinnedFocusCallCount == 0)
        #expect(result.targetIdentity?.exactWindow?.identity.hasSameStableReceipt(
            as: expectedIdentity
        ) == true)
    }

    @Test
    func `window focus command refuses app and window ID owned by different processes`() async throws {
        let otherWindow = Self.window(
            id: 88,
            title: "Other",
            processIdentifier: 84,
            processGeneration: 7001
        )
        let applications = StubApplicationService(applications: [
            Self.application,
            ServiceApplicationInfo(
                processIdentifier: 84,
                processStartIdentity: 7001,
                bundleIdentifier: "com.example.Other",
                name: "Other"
            ),
        ])
        let windows = RemoteFocusWindowService(windowsByApp: [
            "Safari": [Self.window],
            "Other": [otherWindow],
        ])
        let services = RemoteFocusTestServices(base: TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        ))
        var command = WindowCommand.FocusSubcommand()
        command.windowOptions.app = "Safari"
        command.windowOptions.windowId = otherWindow.windowID

        do {
            try await command.run(using: Self.runtime(services: services))
            Issue.record("Expected mismatched app/window ownership to be refused")
        } catch let exitCode as ExitCode {
            #expect(exitCode == .failure)
        }

        #expect(windows.listTargets.map(\.description) == ["application(Safari)"])
        #expect(windows.pinnedFocusCalls.isEmpty)
        #expect(windows.unpinnedFocusCallCount == 0)
        #expect(applications.activateCalls.isEmpty)
    }

    @Test
    func `window focus command retains prepared receipt and detects reused ID on readback`() async throws {
        let expectedIdentity = try #require(Self.window.mutationIdentity)
        let replacement = Self.window(
            id: Self.window.windowID,
            title: "Replacement",
            processIdentifier: 42,
            processGeneration: 9002
        )
        let applications = StubApplicationService(applications: [Self.application])
        let windows = RemoteFocusWindowService(windowsByApp: ["Safari": [Self.window]])
        windows.listHandler = { target in
            switch target {
            case .application:
                [Self.window]
            case .windowId:
                [replacement]
            default:
                []
            }
        }
        let services = RemoteFocusTestServices(base: TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows
        ))
        var command = WindowCommand.FocusSubcommand()
        command.windowOptions.app = "Safari"
        command.windowOptions.windowId = Self.window.windowID

        do {
            try await command.run(using: Self.runtime(services: services))
            Issue.record("Expected reused post-focus window ID to fail exact readback")
        } catch let exitCode as ExitCode {
            #expect(exitCode == .failure)
        }

        #expect(windows.listTargets.map(\.description) == [
            "application(Safari)",
            "windowId(77)",
        ])
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(windows.pinnedFocusCalls.first?.identity.hasSameStableReceipt(as: expectedIdentity) == true)
        #expect(windows.unpinnedFocusCallCount == 0)
    }

    @Test
    func `window focus command rejects every non-success canonical outcome`() async throws {
        let outcomes: [DesktopActionOutcome] = [
            .refused(route: .bridge, reason: .targetUnavailable),
            .partial(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ),
            .suspectedNoop(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            ),
            .indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one
            ),
        ]

        for outcome in outcomes {
            let applications = StubApplicationService(applications: [Self.application])
            let windows = RemoteFocusWindowService(windowsByApp: ["Safari": [Self.window]])
            windows.focusOutcome = outcome
            let services = RemoteFocusTestServices(base: TestServicesFactory.makePeekabooServices(
                applications: applications,
                windows: windows
            ))

            var command = WindowCommand.FocusSubcommand()
            command.windowOptions.windowId = 77
            let runtime = CommandRuntime(
                configuration: .init(
                    verbose: false,
                    jsonOutput: true,
                    logLevel: nil,
                    captureEnginePreference: nil,
                    inputStrategy: nil
                ),
                services: services
            )

            do {
                try await command.run(using: runtime)
                Issue.record("Expected window focus to reject \(outcome.state.rawValue)")
            } catch let exitCode as ExitCode {
                #expect(exitCode == .failure)
            }
            #expect(windows.pinnedFocusCalls.map(\.target.description) == ["windowId(77)"])
            #expect(windows.unpinnedFocusCallCount == 0)
            #expect(applications.activateCalls.isEmpty)
        }
    }

    private static let application = ServiceApplicationInfo(
        processIdentifier: 42,
        processStartIdentity: 9001,
        bundleIdentifier: "com.apple.Safari",
        name: "Safari"
    )
    private static let window = ServiceWindowInfo(
        windowID: 77,
        title: "Fixture",
        bounds: CGRect(x: 10, y: 20, width: 300, height: 200),
        mutationIdentity: .init(
            windowID: 77,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
    )
    private static let options = FocusOptions(
        autoFocus: true,
        focusTimeout: nil,
        focusRetryCount: nil,
        spaceSwitch: false,
        bringToCurrentSpace: false
    )

    private static func window(
        id: Int,
        title: String,
        processIdentifier: Int32,
        processGeneration: UInt64
    ) -> ServiceWindowInfo {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            mutationIdentity: .init(
                windowID: id,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: processGeneration,
                capturedBounds: bounds
            )
        )
    }

    private static func runtime(services: any PeekabooServiceProviding) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: true,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services
        )
    }
}

@MainActor
private final class RemoteFocusWindowService: StubWindowService, WindowManagementPinnedFocusActionResultProviding {
    struct PinnedFocusCall {
        let target: WindowTarget
        let identity: WindowMutationIdentity
    }

    var focusFailure: (any Error)?
    var rejectPinnedFocusAsReused = false
    private(set) var unpinnedFocusCallCount = 0
    private(set) var pinnedFocusCalls: [PinnedFocusCall] = []
    private(set) var listTargets: [WindowTarget] = []
    var listHandler: ((WindowTarget) -> [ServiceWindowInfo])?
    var focusOutcome: DesktopActionOutcome = .dispatchedUnverified(
        route: .bridge,
        delivery: .init(mechanism: .composite, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: DesktopActionOutcome.DispatchUnitCount(3)
    )

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        self.unpinnedFocusCallCount += 1
        throw PeekabooError.commandFailed("Focus test requires a pinned provider call")
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.pinnedFocusCalls.append(.init(target: target, identity: expectedIdentity))
        if self.rejectPinnedFocusAsReused {
            throw PeekabooError.windowNotFound(criteria: "windowId \(expectedIdentity.windowID) was reused")
        }
        if let focusFailure {
            throw focusFailure
        }
        guard case let .windowId(windowID) = target,
              windowID == expectedIdentity.windowID,
              let bounds = expectedIdentity.capturedBounds
        else {
            throw PeekabooError.windowNotFound(criteria: target.description)
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.focusOutcome,
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(identity: expectedIdentity, bounds: bounds)
            )
        )
    }

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listTargets.append(target)
        if let listHandler {
            return listHandler(target)
        }
        return try await super.listWindows(target: target)
    }
}

@MainActor
private final class RemoteFocusTestServices: PeekabooServiceProviding {
    let executionHost: PeekabooServiceExecutionHost = .remote
    private let base: PeekabooServices

    init(base: PeekabooServices) {
        self.base = base
    }

    var logging: any LoggingServiceProtocol {
        self.base.logging
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
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
        self.base.dock
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

    var configuration: PeekabooAutomation.ConfigurationManager {
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

    func ensureVisualizerConnection() {}
}
