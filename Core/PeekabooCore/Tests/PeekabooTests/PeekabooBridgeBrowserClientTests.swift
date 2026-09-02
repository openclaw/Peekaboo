import Darwin
import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooBridgeTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge
@testable import PeekabooCore

extension PeekabooBridgeBrowserClientTests {
    @Test(arguments: [false, true])
    @MainActor
    func `unscoped status distinguishes confirmed absence from transport timeout`(timesOut: Bool) async throws {
        let version = Self.legacyBrowserConnectVersion
        let peer = try ScriptedBridgePeer(scripts: [
            [.respond(.handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserStatus])))],
            timesOut ? [.idle(seconds: 0.3)] : [.respond(.browserStatus(.init(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: [])))],
        ], socketPathPrefix: "pr660-status")
        let bridge = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.1)
        _ = try await bridge.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.status-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()), protocolVersion: version)
        let client = RemoteBrowserMCPClient(client: bridge)
        let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
            arguments: ToolArguments(raw: ["action": "status"]))
        let text = response.content.compactMap { item -> String? in
            guard case let .text(value, _, _) = item else { return nil }
            return value
        }.joined(separator: "\n")
        let meta = try #require(response.meta?.objectValue)
        #expect(!response.isError)
        #expect(meta["status_observation"] == .string(timesOut ? "indeterminate" : "confirmed"))
        #expect(meta["connected"] == (timesOut ? .null : .bool(false)))
        #expect(meta["tool_count"] == (timesOut ? .null : .int(0)))
        #expect(meta["browser_count"] == (timesOut ? .null : .int(0)))
        #expect(meta["channels"] == (timesOut ? .null : .array([])))
        #expect(text.contains(timesOut ? "Connected: unknown" : "Connected: no"))
        #expect(text.contains(timesOut ? "Tools: unknown" : "Tools: 0"))
        #expect(text.contains(timesOut ? "Detected Chrome: unknown" : "Detected Chrome: none"))
        #expect(text.contains("To enable browser control:") == !timesOut)
        #expect(text.contains("Error:") == timesOut)
        if timesOut {
            #expect(text.contains(POSIXError(.ETIMEDOUT).localizedDescription))
        }
        #expect(meta["mutation_dispatched"] == nil)
        await peer.waitUntilFinished()
        let requests = await peer.requests
        #expect(requests.count == 2)
        for data in requests.dropFirst() {
            let request = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: data)
            #expect(request.operation == .browserStatus)
        }
    }

    @Test(arguments: [false, true])
    @MainActor
    func `unattributed connect preserves bounded typed diagnostics and unsafe outcome`(longCause: Bool) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pr660-connect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        let services = StubServices(snapshots: InMemorySnapshotManager(desktopMutationWatermarkStore: store))
        let original = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Browser connection completion is unknown after the provider accepted the request.",
            hint: "Check browser status before deciding whether to reconnect.",
            causeDescription: "Fixture approval deadline elapsed." +
                (longCause ? String(repeating: "x", count: 5000) : ""))
        services.browserConnectError = PeekabooBridgeErrorEnvelope(
            code: .internalError,
            actionFailure: original,
            details: "RAW-DIAGNOSTIC-NOT-FOR-PROJECTION")
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            desktopMutationWatermarkStore: store,
            desktopOperationLaneCoordinator: DesktopOperationLaneCoordinator(
                coordinationRootURL: root.appendingPathComponent("coordination")),
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
        // Keep the Unix-socket pathname below the platform limit; all persistent fixture state is owned above.
        let socketPath = "/tmp/pr660-connect-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        do {
            let bridge = TrustedBridgeClientFixture.make(
                socketPath: socketPath,
                operationReceiptExportDirectory: root.appendingPathComponent("receipts"))
            _ = try await bridge.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.connect-diagnostic-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()))
            let client = RemoteBrowserMCPClient(client: bridge)
            let response = try await BrowserTool(client: client, executionPolicy: .unrestricted).execute(
                arguments: ToolArguments(raw: ["action": "connect", "channel": "stable"]))
            #expect(response.isError)
            let text = response.content.compactMap { item -> String? in
                guard case let .text(value, _, _) = item else { return nil }
                return value
            }.joined(separator: "\n")
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("indeterminate"))
            #expect(meta["dispatch_state"] == .string("may_have_dispatched"))
            #expect(meta["dispatched_unit_count"] == .int(1))
            #expect(meta["retry_safe"] == .bool(false))
            let bundle = try #require(await bridge.lastOperationReceiptBundle())
            let canonicalResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self, from: bundle.canonicalResponse)
            guard case let .projectedAction(projected) = canonicalResponse,
                  case let .error(envelope) = projected.response
            else {
                Issue.record("Expected a projected attribution failure in the verified receipt bundle")
                await host.stop()
                return
            }
            let failure = try #require(envelope.desktopActionFailure)
            #expect(failure.message == "Bridge operation completed without a trustworthy exact target receipt.")
            let cause = try #require(failure.causeDescription)
            #expect(cause.contains(original.message))
            #expect(cause.contains("Fixture approval deadline elapsed."))
            #expect(cause.contains(DesktopTargetIdentityError.incompleteExactWindow.localizedDescription))
            #expect(!cause.contains("RAW-DIAGNOSTIC-NOT-FOR-PROJECTION"))
            #expect(text.contains(cause))
            #expect(envelope.details == nil)
            #expect(envelope.operationMayHaveCompleted)
            #expect(cause.count < 2500)
            #expect(failure.outcome == original.outcome.routed(to: .bridge))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == nil)
            #expect(failure.selectedLeafEvidence == nil)
            let receipt = bundle.receipt
            #expect(receipt.payload.target == nil)
            #expect(receipt.payload.targetAttributionFailure?.code == .incompleteExactWindow)
            #expect(receipt.payload.targetAttributionFailure?.stage == .postExecution)
            #expect(receipt.payload.outcome == failure.outcome.projection)
            #expect(services.browserConnectResultCallCount == 1)
            #expect(services.lastBrowserStatusChannel == nil)
            #expect(services.lastBrowserExecute == nil)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }
}

struct PeekabooBridgeBrowserClientTests {
    @Test
    func `legacy browser status info decodes without a process generation`() throws {
        let legacyJSON = Data(#"""
        {
            "name":"Google Chrome",
            "bundleIdentifier":"com.google.Chrome",
            "processIdentifier":4242,
            "version":"150.0",
            "channel":"stable"
        }
        """#.utf8)
        let browser = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeBrowserInfo.self,
            from: legacyJSON)

        #expect(browser.processStartIdentity == nil)
        #expect(browser.processStartIdentityDecimal == nil)
    }

    @Test
    @MainActor
    func `remote browser status preserves a detected process generation`() async throws {
        let protocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let generation: UInt64 = 9_007_199_254_740_993
        let expected = PeekabooBridgeBrowserStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [
                PeekabooBridgeBrowserInfo(
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 4242,
                    processStartIdentity: generation,
                    version: "151.0",
                    channel: "stable"),
            ])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: protocolVersion,
                supportedOperations: [.browserStatus])),
            .browserStatus(expected),
        ])
        let bridge = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await bridge.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: protocolVersion)
        let client = RemoteBrowserMCPClient(client: bridge)

        let status = await client.status(channel: .stable)

        #expect(status.error == nil)
        #expect(status.detectedBrowsers.first?.processStartIdentity == generation)
        await peer.waitUntilFinished()
    }

    @Test
    func `protocol 1_28 browser response decodes without receipt or progress fields`() throws {
        let legacyJSON = Data(#"{"content":[],"isError":false,"meta":null}"#.utf8)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeBrowserToolResponse.self,
            from: legacyJSON)

        #expect(response.connectionReceipt == nil)
        #expect(response.completedCallCount == nil)
        #expect(response.dispatchedCallCount == nil)
        #expect(response.actionFailure == nil)
    }

    @Test(arguments: [
        PeekabooBridgeProtocolVersion(major: 1, minor: 23),
        PeekabooBridgeProtocolVersion(major: 1, minor: 28),
    ])
    func `receipt bound legacy browser mutation keeps direct response behavior`(
        version: PeekabooBridgeProtocolVersion) async throws
    {
        let expected = PeekabooBridgeBrowserToolResponse(
            content: [.object([
                "type": .string("text"),
                "text": .string("clicked"),
            ])],
            isError: false,
            meta: nil)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserExecute],
                hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])),
            .browserToolResponse(expected),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        let response = try await client.browserExecute(.init(
            toolName: "click",
            arguments: ["uid": PeekabooBridgeJSONValue.string("7_1")],
            channel: "stable",
            expectedConnectionReceipt: Self.browserReceipt))

        #expect(response == expected)
        await peer.waitUntilFinished()
        let requests = await peer.requests
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        let wireRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[1])
        guard case let .browserExecute(browserRequest) = wireRequest else {
            Issue.record("Expected a direct legacy browser request")
            return
        }
        #expect(browserRequest.expectedConnectionReceipt == Self.browserReceipt)
        #expect(browserRequest.connectionPolicy == .requireExistingLiveReceipt)
    }

    @Test
    func `protocol 1_28 browser tool error remains a structured response`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let expected = PeekabooBridgeBrowserToolResponse(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string("fixture rejected input"),
                ]),
            ],
            isError: true,
            meta: nil)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserExecute])),
            .browserToolResponse(expected),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        let response = try await client.browserExecute(.init(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.browserReceipt))

        #expect(response == expected)
        await peer.waitUntilFinished()
    }

    @Test
    func `browser client rethrows exact typed batch failure`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let expected = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "second browser call completion unknown",
            hint: "observe before resuming",
            causeDescription: "fixture transport failure")
        let response = PeekabooBridgeBrowserToolResponse(
            content: [],
            isError: true,
            meta: nil,
            connectionReceipt: Self.browserReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 2,
            actionFailure: expected)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserExecute])),
            .browserToolResponse(response),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        do {
            _ = try await client.browserExecute(.init(
                toolName: "click",
                arguments: [:],
                channel: "stable",
                expectedConnectionReceipt: Self.browserReceipt))
            Issue.record("Expected the typed browser batch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure == expected)
        }
        await peer.waitUntilFinished()
    }

    @Test(arguments: [
        PeekabooBridgeProtocolVersion(major: 1, minor: 23),
        PeekabooBridgeProtocolVersion(major: 1, minor: 28),
    ])
    func `receiptless result aware browser mutation refuses before transport`(
        version: PeekabooBridgeProtocolVersion) async throws
    {
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserExecute],
                hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        do {
            _ = try await client.browserExecuteResult(.init(
                toolName: "click",
                arguments: ["uid": PeekabooBridgeJSONValue.string("7_1")],
                channel: "stable",
                expectedConnectionReceipt: Self.browserReceipt))
            Issue.record("Expected result-aware receiptless mutation to refuse before transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .operationUnsupported)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }

        await peer.waitUntilFinished()
        #expect(await peer.requests.count == 1)
    }

    @Test(arguments: [
        PeekabooBridgeProtocolVersion(major: 1, minor: 23),
        PeekabooBridgeProtocolVersion(major: 1, minor: 28),
    ])
    func `receiptless result aware browser read refuses without live status receipt`(
        version: PeekabooBridgeProtocolVersion) async throws
    {
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserStatus, .browserExecute],
                hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])),
            .browserStatus(.init(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: [])),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)

        do {
            _ = try await client.browserExecuteResult(.init(
                toolName: "list_pages",
                arguments: [:],
                channel: "stable"))
            Issue.record("Expected missing live receipt refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }
        await peer.waitUntilFinished()
        let requests = await peer.requests
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        let wireRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[1])
        guard case .browserStatus = wireRequest else {
            Issue.record("Expected only a browser status request")
            return
        }
    }

    @Test
    @MainActor
    func `current client binds result reads and legacy mutations to exact receipts`() async throws {
        let socketPath = "/tmp/peekaboo-current-browser-routing-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectionReceipt = Self.browserReceipt
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
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.current-browser-routing-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.operationAttestation != nil)

        let read = try await client.browserExecuteResult(.init(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable"))
        #expect(read.outcome == nil)
        #expect(!read.payload.isError)
        #expect(read.payload.connectionReceipt == Self.browserReceipt)
        #expect(read.payload.completedCallCount == 1)
        #expect(read.payload.dispatchedCallCount == 1)
        #expect(services.lastExpectedBrowserConnectionReceipt == Self.browserReceipt)
        #expect(services.lastBrowserExecute?.expectedConnectionReceipt == Self.browserReceipt)
        #expect(services.lastBrowserExecute?.connectionPolicy == .requireExistingLiveReceipt)

        let mutation = try await client.browserExecute(.init(
            toolName: "click",
            arguments: ["uid": .string("7_1")],
            channel: "stable"))
        #expect(!mutation.isError)
        #expect(services.lastExpectedBrowserConnectionReceipt == Self.browserReceipt)
        await host.stop()
    }

    @Test
    @MainActor
    func `remote browser client carries projected outcome with decoded provider response`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let socketPath = "/tmp/peekaboo-remote-browser-result-\(UUID().uuidString).sock"
        let services = StubServices()
        services.browserConnectionReceipt = Self.browserReceipt
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

        let bridge = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await bridge.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-client-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.operationAttestation != nil)
        let client = RemoteBrowserMCPClient(client: bridge)

        let result = try await client.executeSequenceWithOutcome(
            [
                BrowserMCPMappedCall(toolName: "click", arguments: [:]),
                BrowserMCPMappedCall(toolName: "type_text", arguments: [:]),
            ],
            channel: .stable)

        #expect(result.outcome == outcome)
        #expect(!result.payload.isError)
        guard case let .text(text, _, _) = result.payload.content.first else {
            Issue.record("Expected the decoded provider text response")
            return
        }
        #expect(text == "ok")
        #expect(services.lastExpectedBrowserConnectionReceipt == Self.browserReceipt)
        await host.stop()
    }

    @Test
    @MainActor
    func `current remote browser connect carries signed foreground outcome and target receipt`() async throws {
        let socketPath = "/tmp/peekaboo-remote-browser-connect-\(UUID().uuidString).sock"
        let services = StubServices()
        let processIdentifier = getpid()
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(processIdentifier))
        let processReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.google.Chrome",
            browserURL: "http://127.0.0.1:9222",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/fixture",
            devToolsBrowserID: "fixture",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        services.browserConnectionReceipt = processReceipt
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

        let bridge = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await bridge.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-connect-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.operationAttestation != nil)
        let client = RemoteBrowserMCPClient(client: bridge)

        let result = try await client.connectWithOutcome(channel: .stable, browserURL: nil)

        #expect(result.payload.isConnected)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.route == .bridge)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        let receipt = try #require(await bridge.lastOperationReceipt())
        #expect(receipt.payload.operation == .browserConnect)
        #expect(receipt.payload.target == .process(.init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)))
        #expect(result.payload.connectionReceipt?.webSocketDebuggerURL ==
            processReceipt.webSocketDebuggerURL)
        await host.stop()
    }

    @Test
    @MainActor
    func `legacy remote browser connect is explicit conservative and receiptless`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserConnect])),
            .browserStatus(PeekabooBridgeBrowserStatus(
                isConnected: true,
                toolCount: 29,
                detectedBrowsers: [],
                connectionReceipt: Self.browserReceipt)),
        ])
        let bridge = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await bridge.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)
        let client = RemoteBrowserMCPClient(client: bridge)

        let result = try await client.connectWithOutcome(
            channel: .stable,
            browserURL: "http://127.0.0.1:9222")

        #expect(result.payload.isConnected)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.route == .bridge)
        #expect(result.outcome?.delivery == .init(mechanism: .browserProtocol, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(await bridge.lastOperationReceipt() == nil)
        await peer.waitUntilFinished()
    }

    @Test
    func `browser connect transport outlives the ordinary request timeout for Chrome approval`() async throws {
        let peer = try ScriptedBridgePeer(scripts: [
            [.respond(Self.legacyBrowserConnectHandshake)],
            [
                .delay(seconds: 0.1),
                .respond(.browserStatus(PeekabooBridgeBrowserStatus(
                    isConnected: true,
                    toolCount: 29,
                    detectedBrowsers: [],
                    connectionReceipt: Self.browserReceipt))),
            ],
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 0.05)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: Self.legacyBrowserConnectVersion)

        let status = try await client.browserConnect(
            channel: "stable",
            browserURL: "http://127.0.0.1:9222")

        #expect(status.isConnected)
        #expect(BrowserConnectionTiming.bridgeTransportTimeoutSeconds == 95)
        await peer.waitUntilFinished()
    }

    @Test
    func `legacy result connect refuses before transport without a handshake`() async throws {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/missing-browser-connect-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)

        do {
            _ = try await client.browserConnectResult(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222")
            Issue.record("Expected missing handshake to refuse before browser transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
            #expect(failure.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    func `legacy result connect preserves caller cancellation before transport`() async throws {
        let peer = try ScriptedBridgePeer(responses: [Self.legacyBrowserConnectHandshake])
        let client = try await Self.legacyBrowserConnectClient(peer)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.browserConnectResult(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222")
        }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        await peer.waitUntilFinished()
        #expect(await peer.acceptedConnectionCount == 1)
    }

    @Test
    func `legacy result connect preserves typed predispatch refusal`() async throws {
        let expected = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser target is unavailable",
            hint: "Reconnect the selected browser.")
        let peer = try ScriptedBridgePeer(responses: [
            Self.legacyBrowserConnectHandshake,
            .error(.init(code: .serverBusy, actionFailure: expected)),
        ])
        let client = try await Self.legacyBrowserConnectClient(peer)

        do {
            _ = try await client.browserConnectResult(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222")
            Issue.record("Expected typed browser preparation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == expected.outcome)
            #expect(failure.message == expected.message)
            #expect(failure.hint == expected.hint)
        }

        await peer.waitUntilFinished()
    }

    @Test
    func `legacy result connect preserves postdispatch response loss`() async throws {
        let peer = try ScriptedBridgePeer(scripts: [
            [.respond(Self.legacyBrowserConnectHandshake)],
            [.close],
        ])
        let client = try await Self.legacyBrowserConnectClient(peer)

        do {
            _ = try await client.browserConnectResult(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222")
            Issue.record("Expected browser response loss")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.outcome.retrySafety == .unsafe)
        }

        await peer.waitUntilFinished()
    }

    @Test
    func `legacy result connect preserves unexpected response as response loss`() async throws {
        let peer = try ScriptedBridgePeer(responses: [
            Self.legacyBrowserConnectHandshake,
            .ok,
        ])
        let client = try await Self.legacyBrowserConnectClient(peer)

        do {
            _ = try await client.browserConnectResult(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222")
            Issue.record("Expected unexpected browser response to be treated as response loss")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.delivery == nil)
            #expect(failure.outcome.dispatchState.unitCount == nil)
        }

        await peer.waitUntilFinished()
    }

    @Test
    @MainActor
    func `remote existing receipt policy refuses receiptless host before browser execution`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserStatus, .browserExecute])),
            .browserStatus(PeekabooBridgeBrowserStatus(
                isConnected: true,
                toolCount: 29,
                detectedBrowsers: [],
                connectionReceipt: nil)),
        ])
        let bridge = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await bridge.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)
        let client = RemoteBrowserMCPClient(client: bridge)

        do {
            _ = try await client.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
                channel: .stable,
                connectionPolicy: .requireExistingLiveReceipt)
            Issue.record("Expected a receiptless remote browser host to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }

        await peer.waitUntilFinished()
        let requests = await peer.requests
        #expect(requests.count == 2)
        guard requests.count == 2 else { return }
        let statusRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[1])
        guard case .browserStatus = statusRequest else {
            Issue.record("Expected only a browser status preflight")
            return
        }
    }

    @Test
    @MainActor
    func `remote existing receipt policy preserves preconnected read and its wire requirement`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let expected = PeekabooBridgeBrowserToolResponse(
            content: [.object([
                "type": .string("text"),
                "text": .string("pages"),
            ])],
            isError: false,
            meta: nil)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.browserStatus, .browserExecute])),
            .browserStatus(PeekabooBridgeBrowserStatus(
                isConnected: true,
                toolCount: 29,
                detectedBrowsers: [],
                connectionReceipt: Self.browserReceipt)),
            .browserToolResponse(expected),
        ])
        let bridge = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await bridge.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: version)
        let client = RemoteBrowserMCPClient(client: bridge)

        let result = try await client.executeSequenceWithOutcome(
            [BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])],
            channel: .stable,
            connectionPolicy: .requireExistingLiveReceipt)

        #expect(result.outcome == nil)
        #expect(!result.payload.isError)
        guard case let .text(text, _, _) = result.payload.content.first else {
            Issue.record("Expected the legacy browser read response payload")
            return
        }
        #expect(text == "pages")
        await peer.waitUntilFinished()
        let requests = await peer.requests
        #expect(requests.count == 3)
        guard requests.count == 3 else { return }
        let wireRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[2])
        guard case let .browserExecute(browserRequest) = wireRequest else {
            Issue.record("Expected a browser execution after the status preflight")
            return
        }
        #expect(browserRequest.connectionPolicy == .requireExistingLiveReceipt)
        #expect(browserRequest.expectedConnectionReceipt == Self.browserReceipt)
    }

    @Test(arguments: ["status", "connect", "execute"])
    func `browser client preserves structured Bridge errors`(operation: String) async throws {
        let expected = PeekabooBridgeErrorEnvelope(
            code: .operationNotSupported,
            message: "browser backend unavailable",
            details: "npx is not available to this host")
        let receiptlessVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: receiptlessVersion,
            supportedOperations: [.browserStatus, .browserConnect, .browserExecute])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .error(expected),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: receiptlessVersion)

        do {
            switch operation {
            case "status":
                _ = try await client.browserStatus(channel: "stable")
            case "connect":
                _ = try await client.browserConnect(
                    channel: "stable",
                    browserURL: "http://127.0.0.1:9222")
            case "execute":
                _ = try await client.browserExecute(.init(
                    toolName: "list_pages",
                    arguments: [:],
                    channel: "stable"))
            default:
                Issue.record("Unknown test operation")
            }
            Issue.record("Expected the structured browser error")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == expected.code)
            #expect(envelope.message == expected.message)
            #expect(envelope.details == expected.details)
        }
        await peer.waitUntilFinished()
    }

    static let browserReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9222",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/fixture",
        devToolsBrowserID: "fixture",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static let legacyBrowserConnectVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
    private static let legacyBrowserConnectHandshake = PeekabooBridgeResponse.handshake(BridgeTestFixtures.handshake(
        negotiatedVersion: Self.legacyBrowserConnectVersion,
        supportedOperations: [.browserConnect]))

    private static func legacyBrowserConnectClient(
        _ peer: ScriptedBridgePeer) async throws -> PeekabooBridgeClient
    {
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: self.legacyBrowserConnectVersion)
        return client
    }
}

extension StubServices: PeekabooBridgeBrowserConnectionResultProviding {
    var supportsNativeBrowserConnectionBinding: Bool {
        true
    }

    func browserConnectResult(
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        self.browserConnectResultCallCount += 1
        if let browserConnectError {
            throw browserConnectError
        }
        if let browserConnectFailure {
            throw browserConnectFailure
        }
        return try await DesktopActionResult(
            payload: self.browserConnect(channel: channel, browserURL: browserURL),
            outcome: self.browserConnectOutcome)
    }
}
