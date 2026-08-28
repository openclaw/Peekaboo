import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
@MainActor
struct PressFocusProofTests {
    @Test
    func `foreground press stops after retry-unsafe focus proof failure without sending a chord`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("press-focus-proof-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let windows = FailedFocusProofWindows()
        let automation = FocusProofHotkeyRecorder()
        let services = FocusProofPressServices(windows: windows, automation: automation)
        let runtime = CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: services,
            interactionMutationTracker: InteractionMutationTracker(
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(directoryURL: root)
            )
        )
        var command = PressCommand()
        command.chords = ["return", "cmd+s"]
        command.count = 3
        command.target.windowId = 77
        command.focusOptions.foreground = true
        command.focusOptions.focusRetryCount = 5

        await #expect(throws: ExitCode.self) { try await command.run(using: runtime) }

        #expect(windows.focusCalls == 1)
        #expect(automation.hotkeyCount == 0)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .hotkey) == 0)
        #expect(windows.failure.outcome.projection.retrySafe == false)
        #expect(windows.failure.outcome.projection.mutationDispatched)
    }
}

@MainActor
private final class FailedFocusProofWindows: ScriptedWindowInventoryService,
WindowManagementPinnedFocusActionResultProviding {
    let identity = WindowMutationIdentity(
        windowID: 77,
        ownerProcessIdentifier: 420,
        ownerProcessStartIdentity: 9001,
        capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100)
    )
    var focusCalls = 0

    var failure: DesktopActionFailure {
        DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "The accepted focus could not prove its exact window postcondition.",
            hint: "Observe before retrying."
        )
        .attributed(to: self.identity.actionTargetReceipt)
    }

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        [ServiceWindowInfo(
            windowID: 77, title: "Fixture", bounds: self.identity.capturedBounds!, mutationIdentity: self.identity
        )]
    }

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindowActionResult(target: target, expectedIdentity: self.identity)
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget, expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        #expect(target == .windowId(77))
        #expect(expectedIdentity == self.identity)
        self.focusCalls += 1
        throw self.failure
    }
}

@MainActor
private final class FocusProofHotkeyRecorder: MockAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript(outcomes: [:], defaultOutcome: .dispatchedUnverified(
        delivery: .init(mechanism: .globalEvents, mode: .foreground), evidence: .deliveryAccepted
    ))
    var hotkeyCount = 0

    override func hotkey(keys: String, holdDuration: Int) async throws {
        self.hotkeyCount += 1
    }
}

/// No native service graph: any unexpected service access stops the deterministic test.
@MainActor
private final class FocusProofPressServices: PeekabooServiceProviding {
    let executionHost: PeekabooServiceExecutionHost = .remote
    let windows: any WindowManagementServiceProtocol
    let automation: any UIAutomationServiceProtocol
    let snapshots: any SnapshotManagerProtocol = InMemorySnapshotManager()
    var agent: (any AgentServiceProtocol)? {
        nil
    }

    init(windows: any WindowManagementServiceProtocol, automation: any UIAutomationServiceProtocol) {
        self.windows = windows
        self.automation = automation
    }

    func ensureVisualizerConnection() {}
    var logging: any LoggingServiceProtocol {
        fatalError("Unexpected logging service")
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        fatalError("Unexpected capture")
    }

    var applications: any ApplicationServiceProtocol {
        fatalError("Unexpected application operation")
    }

    var menu: any MenuServiceProtocol {
        fatalError("Unexpected menu")
    }

    var dock: any DockServiceProtocol {
        fatalError("Unexpected Dock")
    }

    var dialogs: any DialogServiceProtocol {
        fatalError("Unexpected dialog")
    }

    var files: any FileServiceProtocol {
        fatalError("Unexpected files")
    }

    var clipboard: any ClipboardServiceProtocol {
        fatalError("Unexpected clipboard")
    }

    var configuration: PeekabooCore.ConfigurationManager {
        fatalError("Unexpected configuration")
    }

    var permissions: PermissionsService {
        fatalError("Unexpected permissions")
    }

    var audioInput: AudioInputService {
        fatalError("Unexpected audio")
    }

    var screens: any ScreenServiceProtocol {
        fatalError("Unexpected screens")
    }

    var browser: any BrowserMCPClientProviding {
        fatalError("Unexpected browser")
    }
}
