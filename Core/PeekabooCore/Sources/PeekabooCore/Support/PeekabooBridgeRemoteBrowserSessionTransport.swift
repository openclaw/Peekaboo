import Foundation
import PeekabooAgentRuntime
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import TachikomaMCP

@MainActor
protocol PeekabooBridgeBrowserSessionClientProviding: AnyObject, Sendable {
    func browserSessionBootstrap(
        receiptBundle: PeekabooBridgeOperationReceiptBundle?,
        claimID: UUID) async throws -> PeekabooBridgeBrowserSessionBootstrapResponse
    func browserStatus(channel: String?, sessionID: UUID?) async throws -> PeekabooBridgeBrowserStatus
    func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    func browserExecuteResult(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<PeekabooBridgeBrowserToolResponse>
    func browserSessionDisconnect(_ sessionID: UUID) async throws
    func browserSessionEnd(_ sessionID: UUID) async throws
}

@MainActor
private final class PeekabooBridgeBrowserSessionClientAdapter: PeekabooBridgeBrowserSessionClientProviding,
    @unchecked Sendable
{
    private let client: PeekabooBridgeClient

    init(client: PeekabooBridgeClient) {
        self.client = client
    }

    func browserSessionBootstrap(
        receiptBundle: PeekabooBridgeOperationReceiptBundle?,
        claimID: UUID) async throws -> PeekabooBridgeBrowserSessionBootstrapResponse
    {
        try await self.client.browserSessionBootstrap(receiptBundle: receiptBundle, claimID: claimID)
    }

    func browserStatus(channel: String?, sessionID: UUID?) async throws -> PeekabooBridgeBrowserStatus {
        try await self.client.browserStatus(channel: channel, sessionID: sessionID)
    }

    func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        try await self.client.browserConnectResult(
            sessionID: sessionID,
            channel: channel,
            browserURL: browserURL)
    }

    func browserExecuteResult(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<PeekabooBridgeBrowserToolResponse>
    {
        try await self.client.browserExecuteResult(request)
    }

    func browserSessionDisconnect(_ sessionID: UUID) async throws {
        try await self.client.browserSessionDisconnect(sessionID)
    }

    func browserSessionEnd(_ sessionID: UUID) async throws {
        try await self.client.browserSessionEnd(sessionID)
    }
}

/// Production adapter from authenticated Bridge browser-session wire calls to the Agent runtime contract.
@MainActor
public final class PeekabooBridgeRemoteBrowserSessionTransport: RemoteBrowserMCPSessionTransport, @unchecked Sendable {
    private static let maximumHandoffBytes = 256 * 1024 * 1024

    private let client: any PeekabooBridgeBrowserSessionClientProviding

    public init(client: PeekabooBridgeClient) {
        self.client = PeekabooBridgeBrowserSessionClientAdapter(client: client)
    }

    init(client: any PeekabooBridgeBrowserSessionClientProviding) {
        self.client = client
    }

    public func openSession(
        handoff: BrowserMCPHandoffGrant?,
        claimID: UUID) async throws -> RemoteBrowserMCPSessionHandle
    {
        let receiptBundle = try handoff.map(Self.decodeCanonicalReceiptBundle)
        let response = try await self.mappingTerminalFailure {
            try await self.client.browserSessionBootstrap(
                receiptBundle: receiptBundle,
                claimID: claimID)
        }
        return RemoteBrowserMCPSessionHandle(
            sessionID: response.sessionID,
            targetReceiptSHA256: response.targetReceiptSHA256)
    }

    public func status(
        session: RemoteBrowserMCPSessionHandle,
        channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus
    {
        let status = try await self.mappingTerminalFailure {
            try await self.client.browserStatus(
                channel: channel?.rawValue,
                sessionID: session.sessionID)
        }
        return try RemoteBrowserMCPClient.status(from: status)
    }

    public func connectWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        let result = try await self.mappingTerminalFailure {
            try await self.client.browserConnectResult(
                sessionID: session.sessionID,
                channel: channel?.rawValue,
                browserURL: browserURL)
        }
        return try DesktopActionResult(
            payload: RemoteBrowserMCPClient.status(from: result.payload),
            outcome: result.outcome)
    }

    public func executeSequenceWithOutcome(
        session: RemoteBrowserMCPSessionHandle,
        calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        let bridgeCalls = try calls.map { call in
            try PeekabooBridgeBrowserToolCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) })
        }
        let bridgePreflight = elementPreflight.map {
            PeekabooBridgeBrowserElementPreflight(
                providerPageID: $0.providerPageID,
                providerUIDs: $0.providerUIDs.sorted())
        }
        let expectedBridgeReceipt = RemoteBrowserMCPClient.bridgeReceipt(
            from: expectedSessionBinding.connectionReceipt)
        let result = try await self.mappingTerminalFailure {
            try await self.client.browserExecuteResult(PeekabooBridgeBrowserExecuteRequest(
                calls: bridgeCalls,
                channel: channel?.rawValue,
                expectedConnectionReceipt: expectedBridgeReceipt,
                connectionPolicy: .requireExistingLiveReceipt,
                sessionID: session.sessionID,
                expectedProviderSessionEpoch: expectedSessionBinding.providerSessionEpoch.transportID,
                elementPreflight: bridgePreflight))
        }
        guard result.payload.connectionReceipt == expectedBridgeReceipt,
              result.payload.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch.transportID
        else {
            throw Self.invalidExecutionBinding(calls: calls, outcome: result.outcome)
        }
        if result.outcome == nil, let failure = result.payload.actionFailure {
            throw failure
        }
        let response = try RemoteBrowserMCPClient.toolResponse(from: result.payload)
        return DesktopActionResult(payload: response, outcome: result.outcome)
    }

    public func disconnect(session: RemoteBrowserMCPSessionHandle) async throws {
        try await self.mappingTerminalFailure {
            try await self.client.browserSessionDisconnect(session.sessionID)
        }
    }

    public func endSession(_ session: RemoteBrowserMCPSessionHandle) async throws {
        try await self.mappingTerminalFailure {
            try await self.client.browserSessionEnd(session.sessionID)
        }
    }

    private func mappingTerminalFailure<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch {
            guard let terminal = PeekabooBridgeClient.browserSessionTerminalFailure(from: error) else {
                throw error
            }
            throw switch terminal {
            case .invalidSession: RemoteBrowserMCPSessionTransportError.invalidSession
            case .sessionEnded: RemoteBrowserMCPSessionTransportError.sessionEnded
            case .wrongOwner: RemoteBrowserMCPSessionTransportError.wrongOwner
            case .hostGenerationChanged: RemoteBrowserMCPSessionTransportError.hostGenerationChanged
            }
        }
    }

    static func decodeCanonicalReceiptBundle(
        _ handoff: BrowserMCPHandoffGrant) throws -> PeekabooBridgeOperationReceiptBundle
    {
        guard !handoff.payload.isEmpty, handoff.payload.count <= self.maximumHandoffBytes else {
            throw RemoteBrowserMCPSessionError.invalidHandle
        }
        let bundle = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationReceiptBundle.self,
            from: handoff.payload)
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard try encoder.encode(bundle) == handoff.payload else {
            throw RemoteBrowserMCPSessionError.invalidHandle
        }
        try bundle.validate()
        return bundle
    }

    private static func invalidExecutionBinding(
        calls: [BrowserMCPMappedCall],
        outcome: DesktopActionOutcome?) -> any Error
    {
        let mutationCount = calls.count { call in
            BrowserToolActionSemantics.classify(toolName: call.toolName) { name in
                call.arguments[name] as? Bool
            } != .readOnly
        }
        guard let unitCount = outcome?.dispatchState.unitCount ??
            DesktopActionOutcome.DispatchUnitCount(mutationCount)
        else {
            return BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        }
        return DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: "Scoped browser execution returned a different target or provider generation.",
            hint: "Observe the browser before retrying and obtain fresh page and element references.")
    }
}
