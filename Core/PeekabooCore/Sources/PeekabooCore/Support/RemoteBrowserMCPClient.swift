import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooBridge
import PeekabooFoundation
import TachikomaMCP

public final class RemoteBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPAtomicSessionActionProviding, BrowserMCPConnectionResultProviding,
    BrowserMCPScopedSessionOpening, BrowserMCPScopedSessionEnding, @unchecked Sendable
{
    private let client: PeekabooBridgeClient
    private let sessionTransport: (any RemoteBrowserMCPSessionTransport)?
    private let sessionHandle: RemoteBrowserMCPSessionHandle?
    @MainActor private var lastScopedStatus: BrowserMCPStatus?
    @MainActor private var scopedSessionEnded = false

    public init(
        client: PeekabooBridgeClient,
        sessionTransport: (any RemoteBrowserMCPSessionTransport)? = nil)
    {
        self.client = client
        self.sessionTransport = sessionTransport
        self.sessionHandle = nil
    }

    private init(
        client: PeekabooBridgeClient,
        sessionTransport: any RemoteBrowserMCPSessionTransport,
        sessionHandle: RemoteBrowserMCPSessionHandle)
    {
        self.client = client
        self.sessionTransport = sessionTransport
        self.sessionHandle = sessionHandle
    }

    @MainActor
    public func openBrowserMCPScopedSession(
        handoff: BrowserMCPHandoffGrant?) async throws -> any BrowserMCPClientProviding
    {
        guard self.sessionHandle == nil,
              let sessionTransport = self.sessionTransport
        else {
            throw RemoteBrowserMCPSessionError.unavailable
        }
        let handle = try await sessionTransport.openSession(
            handoff: handoff,
            claimID: UUID())
        guard handle.isCanonical,
              (handoff == nil) == (handle.targetReceiptSHA256 == nil)
        else {
            if handle.isCanonical {
                await sessionTransport.endSession(handle)
            }
            throw RemoteBrowserMCPSessionError.invalidHandle
        }
        return RemoteBrowserMCPClient(
            client: self.client,
            sessionTransport: sessionTransport,
            sessionHandle: handle)
    }

    @MainActor
    public func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus {
        if let sessionHandle, let sessionTransport {
            guard !self.scopedSessionEnded else {
                return Self.endedStatus()
            }
            do {
                let status = try await sessionTransport.status(
                    session: sessionHandle,
                    channel: channel)
                try Self.validateScopedStatus(status)
                self.lastScopedStatus = status
                return status
            } catch {
                return self.indeterminateStatus(error: error)
            }
        }
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
        if let sessionHandle, let sessionTransport {
            guard !self.scopedSessionEnded else { throw RemoteBrowserMCPSessionError.ended }
            let result = try await sessionTransport.connectWithOutcome(
                session: sessionHandle,
                channel: channel,
                browserURL: browserURL)
            try Self.validateScopedStatus(result.payload)
            self.lastScopedStatus = result.payload
            return result
        }
        do {
            let result = try await self.client.browserConnectResult(
                channel: channel?.rawValue,
                browserURL: browserURL)
            return try DesktopActionResult(
                payload: Self.status(from: result.payload),
                outcome: result.outcome)
        } catch let failure as DesktopActionFailure where Self.isBrowserTargetLockedFailure(failure) {
            throw BrowserMCPConnectionError.targetLocked
        }
    }

    @MainActor
    public func disconnect() async {
        if let sessionHandle, let sessionTransport {
            guard !self.scopedSessionEnded else { return }
            await sessionTransport.disconnect(session: sessionHandle)
            self.lastScopedStatus = Self.disconnectedStatus(
                detectedBrowsers: self.lastScopedStatus?.detectedBrowsers ?? [])
            return
        }
        try? await self.client.browserDisconnect()
    }

    @MainActor
    public func endBrowserMCPScopedSession() async {
        guard let sessionHandle, let sessionTransport, !self.scopedSessionEnded else { return }
        self.scopedSessionEnded = true
        self.lastScopedStatus = nil
        await sessionTransport.endSession(sessionHandle)
    }

    @MainActor
    public func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        if self.sessionHandle != nil {
            throw Self.scopedAtomicExecutionRequired()
        }
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
        if self.sessionHandle != nil {
            return try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                connectionPolicy: .requireExistingLiveReceipt).payload
        }
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
        if self.sessionHandle != nil {
            let status = await self.status(channel: channel)
            guard status.connectionReceipt != nil,
                  status.providerSessionEpoch != nil,
                  let binding = Self.sessionBinding(from: status)
            else {
                throw Self.existingScopedConnectionRequired()
            }
            return try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                expectedSessionBinding: binding,
                elementPreflight: nil)
        }
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

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        guard let sessionHandle, let sessionTransport else {
            throw Self.scopedAtomicExecutionRequired()
        }
        guard !self.scopedSessionEnded else { throw RemoteBrowserMCPSessionError.ended }
        guard let status = self.lastScopedStatus,
              status.connectionReceipt == expectedSessionBinding.connectionReceipt,
              status.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "The exact remote browser provider session changed before tool dispatch.",
                hint: "Refresh browser status and obtain fresh page and element references.")
        }
        return try await sessionTransport.executeSequenceWithOutcome(
            session: sessionHandle,
            calls: calls,
            channel: channel,
            expectedSessionBinding: expectedSessionBinding,
            elementPreflight: elementPreflight)
    }

    @MainActor
    private func indeterminateStatus(error: any Error) -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: self.lastScopedStatus?.detectedBrowsers ?? [],
            connectionReceipt: self.lastScopedStatus?.connectionReceipt,
            providerSessionEpoch: self.lastScopedStatus?.providerSessionEpoch,
            error: error.localizedDescription,
            observation: .indeterminate)
    }

    private static func validateScopedStatus(_ status: BrowserMCPStatus) throws {
        guard (status.connectionReceipt == nil) == (status.providerSessionEpoch == nil) else {
            throw RemoteBrowserMCPSessionError.invalidStatus
        }
        switch status.observation {
        case .confirmed:
            guard status.isConnected == (status.connectionReceipt != nil) else {
                throw RemoteBrowserMCPSessionError.invalidStatus
            }
        case .indeterminate:
            guard !status.isConnected, status.toolCount == 0 else {
                throw RemoteBrowserMCPSessionError.invalidStatus
            }
        }
    }

    private static func sessionBinding(from status: BrowserMCPStatus) -> BrowserMCPExecutionSessionBinding? {
        guard let connectionReceipt = status.connectionReceipt,
              let providerSessionEpoch = status.providerSessionEpoch
        else { return nil }
        return BrowserMCPExecutionSessionBinding(
            connectionReceipt: connectionReceipt,
            providerSessionEpoch: providerSessionEpoch)
    }

    private static func disconnectedStatus(detectedBrowsers: [DetectedBrowser]) -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: detectedBrowsers)
    }

    private static func endedStatus() -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [],
            error: RemoteBrowserMCPSessionError.ended.localizedDescription)
    }

    private static func scopedAtomicExecutionRequired() -> DesktopActionFailure {
        .preDispatchRefusal(
            route: .bridge,
            reason: .operationUnsupported,
            message: "Caller-scoped remote browser execution requires an exact provider epoch.",
            hint: "Open an authenticated browser session and retry through its capability-bound client.")
    }

    private static func existingScopedConnectionRequired() -> DesktopActionFailure {
        .preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser execution requires an existing caller-scoped connection.",
            hint: "Connect this exact foreground-authorized session or provide a valid handoff when it opens.")
    }

    private static func status(from bridgeStatus: PeekabooBridgeBrowserStatus) throws -> BrowserMCPStatus {
        let detectedBrowsers = try bridgeStatus.detectedBrowsers.map { browser in
            guard let channel = BrowserMCPChannel(rawValue: browser.channel),
                  let identity = ChromeChannelIdentity(rawValue: channel.rawValue),
                  identity.matches(bundleIdentifier: browser.bundleIdentifier)
            else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Bridge reported a browser with a noncanonical channel bundle")
            }
            return DetectedBrowser(
                name: browser.name,
                bundleIdentifier: identity.bundleIdentifier,
                processIdentifier: browser.processIdentifier,
                processStartIdentity: browser.processStartIdentity,
                version: browser.version,
                channel: channel)
        }
        let connectionReceipt = try bridgeStatus.connectionReceipt.map { receipt in
            guard receipt.isCanonicalTarget else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Bridge reported a noncanonical browser connection receipt")
            }
            return Self.runtimeReceipt(from: receipt)
        }
        return BrowserMCPStatus(
            isConnected: bridgeStatus.isConnected,
            toolCount: bridgeStatus.toolCount,
            detectedBrowsers: detectedBrowsers,
            connectionReceipt: connectionReceipt,
            error: bridgeStatus.error)
    }

    private static func isBrowserTargetLockedFailure(_ failure: DesktopActionFailure) -> Bool {
        failure.standardErrorCode == .browserTargetLocked &&
            failure.outcome.state == .refused &&
            failure.outcome.refusalReason == .transportSessionUnavailable &&
            failure.outcome.dispatchState == .none &&
            failure.outcome.retrySafety == .safe
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
