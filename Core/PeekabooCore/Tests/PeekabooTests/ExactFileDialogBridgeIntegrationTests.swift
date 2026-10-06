import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@MainActor
struct ExactFileDialogBridgeIntegrationTests {
    @Test
    func `attested file execution preserves parent selector target and owner dispatch count`() async throws {
        let dialogs = ExactFileDialogBridgeStub()
        let fixture = try await Self.startHost(dialogs: dialogs)
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.exactFileDialogExecution) == true)
        #expect(handshake.enabledOperations?.contains(.dialogHandleFile) == true)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.dialogHandleFile.rawValue] == [
            .accessibility, .postEvent,
        ])
        let request = try Self.request()

        let result = try await fixture.client.dialogHandleFile(request)

        #expect(dialogs.requests == [request])
        #expect(dialogs.legacyCalls == 0)
        #expect(result.targetReceipt == dialogs.identity.actionTargetReceipt)
        #expect(result.targetWindowIdentity == dialogs.identity)
        #expect(result.targetWindowBounds == dialogs.bounds)
        #expect(result.outcome == dialogs.outcome?.routed(to: .bridge))
        let receipt = try #require(await fixture.client.lastOperationReceipt())
        #expect(receipt.payload.target == .window(dialogs.identity))
        #expect(receipt.payload.outcome?.dispatchState.unitCount?.rawValue == 3)
    }

    @Test
    func `incapable disabled and older attested hosts refuse typed and raw file sends before dispatch`() async throws {
        for mode in 0..<3 {
            let dialogs = ExactFileDialogBridgeStub()
            dialogs.supportsExactFileDialogExecution = mode != 0
            let fixture = try await Self.startHost(
                dialogs: dialogs,
                version: mode == 2 ? .init(major: 1, minor: 42) : PeekabooBridgeConstants.protocolVersion,
                allowedOperations: mode == 1 ? [] : [.dialogHandleFile])
            defer { Task { await fixture.host.stop() } }
            let handshake = try await fixture.client.handshake(client: Self.clientIdentity)
            #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.exactFileDialogExecution) != true)
            let request = try Self.request()

            for raw in [false, true] {
                do {
                    if raw {
                        _ = try await fixture.client.send(.dialogHandleFile(.init(execution: request)))
                    } else {
                        _ = try await fixture.client.dialogHandleFile(request)
                    }
                    Issue.record("Expected unsupported file execution to refuse before transport")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome.state == .refused)
                    #expect(failure.outcome.dispatchState == .none)
                    #expect(failure.outcome.retrySafety == .safe)
                }
            }
            #expect(dialogs.requests.isEmpty)
            #expect(dialogs.legacyCalls == 0)
        }
    }

    @Test
    func `server requires attestation claimed capability and version before the file provider`() throws {
        let dialogs = ExactFileDialogBridgeStub()
        let server = PeekabooBridgeServer(
            services: ExactFileDialogBridgeServices(dialogs: dialogs),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.dialogHandleFile])
        let wire = try PeekabooBridgeRequest.dialogHandleFile(.init(execution: Self.request()))
        for mode in 0..<3 {
            let claim = PeekabooBridgeNegotiatedSessionCapabilities(
                protocolVersion: mode == 2 ? .init(major: 1, minor: 42) : PeekabooBridgeConstants.protocolVersion,
                statelessClickVariants: false,
                exactWindowHeldPointerLifecycle: false,
                exactFileDialogExecution: mode != 1)
            let error = PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(mode != 0) {
                PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(claim) {
                    #expect(throws: DesktopActionFailure.self) {
                        try server.validateExactFileDialogExecutionAccess(wire)
                    }
                }
            }
            #expect(error?.outcome.state == .refused)
            #expect(error?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        }
        #expect(dialogs.requests.isEmpty)
    }

    @Test
    func `remote file capability defaults to refusal without a legacy fallback`() async throws {
        let client = PeekabooBridgeClient(socketPath: "/tmp/nonexistent-file-dialog-\(UUID().uuidString).sock")
        let remote = RemoteDialogService(client: client)
        #expect(!remote.supportsExactFileDialogExecution)
        do {
            _ = try await remote.handleFileDialog(Self.request())
            Issue.record("Expected remote capability refusal before any socket access")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `typed file requires PostEvent even when Accessibility is granted`() throws {
        let dialogs = ExactFileDialogBridgeStub()
        let server = PeekabooBridgeServer(
            services: ExactFileDialogBridgeServices(dialogs: dialogs),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.dialogHandleFile])
        let wire = try PeekabooBridgeRequest.dialogHandleFile(.init(execution: Self.request()))
        let error = PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                    try server.validateOperationAccess(
                        for: wire,
                        permissions: .init(screenRecording: false, accessibility: true, postEvent: false),
                        effectiveOps: [.dialogHandleFile])
                }
            }
        }
        #expect(error?.permission == .postEvent)
        #expect(dialogs.requests.isEmpty)
    }

    @Test
    func `attested legacy file remains refused even when typed file capability is enabled`() async throws {
        let dialogs = ExactFileDialogBridgeStub()
        let fixture = try await Self.startHost(dialogs: dialogs)
        defer { Task { await fixture.host.stop() } }
        _ = try await fixture.client.handshake(client: Self.clientIdentity)

        do {
            _ = try await fixture.client.dialogHandleFile(
                path: "/tmp", filename: "legacy.txt", actionButton: "Save", appName: nil)
            Issue.record("Expected the legacy attested operation to remain fail-closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(dialogs.requests.isEmpty)
        #expect(dialogs.legacyCalls == 0)
    }

    @Test
    func `signed file responses reject sheet targets incomplete outcomes and absent selector proof`() async throws {
        for mode in 0..<5 {
            let dialogs = ExactFileDialogBridgeStub()
            dialogs.windowIDOverride = mode == 0 ? 701 : nil
            dialogs.omitTarget = mode == 1
            if mode == 2 {
                dialogs.outcome = nil
            }
            if mode == 3 {
                dialogs.outcome = .dispatchedUnverified(
                    delivery: .init(mechanism: .composite, mode: .foreground),
                    evidence: .deliveryAccepted)
            }
            let fixture = try await Self.startHost(dialogs: dialogs)
            defer { Task { await fixture.host.stop() } }
            _ = try await fixture.client.handshake(client: Self.clientIdentity)
            let request = try mode == 4
                ? DialogFileExecutionRequest(target: DialogTargetSelector(applicationIdentifier: "Fixture"))
                : Self.request()

            do {
                _ = try await fixture.client.dialogHandleFile(request)
                Issue.record("Expected exact file result evidence to fail closed")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.retrySafety == .unsafe)
            }
            #expect(dialogs.requests.count == 1)
            #expect(dialogs.legacyCalls == 0)
        }
    }

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        .init(bundleIdentifier: nil, teamIdentifier: nil, processIdentifier: getpid())
    }

    private static func request() throws -> DialogFileExecutionRequest {
        try DialogFileExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            path: "/tmp",
            filename: "fixture.txt",
            actionButton: "Save",
            ensureExpanded: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false, timeout: 1.5, retryCount: 4))
    }

    private static func startHost(
        dialogs: ExactFileDialogBridgeStub,
        version: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants.protocolVersion,
        allowedOperations: Set<PeekabooBridgeOperation> = [.dialogHandleFile]) async throws
        -> (host: PeekabooBridgeHost, client: PeekabooBridgeClient)
    {
        try await BridgeInputCapabilityFixture.startHost(
            services: ExactFileDialogBridgeServices(dialogs: dialogs),
            supportedVersions: version...version,
            allowedOperations: allowedOperations)
    }
}

@MainActor
private final class ExactFileDialogBridgeStub: DialogServiceProtocol {
    var supportsExactFileDialogExecution = true
    var requests: [DialogFileExecutionRequest] = []
    var legacyCalls = 0
    var windowIDOverride: Int?
    var omitTarget = false
    var outcome: DesktopActionOutcome? = .dispatchedUnverified(
        delivery: .init(mechanism: .composite, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .init(3))
    let bounds = CGRect(x: 10, y: 20, width: 480, height: 320)

    var identity: WindowMutationIdentity {
        .init(
            windowID: self.windowIDOverride ?? 700,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: self.bounds)
    }

    func handleFileDialog(_ request: DialogFileExecutionRequest) async throws -> DialogActionResult {
        self.requests.append(request)
        return DialogActionResult(
            success: true,
            action: .handleFileDialog,
            details: ["button_clicked": "Save"],
            outcome: self.outcome,
            targetReceipt: self.omitTarget ? nil : self.identity.actionTargetReceipt,
            targetWindowIdentity: self.omitTarget ? nil : self.identity,
            targetWindowBounds: self.omitTarget ? nil : self.bounds,
            focusedElement: nil)
    }

    func handleFileDialog(
        path _: String?, filename _: String?, actionButton _: String?, ensureExpanded _: Bool, appName _: String?)
        async throws -> DialogActionResult
    {
        self.legacyCalls += 1
        throw PeekabooError.notImplemented("Legacy file dispatch must not be used")
    }

    func findActiveDialog(windowTitle _: String?, appName _: String?) async throws -> DialogInfo {
        throw PeekabooError.notImplemented("stub")
    }

    func clickButton(
        buttonText _: String,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func enterText(
        text _: String, fieldIdentifier _: String?, clearExisting _: Bool, windowTitle _: String?, appName _: String?)
        async throws -> DialogActionResult
    {
        throw PeekabooError.notImplemented("stub")
    }

    func dismissDialog(force _: Bool, windowTitle _: String?, appName _: String?) async throws -> DialogActionResult {
        throw PeekabooError.notImplemented("stub")
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw PeekabooError.notImplemented("stub")
    }
}

@MainActor
private final class ExactFileDialogBridgeServices: PeekabooBridgeServiceProviding {
    private let base = StubServices()
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
