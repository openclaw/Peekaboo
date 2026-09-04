import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized, .tags(.safe))
struct DialogDiscoveryCommandTests {
    @Test func `targetless foreground click and dismiss still refuse`() {
        #expect(throws: (any Error).self) {
            _ = try DialogCommand.ClickSubcommand.parse(["--button", "Don't Allow", "--foreground"])
        }
        #expect(throws: (any Error).self) {
            _ = try DialogCommand.DismissSubcommand.parse([])
        }
    }

    @Test func `targetless list emits discovered system alert owner`() async throws {
        let dialogs = try StubDiscoveredDialogService()
        let services = DiscoveryCommandServices(dialogs: dialogs)
        var command = try DialogCommand.ListSubcommand.parse([])
        let output = try await self.capture {
            try await command.run(using: self.runtime(services))
        }
        let envelope = try #require(JSONSerialization.jsonObject(with: output) as? [String: Any])
        let data = try #require(envelope["data"] as? [String: Any])
        let owner = try #require(data["owner"] as? [String: Any])
        #expect(owner["bundleIdentifier"] as? String == "com.apple.UserNotificationCenter")
        #expect(owner["processIdentifier"] as? Int == 42)
        #expect((data["title"] as? String)?.isEmpty == true)
        #expect(data["displayTitle"] as? String == "Untitled Dialog")
        #expect(dialogs.listCalls == 1)
        #expect(dialogs.preparedRequests.isEmpty)
    }

    @Test func `targetless click dont allow prepares discovered receipt`() async throws {
        let dialogs = try StubDiscoveredDialogService()
        let services = DiscoveryCommandServices(dialogs: dialogs)
        var command = try DialogCommand.ClickSubcommand.parse(["--button", "Don't Allow"])
        _ = try await self.capture { try await command.run(using: self.runtime(services)) }
        #expect(dialogs.preparedRequests.count == 1)
        #expect(dialogs.preparedRequests.first?.target.hasTarget == false)
        #expect(dialogs.preparedRequests.first?.buttonText == "Don't Allow")
        #expect(dialogs.executedReceipts == [dialogs.receipt])
    }

    @Test func `remote without discovery capability refuses before transport`() async throws {
        let service = RemoteDialogService(
            client: PeekabooBridgeClient(socketPath: "/nonexistent/item5-dialog.sock"),
            capabilities: .init(
                prepareAction: true,
                exactClick: true
            )
        )
        let request = try DialogActionPreparationRequest(
            target: DialogTargetSelector(),
            kind: .clickButton,
            buttonText: "Don't Allow"
        )
        do {
            _ = try await service.prepareDialogAction(request)
            Issue.record("Expected capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.message.contains("system-alert discovery"))
        }
    }

    private func runtime(_ services: DiscoveryCommandServices) -> CommandRuntime {
        CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: true,
                logLevel: nil
            ),
            services: services,
            interactionMutationTracker: InteractionMutationTracker(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: services.directory)
            )
        )
    }

    private func capture(_ operation: () async throws -> Void) async throws -> Data {
        let pipe = Pipe()
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        guard original >= 0, dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(original) }
        do {
            try await operation()
        } catch {
            fflush(stdout)
            _ = dup2(original, STDOUT_FILENO)
            throw error
        }
        fflush(stdout)
        _ = dup2(original, STDOUT_FILENO)
        try pipe.fileHandleForWriting.close()
        return try pipe.fileHandleForReading.readToEnd() ?? Data()
    }
}

@MainActor
private final class StubDiscoveredDialogService: DialogServiceProtocol {
    let supportsSystemAlertDiscovery = true
    let receipt: PreparedDialogActionReceipt
    let elements: DialogElements
    var listCalls = 0
    var preparedRequests: [DialogActionPreparationRequest] = []
    var executedReceipts: [PreparedDialogActionReceipt] = []

    init() throws {
        let bounds = CGRect(
            x: 10,
            y: 20,
            width: 300,
            height: 200
        )
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 9001,
            capturedBounds: bounds
        )
        let target = try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds
        )
        let owner = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 9001,
            bundleIdentifier: "com.apple.UserNotificationCenter",
            name: "UserNotificationCenter"
        )
        let resolved = try ResolvedDialogTargetEvidence(
            target: target,
            application: owner,
            window: .init(
                windowID: 700,
                title: "",
                bounds: bounds,
                index: 0,
                mutationIdentity: identity
            )
        )
        let info = DialogInfo(
            title: "",
            role: "AXWindow",
            subrole: "AXSystemDialog",
            isFileDialog: false,
            bounds: bounds
        )
        let buttons = [DialogButton(
            title: "Don’t Allow",
            supportsAXPress: true
        )]
        let child = DialogElements(
            dialogInfo: info,
            buttons: buttons,
            resolvedTarget: resolved
        )
        self.elements = DialogElements(
            dialogInfo: info,
            buttons: buttons,
            resolvedTarget: resolved,
            discovery: .init(
                dialogs: [.init(
                    owner: owner,
                    elements: child,
                    source: "system_alert_host"
                )],
                isComplete: true
            )
        )
        self.receipt = PreparedDialogActionReceipt(
            token: UUID(),
            kind: .clickButton,
            target: target,
            resolvedTarget: resolved,
            discoveryProof: .init(
                scannedOwners: [identity.processIdentity],
                isComplete: true,
                dialogCount: 1,
                enabledPressButtonCount: 1,
                buttonTitle: "Don’t Allow"
            )
        )
    }

    func listDialogElements(
        windowTitle: String?,
        appName: String?
    ) async throws -> DialogElements {
        #expect(windowTitle == nil && appName == nil)
        self.listCalls += 1
        return self.elements
    }

    func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws -> PreparedDialogActionReceipt {
        self.preparedRequests.append(request)
        return self.receipt
    }

    func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws -> DialogActionResult {
        self.executedReceipts.append(receipt)
        return DialogActionResult(
            success: true,
            action: .clickButton,
            details: ["button": "Don’t Allow"],
            outcome: .confirmedChange(
                delivery: .init(
                    mechanism: .accessibilityAction,
                    mode: .background
                ),
                unitCount: .one
            ),
            targetReceipt: nil,
            targetWindowIdentity: receipt.target.identity,
            targetWindowBounds: receipt.target.bounds,
            focusedElement: nil,
            resolvedTarget: receipt.resolvedTarget
        )
    }

    func findActiveDialog(
        windowTitle: String?,
        appName: String?
    ) async throws -> DialogInfo {
        fatalError("unused")
    }

    func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?
    ) async throws -> DialogActionResult {
        fatalError("Legacy click must never be used")
    }

    func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?
    ) async throws
    -> DialogActionResult {
        fatalError("unused")
    }

    func handleFileDialog(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool,
        appName: String?
    ) async throws
    -> DialogActionResult {
        fatalError("unused")
    }

    func dismissDialog(
        force: Bool,
        windowTitle: String?,
        appName: String?
    ) async throws -> DialogActionResult {
        fatalError("unused")
    }
}

@MainActor
private final class DiscoveryCommandServices: PeekabooServiceProviding {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dialog-command-\(UUID())")
    let dialogs: any DialogServiceProtocol
    let snapshots: any SnapshotManagerProtocol = InMemorySnapshotManager()
    let automation: any UIAutomationServiceProtocol = MockAutomationService()
    let windows: any WindowManagementServiceProtocol = MockWindowService(result: [])
    let menu: any MenuServiceProtocol = MockMenuService(barItems: [])
    let dock: any DockServiceProtocol = MockDockService(items: [])
    let permissions = PermissionsService()
    let screens: any ScreenServiceProtocol = ScreenService()
    let clipboard: any ClipboardServiceProtocol = ClipboardService()
    let agent: (any AgentServiceProtocol)? = nil
    let screenCapture: any ScreenCaptureServiceProtocol
    let applications: any ApplicationServiceProtocol
    let browser: any BrowserMCPClientProviding

    init(dialogs: any DialogServiceProtocol) {
        self.dialogs = dialogs
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/item5-dialog.sock")
        self.screenCapture = RemoteScreenCaptureService(client: client)
        self.applications = RemoteApplicationService(client: client)
        self.browser = RemoteBrowserMCPClient(client: client)
    }

    deinit {
        try? FileManager.default.removeItem(at: self.directory)
    }

    var configuration: PeekabooCore.ConfigurationManager {
        fatalError("unused")
    }

    var audioInput: AudioInputService {
        fatalError("unused")
    }

    var logging: any LoggingServiceProtocol {
        fatalError("unused")
    }

    var files: any FileServiceProtocol {
        fatalError("unused")
    }

    func ensureVisualizerConnection() {}
}
