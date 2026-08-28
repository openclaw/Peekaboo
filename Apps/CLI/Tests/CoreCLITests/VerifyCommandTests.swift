import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct VerifyCommandTests {
    @Test
    func `window predicate parses with defaults`() throws {
        let command = try VerifyCommand.parse(["--app", "Finder", "--window-exists"])
        #expect(command.target.app == "Finder")
        #expect(command.windowExists)
        #expect(command.timeout.roundedMilliseconds == 5000)
        #expect(command.stableSamples == 2)
    }

    @Test
    func `element predicates and timing parse`() throws {
        let command = try VerifyCommand.parse([
            "--pid", "123", "--on", "button:Save", "--exists", "--value-equals", "Ready",
            "--enabled", "--selected", "--timeout", "9000", "--stable-samples", "3",
        ])
        #expect(command.target.pid == 123)
        #expect(command.on == "button:Save")
        #expect(command.exists && command.enabled && command.selected)
        #expect(command.valueEquals == "Ready")
        #expect(command.timeout.roundedMilliseconds == 9000)
        #expect(command.stableSamples == 3)
        #expect(try VerifyCommand.elementSelector("button:Save") == ["role": "button", "label": "Save"])
        #expect(try VerifyCommand.elementSelector("B7") == ["identifier": "B7"])
    }

    @Test
    func `window bounds accepts optional tolerance`() throws {
        let predicate = try VerifyCommand.boundsPredicate("10,20,800,600,2.5")
        #expect(predicate["kind"] as? String == "window_bounds")
        #expect(predicate["tolerance"] as? Double == 2.5)
        let bounds = try #require(predicate["bounds"] as? [String: Double])
        #expect(bounds["width"] == 800)
        #expect(bounds["height"] == 600)
    }

    @Test
    func `verify is registered under vision`() {
        var category: CommandRegistryEntry.Category?
        for entry in CommandRegistry.entries where entry.type.commandDescription.commandName == "verify" {
            category = entry.category
        }
        #expect(category == .vision)
    }

    @Test(arguments: [false, true])
    func `tool failure exits with unknown error status`(jsonOutput: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("verify-preflight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var command = try VerifyCommand.parse([
            "--app", "Fixture", "--window-exists", "--screenshot", directory.appendingPathComponent("unused.png").path,
        ])
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: jsonOutput, logLevel: nil),
            services: VerifyPreflightServices(directory: directory),
            toolCapturePreflightRefusal: MCPToolCapturePreflightRefusal(message: "fixture capture refusal"),
            interactionMutationTracker: InteractionMutationTracker(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: directory)
            )
        )

        let exitCode = await #expect(throws: ExitCode.self) {
            try await command.run(using: runtime)
        }
        #expect(exitCode == ExitCode(2))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("unused.png").path))
    }
}

@MainActor
private final class VerifyPreflightServices: PeekabooServiceProviding {
    let automation: any UIAutomationServiceProtocol = MockAutomationService()
    let windows: any WindowManagementServiceProtocol = MockWindowService(result: [])
    let menu: any MenuServiceProtocol = MockMenuService(barItems: [])
    let dock: any DockServiceProtocol = MockDockService(items: [])
    let snapshots: any SnapshotManagerProtocol = InMemorySnapshotManager()
    let permissions = PermissionsService()
    let screens: any ScreenServiceProtocol = ScreenService()
    let clipboard: any ClipboardServiceProtocol = ClipboardService()
    let agent: (any AgentServiceProtocol)? = nil
    let screenCapture: any ScreenCaptureServiceProtocol
    let applications: any ApplicationServiceProtocol
    let dialogs: any DialogServiceProtocol
    let browser: any BrowserMCPClientProviding

    init(directory: URL) {
        // These adapters are inert until called; preflight must refuse before any Bridge request.
        let client = PeekabooBridgeClient(socketPath: directory.appendingPathComponent("absent.sock").path)
        self.screenCapture = RemoteScreenCaptureService(client: client)
        self.applications = RemoteApplicationService(client: client)
        self.dialogs = RemoteDialogService(client: client)
        self.browser = RemoteBrowserMCPClient(client: client)
    }

    var configuration: PeekabooCore.ConfigurationManager {
        fatalError("Verification preflight must not load shared configuration")
    }

    var audioInput: AudioInputService {
        fatalError("Verification preflight must not initialize AI providers")
    }

    var logging: any LoggingServiceProtocol {
        fatalError("Verification preflight uses only the CLI logger")
    }

    var files: any FileServiceProtocol {
        fatalError("Verification preflight must not access files")
    }

    func ensureVisualizerConnection() {}
}
