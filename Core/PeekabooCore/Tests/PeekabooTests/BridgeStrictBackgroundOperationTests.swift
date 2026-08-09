import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing
@testable import PeekabooCore

@MainActor
struct BridgeStrictBackgroundOperationTests {
    @Test
    func `strict operations require bridge protocol 1 11`() {
        let operations: Set<PeekabooBridgeOperation> = [
            .backgroundCloseWindow,
            .backgroundDialogClickButton,
        ]

        let legacy = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 10))
        let current = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 11))

        #expect(legacy.isEmpty)
        #expect(current == operations)
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
