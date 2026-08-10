import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCore

@MainActor
struct BridgeStrictBackgroundOperationTests {
    @Test
    func `strict operations require their receipt-compatible bridge protocols`() {
        let operations: Set<PeekabooBridgeOperation> = [
            .backgroundCloseWindow,
            .backgroundDialogClickButton,
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
        #expect(current == operations)
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
}
