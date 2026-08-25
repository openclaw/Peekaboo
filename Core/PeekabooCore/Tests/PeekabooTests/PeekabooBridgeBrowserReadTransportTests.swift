import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

extension PeekabooBridgeBrowserClientTests {
    @Test
    @MainActor
    func `attested browser read preserves provider error over transport`() async throws {
        let socketPath = "/tmp/peekaboo-browser-read-error-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectionReceipt = Self.browserReceipt
        services.browserRawIsError = true
        services.browserResponseContent = [
            .object([
                "type": .string("text"),
                "text": .string("invalid read arguments"),
            ]),
        ]
        services.browserActionFailure = .indeterminate(
            evidence: .completionUnknown,
            message: "Provider returned an error response.")
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-read-error",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        let result = try await client.browserExecuteResult(.init(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable"))

        #expect(result.outcome == nil)
        #expect(result.payload.isError)
        #expect(result.payload.content == services.browserResponseContent)
        #expect(result.payload.connectionReceipt == Self.browserReceipt)
        #expect(result.payload.completedCallCount == 1)
        #expect(result.payload.dispatchedCallCount == 1)
        #expect(result.payload.actionFailure == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `attested browser read cancellation publishes no mutation metadata or progress`() async throws {
        let socketPath = "/tmp/peekaboo-browser-read-cancel-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectionReceipt = Self.browserReceipt
        services.browserExecutionError = CancellationError()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-read-cancel",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        let result = try await client.browserExecuteResult(.init(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable"))

        #expect(result.outcome == nil)
        #expect(result.payload.isError)
        #expect(result.payload.connectionReceipt == Self.browserReceipt)
        #expect(result.payload.completedCallCount == nil)
        #expect(result.payload.dispatchedCallCount == nil)
        #expect(result.payload.actionFailure == nil)
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.outcome == nil)
        #expect(receipt.payload.target != nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `attested browser read refuses a wrong returned receipt over transport`() async throws {
        let socketPath = "/tmp/peekaboo-browser-read-wrong-receipt-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectionReceipt = Self.browserReceipt
        services.browserExecutionReceiptOverride = .init(
            channel: "stable",
            browserURL: "http://127.0.0.1:9333/",
            webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/other",
            devToolsBrowserID: "other",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-read-wrong-receipt",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        do {
            _ = try await client.browserExecuteResult(.init(
                toolName: "list_pages",
                arguments: [:],
                channel: "stable"))
            Issue.record("Expected wrong browser read receipt refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }
        await host.stop()
    }
}
