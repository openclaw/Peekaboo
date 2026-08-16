import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import Testing
@testable import PeekabooCore

@MainActor
struct BridgeStrictBackgroundOperationTests {
    @Test
    func `strict operations require their receipt-compatible bridge protocols`() {
        let operations: Set<PeekabooBridgeOperation> = [
            .backgroundCloseWindow,
            .backgroundDialogClickButton,
            .targetedDialogListElements,
            .prepareDialogAction,
            .exactDialogClickButton,
            .exactDialogDismiss,
            .exactDialogEnterText,
            .exactDialogForceDismiss,
        ]

        let legacy = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 10))
        let backgroundDialog = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 11))
        let current = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 18))

        #expect(legacy.isEmpty)
        #expect(backgroundDialog == [.backgroundDialogClickButton])
        #expect(current == [.backgroundCloseWindow, .backgroundDialogClickButton])
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 24)) ==
            [.backgroundCloseWindow, .backgroundDialogClickButton])
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 25)) ==
            operations.subtracting([.exactDialogEnterText, .exactDialogForceDismiss]))
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 26)) ==
            operations.subtracting([.exactDialogEnterText, .exactDialogForceDismiss]))
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 27)) ==
            operations.subtracting([.exactDialogForceDismiss]))
        #expect(PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 28)) == operations)
    }

    @Test
    func `ordinary desktop observation remains compatible while ROI advances protocol 1_21`() {
        let operation: Set<PeekabooBridgeOperation> = [.desktopObservation]
        let atomicPublication: Set<PeekabooBridgeOperation> = [.storeObservationSnapshot]

        #expect(PeekabooBridgeConstants.exactWindowROIObservationVersion ==
            PeekabooBridgeProtocolVersion(major: 1, minor: 21))
        #expect(PeekabooBridgeOperation.compatible(
            operation,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 4)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            operation,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 5)) == operation)
        #expect(PeekabooBridgeOperation.compatible(
            operation,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 19)) == operation)
        #expect(PeekabooBridgeOperation.compatible(
            operation,
            with: PeekabooBridgeConstants.exactWindowROIObservationVersion) == operation)
        #expect(PeekabooBridgeOperation.compatible(
            atomicPublication,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 20)).isEmpty)
        #expect(PeekabooBridgeOperation.compatible(
            atomicPublication,
            with: PeekabooBridgeConstants.exactWindowROIObservationVersion) == atomicPublication)
    }

    @Test
    func `remote background window close fails before dispatch when unsupported`() async {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteWindowManagementService(client: client, supportsBackgroundClose: false)

        do {
            try await service.closeWindow(target: .windowId(42), allowForegroundFallback: false)
            Issue.record("Expected unsupported background close to fail")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .operationNotSupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `remote window mutation fails before dispatch without pinned identity support`() async {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteWindowManagementService(
            client: client,
            supportsBackgroundClose: true,
            supportsPinnedWindowMutations: false)

        do {
            try await service.moveWindow(target: .windowId(42), to: .zero)
            Issue.record("Expected unpinned remote mutation to fail")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .operationNotSupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `remote restore fails before dispatch when host lacks restore capability`() async {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteWindowManagementService(
            client: client,
            supportsPinnedWindowMutations: true,
            supportsWindowRestore: false)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 1,
            capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            isMinimized: true)

        do {
            try await service.restoreWindow(target: .windowId(42), expectedIdentity: identity)
            Issue.record("Expected unsupported remote restore to fail")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .operationNotSupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `remote background dialog click fails before dispatch when unsupported`() async {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteDialogService(client: client, supportsBackgroundButtonClick: false)

        do {
            _ = try await service.clickButton(
                buttonText: "OK",
                windowTitle: nil,
                appName: "TextEdit",
                allowGlobalFallback: false)
            Issue.record("Expected unsupported background dialog click to fail")
        } catch let error as PeekabooBridgeErrorEnvelope {
            #expect(error.code == .operationNotSupported)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `remote prepared dialog action refuses before transport when one operation is missing`() async throws {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteDialogService(
            client: client,
            capabilities: RemoteDialogCapabilities(
                prepareAction: true,
                exactClick: false))
        let target = try DialogTargetSelector(processIdentifier: 123)
        let request = try DialogActionPreparationRequest(
            target: target,
            kind: .clickButton,
            buttonText: "OK")

        do {
            _ = try await service.prepareDialogAction(request)
            Issue.record("Expected capability refusal before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `remote exact dialog input refuses before transport when capability is missing`() async throws {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteDialogService(
            client: client,
            capabilities: RemoteDialogCapabilities(exactInput: false))
        let request = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 123),
            text: "must not dispatch",
            focus: DialogForegroundFocusPolicy(autoFocus: false))

        do {
            _ = try await service.enterText(request)
            Issue.record("Expected exact dialog input capability refusal before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.hint?.contains("1.27") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `current remote exact dialog input rejects dishonest foreground compatibility`() async throws {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteDialogService(
            client: client,
            capabilities: .init(exactInput: true, backgroundExactInput: true))
        let request = try DialogInputExecutionRequest(
            target: .init(processIdentifier: 123, windowID: 700),
            text: "must not dispatch")

        do {
            _ = try await service.enterTextForegroundCompatible(request)
            Issue.record("Expected current background-only exact provider to reject foreground compatibility")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `remote foreground dialog additions refuse before transport when capability is missing`() async throws {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        let service = RemoteDialogService(client: client)
        let dismissRequest = try DialogForcedDismissExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 123, windowID: 700))

        do {
            _ = try await service.forceDismissDialog(dismissRequest)
            Issue.record("Expected exact forced-dismiss capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }

        do {
            _ = try await service.enterText(DialogLegacyInputExecutionRequest(
                text: "must not dispatch",
                fieldIdentifier: nil,
                clearExisting: false,
                windowTitle: nil,
                appName: nil,
                focus: DialogForegroundFocusPolicy(autoFocus: false)))
            Issue.record("Expected legacy focus-policy capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `remote service initializer preserves legacy background dialog capability label`() {
        let client = PeekabooBridgeClient(socketPath: "/nonexistent/peekaboo-test.sock")
        _ = RemotePeekabooServices(
            client: client,
            supportsBackgroundDialogClick: true)
    }

    @Test
    func `remote prepare errors normalize to canonical bridge pre-dispatch refusals`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: "Dialog became ambiguous",
            details: "candidate_window_ids=700,701")
        let failure = RemoteDialogService.preDispatchFailure(for: envelope)

        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.refusalReason == .invalidRequest)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.retrySafety == .safe)
        #expect(failure.causeDescription == "candidate_window_ids=700,701")
    }

    @Test
    func `remote authority errors retain transport-session refusal semantics`() {
        for code in [PeekabooBridgeErrorCode.unauthorizedClient, .serverBusy, .timeout] {
            let failure = RemoteDialogService.preDispatchFailure(for: .init(
                code: code,
                message: "Dialog authority unavailable"))

            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }
    }

    @Test
    func `remote prepared action may-complete errors remain indeterminate and retry unsafe`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Dialog completion could not be verified",
            details: "response lost after AXPress",
            operationMayHaveCompleted: true)
        let failure = RemoteDialogService.actionFailure(for: envelope)

        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .completionUnknown)
        #expect(failure.outcome.dispatchState.mutationDispatched)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.projection.requiresFreshObservation)
        #expect(failure.causeDescription == "response lost after AXPress")
    }

    @Test
    func `remote exact input may-complete errors retain foreground global delivery semantics`() {
        let envelope = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            message: "Dialog input response was lost",
            details: "response lost after keyboard delivery",
            operationMayHaveCompleted: true)
        let failure = RemoteDialogService.inputActionFailure(
            for: envelope,
            delivery: .init(mechanism: .globalEvents, mode: .foreground))

        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.causeDescription == "response lost after keyboard delivery")
    }

    @Test
    func `prepared dialog request wire retains exact action and window receipt`() throws {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 999,
            capturedBounds: bounds)
        let receipt = try PreparedDialogActionReceipt(
            token: UUID(),
            kind: .clickButton,
            target: UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds))
        let request = PeekabooBridgeRequest.exactDialogClickButton(receipt)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
        #expect(decoded.operation == .exactDialogClickButton)
        guard case let .exactDialogClickButton(decodedReceipt) = decoded else {
            Issue.record("Expected exact dialog click request")
            return
        }
        #expect(decodedReceipt == receipt)
    }
}
