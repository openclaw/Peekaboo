import Darwin
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite("Bridge signed process-generation observation", .serialized)
@MainActor
struct PeekabooBridgeProcessGenerationObservationTests {
    @Test
    func `Classifier returns stable alive absent and reused dispositions`() throws {
        let expected = PeekabooBridgeProcessGenerationIdentity(
            processIdentifier: 4242,
            processStartIdentity: 100)
        let request = PeekabooBridgeProcessGenerationObservationRequest(expected: expected)

        let alive = Self.server(start: 100, presence: true)
        let aliveResponse = try alive.handleProcessGenerationObservation(request)
        #expect(aliveResponse.disposition == .sameGenerationAlive)
        #expect(aliveResponse.observed == expected)

        let absent = Self.server(start: nil, presence: false)
        let absentResponse = try absent.handleProcessGenerationObservation(request)
        #expect(absentResponse.disposition == .exactGenerationAbsent)
        #expect(absentResponse.observed == nil)

        let reused = Self.server(start: 101, presence: true)
        let reusedResponse = try reused.handleProcessGenerationObservation(request)
        #expect(reusedResponse.disposition == .pidReused)
        #expect(reusedResponse.observed == .init(processIdentifier: 4242, processStartIdentity: 101))

        for response in [aliveResponse, absentResponse, reusedResponse] {
            #expect(response.observationStartedAtUnixMilliseconds > 0)
            #expect(response.observationCompletedAtUnixMilliseconds >=
                response.observationStartedAtUnixMilliseconds)
            try response.validate(request: request)
        }
    }

    @Test
    func `Ambiguous and failed presence observations are errors not a fourth disposition`() {
        let request = PeekabooBridgeProcessGenerationObservationRequest(
            expected: .init(processIdentifier: 4242, processStartIdentity: 100))
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try Self.server(start: nil, presence: true).handleProcessGenerationObservation(request)
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try Self.server(start: nil, presence: nil).handleProcessGenerationObservation(request)
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try Self.server(start: 100, presence: nil).handleProcessGenerationObservation(request)
        }

        let samples = ProcessStartSamples([100, 101])
        let drifting = Self.server(
            startProvider: { _ in samples.next() },
            presence: true)
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try drifting.handleProcessGenerationObservation(request)
        }
    }

    @Test
    func `Unreaped zombie is terminal signed-error evidence not an alive generation`() {
        var zombie = proc_bsdinfo()
        zombie.pbi_status = UInt32(SZOMB)
        #expect(PeekabooBridgeServer.observeProcessPresence(
            4242,
            processInfoProvider: { _ in zombie },
            absenceProvider: { _ in false }) == nil)

        var running = proc_bsdinfo()
        running.pbi_status = UInt32(SRUN)
        #expect(PeekabooBridgeServer.observeProcessPresence(
            4242,
            processInfoProvider: { _ in running },
            absenceProvider: { _ in false }) == true)
        #expect(PeekabooBridgeServer.observeProcessPresence(
            4242,
            processInfoProvider: { _ in nil },
            absenceProvider: { _ in true }) == false)
    }

    @Test
    func `Only live current Foundation CLI identity is authorized`() throws {
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        let accepted = PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier)
        try Self.server(start: 100, presence: true).requireCertificationCaller(accepted)

        let rejected: [PeekabooBridgePeer?] = [
            nil,
            PeekabooBridgePeer(
                liveIdentity: live,
                bundleIdentifier: "boo.peekaboo.other",
                teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier),
            PeekabooBridgePeer(
                liveIdentity: live,
                bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
                teamIdentifier: "Y5PE65HELJ"),
            PeekabooBridgePeer(
                processIdentifier: live.processIdentifier,
                auditTokenProcessIdentifierVersion: live.processIdentifierVersion,
                processStartIdentity: live.processStartIdentity,
                codeSignatureHash: live.codeSignatureHash,
                userIdentifier: live.effectiveUserIdentifier,
                bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
                teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier),
        ]
        for peer in rejected {
            #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                try Self.server(start: 100, presence: true).requireCertificationCaller(peer)
            }
        }
    }

    @Test
    func `Attested observation signs exact response and encloses host timing`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pb-process-observation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let peer = try Self.certificationPeer()
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let server = Self.server(start: 100, presence: true)
        let request = PeekabooBridgeRequest.observeProcessGeneration(.init(
            expected: .init(processIdentifier: 4242, processStartIdentity: 100)))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(payload, peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data),
            case let .processGenerationObservation(response) = attested.response
        else {
            Issue.record("Expected signed process-generation observation")
            return
        }
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: request,
            response: attested.response)
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.operation == .observeProcessGeneration)
        #expect(bundle.receipt.payload.target == .global)
        #expect(bundle.receipt.payload.outcome == nil)
        #expect(bundle.receipt.payload.startedAtUnixMilliseconds <=
            response.observationStartedAtUnixMilliseconds)
        #expect(response.observationCompletedAtUnixMilliseconds <=
            bundle.receipt.payload.completedAtUnixMilliseconds)
    }

    @Test
    func `Unauthorized caller gets signed refusal before observing process state`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pb-process-refusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        let transitionalPeer = PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: "Y5PE65HELJ")
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            peer: transitionalPeer)
        let observations = ObservationCounter()
        let server = Self.server(
            startProvider: { _ in
                observations.increment()
                return 100
            },
            presence: true)
        let request = PeekabooBridgeRequest.observeProcessGeneration(.init(
            expected: .init(processIdentifier: 4242, processStartIdentity: 100)))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(payload, peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data),
            case let .error(envelope) = attested.response
        else {
            Issue.record("Expected signed unauthorized refusal")
            return
        }
        #expect(envelope.code == .unauthorizedClient)
        #expect(observations.isEmpty)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: request,
            response: attested.response)
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.operation == .observeProcessGeneration)
        #expect(bundle.receipt.payload.target == nil)
    }

    @Test
    func `Receiptless access and receiptless advertisement fail before observation`() async throws {
        let observations = ObservationCounter()
        let server = Self.server(
            startProvider: { _ in
                observations.increment()
                return 100
            },
            presence: true,
            allowedOperations: [.observeProcessGeneration])
        let peer = try Self.certificationPeer()
        let request = PeekabooBridgeRequest.observeProcessGeneration(.init(
            expected: .init(processIdentifier: 4242, processStartIdentity: 100)))
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await server.route(request, peer: peer)
        }
        #expect(observations.isEmpty)

        let handshakeResponse = try await server.handleHandshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: .init(
                    bundleIdentifier: "untrusted-handshake-claims",
                    teamIdentifier: "Y5PE65HELJ",
                    processIdentifier: getpid())),
            peer: peer,
            permissions: PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true))
        guard case let .handshake(handshake) = handshakeResponse else {
            Issue.record("Expected receiptless handshake response")
            return
        }
        #expect(!handshake.supportedOperations.contains(.observeProcessGeneration))
        #expect(handshake.enabledOperations?.contains(.observeProcessGeneration) == false)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationObservation) == false)
    }

    @Test
    func `Live client requires capability and retains the required receipt`() async throws {
        let socketPath = "/tmp/peekaboo-process-observation-\(UUID().uuidString).sock"
        let server = Self.server(start: 100, presence: true, allowedOperations: [.observeProcessGeneration])
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        await host.setAuthenticationForTesting(Self.certificationAuthentication())
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "caller-claims-are-not-authority",
            teamIdentifier: "Y5PE65HELJ",
            processIdentifier: getpid()))
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(handshake.supportedOperations.contains(.observeProcessGeneration))
        #expect(handshake.enabledOperations?.contains(.observeProcessGeneration) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationObservation) == true)

        let request = PeekabooBridgeProcessGenerationObservationRequest(
            expected: .init(processIdentifier: 4242, processStartIdentity: 100))
        let delivery = try await client.observeProcessGenerationWithReceipt(request)
        #expect(delivery.response.disposition == .sameGenerationAlive)
        try delivery.receiptBundle.validate(
            trustAnchor: .listenerAttestation(#require(handshake.operationAttestation)))
        #expect(delivery.receiptBundle.receipt.payload.operation == .observeProcessGeneration)
        #expect(await client.lastOperationReceiptBundle() == delivery.receiptBundle)

        let substitutedResponse = PeekabooBridgeResponse.processGenerationObservation(.init(
            expected: request.expected,
            disposition: .pidReused,
            observed: .init(processIdentifier: 4242, processStartIdentity: 101),
            observationStartedAtUnixMilliseconds:
            delivery.response.observationStartedAtUnixMilliseconds,
            observationCompletedAtUnixMilliseconds:
            delivery.response.observationCompletedAtUnixMilliseconds))
        let forged = try PeekabooBridgeOperationReceiptBundle(
            operationAttestation: delivery.receiptBundle.operationAttestation,
            operationSessionAttestation: delivery.receiptBundle.operationSessionAttestation,
            receipt: delivery.receiptBundle.receipt,
            canonicalListenerAttestationPayload:
            delivery.receiptBundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload:
            delivery.receiptBundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: delivery.receiptBundle.canonicalReceiptPayload,
            canonicalRequest: delivery.receiptBundle.canonicalRequest,
            canonicalResponse: PeekabooBridgeOperationReceiptCoding.canonicalData(substitutedResponse))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try forged.validateIntegrity()
        }
        await host.stop()
    }

    @Test
    func `Client refuses missing capability before observation`() async throws {
        let socketPath = "/tmp/peekaboo-process-observation-disabled-\(UUID().uuidString).sock"
        let observations = ObservationCounter()
        let server = Self.server(
            startProvider: { _ in
                observations.increment()
                return 100
            },
            presence: true,
            allowedOperations: [.permissionsStatus])
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        await host.setAuthenticationForTesting(Self.certificationAuthentication())
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: nil,
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(!handshake.supportedOperations.contains(.observeProcessGeneration))
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await client.observeProcessGeneration(.init(
                expected: .init(processIdentifier: 4242, processStartIdentity: 100)))
        }
        #expect(observations.isEmpty)
        await host.stop()
    }

    @Test
    func `Ambiguous observation remains available as a signed error bundle`() async throws {
        let socketPath = "/tmp/peekaboo-process-observation-error-\(UUID().uuidString).sock"
        let server = Self.server(start: nil, presence: nil, allowedOperations: [.observeProcessGeneration])
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        await host.setAuthenticationForTesting(Self.certificationAuthentication())
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: nil,
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let request = PeekabooBridgeProcessGenerationObservationRequest(
            expected: .init(processIdentifier: 4242, processStartIdentity: 100))
        let bundle = try await client.observeProcessGenerationReceiptBundle(request)
        try bundle.validate(trustAnchor: .listenerAttestation(#require(handshake.operationAttestation)))
        guard case let .error(envelope) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        else {
            Issue.record("Expected signed observation failure")
            return
        }
        #expect(envelope.code == .internalError)
        #expect(bundle.receipt.payload.operation == .observeProcessGeneration)
        await host.stop()
    }

    private static func server(
        start: UInt64?,
        presence: Bool?,
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist)
        -> PeekabooBridgeServer
    {
        self.server(
            startProvider: { _ in start },
            presence: presence,
            allowedOperations: allowedOperations)
    }

    private static func server(
        startProvider: @escaping @Sendable (pid_t) -> UInt64?,
        presence: Bool?,
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist)
        -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: allowedOperations,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            },
            processStartIdentityProvider: startProvider,
            processPresenceProvider: { _ in presence })
    }

    private static func certificationPeer() throws -> PeekabooBridgePeer {
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        return PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier)
    }

    private static func certificationAuthentication() -> PeekabooBridgeHostAuthentication {
        .init(
            liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
            coldPeer: { identity, _ in
                PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
                    teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier)
            })
    }
}

private final class ProcessStartSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [UInt64?]

    init(_ samples: [UInt64?]) {
        self.samples = samples
    }

    func next() -> UInt64? {
        self.lock.withLock {
            guard !self.samples.isEmpty else { return nil }
            return self.samples.removeFirst()
        }
    }
}

private final class ObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var isEmpty: Bool {
        self.lock.withLock { self.value == 0 }
    }

    func increment() {
        self.lock.withLock { self.value += 1 }
    }
}
