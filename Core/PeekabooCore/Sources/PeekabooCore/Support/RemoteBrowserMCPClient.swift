import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooBridge
import PeekabooFoundation
import TachikomaMCP

public final class RemoteBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPConnectionResultProviding, @unchecked Sendable
{
    private let client: PeekabooBridgeClient

    public init(client: PeekabooBridgeClient) {
        self.client = client
    }

    @MainActor
    public func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus {
        do {
            return try await Self.status(from: self.client.browserStatus(channel: channel?.rawValue))
        } catch {
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: [],
                error: error.localizedDescription)
        }
    }

    @MainActor
    public func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        try await self.connect(channel: channel, browserURL: nil)
    }

    @MainActor
    public func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus {
        try await self.connectWithOutcome(channel: channel, browserURL: browserURL).payload
    }

    @MainActor
    public func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        let result = try await self.client.browserConnectResult(
            channel: channel?.rawValue,
            browserURL: browserURL)
        return DesktopActionResult(
            payload: Self.status(from: result.payload),
            outcome: result.outcome)
    }

    @MainActor
    public func disconnect() async {
        try? await self.client.browserDisconnect()
    }

    @MainActor
    public func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let request = try PeekabooBridgeBrowserExecuteRequest(
            toolName: toolName,
            arguments: arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) },
            channel: channel?.rawValue)
        let response = try await self.client.browserExecute(request)
        return try Self.toolResponse(from: response)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let bridgeCalls = try calls.map { call in
            try PeekabooBridgeBrowserToolCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) })
        }
        let response = try await self.client.browserExecute(PeekabooBridgeBrowserExecuteRequest(
            calls: bridgeCalls,
            channel: channel?.rawValue))
        return try Self.toolResponse(from: response)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        try await self.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: .allowAutoConnect)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        let bridgeCalls = try calls.map { call in
            try PeekabooBridgeBrowserToolCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) })
        }
        let expectedReceipt: PeekabooBridgeBrowserConnectionReceipt?
        let bridgeConnectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy?
        switch connectionPolicy {
        case .allowAutoConnect:
            expectedReceipt = nil
            bridgeConnectionPolicy = nil
        case .requireExistingLiveReceipt:
            let status = await self.status(channel: channel)
            guard status.isConnected, let receipt = status.connectionReceipt else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .targetUnavailable,
                    message: "Browser execution requires an existing live exact connection receipt.",
                    hint: "Connect the intended browser explicitly and retry.")
            }
            expectedReceipt = Self.bridgeReceipt(from: receipt)
            bridgeConnectionPolicy = .requireExistingLiveReceipt
        }
        let result = try await self.client.browserExecuteResult(PeekabooBridgeBrowserExecuteRequest(
            calls: bridgeCalls,
            channel: channel?.rawValue,
            expectedConnectionReceipt: expectedReceipt,
            connectionPolicy: bridgeConnectionPolicy))
        if result.outcome == nil, let failure = result.payload.actionFailure {
            throw failure
        }
        let response = try Self.toolResponse(from: result.payload)
        return DesktopActionResult(payload: response, outcome: result.outcome)
    }

    private static func status(from bridgeStatus: PeekabooBridgeBrowserStatus) -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: bridgeStatus.isConnected,
            toolCount: bridgeStatus.toolCount,
            detectedBrowsers: bridgeStatus.detectedBrowsers.compactMap { browser in
                guard let channel = BrowserMCPChannel(rawValue: browser.channel) else { return nil }
                return DetectedBrowser(
                    name: browser.name,
                    bundleIdentifier: browser.bundleIdentifier,
                    processIdentifier: browser.processIdentifier,
                    processStartIdentity: browser.processStartIdentity,
                    version: browser.version,
                    channel: channel)
            },
            connectionReceipt: bridgeStatus.connectionReceipt.map { receipt in
                BrowserMCPConnectionReceipt(
                    channel: receipt.channel.flatMap(BrowserMCPChannel.init(rawValue:)),
                    processIdentifier: receipt.processIdentifier,
                    processStartIdentity: receipt.processStartIdentity,
                    bundleIdentifier: receipt.bundleIdentifier,
                    browserURL: receipt.browserURL,
                    webSocketDebuggerURL: receipt.webSocketDebuggerURL,
                    devToolsBrowserID: receipt.devToolsBrowserID,
                    browserVersion: receipt.browserVersion,
                    protocolVersion: receipt.protocolVersion)
            },
            error: bridgeStatus.error)
    }

    private static func bridgeReceipt(
        from receipt: BrowserMCPConnectionReceipt) -> PeekabooBridgeBrowserConnectionReceipt
    {
        PeekabooBridgeBrowserConnectionReceipt(
            channel: receipt.channel?.rawValue,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func toolResponse(from bridgeResponse: PeekabooBridgeBrowserToolResponse) throws -> ToolResponse {
        let content: [MCP.Tool.Content] = try bridgeResponse.content.map { value in
            try self.decode(MCP.Tool.Content.self, from: value)
        }
        let meta: Value? = try bridgeResponse.meta.map { try self.decode(Value.self, from: $0) }
        let response = ToolResponse(content: content, isError: bridgeResponse.isError, meta: meta)
        guard let receipt = bridgeResponse.connectionReceipt,
              let completedCallCount = bridgeResponse.completedCallCount,
              let dispatchedCallCount = bridgeResponse.dispatchedCallCount
        else {
            return response
        }
        return BrowserMCPExecutionEvidence.attaching(
            to: response,
            connectionReceipt: Self.runtimeReceipt(from: receipt),
            completedCallCount: completedCallCount,
            dispatchedCallCount: dispatchedCallCount)
    }

    private static func runtimeReceipt(
        from receipt: PeekabooBridgeBrowserConnectionReceipt) -> BrowserMCPConnectionReceipt
    {
        BrowserMCPConnectionReceipt(
            channel: receipt.channel.flatMap(BrowserMCPChannel.init(rawValue:)),
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: PeekabooBridgeJSONValue) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value.toAny(), options: [])
        return try JSONDecoder().decode(type, from: data)
    }
}
