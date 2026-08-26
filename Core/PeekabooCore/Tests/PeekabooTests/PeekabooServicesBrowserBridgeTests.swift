import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge
@testable import PeekabooCore

struct PeekabooServicesBrowserBridgeTests {
    @Test
    @MainActor
    func `target lock stays retry safe through Bridge remote client and Browser tool`() async throws {
        let browser = TargetLockedBrowserMCPClient()
        let services = Self.services(browser: browser)
        let socketPath = "/tmp/peekaboo-browser-target-lock-\(UUID().uuidString).sock"
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

        let bridge = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await bridge.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.browser-target-lock",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let response = try await BrowserTool(
            client: RemoteBrowserMCPClient(client: bridge),
            executionPolicy: .unrestricted,
            instructionAudience: .commandLine).execute(
            arguments: ToolArguments(raw: ["action": "connect", "channel": "canary"]))

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("refused"))
        #expect(metadata["dispatch_state"] == .string("none"))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(true))
        #expect(metadata["refusal_reason"] == .string("transport_session_unavailable"))
        #expect(metadata["escalation"] == .string("reconnect_session"))

        guard case let .text(text: text, annotations: _, _meta: _) = response.content.first else {
            Issue.record("Expected a text error response")
            return
        }
        #expect(text.contains(BrowserMCPConnectionError.targetLocked.localizedDescription))
        #expect(text.contains("Run `peekaboo browser disconnect`"))
        #expect(!text.contains("enable remote debugging"))
        #expect(browser.connectCount == 1)

        let bundle = try #require(await bridge.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.operation == .browserConnect)
        #expect(bundle.receipt.payload.outcome?.state == .refused)
        #expect(bundle.receipt.payload.outcome?.refusalReason == .transportSessionUnavailable)
        #expect(bundle.receipt.payload.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        let certifiedResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        guard case let .projectedAction(projected) = certifiedResponse,
              case let .error(envelope) = projected.response
        else {
            Issue.record("Expected the target lock refusal envelope")
            return
        }
        #expect(envelope.standardizedErrorCode == .browserTargetLocked)
        await host.stop()
    }

    @Test
    @MainActor
    func `legacy injected browser omits native binding capability and refuses channel connect`() async throws {
        let browser = AdapterBrowserMCPClient(result: .init(
            response: .text("ok"),
            connectionReceipt: Self.runtimeReceipt,
            completedCallCount: 0,
            dispatchedCallCount: 0))
        let services = Self.services(browser: browser)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let handshakeRequest = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peekaboo.legacy-browser-capability",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            requestedHostKind: .onDemand))
        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(handshakeRequest),
            peer: nil)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response")
            return
        }
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)

        let request = PeekabooBridgeRequest.browserConnect(.init(channel: "stable"))
        let capabilities = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            statelessClickVariants: true,
            exactWindowHeldPointerLifecycle: true,
            nativeBrowserConnectionBinding: false)
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(capabilities) {
                try server.validateOperationAccess(
                    for: request,
                    permissions: Self.permissions,
                    effectiveOps: [.browserConnect])
            }
        }
        #expect(browser.connectCount == 0)
    }

    @Test
    @MainActor
    func `configured nonnative browser omits capability but retains explicit endpoint connect`() async throws {
        let environments = [
            ["PEEKABOO_BROWSER_MCP_ISOLATED": "1"],
            ["PEEKABOO_BROWSER_MCP_BROWSER_URL": "http://127.0.0.1:9222"],
        ]

        for environment in environments {
            let manager = ConfiguredBrowserMCPManager()
            let session = BrowserMCPSessionManager(
                serverName: "test-browser",
                manager: manager,
                detectedBrowsers: { _ in [] },
                processStartIdentity: { _ in nil },
                endpointResolver: BrowserMCPDevToolsEndpointResolver { rawURL in
                    guard let port = URL(string: rawURL)?.port else {
                        throw BrowserMCPConnectionError.invalidEndpoint("missing fixture port")
                    }
                    return BrowserMCPDevToolsEndpoint(
                        browserURL: "http://127.0.0.1:\(port)/",
                        webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/browser-a",
                        browserID: "browser-a",
                        browserVersion: "Chrome/151.0",
                        protocolVersion: "1.3")
                },
                environment: environment)
            let browser = BrowserMCPService(sessionManager: session)
            let services = Self.services(browser: browser)
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in Self.permissions })
            let handshakeRequest = PeekabooBridgeRequest.handshake(.init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: .init(
                    bundleIdentifier: "dev.peekaboo.configured-browser-capability",
                    teamIdentifier: nil,
                    processIdentifier: getpid()),
                requestedHostKind: .onDemand))
            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(handshakeRequest),
                peer: nil)
            let response = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: responseData)
            guard case let .handshake(handshake) = response else {
                Issue.record("Expected handshake response")
                continue
            }
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)

            let capabilities = PeekabooBridgeNegotiatedSessionCapabilities(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                nativeBrowserConnectionBinding: false)
            #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                try PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(capabilities) {
                    try server.validateOperationAccess(
                        for: .browserConnect(.init(channel: "stable")),
                        permissions: Self.permissions,
                        effectiveOps: [.browserConnect])
                }
            }
            #expect(manager.addServerCount == 0)

            let explicitRequest = PeekabooBridgeRequest.browserConnect(.init(
                channel: "stable",
                browserURL: "http://127.0.0.1:9333"))
            let handled = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities
                .withValue(capabilities) {
                    try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                        try server.validateOperationAccess(
                            for: explicitRequest,
                            permissions: Self.permissions,
                            effectiveOps: [.browserConnect])
                        return try await server.handleAuthorized(
                            explicitRequest,
                            peer: nil,
                            permissions: Self.permissions)
                    }
                }
            guard case let .browserStatus(status) = handled.response else {
                Issue.record("Expected explicit endpoint status")
                continue
            }
            #expect(status.connectionReceipt?.browserURL == "http://127.0.0.1:9333/")
            #expect(manager.addServerCount == 1)
            await browser.disconnect()
        }
    }

    @Test
    @MainActor
    func `browser status preserves a lossless detected process generation`() async throws {
        let generation: UInt64 = 9_007_199_254_740_993
        let browser = AdapterBrowserMCPClient(
            result: BrowserMCPExecutionResult(
                response: .text("ok"),
                connectionReceipt: Self.runtimeReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1),
            detectedBrowsers: [
                DetectedBrowser(
                    name: "Google Chrome",
                    bundleIdentifier: "com.google.Chrome",
                    processIdentifier: 4242,
                    processStartIdentity: generation,
                    version: "151.0",
                    channel: .stable),
            ])
        let status = try await Self.services(browser: browser).browserStatus(channel: "stable")
        let detected = try #require(status.detectedBrowsers.first)

        #expect(detected.processStartIdentity == generation)
        #expect(detected.processStartIdentityDecimal == String(generation))

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(status)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeBrowserStatus.self,
            from: data)
        #expect(decoded.detectedBrowsers.first?.processStartIdentity == generation)
        #expect(decoded.detectedBrowsers.first?.processStartIdentityDecimal == String(generation))
    }

    @Test
    @MainActor
    func `browser channel parser rejects unknown present values before dispatch`() throws {
        #expect(try PeekabooServices.browserChannel(from: nil) == nil)
        #expect(try PeekabooServices.browserChannel(from: "stable") == .stable)

        do {
            _ = try PeekabooServices.browserChannel(from: "unknown")
            Issue.record("Expected an invalid browser channel to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(!failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    @MainActor
    func `read-only browser adapter atomically forwards the expected receipt without connecting`() async throws {
        let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
            response: .text("pages"),
            connectionReceipt: Self.runtimeReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 1))
        let services = Self.services(browser: browser)

        let response = try await services.browserExecute(PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.bridgeReceipt,
            connectionPolicy: .requireExistingLiveReceipt))

        #expect(!response.isError)
        #expect(response.actionFailure == nil)
        #expect(browser.expectedConnectionReceipts == [Self.runtimeReceipt])
        #expect(browser.receiptBoundDispatchCount == 1)
        #expect(browser.connectionPolicies.isEmpty)
        #expect(browser.connectCount == 0)
    }

    @Test
    @MainActor
    func `read-only browser adapter refuses a reconnected wrong profile before provider dispatch`() async throws {
        let changedReceipt = BrowserMCPConnectionReceipt(
            channel: .stable,
            browserURL: "http://127.0.0.1:9333/",
            webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-b",
            devToolsBrowserID: "browser-b",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
        let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
            response: .text("wrong-profile pages"),
            connectionReceipt: changedReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 1))
        let services = Self.services(browser: browser)

        let response = try await services.browserExecute(PeekabooBridgeBrowserExecuteRequest(
            toolName: "list_pages",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.bridgeReceipt,
            connectionPolicy: .requireExistingLiveReceipt))

        #expect(response.isError)
        #expect(response.actionFailure?.outcome.state == .refused)
        #expect(response.actionFailure?.outcome.refusalReason == .targetUnavailable)
        #expect(response.actionFailure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(browser.expectedConnectionReceipts == [Self.runtimeReceipt])
        #expect(browser.receiptBoundDispatchCount == 0)
        #expect(browser.connectCount == 0)
    }

    @Test
    @MainActor
    func `production browser adapter enriches a successful wire response exactly once`() async throws {
        let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
            response: .text("ok"),
            connectionReceipt: Self.runtimeReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 1))
        let services = Self.services(browser: browser)
        let request = PeekabooBridgeBrowserExecuteRequest(
            toolName: "click",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.bridgeReceipt)

        let adapted = try await services.browserExecute(
            request,
            expectedConnectionReceipt: Self.bridgeReceipt)
        #expect(adapted.connectionReceipt == Self.bridgeReceipt)
        #expect(adapted.completedCallCount == 1)
        #expect(adapted.dispatchedCallCount == 1)
        #expect(adapted.response.connectionReceipt == nil)
        #expect(adapted.response.completedCallCount == nil)
        #expect(adapted.response.dispatchedCallCount == nil)
        #expect(adapted.response.actionFailure == nil)

        let handled = try await Self.handleCurrent(request, services: services)
        #expect(handled.outcome?.state == .dispatchedUnverified)
        #expect(handled.outcome?.dispatchState.unitCount == .one)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected the canonical browser wire response")
            return
        }
        #expect(!response.isError)
        #expect(response.connectionReceipt == Self.bridgeReceipt)
        #expect(response.completedCallCount == 1)
        #expect(response.dispatchedCallCount == 1)
        #expect(response.actionFailure == nil)
    }

    @Test
    @MainActor
    func `production browser adapter preserves typed failure progress for wire enrichment`() async throws {
        let failure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Second browser call completion is unknown")
        let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
            response: .error("browser sequence failed"),
            connectionReceipt: Self.runtimeReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 2,
            actionFailure: failure))
        let services = Self.services(browser: browser)
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type_text", arguments: [:]),
                .init(toolName: "hover", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.bridgeReceipt)

        let adapted = try await services.browserExecute(
            request,
            expectedConnectionReceipt: Self.bridgeReceipt)
        #expect(adapted.actionFailure == failure)
        #expect(adapted.completedCallCount == 1)
        #expect(adapted.dispatchedCallCount == 2)
        #expect(adapted.response.connectionReceipt == nil)
        #expect(adapted.response.actionFailure == nil)

        let compatibilityResponse = try await services.browserExecute(request)
        #expect(compatibilityResponse.connectionReceipt == Self.bridgeReceipt)
        #expect(compatibilityResponse.completedCallCount == 1)
        #expect(compatibilityResponse.dispatchedCallCount == 2)
        #expect(compatibilityResponse.actionFailure == failure)

        let handled = try await Self.handleCurrent(request, services: services)
        #expect(handled.outcome?.state == .indeterminate)
        #expect(handled.outcome?.dispatchState.unitCount?.rawValue == 2)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected the canonical failed browser wire response")
            return
        }
        #expect(response.isError)
        #expect(response.connectionReceipt == Self.bridgeReceipt)
        #expect(response.completedCallCount == 1)
        #expect(response.dispatchedCallCount == 2)
        #expect(response.actionFailure?.outcome.route == .bridge)
        #expect(response.actionFailure?.outcome.dispatchState.unitCount?.rawValue == 2)
    }

    @Test
    @MainActor
    func `production browser adapter counts only mutations in a mixed successful batch`() async throws {
        let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
            response: .text("ok"),
            connectionReceipt: Self.runtimeReceipt,
            completedCallCount: 3,
            dispatchedCallCount: 3))
        let services = Self.services(browser: browser)
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "take_snapshot", arguments: [:]),
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "list_console_messages", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.bridgeReceipt)

        let adapted = try await services.browserExecute(
            request,
            expectedConnectionReceipt: Self.bridgeReceipt)
        #expect(adapted.completedCallCount == 1)
        #expect(adapted.dispatchedCallCount == 1)
        #expect(adapted.actionFailure == nil)

        let handled = try await Self.handleCurrent(request, services: services)
        #expect(handled.outcome?.state == .dispatchedUnverified)
        #expect(handled.outcome?.dispatchState.unitCount == .one)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected the canonical mixed browser response")
            return
        }
        #expect(response.completedCallCount == 1)
        #expect(response.dispatchedCallCount == 1)
    }

    @Test
    @MainActor
    func `production browser adapter rejects provider progress beyond the requested batch`() async throws {
        let cases: [([PeekabooBridgeBrowserToolCall], Int)] = [
            ([
                .init(toolName: "take_snapshot", arguments: [:]),
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "list_console_messages", arguments: [:]),
            ], 1),
            ([
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type_text", arguments: [:]),
            ], 2),
        ]

        for (calls, mutationCount) in cases {
            let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
                response: .text("impossible"),
                connectionReceipt: Self.runtimeReceipt,
                completedCallCount: calls.count + 1,
                dispatchedCallCount: calls.count + 1))
            let services = Self.services(browser: browser)
            let request = PeekabooBridgeBrowserExecuteRequest(
                calls: calls,
                channel: "stable",
                expectedConnectionReceipt: Self.bridgeReceipt)

            do {
                _ = try await services.browserExecute(
                    request,
                    expectedConnectionReceipt: Self.bridgeReceipt)
                Issue.record("Expected impossible browser progress to fail closed")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .indeterminate)
                #expect(failure.outcome.retrySafety == .unsafe)
                #expect(failure.outcome.dispatchState.unitCount?.rawValue == mutationCount)
            }
        }
    }

    @Test
    @MainActor
    func `production browser adapter makes a read failure before mutation retry safe`() async throws {
        let rawFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Browser read failed before click")
        let browser = AdapterBrowserMCPClient(result: BrowserMCPExecutionResult(
            response: .error("snapshot failed"),
            connectionReceipt: Self.runtimeReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 1,
            actionFailure: rawFailure))
        let services = Self.services(browser: browser)
        let request = PeekabooBridgeBrowserExecuteRequest(
            calls: [
                .init(toolName: "take_snapshot", arguments: [:]),
                .init(toolName: "click", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: Self.bridgeReceipt)

        let adapted = try await services.browserExecute(
            request,
            expectedConnectionReceipt: Self.bridgeReceipt)
        #expect(adapted.completedCallCount == 0)
        #expect(adapted.dispatchedCallCount == 0)
        #expect(adapted.actionFailure?.outcome.state == .refused)
        #expect(adapted.actionFailure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(adapted.actionFailure?.outcome.retrySafety == .safe)

        let handled = try await Self.handleCurrent(request, services: services)
        #expect(handled.outcome?.state == .refused)
        #expect(handled.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        guard case let .browserToolResponse(response) = handled.response else {
            Issue.record("Expected the canonical no-dispatch browser response")
            return
        }
        #expect(response.completedCallCount == 0)
        #expect(response.dispatchedCallCount == 0)
        #expect(response.actionFailure?.outcome.retrySafety == .safe)
    }

    @MainActor
    private static func handleCurrent(
        _ request: PeekabooBridgeBrowserExecuteRequest,
        services: PeekabooServices) async throws -> PeekabooBridgeHandledResponse
    {
        let request = if let receipt = request.expectedConnectionReceipt {
            request.binding(to: receipt)
        } else {
            request
        }
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in Self.permissions })
        return try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
            try await server.handleAuthorized(
                .browserExecute(request),
                peer: nil,
                permissions: Self.permissions)
        }
    }

    @MainActor
    private static func services(browser: any BrowserMCPClientProviding) -> PeekabooServices {
        let defaults = PeekabooServices()
        return PeekabooServices(
            logging: defaults.logging,
            screenCapture: defaults.screenCapture,
            applications: defaults.applications,
            automation: defaults.automation,
            windows: defaults.windows,
            menu: defaults.menu,
            dock: defaults.dock,
            dialogs: defaults.dialogs,
            snapshots: defaults.snapshots,
            files: defaults.files,
            clipboard: defaults.clipboard,
            permissions: defaults.permissions,
            audioInput: defaults.audioInput,
            browser: browser,
            configuration: defaults.configuration,
            screens: defaults.screens)
    }

    private static let runtimeReceipt = BrowserMCPConnectionReceipt(
        channel: .stable,
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
        devToolsBrowserID: "browser-a",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static let bridgeReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
        devToolsBrowserID: "browser-a",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static let permissions = PermissionsStatus(
        screenRecording: true,
        accessibility: true,
        postEvent: true)
}

@MainActor
private final class TargetLockedBrowserMCPClient: BrowserMCPClientProviding,
    BrowserMCPConnectionResultProviding, @unchecked Sendable
{
    nonisolated var supportsNativeBrowserConnectionBinding: Bool {
        true
    }

    private(set) var connectCount = 0

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.connectCount += 1
        throw BrowserMCPConnectionError.targetLocked
    }

    func connect(channel _: BrowserMCPChannel?, browserURL _: String?) async throws -> BrowserMCPStatus {
        self.connectCount += 1
        throw BrowserMCPConnectionError.targetLocked
    }

    func connectWithOutcome(
        channel _: BrowserMCPChannel?,
        browserURL _: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        self.connectCount += 1
        throw BrowserMCPConnectionError.targetLocked
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        .error("unexpected")
    }
}

@MainActor
private final class AdapterBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    @unchecked Sendable
{
    let result: BrowserMCPExecutionResult
    let detectedBrowsers: [DetectedBrowser]
    private(set) var connectionPolicies: [BrowserMCPExecutionConnectionPolicy] = []
    private(set) var expectedConnectionReceipts: [BrowserMCPConnectionReceipt] = []
    private(set) var receiptBoundDispatchCount = 0
    private(set) var connectCount = 0

    init(result: BrowserMCPExecutionResult, detectedBrowsers: [DetectedBrowser] = []) {
        self.result = result
        self.detectedBrowsers = detectedBrowsers
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: true,
            toolCount: 1,
            detectedBrowsers: self.detectedBrowsers,
            connectionReceipt: self.result.connectionReceipt)
    }

    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.connectCount += 1
        return await self.status(channel: channel)
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.result.response
    }

    func executeSequence(
        _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        self.expectedConnectionReceipts.append(expectedConnectionReceipt)
        guard expectedConnectionReceipt == self.result.connectionReceipt else {
            throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
        }
        self.receiptBoundDispatchCount += 1
        return self.result
    }

    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        try await self.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: .allowAutoConnect)
    }

    func executeSequenceWithOutcome(
        _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        self.connectionPolicies.append(connectionPolicy)
        return DesktopActionResult(payload: self.result.response, outcome: nil)
    }
}

@MainActor
private final class ConfiguredBrowserMCPManager: BrowserMCPManaging {
    var addServerCount = 0
    private var connected = false

    func hasServer(name _: String) -> Bool {
        self.connected
    }

    func isServerConnected(name _: String) async -> Bool {
        self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config _: MCPServerConfig) async throws {
        self.addServerCount += 1
        self.connected = true
    }

    func removeServer(name _: String) async {
        self.connected = false
    }

    func executeTool(
        serverName _: String,
        toolName _: String,
        arguments _: [String: Any]) async throws -> ToolResponse
    {
        .text("ok")
    }
}
