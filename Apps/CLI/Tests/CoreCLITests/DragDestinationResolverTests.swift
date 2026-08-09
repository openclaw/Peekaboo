import CoreGraphics
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.unit))
struct DragDestinationResolverTests {
    @Test
    @MainActor
    func `Trash destination resolves through Dock service`() async throws {
        let dock = DestinationDockService(items: [
            DockItem(
                index: 0,
                title: "Trash",
                itemType: .trash,
                position: CGPoint(x: 100, y: 200),
                size: CGSize(width: 40, height: 60)
            ),
        ])
        let services = ServicesWithDestinationStubs(dock: dock)

        let point = try await DragDestinationResolver(services: services)
            .destinationPoint(forApplicationNamed: "Trash")

        #expect(point == CGPoint(x: 120, y: 230))
    }

    @Test
    @MainActor
    func `App destination falls back to window management service`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 101,
            bundleIdentifier: "com.apple.finder",
            name: "Finder",
            windowCount: 1
        )
        let window = ServiceWindowInfo(
            windowID: 7,
            title: "Finder",
            bounds: CGRect(x: 20, y: 40, width: 300, height: 200),
            isMainWindow: true
        )
        let services = ServicesWithDestinationStubs(
            applications: DestinationApplicationService(applications: [app], windowsByApp: [:]),
            windows: DestinationWindowService(windowsByApp: ["Finder": [window]])
        )

        let point = try await DragDestinationResolver(services: services)
            .destinationPoint(forApplicationNamed: "Finder")

        #expect(point == CGPoint(x: 170, y: 140))
    }
}

@MainActor
private final class ServicesWithDestinationStubs: PeekabooServiceProviding {
    private let base = PeekabooServices()
    private let stubApplications: any ApplicationServiceProtocol
    private let stubWindows: any WindowManagementServiceProtocol
    private let stubDock: any DockServiceProtocol

    init(
        applications: any ApplicationServiceProtocol = DestinationApplicationService(applications: []),
        windows: any WindowManagementServiceProtocol = DestinationWindowService(windowsByApp: [:]),
        dock: any DockServiceProtocol = DestinationDockService(items: [])
    ) {
        self.stubApplications = applications
        self.stubWindows = windows
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
        self.stubApplications
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.stubWindows
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

@MainActor
private final class DestinationApplicationService: ApplicationServiceProtocol {
    private let applications: [ServiceApplicationInfo]
    private let windowsByApp: [String: [ServiceWindowInfo]]

    init(applications: [ServiceApplicationInfo], windowsByApp: [String: [ServiceWindowInfo]] = [:]) {
        self.applications = applications
        self.windowsByApp = windowsByApp
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.applications),
            summary: .init(brief: "Stub application list", status: .success),
            metadata: .init(duration: 0)
        )
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        if let match = self.applications.first(where: { $0.name == identifier || $0.bundleIdentifier == identifier }) {
            return match
        }
        throw PeekabooError.appNotFound(identifier)
    }

    func listWindows(
        for appIdentifier: String,
        timeout _: Float?
    ) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        let targetApp = self.applications.first { $0.name == appIdentifier || $0.bundleIdentifier == appIdentifier }
        let windows = self.windowsByApp[appIdentifier] ?? targetApp.flatMap { self.windowsByApp[$0.name] } ?? []
        return UnifiedToolOutput(
            data: ServiceWindowListData(windows: windows, targetApplication: targetApp),
            summary: .init(brief: "Stub window list", status: .success),
            metadata: .init(duration: 0)
        )
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        guard let app = self.applications.first else {
            throw PeekabooError.appNotFound("frontmost")
        }
        return app
    }

    func isApplicationRunning(identifier: String) async -> Bool {
        self.applications.contains { $0.name == identifier || $0.bundleIdentifier == identifier }
    }

    func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        try await self.findApplication(identifier: identifier)
    }

    func activateApplication(identifier _: String) async throws {}
    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
}

private final class DestinationWindowService: WindowManagementServiceProtocol {
    private let windowsByApp: [String: [ServiceWindowInfo]]

    init(windowsByApp: [String: [ServiceWindowInfo]]) {
        self.windowsByApp = windowsByApp
    }

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        guard case let .application(appName) = target else {
            return []
        }
        return self.windowsByApp[appName] ?? []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
}

@MainActor
private final class DestinationDockService: DockServiceProtocol {
    private let items: [DockItem]

    init(items: [DockItem]) {
        self.items = items
    }

    func findDockItem(name: String) async throws -> DockItem {
        guard let item = self.items.first(where: { $0.title == name }) else {
            throw PeekabooError.elementNotFound(name)
        }
        return item
    }

    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        self.items
    }

    func launchFromDock(appName _: String) async throws {}
    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}
    func rightClickDockItem(appName _: String, menuItem _: String?) async throws {}
    func hideDock() async throws {}
    func showDock() async throws {}
    func isDockAutoHidden() async -> Bool {
        false
    }
}
