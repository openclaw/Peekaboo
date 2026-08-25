import Darwin
import Foundation
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct NativeBrowserConnectionBindingTests {
    @Test
    func `native browser connection binding owns protocol 1 34`() {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 34)
        #expect(PeekabooBridgeConstants.protocolVersion >= version)
        #expect(PeekabooBridgeConstants.nativeBrowserConnectionBindingVersion == version)
        #expect(PeekabooBridgeHostCapability.nativeBrowserConnectionBinding ==
            "nativeBrowserConnectionBinding")
    }

    @Test
    @MainActor
    func `current Bridge signs pre and post approval connect failures canonically`() async throws {
        let failures = [
            DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "connect cancelled before dispatch"),
            DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "authority unavailable"),
            DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "approval completion unknown"),
        ]

        for failure in failures {
            let socketPath = "/tmp/peekaboo-browser-binding-outcome-\(UUID().uuidString).sock"
            let services = StubServices()
            services.browserConnectFailure = failure
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [])
            let host = PeekabooBridgeHost(
                socketPath: socketPath,
                server: server,
                allowedTeamIDs: [],
                requestTimeoutSec: 2)
            try await host.startChecked()
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            let handshake = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.browser-binding-outcome",
                teamIdentifier: nil,
                processIdentifier: getpid()))
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) == true)

            do {
                _ = try await client.browserConnectResult(channel: "stable")
                Issue.record("Expected signed browser connect failure")
            } catch let received as DesktopActionFailure {
                #expect(received.outcome.routed(to: .local) == failure.outcome)
            }
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .browserConnect)
            #expect(receipt.payload.outcome == failure.outcome.routed(to: .bridge).projection)
            await host.stop()
        }
    }

    @Test
    @MainActor
    func `arbitrary raw provider cancellation is signed as indeterminate`() async throws {
        let socketPath = "/tmp/peekaboo-browser-connect-cancel-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectError = CancellationError()
        let server = Self.server(services: services)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-connect-cancel",
            teamIdentifier: nil,
            processIdentifier: getpid()))

        do {
            _ = try await client.browserConnectResult(channel: "stable")
            Issue.record("Expected conservative raw-provider cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.operation == .browserConnect)
        #expect(receipt.payload.outcome?.state == .indeterminate)
        #expect(receipt.payload.outcome?.dispatchState == .mayHaveDispatched(unitCount: nil))
        await host.stop()
    }

    @Test
    @MainActor
    func `legacy explicit URL keeps arbitrary raw provider cancellation indeterminate`() async throws {
        let socketPath = "/tmp/peekaboo-browser-legacy-connect-cancel-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectError = CancellationError()
        let server = Self.server(services: services)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-legacy-connect-cancel",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: .init(major: 1, minor: 33))
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            browserURL: "http://127.0.0.1:9333"))

        do {
            _ = try await client.send(request)
            Issue.record("Expected conservative legacy raw-provider cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(services.lastBrowserConnectTarget == nil)
    }

    @Test
    @MainActor
    func `legacy explicit URL preserves typed predispatch cancellation refusal`() async throws {
        let expected = DesktopActionFailure.preDispatchRefusal(
            reason: .requestCancelled,
            message: "connect cancelled before dispatch")
        let services = StubServices()
        services.browserConnectFailure = expected
        let server = Self.server(services: services)
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            browserURL: "http://127.0.0.1:9333"))

        do {
            _ = try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(false) {
                try await server.handleAuthorized(
                    request,
                    peer: nil,
                    permissions: Self.permissions)
            }
            Issue.record("Expected typed legacy connect cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure == expected)
        }
        #expect(services.lastBrowserConnectTarget == nil)
    }

    @Test
    @MainActor
    func `protocol 1 33 server refuses channel connect before provider entry`() async throws {
        let socketPath = "/tmp/peekaboo-browser-binding-downgrade-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
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
        let protocol133 = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-binding-downgrade",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: protocol133)
        #expect(handshake.negotiatedVersion == protocol133)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)

        do {
            _ = try await client.send(.browserConnect(.init(channel: "stable")))
            Issue.record("Expected protocol downgrade refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.lastBrowserConnectTarget == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `server route refuses protocol 1 33 channel connect before provider entry`() async throws {
        let services = StubServices()
        let server = Self.server(services: services)
        let request = PeekabooBridgeRequest.browserConnect(.init(channel: "stable"))

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await Self.route(
                request,
                server: server,
                capabilities: Self.protocol133Capabilities)
        }

        #expect(services.lastBrowserConnectTarget == nil)
    }

    @Test
    @MainActor
    func `server route refuses protocol 1 33 process bound execute before provider entry`() async throws {
        let services = StubServices()
        let server = Self.server(services: services)
        let payload = PeekabooBridgeBrowserExecuteRequest(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: services.browserConnectionReceipt)
        let request = PeekabooBridgeRequest.browserExecute(
            payload.binding(to: services.browserConnectionReceipt))

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await Self.route(
                request,
                server: server,
                capabilities: Self.protocol133Capabilities)
        }

        #expect(services.lastBrowserStatusChannel == nil)
        #expect(services.lastBrowserExecute == nil)
    }

    @Test
    @MainActor
    func `server route refuses permissive execute policy before provider entry`() async throws {
        let services = StubServices()
        let server = Self.server(services: services)
        let request = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: services.browserConnectionReceipt))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await Self.route(
                request,
                server: server,
                capabilities: .current)
        }

        #expect(services.lastBrowserStatusChannel == nil)
        #expect(services.lastBrowserExecute == nil)
    }

    @Test
    @MainActor
    func `server route permits protocol 1 33 explicit URL connect`() async throws {
        let services = StubServices()
        let receipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9333/",
            webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-b",
            devToolsBrowserID: "browser-b",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        services.browserConnectionReceipt = receipt
        let server = Self.server(services: services)
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            browserURL: "http://127.0.0.1:9333"))

        let handled = try await Self.route(
            request,
            server: server,
            capabilities: Self.protocol133Capabilities)

        guard case let .browserStatus(status) = handled.response else {
            Issue.record("Expected explicit URL browser status")
            return
        }
        #expect(status.connectionReceipt == receipt)
        #expect(services.lastBrowserConnectTarget?.browserURL == "http://127.0.0.1:9333")
    }

    @Test
    @MainActor
    func `new client refuses downgraded channel connect before provider entry`() async throws {
        let protocol133 = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let socketPath = "/tmp/peekaboo-browser-binding-client-downgrade-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
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
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-binding-old-host",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: protocol133)

        do {
            _ = try await client.browserConnectResult(channel: "stable")
            Issue.record("Expected client-side capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.lastBrowserConnectTarget == nil)
        await host.stop()
    }

    @Test(arguments: [
        PeekabooBridgeProtocolVersion(major: 1, minor: 33),
        PeekabooBridgeConstants.protocolVersion,
    ])
    @MainActor
    func `raw receiptless execute refuses before browser provider entry`(
        version: PeekabooBridgeProtocolVersion) async throws
    {
        let socketPath = "/tmp/peekaboo-browser-execute-unbound-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
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
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-execute-unbound",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        do {
            _ = try await client.send(.browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable")))
            Issue.record("Expected receiptless execute refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.outcome.dispatchState == .none)
        }

        #expect(services.lastBrowserStatusChannel == nil)
        #expect(services.lastBrowserConnectTarget == nil)
        #expect(services.lastBrowserExecute == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `raw receiptless read refuses in handler before provider entry`() async throws {
        let versions = [Self.protocol133Capabilities, PeekabooBridgeNegotiatedSessionCapabilities.current]
        let tools = ["list_pages", "take_snapshot"]

        for capabilities in versions {
            for toolName in tools {
                let services = StubServices()
                let server = Self.server(services: services)
                do {
                    _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities
                        .withValue(capabilities) {
                            try await server.handleAuthorized(
                                .browserExecute(.init(
                                    toolName: toolName,
                                    arguments: [:],
                                    channel: "stable")),
                                peer: nil,
                                permissions: Self.permissions)
                        }
                    Issue.record("Expected unbound read-only execute refusal")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome.state == .refused)
                    #expect(failure.outcome.refusalReason == .invalidRequest)
                    #expect(failure.outcome.dispatchState == .none)
                }
                #expect(services.lastBrowserStatusChannel == nil)
                #expect(services.lastBrowserExecute == nil)
            }
        }
    }

    @Test
    @MainActor
    func `protocol 1 33 executes against an explicit endpoint receipt`() async throws {
        let protocol133 = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let socketPath = "/tmp/peekaboo-browser-execute-external-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
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
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-execute-external",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: protocol133)
        let receipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            browserURL: "http://127.0.0.1:9333/",
            webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-b",
            devToolsBrowserID: "browser-b",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        services.browserConnectionReceipt = receipt

        let payload = PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: receipt)
        let response = try await client.send(.browserExecute(payload.binding(to: receipt)))

        guard case .browserToolResponse = response else {
            Issue.record("Expected explicit endpoint browser response")
            return
        }
        #expect(services.lastBrowserExecute?.expectedConnectionReceipt == receipt)
        await host.stop()
    }

    @Test
    func `legacy handshake decoder ignores native browser capability from new host`() throws {
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.browserConnect],
            hostCapabilities: [PeekabooBridgeHostCapability.nativeBrowserConnectionBinding])
        let encoded = try JSONEncoder.peekabooBridgeEncoder().encode(current)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyBrowserHandshake.self,
            from: encoded)

        #expect(decoded.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(decoded.supportedOperations == [.browserConnect])
    }

    @MainActor
    private static func server(services: StubServices) -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions })
    }

    @MainActor
    private static func route(
        _ request: PeekabooBridgeRequest,
        server: PeekabooBridgeServer,
        capabilities: PeekabooBridgeNegotiatedSessionCapabilities) async throws
        -> PeekabooBridgeHandledResponse
    {
        try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(capabilities) {
            try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                try server.validateOperationAccess(
                    for: request,
                    permissions: Self.permissions,
                    effectiveOps: [request.operation])
                return try await server.handleAuthorized(
                    request,
                    peer: nil,
                    permissions: Self.permissions)
            }
        }
    }

    private static let protocol133Capabilities = PeekabooBridgeNegotiatedSessionCapabilities(
        protocolVersion: .init(major: 1, minor: 33),
        statelessClickVariants: true,
        exactWindowHeldPointerLifecycle: true,
        nativeBrowserConnectionBinding: false)
    private static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
}

private struct LegacyBrowserHandshake: Decodable {
    let negotiatedVersion: PeekabooBridgeProtocolVersion
    let supportedOperations: [PeekabooBridgeOperation]
}
