import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct ExactDialogInputBridgeIntegrationTests {
    @Test
    @MainActor
    func `legacy exact dialog input refuses missing PostEvent before dispatch`() throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 4242,
            processStartIdentity: 99,
            windowID: 700)
        let dialogs = ExactDialogInputBridgeStub(receipt: receipt)
        let server = PeekabooBridgeServer(
            services: ExactDialogInputBridgeServices(dialogs: dialogs),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.exactDialogEnterText])
        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "must-not-dispatch",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))

        let error = #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try server.validateOperationAccess(
                for: .exactDialogEnterText(request),
                permissions: PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    postEvent: false),
                effectiveOps: [.exactDialogEnterText])
        }

        #expect(error?.code == .permissionDenied)
        #expect(error?.permission == .postEvent)
        #expect(dialogs.lastForegroundCompatibleRequest == nil)
        #expect(dialogs.lastExactRequest == nil)
    }

    @Test
    func `exact dialog input permissions follow negotiated execution path`() async throws {
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
        let dialogs = await MainActor.run {
            ExactDialogInputBridgeStub(
                receipt: receipt,
                windowIdentity: identity,
                windowBounds: bounds)
        }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogs) }
        let socketPath = "/tmp/peekaboo-bridge-dialog-permissions-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.exactDialogEnterText],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        postEvent: false)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let legacyClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let legacy = try await legacyClient.handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 28))
        #expect(legacy.permissionTags[PeekabooBridgeOperation.exactDialogEnterText.rawValue] == [
            .accessibility,
            .postEvent,
        ])
        #expect(legacy.enabledOperations?.contains(.exactDialogEnterText) == false)

        let currentClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let current = try await currentClient.handshake(client: Self.clientIdentity)
        #expect(current.permissionTags[PeekabooBridgeOperation.exactDialogEnterText.rawValue] == [.accessibility])
        #expect(current.enabledOperations?.contains(.exactDialogEnterText) == true)
        #expect(current.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) == true)

        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "background",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))
        let result = try await currentClient.exactDialogEnterText(request)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityValue, mode: .background))

        do {
            _ = try await legacyClient.exactDialogEnterText(request)
            Issue.record("Expected legacy exact input to require PostEvent permission")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }

        do {
            _ = try await server.route(.exactDialogEnterText(request), peer: nil)
            Issue.record("Expected raw legacy dispatch to require PostEvent permission")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .postEvent)
            #expect(envelope.actionOutcome?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        }
    }

    @Test
    func `attested exact dialog input cannot bypass a disabled host operation`() async throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 4242,
            processStartIdentity: 99,
            windowID: 700)
        let dialogs = await MainActor.run { ExactDialogInputBridgeStub(receipt: receipt) }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogs) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        postEvent: false)
                })
        }
        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "must-not-dispatch",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))

        do {
            _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.route(.exactDialogEnterText(request), peer: nil)
            }
            Issue.record("Expected the disabled exact-dialog operation to be rejected")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.actionOutcome?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        }

        let dispatchedRequest = await MainActor.run { dialogs.lastExactRequest }
        #expect(dispatchedRequest == nil)
    }

    @Test
    func `receiptless protocol 1 29 preserves foreground exact dialog execution`() async throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 4242,
            processStartIdentity: 99,
            windowID: 700)
        let dialogs = await MainActor.run {
            ExactDialogInputBridgeStub(
                receipt: receipt,
                supportsBackgroundExactDialogInput: false)
        }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogs) }
        let postEvent = DialogPermissionBox(true)
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.exactDialogEnterText],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        postEvent: postEvent.value)
                })
        }
        let handshake = try await server.route(.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            client: Self.clientIdentity,
            requestedHostKind: .gui)), peer: nil)
        guard case let .handshake(capabilities) = handshake.response else {
            Issue.record("Expected receiptless protocol 1.29 handshake")
            return
        }
        #expect(capabilities.negotiatedVersion == PeekabooBridgeConstants.attestedOperationReceiptVersion)
        #expect(capabilities.supportedOperations.contains(.exactDialogEnterText))
        #expect(capabilities.enabledOperations?.contains(.exactDialogEnterText) == true)
        #expect(capabilities.permissionTags[PeekabooBridgeOperation.exactDialogEnterText.rawValue] == [
            .accessibility,
            .postEvent,
        ])
        #expect(capabilities.hostCapabilities?.contains(PeekabooBridgeHostCapability.attestedOperationReceipts) != true)

        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "receiptless-foreground",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))
        let handled = try await server.route(.exactDialogEnterText(request), peer: nil)
        guard case let .dialogResult(result) = handled.response else {
            Issue.record("Expected receiptless exact dialog result")
            return
        }
        #expect(result.outcome?.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        let calls = await MainActor.run {
            (dialogs.lastForegroundCompatibleRequest, dialogs.lastExactRequest)
        }
        #expect(calls.0 == request)
        #expect(calls.1 == nil)

        postEvent.value = false
        let blockedRequest = try DialogInputExecutionRequest(
            target: request.target,
            text: "must-not-dispatch",
            fieldIdentifier: request.fieldIdentifier,
            clearExisting: request.clearExisting,
            focus: request.focus)
        do {
            _ = try await server.route(.exactDialogEnterText(blockedRequest), peer: nil)
            Issue.record("Expected receiptless protocol 1.29 input to require PostEvent")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .postEvent)
        }
        let finalForegroundRequest = await MainActor.run { dialogs.lastForegroundCompatibleRequest }
        #expect(finalForegroundRequest == request)
    }

    @Test
    func `attested protocol 1 29 omits and refuses a foreground-only provider`() async throws {
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
        let dialogs = await MainActor.run {
            ExactDialogInputBridgeStub(
                receipt: receipt,
                windowIdentity: identity,
                windowBounds: bounds,
                foregroundCompatibleInputOutcome: Self.projectedExactInputOutcome,
                supportsBackgroundExactDialogInput: false)
        }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogs) }
        let socketPath = "/tmp/peekaboo-bridge-dialog-provider-capability-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.exactDialogEnterText],
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

        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "legacy-only",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))
        let legacyClient = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let legacyHandshake = try await legacyClient.handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 28))
        #expect(legacyHandshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(legacyHandshake.enabledOperations?.contains(.exactDialogEnterText) == true)
        _ = try await legacyClient.exactDialogEnterText(request)

        let currentClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let currentHandshake = try await currentClient.handshake(client: Self.clientIdentity)
        #expect(!currentHandshake.supportedOperations.contains(.exactDialogEnterText))
        #expect(currentHandshake.permissionTags[PeekabooBridgeOperation.exactDialogEnterText.rawValue] == nil)

        do {
            _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try await server.route(.exactDialogEnterText(request), peer: nil)
            }
            Issue.record("Expected current exact input to reject a foreground-only provider")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
            #expect(envelope.actionOutcome?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        }

        let calls = await MainActor.run {
            (dialogs.lastForegroundCompatibleRequest, dialogs.lastExactRequest)
        }
        #expect(calls.0 == request)
        #expect(calls.1 == nil)
    }

    @Test
    func `current signed exact dialog refusals remain retry safe`() async throws {
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
        let dialogs = await MainActor.run {
            ExactDialogInputBridgeStub(
                receipt: receipt,
                windowIdentity: identity,
                windowBounds: bounds)
        }
        let services = await MainActor.run { ExactDialogInputBridgeServices(dialogs: dialogs) }
        let socketPath = "/tmp/peekaboo-bridge-dialog-refusals-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.exactDialogEnterText, .exactDialogForceDismiss],
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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let target = try DialogTargetSelector(processIdentifier: 4242, windowID: 700)
        let input = try DialogInputExecutionRequest(
            target: target,
            text: "must-not-dispatch",
            focus: DialogForegroundFocusPolicy(autoFocus: false))
        let forceDismiss = try DialogForcedDismissExecutionRequest(
            target: target,
            focus: DialogForegroundFocusPolicy(autoFocus: false))

        await MainActor.run { dialogs.exactInputRefusalReason = .permissionDenied }
        await Self.expectRefusal(.permissionDenied) {
            _ = try await client.exactDialogEnterText(input)
        }

        await MainActor.run { dialogs.exactForceDismissRefusalReason = .operationUnsupported }
        await Self.expectRefusal(.operationUnsupported) {
            _ = try await client.exactDialogForceDismiss(forceDismiss)
        }

        await MainActor.run { dialogs.exactInputRefusalReason = .targetUnavailable }
        await Self.expectRefusal(.targetUnavailable) {
            _ = try await client.exactDialogEnterText(input)
        }
    }

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

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
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
        let handshake = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 28))
        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 28))
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
        let resolvedTarget = try Self.resolvedDialogTarget(identity: identity, bounds: bounds)
        let dialogService = await MainActor.run {
            ExactDialogInputBridgeStub(
                receipt: receipt,
                windowIdentity: identity,
                windowBounds: bounds,
                resolvedTarget: resolvedTarget,
                foregroundCompatibleInputOutcome: Self.projectedExactInputOutcome)
        }
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
        let exactRequest = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            text: "exact",
            fieldIdentifier: "Name",
            clearExisting: true,
            focus: DialogForegroundFocusPolicy(autoFocus: false))
        _ = try await oldClient.dialogEnterText(
            text: "legacy",
            fieldIdentifier: "Name",
            clearExisting: false,
            windowTitle: "Sheet",
            appName: "TextEdit")
        _ = try await oldClient.exactDialogEnterText(exactRequest)
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

        let currentClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
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
        let exactResult = try await remoteService.enterText(exactRequest)
        let focusPolicy = DialogForegroundFocusPolicy(autoFocus: false, timeout: 1.5, retryCount: 4)
        do {
            _ = try await remoteService.enterText(DialogLegacyInputExecutionRequest(
                text: "policy",
                fieldIdentifier: "Name",
                clearExisting: false,
                windowTitle: nil,
                appName: nil,
                focus: focusPolicy))
            Issue.record("Expected protocol 1.29 legacy dialog input to refuse without an exact target")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
        }
        let dismissRequest = try DialogForcedDismissExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 4242, windowID: 700),
            focus: focusPolicy)
        let dismissResult = try await remoteService.forceDismissDialog(dismissRequest)

        let calls = await MainActor.run {
            (
                dialogService.legacyTexts,
                dialogService.lastExactRequest,
                dialogService.lastForegroundCompatibleRequest,
                dialogService.lastLegacyFocus,
                dialogService.lastExactDismissRequest,
                dialogService.legacyDismissCount)
        }
        #expect(calls.0 == ["legacy", "fallback"])
        #expect(calls.1 == exactRequest)
        #expect(calls.2 == exactRequest)
        #expect(calls.3 == nil)
        #expect(calls.4 == dismissRequest)
        #expect(calls.5 == 1)
        Self.expectExactDialogResults(
            exactResult,
            dismissResult,
            receipt: receipt,
            resolvedTarget: resolvedTarget)
        #expect(exactResult.details["process_start_identity_decimal"] == "99")
        #expect(exactResult.details["window_id"] == "700")
    }

    private static func resolvedDialogTarget(
        identity: WindowMutationIdentity,
        bounds: CGRect) throws -> ResolvedDialogTargetEvidence
    {
        try ResolvedDialogTargetEvidence(
            target: UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds),
            application: ServiceApplicationInfo(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                bundleIdentifier: "com.apple.TextEdit",
                name: "TextEdit"),
            window: ServiceWindowInfo(
                windowID: identity.windowID,
                title: "Document",
                bounds: bounds,
                index: 0,
                mutationIdentity: identity))
    }

    private static func expectExactDialogResults(
        _ input: DialogActionResult,
        _ dismissal: DialogActionResult,
        receipt: DesktopActionTargetReceipt,
        resolvedTarget: ResolvedDialogTargetEvidence)
    {
        for result in [input, dismissal] {
            #expect(result.outcome?.route == .bridge)
            #expect(result.outcome?.state == .dispatchedUnverified)
            #expect(result.targetReceipt == receipt)
            #expect(result.resolvedTarget == resolvedTarget)
        }
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

    private static func expectRefusal(
        _ reason: DesktopActionOutcome.RefusalReason,
        operation: () async throws -> Void) async
    {
        do {
            try await operation()
            Issue.record("Expected exact dialog refusal \(reason.rawValue)")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == reason)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == nil)
        } catch {
            Issue.record("Unexpected exact dialog error: \(error)")
        }
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peeka.cli",
        teamIdentifier: "TEAMID",
        processIdentifier: getpid())

    private static let projectedExactInputOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .accessibilityValue, mode: .background),
        evidence: .deliveryAccepted,
        unitCount: .one)
}

private final class DialogPermissionBox: @unchecked Sendable {
    var value: Bool

    init(_ value: Bool) {
        self.value = value
    }
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
    let supportsBackgroundExactDialogInput: Bool
    private let receipt: DesktopActionTargetReceipt
    private let windowIdentity: WindowMutationIdentity?
    private let windowBounds: CGRect?
    private let resolvedTarget: ResolvedDialogTargetEvidence?
    private let foregroundCompatibleInputOutcome: DesktopActionOutcome
    private(set) var legacyTexts: [String] = []
    private(set) var lastExactRequest: DialogInputExecutionRequest?
    private(set) var lastForegroundCompatibleRequest: DialogInputExecutionRequest?
    private(set) var lastLegacyFocus: DialogForegroundFocusPolicy?
    private(set) var lastExactDismissRequest: DialogForcedDismissExecutionRequest?
    private(set) var legacyDismissCount = 0
    var exactInputRefusalReason: DesktopActionOutcome.RefusalReason?
    var exactForceDismissRefusalReason: DesktopActionOutcome.RefusalReason?

    init(
        receipt: DesktopActionTargetReceipt,
        windowIdentity: WindowMutationIdentity? = nil,
        windowBounds: CGRect? = nil,
        resolvedTarget: ResolvedDialogTargetEvidence? = nil,
        foregroundCompatibleInputOutcome: DesktopActionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one),
        supportsBackgroundExactDialogInput: Bool = true)
    {
        self.receipt = receipt
        self.windowIdentity = windowIdentity
        self.windowBounds = windowBounds
        self.resolvedTarget = resolvedTarget
        self.foregroundCompatibleInputOutcome = foregroundCompatibleInputOutcome
        self.supportsBackgroundExactDialogInput = supportsBackgroundExactDialogInput
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
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: [:])
    }

    func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.lastExactRequest = request
        if let exactInputRefusalReason {
            return DialogActionResult(
                success: false,
                action: .enterText,
                outcome: .refused(reason: exactInputRefusalReason))
        }
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
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetReceipt: self.receipt,
            targetWindowIdentity: self.windowIdentity,
            targetWindowBounds: self.windowBounds,
            focusedElement: nil,
            resolvedTarget: self.resolvedTarget)
    }

    func enterTextForegroundCompatible(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        self.lastForegroundCompatibleRequest = request
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: [
                "pid": "4242",
                "process_start_identity": "99",
                "process_start_identity_decimal": "99",
                "window_id": "700",
            ],
            outcome: self.foregroundCompatibleInputOutcome,
            targetReceipt: self.receipt,
            targetWindowIdentity: self.windowIdentity,
            targetWindowBounds: self.windowBounds,
            focusedElement: nil,
            resolvedTarget: self.resolvedTarget)
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
            details: ["method": "escape"])
    }

    func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult {
        self.lastExactDismissRequest = request
        if let exactForceDismissRefusalReason {
            return DialogActionResult(
                success: false,
                action: .dismiss,
                outcome: .refused(reason: exactForceDismissRefusalReason))
        }
        return DialogActionResult(
            success: true,
            action: .dismiss,
            details: ["method": "escape"],
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetReceipt: self.receipt,
            targetWindowIdentity: self.windowIdentity,
            targetWindowBounds: self.windowBounds,
            focusedElement: nil,
            resolvedTarget: self.resolvedTarget)
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw PeekabooError.notImplemented("stub")
    }
}
