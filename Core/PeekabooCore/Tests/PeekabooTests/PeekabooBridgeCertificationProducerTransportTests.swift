import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Security
import Testing
@testable import PeekabooBridge

@Suite("Bridge certification producer transport", .serialized)
struct PeekabooBridgeCertificationProducerTransportTests {
    @Test
    func `Producer authorization rejects identifier team generation and source drift`() throws {
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        let expected = try PeekabooBridgeCertificationProducerExpectation(
            processIdentifier: live.processIdentifier,
            processStartIdentity: live.processStartIdentity,
            codeSignatureHash: #require(live.codeSignatureHash))
        let executablePath = "/private/tmp/peekaboo-certification-producer"
        let executableSHA256 = String(repeating: "b", count: 64)
        let sourceCommit = String(repeating: "c", count: 40)

        func information(identifier: String, team: String, source: String) -> [String: Any] {
            [
                kSecCodeInfoIdentifier as String: identifier,
                kSecCodeInfoTeamIdentifier as String: team,
                kSecCodeInfoPList as String: ["PeekabooSourceCommit": source],
                kSecCodeInfoMainExecutable as String: URL(fileURLWithPath: executablePath),
            ]
        }

        func authorize(
            identifier: String = PeekabooBridgeCertificationProducerAttestationKind.crashInventoryPair
                .expectedSigningIdentifier,
            team: String = PeekabooBridgeCertificationValidation.foundationTeamIdentifier,
            source: String = sourceCommit,
            processPath: String = executablePath,
            identity: PeekabooBridgeLivePeerIdentity? = nil,
            expectation: PeekabooBridgeCertificationProducerExpectation? = nil) throws
            -> PeekabooBridgeCertificationProducerTransport.ExecutableIdentity
        {
            try PeekabooBridgeCertificationProducerTransport.authenticateProducer(
                identity ?? live,
                expected: expectation ?? expected,
                kind: .crashInventoryPair,
                signingInformationProvider: { _ in
                    information(identifier: identifier, team: team, source: source)
                },
                processPathProvider: { _ in processPath },
                canonicalPathProvider: { $0 },
                executableSHA256Provider: { _ in executableSHA256 },
                staticCodeSignatureHashProvider: { _ in expected.codeSignatureHash })
        }

        let accepted = try authorize()
        #expect(accepted.signingIdentifier ==
            PeekabooBridgeCertificationProducerAttestationKind.crashInventoryPair.expectedSigningIdentifier)
        #expect(accepted.teamIdentifier == PeekabooBridgeCertificationValidation.foundationTeamIdentifier)
        #expect(accepted.sourceCommit == sourceCommit)
        #expect(accepted.sha256 == executableSHA256)

        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try authorize(identifier: "boo.peekaboo.same-team-impostor")
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try authorize(team: "Y5PE65HELJ")
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try authorize(source: String(repeating: "g", count: 40))
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try authorize(processPath: executablePath + "-substituted")
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try authorize(expectation: .init(
                processIdentifier: expected.processIdentifier,
                processStartIdentity: expected.processStartIdentity + 1,
                codeSignatureHash: expected.codeSignatureHash))
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try authorize(expectation: .init(
                processIdentifier: expected.processIdentifier,
                processStartIdentity: expected.processStartIdentity,
                codeSignatureHash: String(repeating: "d", count: 40)))
        }
    }

    @Test
    func `Owner private socket identity detects substitution and rejects links`() throws {
        let root = "/private/tmp/pb-cert-socket-\(UUID().uuidString.lowercased())"
        guard mkdir(root, S_IRWXU) == 0 else { throw POSIXError(.EIO) }
        defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/producer.sock"
        #expect(PeekabooBridgeAgentExecutionExecutable.canonicalPath(root) == root)
        #expect(path == NSString(string: path).standardizingPath)
        #expect(URL(fileURLWithPath: root).appendingPathComponent("producer.sock").path == path)
        #expect(NSString(string: root).appendingPathComponent("producer.sock") == path)

        let first = try Self.bindSocket(path: path)
        defer { close(first) }
        let firstIdentity = try PeekabooBridgeCertificationProducerTransport.requireOwnerPrivateSocket(path)
        guard unlink(path) == 0 else { throw POSIXError(.EIO) }

        let second = try Self.bindSocket(path: path)
        defer { close(second) }
        let secondIdentity = try PeekabooBridgeCertificationProducerTransport.requireOwnerPrivateSocket(path)
        #expect(firstIdentity != secondIdentity)
        guard unlink(path) == 0,
              symlink("missing.sock", path) == 0
        else { throw POSIXError(.EIO) }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try PeekabooBridgeCertificationProducerTransport.requireOwnerPrivateSocket(path)
        }
    }

    @Test
    func `Challenge envelope rejects replay substitution and cross kind payload`() throws {
        let root = "/private/tmp/pb-cert-envelope-\(UUID().uuidString.lowercased())"
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: root + ".sock")
        let listener = authority.attestation
        let request = Self.request(socketPath: root + "/producer.sock")
        let challenge = PeekabooBridgeCertificationProducerChallenge(
            kind: request.kind,
            executionNonce: request.executionNonce,
            monitorInstanceID: request.monitorInstanceID,
            challenge: String(repeating: "e", count: 64),
            listenerInstanceID: listener.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(listener.publicKey))
        let payload = PeekabooBridgeCertificationProducerPayload.crashInventoryPair(Self.crashPayload())
        let response = PeekabooBridgeCertificationProducerWireResponse(
            kind: request.kind,
            executionNonce: request.executionNonce,
            monitorInstanceID: request.monitorInstanceID,
            challenge: challenge.challenge,
            listenerInstanceID: challenge.listenerInstanceID,
            listenerPublicKeySHA256: challenge.listenerPublicKeySHA256,
            payload: payload)
        try PeekabooBridgeCertificationProducerTransport.validateWireEnvelope(
            response,
            request: request,
            challenge: challenge,
            listenerAttestation: listener)

        let replay = PeekabooBridgeCertificationProducerWireResponse(
            kind: request.kind,
            executionNonce: request.executionNonce,
            monitorInstanceID: request.monitorInstanceID,
            challenge: String(repeating: "f", count: 64),
            listenerInstanceID: challenge.listenerInstanceID,
            listenerPublicKeySHA256: challenge.listenerPublicKeySHA256,
            payload: payload)
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try PeekabooBridgeCertificationProducerTransport.validateWireEnvelope(
                replay,
                request: request,
                challenge: challenge,
                listenerAttestation: listener)
        }

        let crossKind = PeekabooBridgeCertificationProducerWireResponse(
            kind: .monitorSeal,
            executionNonce: request.executionNonce,
            monitorInstanceID: request.monitorInstanceID,
            challenge: challenge.challenge,
            listenerInstanceID: challenge.listenerInstanceID,
            listenerPublicKeySHA256: challenge.listenerPublicKeySHA256,
            payload: payload)
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try PeekabooBridgeCertificationProducerTransport.validateWireEnvelope(
                crossKind,
                request: request,
                challenge: challenge,
                listenerAttestation: listener)
        }
    }

    @Test
    func `Response record is exactly one bounded newline terminated document`() throws {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        var data = try encoder.encode(PeekabooBridgeCertificationProducerWireResponse(
            kind: .crashInventoryPair,
            executionNonce: String(repeating: "a", count: 64),
            monitorInstanceID: #require(UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")),
            challenge: String(repeating: "b", count: 64),
            listenerInstanceID: UUID(),
            listenerPublicKeySHA256: String(repeating: "c", count: 64),
            payload: .crashInventoryPair(Self.crashPayload())))
        data.append(0x0A)
        _ = try PeekabooBridgeCertificationProducerTransport.decodeOneRecord(
            data,
            maximumBytes: data.count)

        var extra = data
        extra.append(contentsOf: [0x7B, 0x7D, 0x0A])
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try PeekabooBridgeCertificationProducerTransport.decodeOneRecord(
                extra,
                maximumBytes: extra.count)
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try PeekabooBridgeCertificationProducerTransport.decodeOneRecord(
                data,
                maximumBytes: data.count - 1)
        }
        #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try PeekabooBridgeCertificationProducerTransport.decodeOneRecord(
                data.dropLast(),
                maximumBytes: data.count)
        }
    }

    @Test
    @MainActor
    func `Transitional caller is refused with a signed receipt before producer transport`() async throws {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/private/tmp/pb-cert-refusal-\(UUID().uuidString.lowercased()).sock")
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        let peer = PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: "Y5PE65HELJ")
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let request = PeekabooBridgeRequest.certificationProducerAttestation(Self.request(
            socketPath: "/private/tmp/producer-must-not-be-contacted.sock"))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await Self.server().handleAttestedOperation(payload, peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data),
            case let .error(error) = attested.response
        else {
            Issue.record("Expected signed certification caller refusal")
            return
        }
        #expect(error.code == .unauthorizedClient)
        #expect(error.message == "Certification operations require the authenticated Foundation-signed Peekaboo CLI")
        #expect(!error.operationMayHaveCompleted)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: request,
            response: attested.response)
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.operation == .certificationProducerAttestation)
        // Caller authorization refuses before producer transport can attest any target.
        #expect(bundle.receipt.payload.target == nil)
        #expect(bundle.receipt.payload.targetAttributionFailure == nil)
        #expect(bundle.receipt.payload.targetAttributionEvidence == nil)
        let outcome = try #require(bundle.receipt.payload.outcome?.outcome)
        #expect(outcome.state == .refused)
        #expect(outcome.route == .bridge)
        #expect(outcome.delivery == nil)
        #expect(outcome.evidence == .requestRefused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.retrySafety == .safe)
        #expect(outcome.refusalReason == .transportSessionUnavailable)
        #expect(error.actionOutcome == bundle.receipt.payload.outcome)
        #expect(error.actionTargetReceipt == nil)
    }

    @Test
    @MainActor
    func `Authorized producer transport failure remains a signed terminal bundle`() async throws {
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/private/tmp/pb-cert-transport-failure-\(UUID().uuidString.lowercased()).sock")
        let live = try #require(OperationReceiptSessionFixture.currentPeer().liveIdentity)
        let peer = PeekabooBridgePeer(
            liveIdentity: live,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier)
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let request = PeekabooBridgeRequest.certificationProducerAttestation(Self.request(
            socketPath: "/private/tmp/missing-certification-producer.sock"))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await Self.server().handleAttestedOperation(payload, peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data),
            case let .error(error) = attested.response
        else {
            Issue.record("Expected signed certification transport failure")
            return
        }
        #expect(error.code == .invalidRequest)
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: request,
            response: attested.response)
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.operation == .certificationProducerAttestation)
    }

    @Test
    @MainActor
    func `Live client advertises capability and retains required signed failures`() async throws {
        let socketPath = "/private/tmp/pb-cert-client-\(UUID().uuidString.lowercased()).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: Self.server(), allowedTeamIDs: [])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { try PeekabooBridgeSocketIO.livePeerIdentity(fd: $0) },
            coldPeer: { identity, _ in
                PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
                    teamIdentifier: PeekabooBridgeServer.certificationCallerTeamIdentifier)
            }))
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "untrusted-claims",
            teamIdentifier: "Y5PE65HELJ",
            processIdentifier: getpid()))
        #expect(handshake.supportedOperations.contains(.certificationProducerAttestation))
        #expect(handshake.enabledOperations?.contains(.certificationProducerAttestation) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.certificationProducerAttestation) == true)

        let request = Self.request(socketPath: "/private/tmp/missing-live-certification-producer.sock")
        let bundle = try await client.certificationProducerAttestationReceiptBundle(request)
        try bundle.validate(trustAnchor: .listenerAttestation(#require(handshake.operationAttestation)))
        guard case let .error(error) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        else {
            Issue.record("Expected retained signed producer failure")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(bundle.receipt.payload.operation == .certificationProducerAttestation)
        #expect(await client.lastOperationReceiptBundle() == bundle)
        await host.stop()
    }

    private static func request(socketPath: String) -> PeekabooBridgeCertificationProducerAttestationRequest {
        .init(
            kind: .crashInventoryPair,
            executionNonce: String(repeating: "a", count: 64),
            monitorInstanceID: UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!,
            producerSocketPath: socketPath,
            expectedProducer: .init(
                processIdentifier: 42,
                processStartIdentity: 99,
                codeSignatureHash: String(repeating: "d", count: 40)),
            timeoutMilliseconds: 1000,
            maximumResponseBytes: 64 * 1024)
    }

    private static func crashPayload() -> PeekabooBridgeCertificationCrashInventoryPairPayload {
        let before = PeekabooBridgeCertificationCrashInventoryPairPayload.Inventory(
            role: .matrixBefore,
            hostUUID: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
            hostname: "test-host",
            entries: [],
            scanCount: 2,
            quietPeriodMilliseconds: 1000,
            captureStartedAtUnixMilliseconds: 1000,
            captureCompletedAtUnixMilliseconds: 2000)
        let after = PeekabooBridgeCertificationCrashInventoryPairPayload.Inventory(
            role: .matrixAfter,
            hostUUID: before.hostUUID,
            hostname: before.hostname,
            entries: [],
            scanCount: 2,
            quietPeriodMilliseconds: 1000,
            captureStartedAtUnixMilliseconds: 2000,
            captureCompletedAtUnixMilliseconds: 3000)
        return .init(
            captureID: "capture",
            source: .init(
                sourceCommit: String(repeating: "a", count: 40),
                executableSHA256: String(repeating: "b", count: 64),
                catalogVersion: 2,
                monitorContractVersion: 1,
                catalogSHA256: String(repeating: "c", count: 64),
                scanDomain: .currentUserDiagnosticReports,
                crashReportPrefixes: ["Peekaboo"]),
            before: before,
            after: after,
            result: .init(passed: true, added: [], changed: [], removed: []))
    }

    private static func bindSocket(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        do {
            var address = sockaddr_un()
            let bytes = Array(path.utf8) + [0]
            let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
                  offset + bytes.count <= Int(UInt8.max)
            else { throw POSIXError(.ENAMETOOLONG) }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(offset + bytes.count)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, addressLength)
                }
            }
            guard result == 0,
                  chmod(path, S_IRUSR | S_IWUSR) == 0
            else { throw POSIXError(.EIO) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    @MainActor
    private static func server() -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.certificationProducerAttestation],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }
}
