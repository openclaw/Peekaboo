import Darwin
import Foundation

enum CertificationMonitorAttestationRunner {
    static func run(planURL: URL) async throws -> URL {
        let plan = try CertificationMonitorAttestationClientPlan.decode(
            CertificationPrivateArtifacts.readPlan(at: planURL)
        )
        try CertificationPrivateArtifacts.preparePrivateDirectory(plan.artifactsURL)
        var existing = stat()
        guard lstat(plan.outputURL.path, &existing) != 0, errno == ENOENT else {
            throw CertificationControllerError.unsafePrivatePath(
                "Monitor attestation output already exists."
            )
        }
        let descriptor = try CertificationUnixSocket.connect(
            path: plan.socketPath,
            timeoutMilliseconds: plan.timeoutMilliseconds
        )
        defer { close(descriptor) }
        let peerBefore = try CertificationAttestationPeerIdentityResolver.resolve(descriptor: descriptor)
        try CertificationAttestationPeerIdentityResolver.requireExpected(
            peerBefore,
            expected: plan.expectedPeer
        )
        let challenge = try CertificationAttestationChallenge.random()
        let request = CertificationAttestationRequest(
            version: 1,
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            challenge: challenge
        )
        try CertificationUnixSocket.writeJSON(request, descriptor: descriptor)
        let data = try CertificationUnixSocket.readJSONLine(
            descriptor: descriptor,
            maximumBytes: plan.maximumResponseBytes,
            timeoutMilliseconds: plan.timeoutMilliseconds
        )
        let peerAfter = try CertificationAttestationPeerIdentityResolver.resolve(descriptor: descriptor)
        try CertificationAttestationPeerIdentityResolver.requireExpected(
            peerAfter,
            expected: plan.expectedPeer
        )
        try CertificationAttestationPeerIdentityResolver.requireStable(before: peerBefore, after: peerAfter)
        let output: Data = switch plan.responseKind {
        case .monitor:
            try self.validateMonitorResponse(data, request: request, expectedPeer: plan.expectedPeer)
        case .observer:
            try self.validateObserverResponse(data, request: request, expectedPeer: plan.expectedPeer)
        }
        try CertificationPrivateArtifacts.writeReceipt(output, to: plan.outputURL)
        try await CertificationControllerLifecycleGate.waitForRelease(
            at: plan.releaseURL,
            executionNonce: plan.executionNonce
        )
        return plan.outputURL
    }

    static func validateMonitorResponse(
        _ data: Data,
        request: CertificationAttestationRequest,
        expectedPeer: CertificationProcessReceipt
    ) throws -> Data {
        try self.requireKeys(data, [
            "version", "execution_nonce", "monitor_instance_id", "challenge", "monitor",
            "monitor_evidence_sha256",
        ])
        try self.requireProcessKeys(data, key: "monitor")
        let response = try JSONDecoder().decode(CertificationMonitorAttestationResponse.self, from: data)
        guard response.version == 1,
              response.executionNonce == request.executionNonce,
              response.monitorInstanceID == request.monitorInstanceID,
              response.challenge == request.challenge,
              response.monitor == expectedPeer,
              Self.isProcess(response.monitor),
              Self.isHex(response.monitorEvidenceSHA256, count: 64)
        else { throw self.refusal() }
        return try self.encoded(response)
    }

    static func validateObserverResponse(
        _ data: Data,
        request: CertificationAttestationRequest,
        expectedPeer: CertificationProcessReceipt
    ) throws -> Data {
        try self.requireKeys(data, [
            "version", "execution_nonce", "monitor_instance_id", "challenge", "observer", "witness_sha256",
            "observation_file_sha256", "restoration_file_sha256", "before_value_sha256",
            "expected_value_sha256", "observed_value_sha256", "restored_value_sha256",
        ])
        try self.requireProcessKeys(data, key: "observer")
        let response = try JSONDecoder().decode(CertificationObserverAttestationResponse.self, from: data)
        let digests = [
            response.witnessSHA256,
            response.observationFileSHA256,
            response.restorationFileSHA256,
            response.beforeValueSHA256,
            response.expectedValueSHA256,
            response.observedValueSHA256,
            response.restoredValueSHA256,
        ]
        guard response.version == 1,
              response.executionNonce == request.executionNonce,
              response.monitorInstanceID == request.monitorInstanceID,
              response.challenge == request.challenge,
              response.observer == expectedPeer,
              Self.isProcess(response.observer),
              digests.allSatisfy({ Self.isHex($0, count: 64) })
        else { throw self.refusal() }
        return try self.encoded(response)
    }

    private static func requireKeys(_ data: Data, _ keys: Set<String>) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any], Set(dictionary.keys) == keys else {
            throw self.refusal()
        }
    }

    private static func requireProcessKeys(_ data: Data, key: String) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              let process = dictionary[key] as? [String: Any],
              Set(process.keys) == ["pid", "start_identity", "code_signature_hash"]
        else { throw self.refusal() }
    }

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    private static func isProcess(_ process: CertificationProcessReceipt) -> Bool {
        guard process.pid > 0,
              process.startIdentity.first != "0",
              let startIdentity = UInt64(process.startIdentity),
              startIdentity > 0,
              String(startIdentity) == process.startIdentity
        else { return false }
        return self.isHex(process.codeSignatureHash, count: 40)
    }

    private static func isHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func refusal() -> CertificationControllerError {
        .runtimeRefusal("Unix attestation response is not closed or challenge/run bound.")
    }
}
