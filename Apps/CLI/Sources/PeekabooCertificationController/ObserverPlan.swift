import Foundation

struct CertificationSemanticElement: Codable, Equatable, Sendable {
    let role: String
    let identifier: String?
    let title: String?
}

struct CertificationObserveOnlyPlan: Codable, Equatable, Sendable {
    let version: Int
    let mode: CertificationObserverMode
    let executionNonce: String
    let monitorInstanceID: String
    let observerID: String
    let clientInstanceID: String
    let socketPath: String
    let trustedBridgeHostTeamIDs: [String]
    let expectedControllerBuild: CertificationExpectedControllerBuild
    let expectedHost: CertificationExpectedHost
    let target: CertificationWindowReceipt
    let semanticElement: CertificationSemanticElement
    let requestMarker: String
    let expectedValueSHA256: String
    let baselineValueSHA256: String
    let artifactsDirectory: String
    let readyPath: String
    let observationRequestPath: String
    let restorationRequestPath: String
    let releasePath: String
    let observationPath: String
    let restorationPath: String
    let witnessPath: String
    let attestationSocketPath: String
    let waitTimeoutSeconds: Int
    let pollIntervalMilliseconds: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case mode
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case observerID = "observer_id"
        case clientInstanceID = "client_instance_id"
        case socketPath = "socket_path"
        case trustedBridgeHostTeamIDs = "trusted_bridge_host_team_ids"
        case expectedControllerBuild = "expected_controller_build"
        case expectedHost = "expected_host"
        case target
        case semanticElement = "semantic_element"
        case requestMarker = "request_marker"
        case expectedValueSHA256 = "expected_value_sha256"
        case baselineValueSHA256 = "baseline_value_sha256"
        case artifactsDirectory = "artifacts_directory"
        case readyPath = "ready_path"
        case observationRequestPath = "observation_request_path"
        case restorationRequestPath = "restoration_request_path"
        case releasePath = "release_path"
        case observationPath = "observation_path"
        case restorationPath = "restoration_path"
        case witnessPath = "witness_path"
        case attestationSocketPath = "attestation_socket_path"
        case waitTimeoutSeconds = "wait_timeout_seconds"
        case pollIntervalMilliseconds = "poll_interval_milliseconds"
    }

    var clientUUID: UUID? {
        UUID(uuidString: self.clientInstanceID)
    }

    var artifactsURL: URL {
        URL(fileURLWithPath: self.artifactsDirectory, isDirectory: true)
    }

    var readyURL: URL {
        URL(fileURLWithPath: self.readyPath)
    }

    var observationRequestURL: URL {
        URL(fileURLWithPath: self.observationRequestPath)
    }

    var restorationRequestURL: URL {
        URL(fileURLWithPath: self.restorationRequestPath)
    }

    var releaseURL: URL {
        URL(fileURLWithPath: self.releasePath)
    }

    var observationURL: URL {
        URL(fileURLWithPath: self.observationPath)
    }

    var restorationURL: URL {
        URL(fileURLWithPath: self.restorationPath)
    }

    var witnessURL: URL {
        URL(fileURLWithPath: self.witnessPath)
    }

    static func decode(_ data: Data) throws -> Self {
        try CertificationObserverPlanShape.validate(data)
        let plan: Self
        do {
            plan = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CertificationControllerError.invalidPlan("Observe-only plan is not valid JSON: \(error)")
        }
        try plan.validate()
        return plan
    }

    func validate() throws {
        let expectedMarker = "peekaboo-foreground-postcondition:\(self.executionNonce)"
        let expectedDigest = CertificationPrivateArtifacts.sha256(Data(expectedMarker.utf8))
        let hasIdentifier = self.semanticElement.identifier?.isEmpty == false
        let hasTitle = self.semanticElement.title?.isEmpty == false
        guard self.version == 1,
              self.mode == .observeOnly,
              Self.isLowerHex(self.executionNonce, count: 64),
              Self.isCanonicalV4UUID(self.monitorInstanceID),
              Self.isSafeID(self.observerID),
              Self.isCanonicalV4UUID(self.clientInstanceID),
              self.clientUUID != nil,
              self.requestMarker == expectedMarker,
              self.expectedValueSHA256 == expectedDigest,
              Self.isLowerHex(self.baselineValueSHA256, count: 64),
              self.baselineValueSHA256 != self.expectedValueSHA256
        else {
            throw CertificationControllerError.invalidPlan(
                "Observe-only run binding, marker, or semantic value digests are invalid."
            )
        }
        guard Self.isAbsolutePath(self.socketPath),
              Self.isAbsolutePath(self.artifactsDirectory),
              URL(fileURLWithPath: self.artifactsDirectory).pathComponents.count > 2,
              !self.trustedBridgeHostTeamIDs.isEmpty,
              Set(self.trustedBridgeHostTeamIDs).count == self.trustedBridgeHostTeamIDs.count,
              self.trustedBridgeHostTeamIDs.allSatisfy(Self.isTeamID)
        else {
            throw CertificationControllerError.invalidPlan(
                "Observe-only socket, artifact root, or Bridge Team IDs are invalid."
            )
        }
        guard Self.isLowerHex(self.expectedControllerBuild.sourceCommit, count: 40),
              Self.isAbsolutePath(self.expectedControllerBuild.executablePath),
              Self.isLowerHex(self.expectedControllerBuild.executableSHA256, count: 64),
              Self.isTeamID(self.expectedControllerBuild.teamID),
              self.expectedHost.processIdentifier > 0,
              Self.isPositiveDecimal(self.expectedHost.processStartIdentityDecimal),
              Self.isLowerHex(self.expectedHost.codeSignatureHash, count: 40),
              Self.isLowerHex(self.expectedHost.sourceCommit, count: 40),
              self.expectedHost.sourceCommit == self.expectedControllerBuild.sourceCommit
        else {
            throw CertificationControllerError.invalidPlan(
                "Observe-only controller and Bridge host must be one source-identical build."
            )
        }
        guard self.target.scope == "window",
              self.target.pid > 0,
              Self.isPositiveDecimal(self.target.startIdentity),
              self.target.windowID > 0,
              UInt32(exactly: self.target.windowID) != nil,
              self.target.bounds.cgRect.width > 0,
              self.target.bounds.cgRect.height > 0,
              !self.semanticElement.role.isEmpty,
              self.semanticElement.role.utf8.count <= 256,
              !self.semanticElement.role.contains("\0"),
              hasIdentifier || hasTitle,
              self.semanticElement.identifier?.utf8.count ?? 0 <= 1024,
              self.semanticElement.title?.utf8.count ?? 0 <= 1024,
              self.semanticElement.identifier?.contains("\0") != true,
              self.semanticElement.title?.contains("\0") != true
        else {
            throw CertificationControllerError.invalidPlan(
                "Observe-only exact window or semantic element identity is invalid."
            )
        }
        let paths = [
            self.readyPath,
            self.observationRequestPath,
            self.restorationRequestPath,
            self.releasePath,
            self.observationPath,
            self.restorationPath,
            self.witnessPath,
            self.attestationSocketPath,
        ]
        guard Set(paths).count == paths.count,
              paths.allSatisfy(Self.isAbsolutePath),
              paths.allSatisfy({ Self.isInside($0, root: self.artifactsDirectory) }),
              (1...3600).contains(self.waitTimeoutSeconds),
              (10...1000).contains(self.pollIntervalMilliseconds)
        else {
            throw CertificationControllerError.invalidPlan(
                "Observe-only evidence paths or wait bounds are invalid."
            )
        }
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isPositiveDecimal(_ value: String) -> Bool {
        guard value.first != "0", let parsed = UInt64(value), parsed > 0 else { return false }
        return String(parsed) == value
    }

    private static func isCanonicalV4UUID(_ value: String) -> Bool {
        guard value == value.lowercased(), value.count == 36,
              value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]),
              let uuid = UUID(uuidString: value)
        else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isSafeID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count),
              bytes.first.map(Self.isLowercaseASCIIOrDigit) == true,
              bytes.last.map(Self.isLowercaseASCIIOrDigit) == true
        else { return false }
        return bytes.allSatisfy { Self.isLowercaseASCIIOrDigit($0) || $0 == 0x2D }
    }

    private static func isLowercaseASCIIOrDigit(_ value: UInt8) -> Bool {
        (0x61...0x7A).contains(value) || (0x30...0x39).contains(value)
    }

    private static func isTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
        }
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isInside(_ path: String, root: String) -> Bool {
        let rootPath = URL(fileURLWithPath: root).standardizedFileURL.path
        let childPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return URL(fileURLWithPath: childPath).deletingLastPathComponent().path == rootPath
    }
}

private enum CertificationObserverPlanShape {
    private static let rootKeys: Set<String> = [
        "version", "mode", "execution_nonce", "observer_id", "client_instance_id", "socket_path",
        "monitor_instance_id",
        "trusted_bridge_host_team_ids", "expected_controller_build", "expected_host", "target",
        "semantic_element", "request_marker", "expected_value_sha256", "baseline_value_sha256",
        "artifacts_directory", "ready_path", "observation_request_path", "restoration_request_path",
        "release_path", "observation_path", "restoration_path", "witness_path", "wait_timeout_seconds",
        "poll_interval_milliseconds", "attestation_socket_path",
    ]
    private static let buildKeys: Set<String> = [
        "source_commit", "executable_path", "executable_sha256", "team_id",
    ]
    private static let hostKeys: Set<String> = [
        "host_kind", "process_identifier", "process_start_identity_decimal", "code_signature_hash",
        "source_commit",
    ]
    private static let targetKeys: Set<String> = [
        "scope", "pid", "start_identity", "window_id", "bounds", "is_minimized",
    ]
    private static let boundsKeys: Set<String> = ["x", "y", "width", "height"]
    private static let semanticKeys: Set<String> = ["role", "identifier", "title"]

    static func validate(_ data: Data) throws {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CertificationControllerError.invalidPlan("Observe-only plan must be one JSON object.")
            }
            root = object
        } catch let error as CertificationControllerError {
            throw error
        } catch {
            throw CertificationControllerError.invalidPlan("Observe-only plan is not valid JSON: \(error)")
        }
        try self.requireExact(root, keys: self.rootKeys, label: "observe-only plan")
        try self.requireNested(root, key: "expected_controller_build", keys: self.buildKeys)
        try self.requireNested(root, key: "expected_host", keys: self.hostKeys)
        let target = try self.nested(root, key: "target")
        try self.requireExact(target, keys: self.targetKeys, label: "target")
        try self.requireNested(target, key: "bounds", keys: self.boundsKeys)
        try self.requireNested(root, key: "semantic_element", keys: self.semanticKeys)
    }

    private static func requireNested(
        _ root: [String: Any],
        key: String,
        keys: Set<String>
    ) throws {
        try self.requireExact(self.nested(root, key: key), keys: keys, label: key)
    }

    private static func nested(_ root: [String: Any], key: String) throws -> [String: Any] {
        guard let value = root[key] as? [String: Any] else {
            throw CertificationControllerError.invalidPlan("\(key) must be one object.")
        }
        return value
    }

    private static func requireExact(
        _ value: [String: Any],
        keys: Set<String>,
        label: String
    ) throws {
        guard Set(value.keys) == keys else {
            throw CertificationControllerError.invalidPlan("\(label) keys are not closed.")
        }
    }
}
