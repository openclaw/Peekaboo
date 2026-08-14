import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct ExactDialogInputBridgeIntegrationTests {
    @Test
    func `protocol 1 28 client keeps exact input but refuses new operations on a 1 27 host`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-dialog-input-old-host-\(UUID().uuidString).sock"
        let oldVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 27)
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
        #expect(handshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(!handshake.supportedOperations.contains(.exactDialogForceDismiss))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactDialogInputExecution) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactForcedDialogDismissExecution) != true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.dialogInputFocusPolicy) != true)

        let dismissRequest = try DialogForcedDismissExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700))
        do {
            _ = try await client.exactDialogForceDismiss(dismissRequest)
            Issue.record("Expected exact forced dismissal to refuse before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.dispatchState == .none)
        }

        do {
            _ = try await client.dialogEnterText(
                text: "must not dispatch",
                fieldIdentifier: nil,
                clearExisting: false,
                windowTitle: nil,
                appName: nil,
                focus: DialogForegroundFocusPolicy(autoFocus: false))
            Issue.record("Expected custom focus policy to refuse before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `legacy focus policy capability is independent from exact input operation`() async throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 4242,
            processStartIdentity: 99,
            windowID: 700)
        let dialogService = await MainActor.run { ExactDialogInputBridgeStub(receipt: receipt) }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogService) }
        let socketPath = "/tmp/peekaboo-bridge-dialog-focus-only-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.dialogEnterText],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
                })
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
        #expect(handshake.supportedOperations.contains(.dialogEnterText))
        #expect(!handshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.dialogInputFocusPolicy) == true)

        _ = try await client.dialogEnterText(DialogLegacyInputExecutionRequest(
            text: "focus-only",
            focus: DialogForegroundFocusPolicy(autoFocus: false)))
        let calls = await MainActor.run { (dialogService.legacyTexts, dialogService.lastLegacyFocus) }
        #expect(calls.0 == ["focus-only"])
        #expect(calls.1?.autoFocus == false)
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
                allowedOperations: [
                    .dialogEnterText,
                    .dialogDismiss,
                    .exactDialogEnterText,
                    .exactDialogForceDismiss,
                ],
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
            protocolVersion: .init(major: 1, minor: 27))
        #expect(oldHandshake.supportedOperations.contains(.dialogEnterText))
        #expect(oldHandshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(!oldHandshake.supportedOperations.contains(.exactDialogForceDismiss))
        #expect(oldHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactDialogInputExecution) == true)
        try Self.requireLegacyProtocol127Handshake(oldHandshake)
        _ = try await oldClient.dialogEnterText(
            text: "legacy",
            fieldIdentifier: "Name",
            clearExisting: false,
            windowTitle: "Sheet",
            appName: "TextEdit")
        _ = try await oldClient.dialogDismiss(
            force: true,
            windowTitle: "Sheet",
            appName: "TextEdit")
        let protocol127Service = await MainActor.run {
            RemoteDialogService(
                client: oldClient,
                capabilities: RemoteDialogCapabilities(exactInput: true))
        }
        _ = try await protocol127Service.enterText(DialogLegacyInputExecutionRequest(text: "fallback"))
        do {
            _ = try await protocol127Service.enterText(DialogLegacyInputExecutionRequest(
                text: "custom-must-not-dispatch",
                focus: DialogForegroundFocusPolicy(autoFocus: false)))
            Issue.record("Expected custom focus policy to refuse on protocol 1.27")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }

        let currentClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let currentHandshake = try await currentClient.handshake(client: Self.clientIdentity)
        #expect(currentHandshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(currentHandshake.supportedOperations.contains(.exactDialogForceDismiss))
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactDialogInputExecution) == true)
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactForcedDialogDismissExecution) == true)
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.dialogInputFocusPolicy) == true)
        let remoteService = await MainActor.run {
            RemoteDialogService(
                client: currentClient,
                capabilities: RemoteDialogCapabilities(
                    exactInput: true,
                    exactForceDismiss: true,
                    legacyInputFocusPolicy: true))
        }
        let exactRequest = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "exact",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))
        let exactResult = try await remoteService.enterText(exactRequest)
        let focusPolicy = DialogForegroundFocusPolicy(autoFocus: false, timeout: 1.5, retryCount: 4)
        _ = try await remoteService.enterText(DialogLegacyInputExecutionRequest(
            text: "policy",
            fieldIdentifier: "Name",
            clearExisting: false,
            windowTitle: nil,
            appName: nil,
            focus: focusPolicy))
        let dismissRequest = try DialogForcedDismissExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            focus: focusPolicy)
        let dismissResult = try await remoteService.forceDismissDialog(dismissRequest)

        let calls = await MainActor.run {
            (
                dialogService.legacyTexts,
                dialogService.lastExactRequest,
                dialogService.lastLegacyFocus,
                dialogService.lastExactDismissRequest,
                dialogService.legacyDismissCount)
        }
        #expect(calls.0 == ["legacy", "fallback", "policy"])
        #expect(calls.1 == exactRequest)
        #expect(calls.2 == focusPolicy)
        #expect(calls.3 == dismissRequest)
        #expect(calls.4 == 1)
        #expect(exactResult.outcome?.route == .bridge)
        #expect(exactResult.outcome?.state == .dispatchedUnverified)
        #expect(exactResult.targetReceipt == receipt)
        #expect(exactResult.details["process_start_identity_decimal"] == "99")
        #expect(exactResult.details["window_id"] == "700")
        #expect(dismissResult.outcome?.route == .bridge)
        #expect(dismissResult.outcome?.state == .dispatchedUnverified)
        #expect(dismissResult.targetReceipt == receipt)
    }

    private static func requireLegacyProtocol127Handshake(
        _ handshake: PeekabooBridgeHandshakeResponse) throws
    {
        let outerData = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeResponse.handshake(handshake))
        let legacyOuter = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyProtocol127Response.self,
            from: outerData)
        guard case let .handshake(legacyHandshake) = legacyOuter else {
            Issue.record("Expected protocol 1.27 legacy handshake response")
            return
        }
        #expect(Set(legacyHandshake.supportedOperations) == [
            .dialogDismiss,
            .dialogEnterText,
            .exactDialogEnterText,
        ])
        #expect(Set(legacyHandshake.enabledOperations ?? []) == [
            .dialogDismiss,
            .dialogEnterText,
            .exactDialogEnterText,
        ])
        #expect(legacyHandshake.permissionTags[PeekabooBridgeOperation.exactDialogForceDismiss.rawValue] == nil)
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peeka.cli",
        teamIdentifier: "TEAMID",
        processIdentifier: getpid())
}

private enum LegacyProtocol127Operation: String, Codable {
    case dialogDismiss
    case dialogEnterText
    case exactDialogEnterText
}

private struct LegacyProtocol127Handshake: Codable {
    let supportedOperations: [LegacyProtocol127Operation]
    let enabledOperations: [LegacyProtocol127Operation]?
    let permissionTags: [String: [PeekabooBridgePermissionKind]]
}

private enum LegacyProtocol127Response: Codable {
    case handshake(LegacyProtocol127Handshake)
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
    private(set) var legacyTexts: [String] = []
    private(set) var lastExactRequest: DialogInputExecutionRequest?
    private(set) var lastLegacyFocus: DialogForegroundFocusPolicy?
    private(set) var lastExactDismissRequest: DialogForcedDismissExecutionRequest?
    private(set) var legacyDismissCount = 0

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
        self.legacyTexts.append(text)
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

    func enterText(_ request: DialogLegacyInputExecutionRequest) async throws -> DialogActionResult {
        self.lastLegacyFocus = request.focus
        return try await self.enterText(
            text: request.text,
            fieldIdentifier: request.fieldIdentifier,
            clearExisting: request.clearExisting,
            windowTitle: request.windowTitle,
            appName: request.appName)
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

    func dismissDialog(force: Bool, windowTitle _: String?, appName _: String?) async throws
        -> DialogActionResult
    {
        guard force else { throw PeekabooError.notImplemented("stub") }
        self.legacyDismissCount += 1
        return DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one))
    }

    func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult {
        self.lastExactDismissRequest = request
        return DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetReceipt: self.receipt)
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw PeekabooError.notImplemented("stub")
    }
}
