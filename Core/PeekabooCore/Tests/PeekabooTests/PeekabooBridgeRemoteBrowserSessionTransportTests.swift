import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
struct PeekabooBridgeRemoteBrowserSessionTransportTests {
    @Test
    func `adapter decodes only canonical handoff bundles and maps opaque handle`() async throws {
        let bundle = try await Self.handoffBundle()
        let data = try Self.canonicalData(bundle)
        let client = RecordingBridgeBrowserSessionClient()
        let sessionID = UUID()
        let claimID = UUID()
        let digest = String(repeating: "a", count: 64)
        client.bootstrapResponse = .init(
            sessionID: sessionID,
            claimID: claimID,
            targetReceiptSHA256: digest)
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)

        let handle = try await adapter.openSession(
            handoff: BrowserMCPHandoffGrant(payload: data),
            claimID: claimID)

        #expect(handle.sessionID == sessionID)
        #expect(handle.targetReceiptSHA256 == digest)
        #expect(client.bootstrapBundles == [bundle])

        var noncanonical = data
        noncanonical.append(0x0A)
        await #expect(throws: RemoteBrowserMCPSessionError.self) {
            _ = try await adapter.openSession(
                handoff: BrowserMCPHandoffGrant(payload: noncanonical),
                claimID: UUID())
        }
        #expect(client.bootstrapBundles.count == 1)
    }

    @Test
    func `adapter maps scoped status observation receipt and provider epoch`() async throws {
        let client = RecordingBridgeBrowserSessionClient()
        let epoch = UUID()
        client.statusResponse = PeekabooBridgeBrowserStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [],
            connectionReceipt: Self.bridgeReceipt,
            error: "status cancelled",
            providerSessionEpoch: epoch,
            observation: .indeterminate)
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)
        let handle = RemoteBrowserMCPSessionHandle(sessionID: UUID())

        let status = try await adapter.status(session: handle, channel: .stable)

        #expect(status.observation == .indeterminate)
        #expect(status.connectionReceipt == Self.runtimeReceipt)
        #expect(status.providerSessionEpoch?.transportID == epoch)
        #expect(client.statusRequests == [.init(sessionID: handle.sessionID, channel: "stable")])
    }

    @Test
    func `adapter routes explicit connect through scoped session`() async throws {
        let client = RecordingBridgeBrowserSessionClient()
        let epoch = UUID()
        client.connectResult = DesktopActionResult(
            payload: PeekabooBridgeBrowserStatus(
                isConnected: true,
                toolCount: 52,
                detectedBrowsers: [],
                connectionReceipt: Self.bridgeReceipt,
                providerSessionEpoch: epoch,
                observation: .confirmed),
            outcome: .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one))
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)
        let handle = RemoteBrowserMCPSessionHandle(sessionID: UUID())

        let result = try await adapter.connectWithOutcome(
            session: handle,
            channel: .stable,
            browserURL: Self.bridgeReceipt.browserURL)

        #expect(result.payload.connectionReceipt == Self.runtimeReceipt)
        #expect(result.payload.providerSessionEpoch?.transportID == epoch)
        #expect(client.connectRequests == [.init(
            sessionID: handle.sessionID,
            channel: "stable",
            browserURL: Self.bridgeReceipt.browserURL)])
    }

    @Test
    func `adapter sends sorted preflight and preserves structured execution evidence`() async throws {
        let client = RecordingBridgeBrowserSessionClient()
        let epoch = UUID()
        client.executionResult = DesktopActionResult(
            payload: PeekabooBridgeBrowserToolResponse(
                content: [.object([
                    "type": .string("text"),
                    "text": .string("uid=1_0 button Continue"),
                ])],
                isError: false,
                meta: nil,
                structuredContent: .object([
                    "snapshot": .object([
                        "id": .string("1_0"),
                        "role": .string("button"),
                    ]),
                ]),
                connectionReceipt: Self.bridgeReceipt,
                completedCallCount: 1,
                dispatchedCallCount: 1,
                providerSessionEpoch: epoch),
            outcome: nil)
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)
        let handle = RemoteBrowserMCPSessionHandle(sessionID: UUID())
        let binding = BrowserMCPExecutionSessionBinding(
            connectionReceipt: Self.runtimeReceipt,
            providerSessionEpoch: BrowserMCPProviderSessionEpoch(transportID: epoch))

        let result = try await adapter.executeSequenceWithOutcome(
            session: handle,
            calls: [.init(toolName: "take_snapshot", arguments: ["pageId": 7])],
            channel: .stable,
            expectedSessionBinding: binding,
            elementPreflight: .init(providerPageID: 7, providerUIDs: ["z_1", "a_1"]))

        let request = try #require(client.executionRequests.first)
        #expect(request.sessionID == handle.sessionID)
        #expect(request.expectedConnectionReceipt == Self.bridgeReceipt)
        #expect(request.expectedProviderSessionEpoch == epoch)
        #expect(request.elementPreflight?.providerPageID == 7)
        #expect(request.elementPreflight?.providerUIDs == ["a_1", "z_1"])
        #expect(result.payload.structuredContent?.objectValue?["snapshot"]?.objectValue?["id"] == .string("1_0"))
        let evidence = result.payload.meta?.objectValue?[BrowserMCPExecutionEvidence.metadataKey]?.objectValue
        #expect(evidence?["provider_session_epoch"] == .string(epoch.uuidString.lowercased()))
    }

    @Test
    func `Bridge handler output mints fresh remote page snapshot and element references`() async throws {
        let services = StubServices()
        services.browserResponseContent = [.object([
            "type": .string("text"),
            "text": .string("## Pages\n7: Example (https://example.test/) [selected]"),
        ])]
        services.browserResponseStructuredContent = .object([
            "pages": .array([.object([
                "id": .int(7),
                "url": .string("https://example.test/"),
                "title": .string("Example"),
                "selected": .bool(true),
            ])]),
        ])
        let listed = try await Self.handledBrowserResponse(
            toolName: "list_pages",
            arguments: [:],
            services: services)
        let rawPages = try RemoteBrowserMCPClient.toolResponse(from: listed)
        let capabilitySession = BrowserToolCapabilitySession()
        let binding = BrowserMCPExecutionSessionBinding(
            connectionReceipt: RemoteBrowserMCPClient.runtimeReceipt(
                from: PeekabooBridgeHandlerMutationSemanticsTests.localBrowserReceipt),
            providerSessionEpoch: BrowserMCPProviderSessionEpoch())
        let pages = try await capabilitySession.project(
            rawPages,
            calls: [.init(toolName: "list_pages", arguments: [:])],
            resolved: nil,
            sessionBinding: binding)
        let pageReference = try #require(
            pages.structuredContent?.objectValue?["pages"]?.arrayValue?.first?
                .objectValue?["id"]?.stringValue)
        #expect(pageReference.hasPrefix("bp1_"))
        #expect(pageReference != "7")

        services.browserResponseContent = [.object([
            "type": .string("text"),
            "text": .string("uid=1_0 button \"Continue\""),
        ])]
        services.browserResponseStructuredContent = .object([
            "snapshot": .object([
                "id": .string("1_0"),
                "role": .string("button"),
                "name": .string("Continue"),
            ]),
        ])
        let snapshotted = try await Self.handledBrowserResponse(
            toolName: "take_snapshot",
            arguments: ["pageId": .int(7)],
            services: services)
        let rawSnapshot = try RemoteBrowserMCPClient.toolResponse(from: snapshotted)
        let resolved = try await capabilitySession.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: binding)
        let snapshot = try await capabilitySession.project(
            rawSnapshot,
            calls: [.init(toolName: "take_snapshot", arguments: ["pageId": 7])],
            resolved: resolved,
            sessionBinding: binding)
        let snapshotRoot = try #require(snapshot.structuredContent?.objectValue)
        let snapshotReference = try #require(snapshotRoot["snapshot_ref"]?.stringValue)
        let elementReference = try #require(snapshotRoot["snapshot"]?.objectValue?["id"]?.stringValue)
        #expect(snapshotReference.hasPrefix("bs1_"))
        #expect(elementReference.hasPrefix("be1_"))
        #expect(elementReference != "1_0")
    }

    @Test(arguments: [
        (
            PeekabooBridgeErrorCode.invalidRequest,
            PeekabooBridgeBrowserSessionErrorContext.invalid,
            RemoteBrowserMCPSessionTransportError.invalidSession),
        (
            PeekabooBridgeErrorCode.invalidRequest,
            PeekabooBridgeBrowserSessionErrorContext.ended,
            RemoteBrowserMCPSessionTransportError.sessionEnded),
        (
            PeekabooBridgeErrorCode.unauthorizedClient,
            PeekabooBridgeBrowserSessionErrorContext.wrongOwner,
            RemoteBrowserMCPSessionTransportError.wrongOwner),
        (
            PeekabooBridgeErrorCode.versionMismatch,
            PeekabooBridgeBrowserSessionErrorContext.hostGenerationChanged,
            RemoteBrowserMCPSessionTransportError.hostGenerationChanged),
    ])
    func `adapter maps only authenticated terminal session contexts`(
        code: PeekabooBridgeErrorCode,
        context: String,
        expected: RemoteBrowserMCPSessionTransportError) async
    {
        let client = RecordingBridgeBrowserSessionClient()
        client.statusError = PeekabooBridgeErrorEnvelope(
            code: code,
            message: "terminal",
            context: context)
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)

        await #expect(throws: expected) {
            _ = try await adapter.status(
                session: .init(sessionID: UUID()),
                channel: nil)
        }
    }

    @Test
    func `adapter leaves cancellation and unclassified envelopes indeterminate`() async {
        let client = RecordingBridgeBrowserSessionClient()
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)
        let handle = RemoteBrowserMCPSessionHandle(sessionID: UUID())
        client.statusError = CancellationError()

        await #expect(throws: CancellationError.self) {
            _ = try await adapter.status(session: handle, channel: nil)
        }

        client.statusError = PeekabooBridgeErrorEnvelope(
            code: .serverBusy,
            message: "busy",
            context: PeekabooBridgeBrowserSessionErrorContext.invalid)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await adapter.status(session: handle, channel: nil)
        }

        #expect(PeekabooBridgeClient.browserSessionTerminalFailure(
            from: PeekabooBridgeOperationReceiptError.peerIdentityMismatch) == .hostGenerationChanged)
        #expect(PeekabooBridgeClient.browserSessionTerminalFailure(
            from: PeekabooBridgeOperationReceiptError.operationSessionMismatch) == nil)
    }

    @Test
    func `adapter routes disconnect and end through exact session handle`() async throws {
        let client = RecordingBridgeBrowserSessionClient()
        let adapter = PeekabooBridgeRemoteBrowserSessionTransport(client: client)
        let handle = RemoteBrowserMCPSessionHandle(sessionID: UUID())

        try await adapter.disconnect(session: handle)
        try await adapter.endSession(handle)

        #expect(client.disconnectedSessionIDs == [handle.sessionID])
        #expect(client.endedSessionIDs == [handle.sessionID])
    }

    private static let bridgeReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9333/",
        webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-adapter",
        devToolsBrowserID: "browser-adapter",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static let runtimeReceipt = BrowserMCPConnectionReceipt(
        channel: .stable,
        browserURL: "http://127.0.0.1:9333/",
        webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-adapter",
        devToolsBrowserID: "browser-adapter",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static func handledBrowserResponse(
        toolName: String,
        arguments: [String: PeekabooBridgeJSONValue],
        services: StubServices) async throws -> PeekabooBridgeBrowserToolResponse
    {
        let handled = try await PeekabooBridgeHandlerMutationSemanticsTests.handleCurrent(
            .browserExecute(.init(
                toolName: toolName,
                arguments: arguments,
                channel: "stable",
                expectedConnectionReceipt: PeekabooBridgeHandlerMutationSemanticsTests.localBrowserReceipt)),
            with: PeekabooBridgeHandlerMutationSemanticsTests.server(services: services))
        guard case let .browserToolResponse(response) = handled.response else {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Expected a browser tool response")
        }
        return response
    }

    private static func handoffBundle() async throws -> PeekabooBridgeOperationReceiptBundle {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/peekaboo-client-adapter-\(UUID().uuidString).sock")
        let peer = try OperationReceiptSessionFixture.currentPeer()
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserConnect(.init(
            channel: "stable",
            browserURL: self.bridgeReceipt.browserURL,
            requestsHandoff: true))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserStatus(.init(
                isConnected: true,
                toolCount: 10,
                detectedBrowsers: [],
                connectionReceipt: self.bridgeReceipt)),
            outcome: outcome.projection))
        return try await session.signedBundle(
            authority: authority,
            sequence: 0,
            request: request,
            response: response,
            target: .browser(self.bridgeReceipt),
            outcome: outcome.projection)
    }

    private static func canonicalData(_ bundle: PeekabooBridgeOperationReceiptBundle) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }
}

@MainActor
private final class RecordingBridgeBrowserSessionClient: PeekabooBridgeBrowserSessionClientProviding,
    @unchecked Sendable
{
    struct StatusRequest: Equatable {
        let sessionID: UUID?
        let channel: String?
    }

    struct ConnectRequest: Equatable {
        let sessionID: UUID
        let channel: String?
        let browserURL: String?
    }

    var bootstrapResponse = PeekabooBridgeBrowserSessionBootstrapResponse(
        sessionID: UUID(),
        claimID: UUID())
    var statusResponse = PeekabooBridgeBrowserStatus(
        isConnected: false,
        toolCount: 0,
        detectedBrowsers: [],
        providerSessionEpoch: nil,
        observation: .confirmed)
    var connectResult: DesktopActionResult<PeekabooBridgeBrowserStatus>?
    var executionResult: DesktopActionResult<PeekabooBridgeBrowserToolResponse>?
    var statusError: (any Error)?
    private(set) var bootstrapBundles: [PeekabooBridgeOperationReceiptBundle?] = []
    private(set) var statusRequests: [StatusRequest] = []
    private(set) var connectRequests: [ConnectRequest] = []
    private(set) var executionRequests: [PeekabooBridgeBrowserExecuteRequest] = []
    private(set) var disconnectedSessionIDs: [UUID] = []
    private(set) var endedSessionIDs: [UUID] = []

    func browserSessionBootstrap(
        receiptBundle: PeekabooBridgeOperationReceiptBundle?,
        claimID _: UUID) async throws -> PeekabooBridgeBrowserSessionBootstrapResponse
    {
        self.bootstrapBundles.append(receiptBundle)
        return self.bootstrapResponse
    }

    func browserStatus(
        channel: String?,
        sessionID: UUID?) async throws -> PeekabooBridgeBrowserStatus
    {
        if let statusError {
            throw statusError
        }
        self.statusRequests.append(.init(sessionID: sessionID, channel: channel))
        return self.statusResponse
    }

    func browserConnectResult(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        self.connectRequests.append(.init(
            sessionID: sessionID,
            channel: channel,
            browserURL: browserURL))
        return try #require(self.connectResult)
    }

    func browserExecuteResult(_ request: PeekabooBridgeBrowserExecuteRequest) async throws
        -> DesktopActionResult<PeekabooBridgeBrowserToolResponse>
    {
        self.executionRequests.append(request)
        return try #require(self.executionResult)
    }

    func browserSessionDisconnect(_ sessionID: UUID) async throws {
        self.disconnectedSessionIDs.append(sessionID)
    }

    func browserSessionEnd(_ sessionID: UUID) async throws {
        self.endedSessionIDs.append(sessionID)
    }
}
