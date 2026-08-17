import CryptoKit
import Foundation

struct HeldPointerCertificationPlan: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let requiredHoldMilliseconds = 500
    private static let clientInstanceDomain = Data(
        "peekaboo.held-pointer-certification.client.v1\0".utf8
    )

    let version: Int
    let executionNonce: String
    let socketPath: String
    let trustedBridgeHostTeamIDs: [String]
    let expectedControllerBuild: CertificationExpectedControllerBuild
    let expectedHost: CertificationExpectedHost
    let target: CertificationExactTarget
    let holdMilliseconds: Int
    let artifactsDirectory: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case socketPath = "socket_path"
        case trustedBridgeHostTeamIDs = "trusted_bridge_host_team_ids"
        case expectedControllerBuild = "expected_controller_build"
        case expectedHost = "expected_host"
        case target
        case holdMilliseconds = "hold_milliseconds"
        case artifactsDirectory = "artifacts_directory"
    }

    var clientUUID: UUID? {
        Self.derivedClientInstanceID(executionNonce: self.executionNonce)
    }

    var artifactsURL: URL {
        URL(fileURLWithPath: self.artifactsDirectory, isDirectory: true)
    }

    var bundleDirectoryURL: URL {
        self.artifactsURL.appendingPathComponent("bundles", isDirectory: true)
    }

    var receiptURL: URL {
        self.artifactsURL.appendingPathComponent("held-pointer-receipt.json", isDirectory: false)
    }

    static func decode(_ data: Data) throws -> Self {
        try HeldPointerCertificationPlanShape.validate(data)
        let plan: Self
        do {
            plan = try JSONDecoder().decode(Self.self, from: data)
        } catch {
            throw CertificationControllerError.invalidPlan(
                "Held-pointer plan is not valid JSON: \(error)"
            )
        }
        try plan.validate()
        return plan
    }

    func validate() throws {
        guard self.version == Self.currentVersion else {
            throw CertificationControllerError.invalidPlan("Held-pointer plan version must be 1.")
        }
        guard CertificationControllerPlan.isLowerHex(self.executionNonce, count: 64) else {
            throw CertificationControllerError.invalidPlan(
                "execution_nonce must be exactly 64 lowercase hex digits."
            )
        }
        guard self.clientUUID != nil else {
            throw CertificationControllerError.invalidPlan(
                "execution_nonce cannot derive the held-pointer client identity."
            )
        }
        guard CertificationControllerPlan.isAbsolutePath(self.socketPath),
              CertificationControllerPlan.isAbsolutePath(self.artifactsDirectory),
              self.artifactsURL.pathComponents.count > 2
        else {
            throw CertificationControllerError.invalidPlan(
                "socket_path and a narrow artifacts_directory must be absolute paths."
            )
        }
        guard !self.trustedBridgeHostTeamIDs.isEmpty,
              Set(self.trustedBridgeHostTeamIDs).count == self.trustedBridgeHostTeamIDs.count,
              self.trustedBridgeHostTeamIDs.allSatisfy(CertificationControllerPlan.isTeamID)
        else {
            throw CertificationControllerError.invalidPlan(
                "trusted_bridge_host_team_ids must be a nonempty unique list of 10-character Team IDs."
            )
        }
        guard CertificationControllerPlan.isLowerHex(self.expectedControllerBuild.sourceCommit, count: 40),
              CertificationControllerPlan.isAbsolutePath(self.expectedControllerBuild.executablePath),
              CertificationControllerPlan.isLowerHex(self.expectedControllerBuild.executableSHA256, count: 64),
              CertificationControllerPlan.isTeamID(self.expectedControllerBuild.teamID)
        else {
            throw CertificationControllerError.invalidPlan(
                "expected_controller_build contains an invalid source, path, digest, or Team ID."
            )
        }
        guard self.expectedHost.processIdentifier > 0,
              CertificationControllerPlan.isCanonicalPositiveDecimal(
                  self.expectedHost.processStartIdentityDecimal
              ),
              self.expectedHost.processStartIdentity != nil,
              CertificationControllerPlan.isLowerHex(self.expectedHost.codeSignatureHash, count: 40),
              CertificationControllerPlan.isLowerHex(self.expectedHost.sourceCommit, count: 40),
              self.expectedHost.sourceCommit == self.expectedControllerBuild.sourceCommit
        else {
            throw CertificationControllerError.invalidPlan(
                "expected_host and expected_controller_build must be one source-identical build."
            )
        }
        guard self.target.processIdentifier > 0,
              self.target.processIdentifier != self.expectedHost.processIdentifier,
              CertificationControllerPlan.isCanonicalPositiveDecimal(
                  self.target.processStartIdentityDecimal
              ),
              self.target.processStartIdentity != nil,
              self.target.windowID > 0,
              UInt32(exactly: self.target.windowID) != nil,
              self.target.isMinimized == false,
              CertificationControllerPlan.isFinitePositiveRect(self.target.bounds.cgRect),
              self.target.bounds.cgRect.contains(self.target.clickPoint.cgPoint)
        else {
            throw CertificationControllerError.invalidPlan(
                "target must be one visible exact process generation and window distinct from the host."
            )
        }
        guard self.holdMilliseconds == Self.requiredHoldMilliseconds else {
            throw CertificationControllerError.invalidPlan(
                "hold_milliseconds must be exactly \(Self.requiredHoldMilliseconds)."
            )
        }
    }

    static func derivedClientInstanceID(executionNonce: String) -> UUID? {
        guard CertificationControllerPlan.isLowerHex(executionNonce, count: 64) else { return nil }
        var input = Self.clientInstanceDomain
        input.append(Data(executionNonce.utf8))
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

private enum HeldPointerCertificationPlanShape {
    private static let rootKeys: Set<String> = [
        "version",
        "execution_nonce",
        "socket_path",
        "trusted_bridge_host_team_ids",
        "expected_controller_build",
        "expected_host",
        "target",
        "hold_milliseconds",
        "artifacts_directory",
    ]
    private static let controllerBuildKeys: Set<String> = [
        "source_commit", "executable_path", "executable_sha256", "team_id",
    ]
    private static let hostKeys: Set<String> = [
        "host_kind", "process_identifier", "process_start_identity_decimal",
        "code_signature_hash", "source_commit",
    ]
    private static let targetKeys: Set<String> = [
        "process_identifier", "process_start_identity_decimal", "window_id", "bounds",
        "is_minimized", "click_point",
    ]
    private static let boundsKeys: Set<String> = ["x", "y", "width", "height"]
    private static let pointKeys: Set<String> = ["x", "y"]

    static func validate(_ data: Data) throws {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CertificationControllerError.invalidPlan(
                    "Held-pointer plan must be one JSON object."
                )
            }
            root = object
        } catch let error as CertificationControllerError {
            throw error
        } catch {
            throw CertificationControllerError.invalidPlan(
                "Held-pointer plan is not valid JSON: \(error)"
            )
        }
        try self.requireExactKeys(root, self.rootKeys, label: "held-pointer plan")
        guard let controllerBuild = root["expected_controller_build"] as? [String: Any],
              let host = root["expected_host"] as? [String: Any],
              let target = root["target"] as? [String: Any],
              let bounds = target["bounds"] as? [String: Any],
              let point = target["click_point"] as? [String: Any]
        else {
            throw CertificationControllerError.invalidPlan(
                "Held-pointer build, host, target, bounds, and point must be objects."
            )
        }
        try self.requireExactKeys(
            controllerBuild,
            self.controllerBuildKeys,
            label: "expected_controller_build"
        )
        try self.requireExactKeys(host, self.hostKeys, label: "expected_host")
        try self.requireExactKeys(target, self.targetKeys, label: "target")
        try self.requireExactKeys(bounds, self.boundsKeys, label: "target.bounds")
        try self.requireExactKeys(point, self.pointKeys, label: "target.click_point")
    }

    private static func requireExactKeys(
        _ value: [String: Any],
        _ expected: Set<String>,
        label: String
    ) throws {
        let actual = Set(value.keys)
        guard actual == expected else {
            let missing = expected.subtracting(actual).sorted().joined(separator: ", ")
            let extra = actual.subtracting(expected).sorted().joined(separator: ", ")
            throw CertificationControllerError.invalidPlan(
                "\(label) keys are not closed (missing: [\(missing)], extra: [\(extra)])."
            )
        }
    }
}
