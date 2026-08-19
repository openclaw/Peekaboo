import CryptoKit
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PeekabooBridgeAgentExecutionTraceTransportTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.agent-trace-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    func `Authenticated 1.31 round trip signs the exact terminal response and process target`() async throws {
        let socketPath = "/tmp/peekaboo-agent-trace-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.agentExecutionTrace],
            servingSocketPath: socketPath)
        server.setAgentExecutionRunnerForTesting(TraceRunnerStub())
        server.allowAuthenticatedAgentExecutionPeerForTesting()
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.agentExecutionTraceVersion)
        #expect(handshake.supportedOperations.contains(.agentExecutionTrace))
        #expect(handshake.enabledOperations?.contains(.agentExecutionTrace) == true)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.agentExecutionTrace) == true)

        let request = Self.request()
        let delivery = try await client.agentExecutionTraceWithReceipt(request, timeoutSeconds: 2)
        let response = delivery.response
        try response.validate(request: request)
        let bundle = delivery.receiptBundle
        #expect(await client.lastOperationReceiptBundle() == bundle)
        #expect(try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeOperationReceiptBundle.self,
            from: bundle.canonicalEncodedData()) == bundle)
        try bundle.validate(trustAnchor: .listenerAttestation(#require(handshake.operationAttestation)))
        #expect(bundle.receipt.payload.schemaVersion == 1)
        #expect(bundle.receipt.payload.operation == .agentExecutionTrace)
        #expect(bundle.receipt.payload.responseSHA256 ==
            PeekabooBridgeOperationReceiptCoding.sha256(bundle.canonicalResponse))
        #expect(bundle.receipt.payload.outcome?.retrySafe == false)
        #expect(bundle.receipt.payload.outcome?.dispatchState == .dispatched(unitCount: .one))
        guard case let .process(target)? = bundle.receipt.payload.target else {
            Issue.record("Expected exact spawned Agent process receipt")
            return
        }
        #expect(target.processIdentifier == response.process.processIdentity.processIdentifier)
        #expect(target.processStartIdentity == response.process.processIdentity.processStartIdentity)

        var substituted = try #require(JSONSerialization.jsonObject(
            with: bundle.canonicalResponse) as? [String: Any])
        substituted["substituted"] = true
        let substitutedBytes = try JSONSerialization.data(withJSONObject: substituted, options: [.sortedKeys])
        let forged = PeekabooBridgeOperationReceiptBundle(
            operationAttestation: bundle.operationAttestation,
            operationSessionAttestation: bundle.operationSessionAttestation,
            receipt: bundle.receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: bundle.canonicalRequest,
            canonicalResponse: substitutedBytes)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forged.validateIntegrity()
        }

        await host.stop()
    }

    @Test
    func `Missing protocol capability refuses before operation transport`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(BridgeTestFixtures.handshake(
                negotiatedVersion: version,
                supportedOperations: [.permissionsStatus])),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: version)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await client.agentExecutionTrace(Self.request(), timeoutSeconds: 1)
        }
        #expect(await peer.requests.count == 1)
        await peer.waitUntilFinished()
    }

    @Test
    func `Pre-release coordination failure stays signed retry-safe and targetless`() async throws {
        let socketPath = "/tmp/peekaboo-agent-trace-refusal-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.agentExecutionTrace],
            servingSocketPath: socketPath)
        server.setAgentExecutionRunnerForTesting(FailingTraceRunnerStub())
        server.allowAuthenticatedAgentExecutionPeerForTesting()
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        let refusalBundle = try await client.agentExecutionTraceReceiptBundle(
            Self.request(),
            timeoutSeconds: 2)
        try refusalBundle.validate(trustAnchor: .listenerAttestation(#require(handshake.operationAttestation)))
        let wireResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: refusalBundle.canonicalResponse)
        let semanticResponse = if case let .projectedAction(projected) = wireResponse {
            projected.response
        } else {
            wireResponse
        }
        guard case .error = semanticResponse else {
            Issue.record("Expected signed refusal response bytes")
            return
        }
        #expect(refusalBundle.receipt.payload.target == nil)
        #expect(refusalBundle.receipt.payload.outcome?.state == .refused)
        #expect(refusalBundle.receipt.payload.outcome?.retrySafe == true)

        do {
            _ = try await client.agentExecutionTrace(Self.request(), timeoutSeconds: 2)
            Issue.record("Expected signed pre-release refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.target == nil)
        #expect(bundle.receipt.payload.outcome?.state == .refused)
        #expect(bundle.receipt.payload.outcome?.retrySafe == true)
        await host.stop()
    }

    private static func request() -> PeekabooBridgeAgentExecutionTraceRequest {
        let root = "/private/tmp/peekaboo-agent-trace-transport"
        return .init(
            task: "Perform exact background work",
            maxSteps: 40,
            runRootPath: root,
            coordinationReceiptPath: root + "/agent-execution-coordination.json",
            acknowledgementPath: root + "/agent-execution-ack.json",
            startTimeoutMilliseconds: 30000,
            runTimeoutMilliseconds: 900_000)
    }
}

private struct TraceRunnerStub: PeekabooBridgeAgentExecutionRunning {
    func run(
        request: PeekabooBridgeAgentExecutionTraceRequest,
        peer: PeekabooBridgePeer,
        servingSocketPath: String) async throws -> PeekabooBridgeAgentExecutionTraceResponse
    {
        let peerStart = try #require(peer.processStartIdentity)
        let peerHash = try #require(peer.codeSignatureHash)
        let requestingPeer = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: peer.processIdentifier,
            processStartIdentity: peerStart,
            codeSignatureHash: peerHash)
        let processIdentity = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 42424,
            processStartIdentity: 989_898,
            codeSignatureHash: peerHash)
        let process = PeekabooBridgeAgentExecutionProcessIdentity(
            processIdentity: processIdentity,
            executablePath: "/usr/local/bin/peekaboo",
            executableSHA256: String(repeating: "b", count: 64))
        let taskSHA = Self.sha256(Data(request.task.utf8))
        let arguments = [
            "agent", "run", request.task, "--no-cache", "--max-steps", String(request.maxSteps),
            "--bridge-socket", servingSocketPath, "--json",
        ]
        let argumentsSHA = try Self.sha256(Self.canonical(arguments))
        let environmentKeys = [
            "PATH", "PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE", "PEEKABOO_AGENT_EXECUTION_GATE_FD",
            "PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD", "PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT",
            "PEEKABOO_OPERATION_RECEIPT_DIRECTORY",
        ]
        let environmentSHA = String(repeating: "c", count: 64)
        let receipt = PeekabooBridgeAgentExecutionCoordinationReceipt(
            challenge: String(repeating: "d", count: 64),
            requestingPeer: requestingPeer,
            process: process,
            bridgeSocketPath: servingSocketPath,
            runRootPath: request.runRootPath,
            coordinationReceiptPath: request.coordinationReceiptPath,
            acknowledgementPath: request.acknowledgementPath,
            operationReceiptDirectoryPath: request.runRootPath + "/agent-operation-receipts",
            taskSHA256: taskSHA,
            maxSteps: request.maxSteps,
            startTimeoutMilliseconds: request.startTimeoutMilliseconds,
            runTimeoutMilliseconds: request.runTimeoutMilliseconds,
            arguments: arguments,
            argumentsSHA256: argumentsSHA,
            backgroundOnly: true,
            allowForeground: false,
            shellAvailable: false,
            processCreationLimit: 0,
            environmentPolicyVersion: 3,
            environmentKeys: environmentKeys,
            environmentSHA256: environmentSHA,
            spawnedAt: 1000,
            lockdownAcknowledgedAt: 1050,
            publishedAt: 1100)
        let receiptBytes = try Self.canonical(receipt)
        let acknowledgement = PeekabooBridgeAgentExecutionAcknowledgement(
            challenge: receipt.challenge,
            coordinationReceiptSHA256: Self.sha256(receiptBytes),
            requestingPeer: requestingPeer,
            process: process,
            taskSHA256: taskSHA,
            argumentsSHA256: argumentsSHA,
            environmentSHA256: environmentSHA,
            acknowledgedAt: 1150)
        let acknowledgementBytes = try Self.canonical(acknowledgement)
        let stdout = try JSONSerialization.data(withJSONObject: [
            "success": true,
            "result": [
                "executionTrace": ["entries": [], "totalCallCount": 0, "truncated": false],
            ],
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        return .init(
            process: process,
            requestingPeer: requestingPeer,
            bridgeSocketPath: servingSocketPath,
            runRootPath: request.runRootPath,
            coordinationReceiptPath: request.coordinationReceiptPath,
            acknowledgementPath: request.acknowledgementPath,
            operationReceiptDirectoryPath: request.runRootPath + "/agent-operation-receipts",
            taskSHA256: taskSHA,
            maxSteps: request.maxSteps,
            startTimeoutMilliseconds: request.startTimeoutMilliseconds,
            runTimeoutMilliseconds: request.runTimeoutMilliseconds,
            arguments: arguments,
            argumentsSHA256: argumentsSHA,
            backgroundOnly: true,
            allowForeground: false,
            shellAvailable: false,
            processCreationLimit: 0,
            environmentPolicyVersion: 3,
            environmentKeys: environmentKeys,
            environmentSHA256: environmentSHA,
            stdout: .init(bytes: stdout),
            stderr: .init(bytes: Data()),
            coordinationReceipt: .init(bytes: receiptBytes),
            acknowledgement: .init(bytes: acknowledgementBytes),
            processDisposition: .exited,
            outputDisposition: .validatedExecutionTrace,
            executionTrace: .object([
                "entries": .array([]),
                "totalCallCount": .int(0),
                "truncated": .bool(false),
            ]),
            exitCode: 0,
            terminationSignal: nil,
            spawnedAt: 1000,
            lockdownAcknowledgedAt: 1050,
            coordinationReceiptPublishedAt: 1100,
            acknowledgedAt: 1200,
            releasedAt: 1300,
            terminalObservationEndedAt: 1400)
    }

    private static func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct FailingTraceRunnerStub: PeekabooBridgeAgentExecutionRunning {
    func run(
        request _: PeekabooBridgeAgentExecutionTraceRequest,
        peer _: PeekabooBridgePeer,
        servingSocketPath _: String) async throws -> PeekabooBridgeAgentExecutionTraceResponse
    {
        throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement("forged challenge")
    }
}
