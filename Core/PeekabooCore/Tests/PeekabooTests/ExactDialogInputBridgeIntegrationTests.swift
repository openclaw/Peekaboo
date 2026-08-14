import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct ExactDialogInputBridgeIntegrationTests {
    @Test
    func `new client negotiating an old host refuses exact input before transport`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-dialog-input-old-host-\(UUID().uuidString).sock"
        let oldVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 26)
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: PeekabooServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...oldVersion)
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)

        #expect(handshake.negotiatedVersion == oldVersion)
        #expect(handshake.supportedOperations.contains(.dialogEnterText))
        #expect(!handshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactDialogInputExecution) != true)

        let exactRequest = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242),
            text: "must not dispatch")
        do {
            _ = try await client.exactDialogEnterText(exactRequest)
            Issue.record("Expected exact dialog input to refuse before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `new host preserves legacy input and routes exact outcome with target receipt`() async throws {
        let bounds = CGRect(x: 10, y: 20, width: 480, height: 320)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: bounds)
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID)
        let dialogService = await MainActor.run { ExactDialogInputBridgeStub(receipt: receipt) }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogService) }
        let socketPath = "/tmp/peekaboo-bridge-dialog-input-current-host-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let oldClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let oldHandshake = try await oldClient.handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 26))
        #expect(oldHandshake.supportedOperations.contains(.dialogEnterText))
        #expect(!oldHandshake.supportedOperations.contains(.exactDialogEnterText))
        _ = try await oldClient.dialogEnterText(
            text: "legacy",
            fieldIdentifier: "Name",
            clearExisting: false,
            windowTitle: "Sheet",
            appName: "TextEdit")

        let currentClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let currentHandshake = try await currentClient.handshake(client: Self.clientIdentity)
        #expect(currentHandshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactDialogInputExecution) == true)
        let remoteService = await MainActor.run {
            RemoteDialogService(
                client: currentClient,
                capabilities: RemoteDialogCapabilities(exactInput: true))
        }
        let exactRequest = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "exact",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogInputFocusPolicy(autoFocus: false))
        let exactResult = try await remoteService.enterText(exactRequest)

        let calls = await MainActor.run { (dialogService.lastLegacyText, dialogService.lastExactRequest) }
        #expect(calls.0 == "legacy")
        #expect(calls.1 == exactRequest)
        #expect(exactResult.outcome?.route == .bridge)
        #expect(exactResult.outcome?.state == .dispatchedUnverified)
        #expect(exactResult.targetReceipt == receipt)
        #expect(exactResult.details["process_start_identity_decimal"] == "99")
        #expect(exactResult.details["window_id"] == "700")
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peeka.cli",
        teamIdentifier: "TEAMID",
        processIdentifier: getpid())
}

@MainActor
private final class ExactDialogInputBridgeServices: PeekabooBridgeServiceProviding {
    private let base = PeekabooServices()
    let dialogs: any DialogServiceProtocol

    init(dialogs: any DialogServiceProtocol) {
        self.dialogs = dialogs
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.base.applications
    }

    var menu: any MenuServiceProtocol {
        self.base.menu
    }

    var dock: any DockServiceProtocol {
        self.base.dock
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }
}

@MainActor
private final class ExactDialogInputBridgeStub: DialogServiceProtocol {
    private let receipt: DesktopActionTargetReceipt
    private(set) var lastLegacyText: String?
    private(set) var lastExactRequest: DialogInputExecutionRequest?

    init(receipt: DesktopActionTargetReceipt) {
        self.receipt = receipt
    }

    func findActiveDialog(windowTitle _: String?, appName _: String?) async throws -> DialogInfo {
        throw PeekabooError.notImplemented("stub")
    }

    func clickButton(buttonText _: String, windowTitle _: String?, appName _: String?) async throws
        -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func enterText(
        text: String,
        fieldIdentifier _: String?,
        clearExisting _: Bool,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        self.lastLegacyText = text
        return DialogActionResult(success: true, action: .enterText)
    }

    func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.lastExactRequest = request
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: [
                "pid": "4242",
                "process_start_identity": "99",
                "process_start_identity_decimal": "99",
                "window_id": "700",
            ],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted),
            targetReceipt: self.receipt)
    }

    func handleFileDialog(
        path _: String?,
        filename _: String?,
        actionButton _: String?,
        ensureExpanded _: Bool,
        appName _: String?) async throws -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func dismissDialog(force _: Bool, windowTitle _: String?, appName _: String?) async throws
        -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw PeekabooError.notImplemented("stub")
    }
}
