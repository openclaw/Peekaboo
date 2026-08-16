import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct PeekabooServicesBrowserBridgeTests {
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
