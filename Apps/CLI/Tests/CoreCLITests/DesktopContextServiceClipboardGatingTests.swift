import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooCore
import Testing
import UniformTypeIdentifiers

struct DesktopContextServiceClipboardGatingTests {
    @Test
    @MainActor
    func `Does not read clipboard when clipboard tool disabled`() async {
        let clipboard = RecordingClipboardService(textPreview: "should-not-be-read")
        let services = ServicesWithStubClipboard(clipboard: clipboard)
        let service = DesktopContextService(services: services)

        let context = await service.gatherContext(includeClipboardPreview: false)

        #expect(clipboard.getCallCount == 0)
        #expect(context.clipboardPreview == nil)
    }

    @Test
    @MainActor
    func `Reads clipboard when clipboard tool enabled`() async {
        let clipboard = RecordingClipboardService(textPreview: "hello from clipboard")
        let services = ServicesWithStubClipboard(clipboard: clipboard)
        let service = DesktopContextService(services: services)

        let context = await service.gatherContext(includeClipboardPreview: true)

        #expect(clipboard.getCallCount == 1)
        #expect(context.clipboardPreview == "hello from clipboard")
    }

    @Test
    @MainActor
    func `Gathers focused window and recent apps through services`() async {
        let activeApp = ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: "com.example.editor",
            name: "Editor",
            isActive: true
        )
        let applications = [
            ServiceApplicationInfo(processIdentifier: 11, bundleIdentifier: nil, name: "Zed"),
            activeApp,
            ServiceApplicationInfo(processIdentifier: 12, bundleIdentifier: nil, name: "Alpha"),
        ]
        let focusedWindow = ServiceWindowInfo(
            windowID: 7,
            title: "Design Notes",
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200)
        )
        let services = ServicesWithStubClipboard(
            clipboard: RecordingClipboardService(textPreview: "ignored"),
            applications: DesktopContextApplicationServiceStub(frontmost: activeApp, applications: applications),
            windows: DesktopContextWindowServiceStub(focusedWindow: focusedWindow)
        )
        let service = DesktopContextService(services: services)

        let context = await service.gatherContext(includeClipboardPreview: false)

        #expect(context.focusedWindow?.appName == "Editor")
        #expect(context.focusedWindow?.title == "Design Notes")
        #expect(context.focusedWindow?.bounds == focusedWindow.bounds)
        #expect(context.focusedWindow?.processId == 42)
        #expect(context.recentApps == ["Editor", "Alpha", "Zed"])
    }
}

@MainActor
private final class ServicesWithStubClipboard: PeekabooServiceProviding {
    private let base = PeekabooServices()
    private let stubClipboard: any ClipboardServiceProtocol
    private let stubApplications: any ApplicationServiceProtocol
    private let stubWindows: any WindowManagementServiceProtocol

    init(
        clipboard: any ClipboardServiceProtocol,
        applications: (any ApplicationServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil
    ) {
        self.stubClipboard = clipboard
        self.stubApplications = applications ?? DesktopContextApplicationServiceStub(frontmost: nil, applications: [])
        self.stubWindows = windows ?? DesktopContextWindowServiceStub(focusedWindow: nil)
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
        self.stubClipboard
    }

    var configuration: PeekabooCore.ConfigurationManager {
        self.base.configuration
    }

    var process: any ProcessServiceProtocol {
        self.base.process
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

private enum DesktopContextStubError: Error {
    case notImplemented
}

@MainActor
private final class DesktopContextApplicationServiceStub: ApplicationServiceProtocol {
    private let frontmost: ServiceApplicationInfo?
    private let applications: [ServiceApplicationInfo]

    init(frontmost: ServiceApplicationInfo?, applications: [ServiceApplicationInfo]) {
        self.frontmost = frontmost
        self.applications = applications
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.applications),
            summary: .init(
                brief: "Found \(self.applications.count) apps",
                status: .success,
                counts: ["applications": self.applications.count]
            ),
            metadata: .init(duration: 0)
        )
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        throw DesktopContextStubError.notImplemented
    }

    func listWindows(for appIdentifier: String, timeout: Float?) async throws
    -> UnifiedToolOutput<ServiceWindowListData> {
        throw DesktopContextStubError.notImplemented
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        guard let frontmost = self.frontmost else {
            throw DesktopContextStubError.notImplemented
        }
        return frontmost
    }

    func isApplicationRunning(identifier: String) async -> Bool {
        false
    }

    func launchApplication(identifier: String) async throws -> ServiceApplicationInfo {
        throw DesktopContextStubError.notImplemented
    }

    func activateApplication(identifier: String) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func quitApplication(identifier: String, force: Bool) async throws -> Bool {
        throw DesktopContextStubError.notImplemented
    }

    func hideApplication(identifier: String) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func unhideApplication(identifier: String) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func hideOtherApplications(identifier: String) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func showAllApplications() async throws {
        throw DesktopContextStubError.notImplemented
    }
}

private final class DesktopContextWindowServiceStub: WindowManagementServiceProtocol {
    private let focusedWindow: ServiceWindowInfo?

    init(focusedWindow: ServiceWindowInfo?) {
        self.focusedWindow = focusedWindow
    }

    func closeWindow(target: WindowTarget) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func minimizeWindow(target: WindowTarget) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func maximizeWindow(target: WindowTarget) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func moveWindow(target: WindowTarget, to position: CGPoint) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func resizeWindow(target: WindowTarget, to size: CGSize) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func setWindowBounds(target: WindowTarget, bounds: CGRect) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func focusWindow(target: WindowTarget) async throws {
        throw DesktopContextStubError.notImplemented
    }

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        throw DesktopContextStubError.notImplemented
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.focusedWindow
    }
}

@MainActor
private final class RecordingClipboardService: ClipboardServiceProtocol {
    private(set) var getCallCount = 0
    private let textPreview: String

    init(textPreview: String) {
        self.textPreview = textPreview
    }

    func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        self.getCallCount += 1
        return ClipboardReadResult(
            utiIdentifier: UTType.plainText.identifier,
            data: Data(self.textPreview.utf8),
            textPreview: self.textPreview
        )
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        throw ClipboardServiceError.writeFailed("Not implemented in test stub.")
    }

    func clear() {}

    func save(slot: String) throws {
        throw ClipboardServiceError.writeFailed("Not implemented in test stub.")
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        throw ClipboardServiceError.writeFailed("Not implemented in test stub.")
    }
}
