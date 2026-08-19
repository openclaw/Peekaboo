import Darwin
import Foundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification PID-auth Unix attestation")
struct MonitorAttestationTests {
    @Test
    func `client plan is closed and transport bounded`() throws {
        let plan = try CertificationMonitorAttestationClientPlan.decode(Self.validPlanData)

        #expect(plan.expectedPeer.pid == 8001)
        #expect(plan.responseKind == .monitor)
        #expect(plan.timeoutMilliseconds == 2000)

        var object = try #require(JSONSerialization.jsonObject(with: Self.validPlanData) as? [String: Any])
        object["unexpected"] = true
        #expect(throws: CertificationControllerError.self) {
            try CertificationMonitorAttestationClientPlan.decode(
                JSONSerialization.data(withJSONObject: object)
            )
        }
    }

    @Test
    func `peer policy refuses every unexpected PID`() throws {
        try CertificationLocalPeerPolicy.requirePeerPID(8001, expected: 8001)
        #expect(throws: CertificationControllerError.self) {
            try CertificationLocalPeerPolicy.requirePeerPID(8002, expected: 8001)
        }
        #expect(throws: CertificationControllerError.self) {
            try CertificationLocalPeerPolicy.requirePeerPID(0, expected: 0)
        }
    }

    @Test
    func `peer identity policy rejects generation CDHash and token drift`() throws {
        let expected = CertificationProcessReceipt(
            pid: 8001,
            startIdentity: "800100",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let identity = CertificationAttestationPeerIdentity(
            auditToken: Data(repeating: 1, count: MemoryLayout<audit_token_t>.size),
            processIdentifierVersion: 7,
            effectiveUserIdentifier: geteuid(),
            process: expected
        )
        try CertificationAttestationPeerIdentityResolver.requireExpected(identity, expected: expected)
        try CertificationAttestationPeerIdentityResolver.requireStable(before: identity, after: identity)

        let wrongGeneration = CertificationProcessReceipt(
            pid: expected.pid,
            startIdentity: "800101",
            codeSignatureHash: expected.codeSignatureHash
        )
        #expect(throws: CertificationControllerError.self) {
            try CertificationAttestationPeerIdentityResolver.requireExpected(identity, expected: wrongGeneration)
        }
        let wrongCDHash = CertificationProcessReceipt(
            pid: expected.pid,
            startIdentity: expected.startIdentity,
            codeSignatureHash: String(repeating: "b", count: 40)
        )
        #expect(throws: CertificationControllerError.self) {
            try CertificationAttestationPeerIdentityResolver.requireExpected(identity, expected: wrongCDHash)
        }
        let driftedToken = CertificationAttestationPeerIdentity(
            auditToken: Data(repeating: 2, count: MemoryLayout<audit_token_t>.size),
            processIdentifierVersion: identity.processIdentifierVersion,
            effectiveUserIdentifier: identity.effectiveUserIdentifier,
            process: expected
        )
        #expect(throws: CertificationControllerError.self) {
            try CertificationAttestationPeerIdentityResolver.requireStable(before: identity, after: driftedToken)
        }
    }

    @Test
    func `peer resolver uses audit token start generation and CDHash providers`() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer { descriptors.forEach { close($0) } }
        let token = try CertificationUnixSocket.peerAuditToken(descriptors[0])
        let hash = Data(repeating: 0xAB, count: 20)
        let identity = try CertificationAttestationPeerIdentityResolver.resolve(
            descriptor: descriptors[0],
            auditTokenProvider: { _ in token },
            processStartIdentityProvider: { _ in 42 },
            codeSignatureHashProvider: { _ in hash }
        )
        #expect(identity.process.pid == getpid())
        #expect(identity.process.startIdentity == "42")
        #expect(identity.process.codeSignatureHash == String(repeating: "ab", count: 20))

        for processIdentifierVersion in [Int32.zero, Int32.min, -1] {
            var bitPatternToken = token
            withUnsafeMutableBytes(of: &bitPatternToken) { bytes in
                bytes.bindMemory(to: UInt32.self)[7] = UInt32(bitPattern: processIdentifierVersion)
            }
            let bitPatternIdentity = try CertificationAttestationPeerIdentityResolver.resolve(
                descriptor: descriptors[0],
                auditTokenProvider: { _ in bitPatternToken },
                processStartIdentityProvider: { _ in 42 },
                codeSignatureHashProvider: { _ in hash }
            )
            #expect(bitPatternIdentity.processIdentifierVersion == processIdentifierVersion)
        }

        var starts: [UInt64] = [42, 43]
        #expect(throws: CertificationControllerError.self) {
            try CertificationAttestationPeerIdentityResolver.resolve(
                descriptor: descriptors[0],
                auditTokenProvider: { _ in token },
                processStartIdentityProvider: { _ in starts.removeFirst() },
                codeSignatureHashProvider: { _ in hash }
            )
        }
        #expect(throws: CertificationControllerError.self) {
            try CertificationAttestationPeerIdentityResolver.resolve(
                descriptor: descriptors[0],
                auditTokenProvider: { _ in token },
                processStartIdentityProvider: { _ in 42 },
                codeSignatureHashProvider: { _ in nil }
            )
        }
    }

    @Test
    func `client listener and accepted sockets are close on exec`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, S_IRWXU) == 0)
        let socketPath = directory.appendingPathComponent("cloexec.sock").path
        let listener = try CertificationUnixSocket.makeServer(path: socketPath)
        defer { close(listener); unlink(socketPath) }
        let client = try CertificationUnixSocket.connect(path: socketPath, timeoutMilliseconds: 2000)
        defer { close(client) }
        let accepted = try CertificationUnixSocket.acceptClient(listener)
        try #require(accepted >= 0)
        defer { close(accepted) }
        for descriptor in [listener, client, accepted] {
            let flags = fcntl(descriptor, F_GETFD)
            #expect(flags >= 0)
            #expect(flags & FD_CLOEXEC != 0)
        }
    }

    @Test
    func `random challenge and wire documents have closed schemas`() throws {
        let challenge = try CertificationAttestationChallenge.random()
        #expect(challenge.utf8.count == 64)
        #expect(challenge.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        })
        let process = CertificationProcessReceipt(
            pid: 8001,
            startIdentity: "800100",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let request = CertificationAttestationRequest(
            version: 1,
            executionNonce: Self.nonce,
            monitorInstanceID: Self.monitorID,
            challenge: challenge
        )
        let monitor = CertificationMonitorAttestationResponse(
            version: 1,
            executionNonce: Self.nonce,
            monitorInstanceID: Self.monitorID,
            challenge: challenge,
            monitor: process,
            monitorEvidenceSHA256: String(repeating: "b", count: 64)
        )
        let observer = CertificationObserverAttestationResponse(
            version: 1,
            executionNonce: Self.nonce,
            monitorInstanceID: Self.monitorID,
            challenge: challenge,
            observer: process,
            witnessSHA256: String(repeating: "c", count: 64),
            observationFileSHA256: String(repeating: "d", count: 64),
            restorationFileSHA256: String(repeating: "e", count: 64),
            beforeValueSHA256: String(repeating: "1", count: 64),
            expectedValueSHA256: String(repeating: "2", count: 64),
            observedValueSHA256: String(repeating: "2", count: 64),
            restoredValueSHA256: String(repeating: "1", count: 64)
        )

        #expect(try Self.keys(request) == [
            "version", "execution_nonce", "monitor_instance_id", "challenge",
        ])
        #expect(try Self.keys(monitor) == [
            "version", "execution_nonce", "monitor_instance_id", "challenge", "monitor",
            "monitor_evidence_sha256",
        ])
        #expect(try Self.keys(observer) == [
            "version", "execution_nonce", "monitor_instance_id", "challenge", "observer", "witness_sha256",
            "observation_file_sha256", "restoration_file_sha256", "before_value_sha256",
            "expected_value_sha256", "observed_value_sha256", "restored_value_sha256",
        ])

        let requestData = try JSONEncoder().encode(monitor)
        _ = try CertificationMonitorAttestationRunner.validateMonitorResponse(
            requestData,
            request: request,
            expectedPeer: process
        )
        var openObject = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        var openProcess = try #require(openObject["monitor"] as? [String: Any])
        openProcess["unexpected"] = true
        openObject["monitor"] = openProcess
        #expect(throws: CertificationControllerError.self) {
            try CertificationMonitorAttestationRunner.validateMonitorResponse(
                JSONSerialization.data(withJSONObject: openObject),
                request: request,
                expectedPeer: process
            )
        }
        openProcess.removeValue(forKey: "unexpected")
        openProcess["start_identity"] = "00"
        openObject["monitor"] = openProcess
        #expect(throws: CertificationControllerError.self) {
            try CertificationMonitorAttestationRunner.validateMonitorResponse(
                JSONSerialization.data(withJSONObject: openObject),
                request: request,
                expectedPeer: process
            )
        }
    }

    @Test
    func `observer server echoes one challenge to a kernel authenticated client`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, S_IRWXU) == 0)
        let socketPath = directory.appendingPathComponent("observer.sock").path
        let process = CertificationProcessReceipt(
            pid: getpid(),
            startIdentity: "800100",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let server = try CertificationObserverAttestationServer(
            socketPath: socketPath,
            executionNonce: Self.nonce,
            monitorInstanceID: Self.monitorID,
            observer: process,
            witnessSHA256: String(repeating: "c", count: 64),
            observationFileSHA256: String(repeating: "d", count: 64),
            restorationFileSHA256: String(repeating: "e", count: 64),
            beforeValueSHA256: String(repeating: "1", count: 64),
            expectedValueSHA256: String(repeating: "2", count: 64),
            observedValueSHA256: String(repeating: "2", count: 64),
            restoredValueSHA256: String(repeating: "1", count: 64)
        )
        let serverTask = Task.detached { await server.serve() }
        defer {
            server.stop()
            serverTask.cancel()
        }
        let client = try CertificationUnixSocket.connect(path: socketPath, timeoutMilliseconds: 2000)
        defer { close(client) }
        try CertificationLocalPeerPolicy.requirePeerPID(
            CertificationUnixSocket.peerPID(client),
            expected: getpid()
        )
        let challenge = String(repeating: "f", count: 64)
        try CertificationUnixSocket.writeJSON(
            CertificationAttestationRequest(
                version: 1,
                executionNonce: Self.nonce,
                monitorInstanceID: Self.monitorID,
                challenge: challenge
            ),
            descriptor: client
        )
        let response = try JSONDecoder().decode(
            CertificationObserverAttestationResponse.self,
            from: CertificationUnixSocket.readJSONLine(
                descriptor: client,
                maximumBytes: 64 * 1024,
                timeoutMilliseconds: 2000
            )
        )
        #expect(response.challenge == challenge)
        #expect(response.executionNonce == Self.nonce)
        #expect(response.monitorInstanceID == Self.monitorID)
        #expect(response.observer.pid == getpid())
        let stalled = try CertificationUnixSocket.connect(path: socketPath, timeoutMilliseconds: 2000)
        _ = Data("{".utf8).withUnsafeBytes { buffer in
            Darwin.write(stalled, buffer.baseAddress, buffer.count)
        }
        try await Task.sleep(for: .milliseconds(50))
        server.stop()
        serverTask.cancel()
        await serverTask.value
        close(stalled)
    }

    @Test
    func `framing rejects unterminated and deadline stalled messages`() async throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let bytes = Data(#"{"version":1}"#.utf8)
        _ = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptors[0], buffer.baseAddress, buffer.count)
        }
        shutdown(descriptors[0], SHUT_WR)
        #expect(throws: CertificationControllerError.self) {
            try CertificationUnixSocket.readJSONLine(
                descriptor: descriptors[1],
                maximumBytes: 1024,
                timeoutMilliseconds: 100
            )
        }

        var stalled = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &stalled) == 0)
        defer {
            close(stalled[0])
            close(stalled[1])
        }
        #expect(throws: CertificationControllerError.self) {
            try CertificationUnixSocket.readJSONLine(
                descriptor: stalled[1],
                maximumBytes: 1024,
                timeoutMilliseconds: 50
            )
        }

        var dripping = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &dripping) == 0)
        defer {
            close(dripping[0])
            close(dripping[1])
        }
        let drippingWriter = dripping[0]
        let writer = Task.detached {
            for _ in 0..<4 {
                _ = Data("{".utf8).withUnsafeBytes { buffer in
                    Darwin.write(drippingWriter, buffer.baseAddress, buffer.count)
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        #expect(throws: CertificationControllerError.self) {
            try CertificationUnixSocket.readJSONLine(
                descriptor: dripping[1],
                maximumBytes: 1024,
                timeoutMilliseconds: 100
            )
        }
        await writer.value
    }

    @Test
    func `closed attestation peer becomes a write error instead of SIGPIPE`() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
        defer {
            if descriptors[0] >= 0 {
                close(descriptors[0])
            }
            if descriptors[1] >= 0 {
                close(descriptors[1])
            }
        }
        try CertificationUnixSocket.disableSIGPIPE(descriptors[0])
        var noSignal: Int32 = 0
        var noSignalSize = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(
            descriptors[0],
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            &noSignalSize
        ) == 0)
        #expect(noSignal == 1)
        shutdown(descriptors[1], SHUT_RDWR)
        close(descriptors[1])
        descriptors[1] = -1
        #expect(throws: CertificationControllerError.self) {
            try CertificationUnixSocket.writeJSON(
                CertificationAttestationRequest(
                    version: 1,
                    executionNonce: Self.nonce,
                    monitorInstanceID: Self.monitorID,
                    challenge: String(repeating: "a", count: 64)
                ),
                descriptor: descriptors[0]
            )
        }
    }

    private static let nonce = String(repeating: "9", count: 64)
    private static let monitorID = "019c0000-0000-4000-8000-000000000031"
    private static let validPlanData = Data("""
    {
      "version": 1,
      "execution_nonce": "\(Self.nonce)",
      "monitor_instance_id": "\(Self.monitorID)",
      "socket_path": "/private/tmp/peekaboo-monitor-attestation.sock",
      "expected_peer": {
        "pid": 8001,
        "start_identity": "800100",
        "code_signature_hash": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      },
      "response_kind": "monitor",
      "artifacts_directory": "/private/tmp/peekaboo-monitor-attestation",
      "output_path": "/private/tmp/peekaboo-monitor-attestation/response.json",
      "release_path": "/private/tmp/peekaboo-monitor-attestation/release.json",
      "timeout_milliseconds": 2000,
      "maximum_response_bytes": 65536
    }
    """.utf8)

    private static func keys(_ value: some Encodable) throws -> Set<String> {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        return Set(object.keys)
    }
}
