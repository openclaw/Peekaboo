import CoreGraphics
import Foundation
import PeekabooBridge

enum CertificationControllerError: Error, LocalizedError, Equatable {
    case invalidArguments(String)
    case invalidPlan(String)
    case unsafePrivatePath(String)
    case runtimeRefusal(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message),
             let .invalidPlan(message),
             let .unsafePrivatePath(message),
             let .runtimeRefusal(message):
            message
        }
    }
}

struct CertificationPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    var cgPoint: CGPoint {
        CGPoint(x: self.x, y: self.y)
    }
}

struct CertificationBounds: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect {
        CGRect(x: self.x, y: self.y, width: self.width, height: self.height)
    }
}

struct CertificationExpectedHost: Codable, Equatable, Sendable {
    let hostKind: PeekabooBridgeHostKind
    let processIdentifier: Int32
    let processStartIdentityDecimal: String
    let codeSignatureHash: String
    let sourceCommit: String

    private enum CodingKeys: String, CodingKey {
        case hostKind = "host_kind"
        case processIdentifier = "process_identifier"
        case processStartIdentityDecimal = "process_start_identity_decimal"
        case codeSignatureHash = "code_signature_hash"
        case sourceCommit = "source_commit"
    }

    var processStartIdentity: UInt64? {
        UInt64(self.processStartIdentityDecimal)
    }
}

struct CertificationExpectedControllerBuild: Codable, Equatable, Sendable {
    let sourceCommit: String
    let executablePath: String
    let executableSHA256: String
    let teamID: String

    private enum CodingKeys: String, CodingKey {
        case sourceCommit = "source_commit"
        case executablePath = "executable_path"
        case executableSHA256 = "executable_sha256"
        case teamID = "team_id"
    }

    func requireMatches(_ observed: CertificationControllerBuildReceipt) throws {
        guard self.sourceCommit == observed.sourceCommit else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller source commit does not match the plan."
            )
        }
        guard self.executablePath == observed.executablePath else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller executable path does not match the kernel-bound path."
            )
        }
        guard self.executableSHA256 == observed.executableSHA256 else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller executable SHA-256 does not match the plan."
            )
        }
        guard self.teamID == observed.teamID else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller signing Team ID does not match the plan."
            )
        }
    }
}

struct CertificationExactTarget: Codable, Equatable, Sendable {
    let processIdentifier: Int32
    let processStartIdentityDecimal: String
    let windowID: Int
    let bounds: CertificationBounds
    let isMinimized: Bool?
    let clickPoint: CertificationPoint

    private enum CodingKeys: String, CodingKey {
        case processIdentifier = "process_identifier"
        case processStartIdentityDecimal = "process_start_identity_decimal"
        case windowID = "window_id"
        case bounds
        case isMinimized = "is_minimized"
        case clickPoint = "click_point"
    }

    var processStartIdentity: UInt64? {
        UInt64(self.processStartIdentityDecimal)
    }
}

struct CertificationControllerPlan: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let controllerID: String
    let targetID: String
    let clientInstanceID: String
    let socketPath: String
    let trustedBridgeHostTeamIDs: [String]
    let expectedControllerBuild: CertificationExpectedControllerBuild
    let expectedHost: CertificationExpectedHost
    let target: CertificationExactTarget
    let typeText: String
    let typingDelayMilliseconds: Int
    let artifactsDirectory: String
    let readyPath: String
    let startPath: String
    let finalBoundsReadyPath: String
    let finalBoundsStartPath: String
    let releasePath: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case controllerID = "controller_id"
        case targetID = "target_id"
        case clientInstanceID = "client_instance_id"
        case socketPath = "socket_path"
        case trustedBridgeHostTeamIDs = "trusted_bridge_host_team_ids"
        case expectedControllerBuild = "expected_controller_build"
        case expectedHost = "expected_host"
        case target
        case typeText = "type_text"
        case typingDelayMilliseconds = "typing_delay_milliseconds"
        case artifactsDirectory = "artifacts_directory"
        case readyPath = "ready_path"
        case startPath = "start_path"
        case finalBoundsReadyPath = "final_bounds_ready_path"
        case finalBoundsStartPath = "final_bounds_start_path"
        case releasePath = "release_path"
    }

    var clientUUID: UUID? {
        UUID(uuidString: self.clientInstanceID)
    }

    var monitorUUID: UUID? {
        UUID(uuidString: self.monitorInstanceID)
    }

    var artifactsURL: URL {
        URL(fileURLWithPath: self.artifactsDirectory, isDirectory: true)
    }

    var bundleDirectoryURL: URL {
        self.artifactsURL.appendingPathComponent("bundles", isDirectory: true)
    }

    var observationDirectoryURL: URL {
        self.artifactsURL.appendingPathComponent("observations", isDirectory: true)
    }

    var receiptURL: URL {
        self.artifactsURL.appendingPathComponent("\(self.controllerID)-receipt.json")
    }

    var mutationStartedURL: URL {
        self.artifactsURL.appendingPathComponent("mutation-started.json")
    }

    var mutationCompletedURL: URL {
        self.artifactsURL.appendingPathComponent("mutation-completed.json")
    }

    var releaseURL: URL {
        URL(fileURLWithPath: self.releasePath)
    }

    var readyURL: URL {
        URL(fileURLWithPath: self.readyPath)
    }

    var startURL: URL {
        URL(fileURLWithPath: self.startPath)
    }

    var finalBoundsReadyURL: URL {
        URL(fileURLWithPath: self.finalBoundsReadyPath)
    }

    var finalBoundsStartURL: URL {
        URL(fileURLWithPath: self.finalBoundsStartPath)
    }

    var slots: [CertificationSlot] {
        [
            .init(
                id: "\(self.controllerID)-mutation-001",
                kind: .typeMutation,
                operation: .exactWindowTargetedTypeActions,
                checkpoint: nil
            ),
            .init(
                id: "\(self.controllerID)-protocol-130-001",
                kind: .tripleClick,
                operation: .exactWindowTargetedClick,
                checkpoint: nil
            ),
            .init(
                id: "\(self.controllerID)-checkpoint-001",
                kind: .observation,
                operation: .desktopObservation,
                checkpoint: "post-mutation"
            ),
            .init(
                id: "\(self.controllerID)-final-bounds",
                kind: .observation,
                operation: .desktopObservation,
                checkpoint: "final-bounds"
            ),
        ]
    }

    static func decode(_ data: Data) throws -> Self {
        try CertificationPlanShape.validate(data)
        let decoder = JSONDecoder()
        let plan: Self
        do {
            plan = try decoder.decode(Self.self, from: data)
        } catch {
            throw CertificationControllerError.invalidPlan("Controller plan is not valid JSON: \(error)")
        }
        try plan.validate()
        return plan
    }

    func validate() throws {
        guard self.version == Self.currentVersion else {
            throw CertificationControllerError.invalidPlan("Controller plan version must be 1.")
        }
        guard Self.isLowerHex(self.executionNonce, count: 64) else {
            throw CertificationControllerError.invalidPlan("execution_nonce must be exactly 64 lowercase hex digits.")
        }
        guard Self.isCanonicalV4UUID(self.monitorInstanceID), self.monitorUUID != nil else {
            throw CertificationControllerError.invalidPlan("monitor_instance_id must be a lowercase UUIDv4.")
        }
        guard Self.isCanonicalV4UUID(self.clientInstanceID), self.clientUUID != nil else {
            throw CertificationControllerError.invalidPlan("client_instance_id must be a lowercase UUIDv4.")
        }
        guard Self.isSafeID(self.controllerID), Self.isSafeID(self.targetID) else {
            throw CertificationControllerError.invalidPlan(
                "controller_id and target_id must contain only lowercase letters, digits, and hyphens."
            )
        }
        guard Self.isAbsolutePath(self.socketPath), Self.isAbsolutePath(self.artifactsDirectory) else {
            throw CertificationControllerError
                .invalidPlan("socket_path and artifacts_directory must be absolute paths.")
        }
        guard URL(fileURLWithPath: self.artifactsDirectory).pathComponents.count > 2 else {
            throw CertificationControllerError.invalidPlan("artifacts_directory is too broad.")
        }
        let artifactPath = self.artifactsURL.standardizedFileURL.path
        let lifecycleURLs = [
            self.readyURL,
            self.startURL,
            self.finalBoundsReadyURL,
            self.finalBoundsStartURL,
            self.releaseURL,
        ]
        let reservedURLs = [self.receiptURL, self.mutationStartedURL, self.mutationCompletedURL]
        guard Set(lifecycleURLs.map(\.standardizedFileURL)).count == lifecycleURLs.count,
              lifecycleURLs.allSatisfy({ Self.isAbsolutePath($0.path) }),
              lifecycleURLs.allSatisfy({
                  $0.standardizedFileURL.deletingLastPathComponent().path == artifactPath
              }),
              lifecycleURLs.allSatisfy({ !reservedURLs.contains($0) })
        else {
            throw CertificationControllerError.invalidPlan(
                "Controller lifecycle paths must be distinct files inside artifacts_directory."
            )
        }
        guard !self.trustedBridgeHostTeamIDs.isEmpty,
              Set(self.trustedBridgeHostTeamIDs).count == self.trustedBridgeHostTeamIDs.count,
              self.trustedBridgeHostTeamIDs.allSatisfy(Self.isTeamID)
        else {
            throw CertificationControllerError.invalidPlan(
                "trusted_bridge_host_team_ids must be a nonempty unique list of 10-character Team IDs."
            )
        }
        guard Self.isLowerHex(self.expectedControllerBuild.sourceCommit, count: 40),
              Self.isAbsolutePath(self.expectedControllerBuild.executablePath),
              Self.isLowerHex(self.expectedControllerBuild.executableSHA256, count: 64),
              Self.isTeamID(self.expectedControllerBuild.teamID)
        else {
            throw CertificationControllerError.invalidPlan(
                "expected_controller_build contains an invalid source, path, digest, or Team ID."
            )
        }
        guard self.expectedHost.processIdentifier > 0,
              Self.isCanonicalPositiveDecimal(self.expectedHost.processStartIdentityDecimal),
              self.expectedHost.processStartIdentity != nil,
              Self.isLowerHex(self.expectedHost.codeSignatureHash, count: 40),
              Self.isLowerHex(self.expectedHost.sourceCommit, count: 40),
              self.expectedHost.sourceCommit == self.expectedControllerBuild.sourceCommit
        else {
            throw CertificationControllerError
                .invalidPlan("expected_host and expected_controller_build must be one source-identical build.")
        }
        guard self.target.processIdentifier > 0,
              Self.isCanonicalPositiveDecimal(self.target.processStartIdentityDecimal),
              self.target.processStartIdentity != nil,
              self.target.windowID > 0,
              UInt32(exactly: self.target.windowID) != nil,
              Self.isFinitePositiveRect(self.target.bounds.cgRect),
              self.target.bounds.cgRect.contains(self.target.clickPoint.cgPoint)
        else {
            throw CertificationControllerError.invalidPlan("target must be one exact process generation and window.")
        }
        guard !self.typeText.isEmpty, self.typeText.utf8.count <= 4096 else {
            throw CertificationControllerError.invalidPlan("type_text must contain 1 through 4096 UTF-8 bytes.")
        }
        guard (1...50).contains(self.typingDelayMilliseconds) else {
            throw CertificationControllerError.invalidPlan(
                "typing_delay_milliseconds must be between 1 and 50."
            )
        }
    }

    func marker(for slot: CertificationSlot) -> String {
        "peekaboo-certification-run:\(self.executionNonce):slot:\(slot.id)"
    }

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    static func isCanonicalPositiveDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.first != "0",
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let parsed = UInt64(value),
              parsed > 0
        else { return false }
        return String(parsed) == value
    }

    static func isCanonicalV4UUID(_ value: String) -> Bool {
        guard value == value.lowercased(),
              value.count == 36,
              value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]),
              let uuid = UUID(uuidString: value)
        else { return false }
        return uuid.uuidString.lowercased() == value
    }

    static func isSafeID(_ value: String) -> Bool {
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

    static func isTeamID(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    static func isAbsolutePath(_ value: String) -> Bool {
        guard value.hasPrefix("/"), !value.contains("\0") else { return false }
        return !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite &&
            rect.width > 0 && rect.height > 0
    }
}

struct CertificationSlot: Equatable, Sendable {
    enum Kind: String, Sendable {
        case typeMutation = "type-mutation"
        case tripleClick = "triple-click"
        case observation
    }

    let id: String
    let kind: Kind
    let operation: PeekabooBridgeOperation
    let checkpoint: String?
}

private enum CertificationPlanShape {
    private static let rootKeys: Set<String> = [
        "version", "execution_nonce", "monitor_instance_id", "controller_id", "target_id",
        "client_instance_id", "socket_path", "trusted_bridge_host_team_ids", "expected_controller_build",
        "expected_host", "target", "type_text", "typing_delay_milliseconds", "artifacts_directory",
        "ready_path", "start_path", "final_bounds_ready_path", "final_bounds_start_path", "release_path",
    ]
    private static let controllerBuildKeys: Set<String> = [
        "source_commit", "executable_path", "executable_sha256", "team_id",
    ]
    private static let hostKeys: Set<String> = [
        "host_kind", "process_identifier", "process_start_identity_decimal", "code_signature_hash",
        "source_commit",
    ]
    private static let targetKeys: Set<String> = [
        "process_identifier", "process_start_identity_decimal", "window_id", "bounds", "is_minimized",
        "click_point",
    ]
    private static let boundsKeys: Set<String> = ["x", "y", "width", "height"]
    private static let pointKeys: Set<String> = ["x", "y"]

    static func validate(_ data: Data) throws {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CertificationControllerError.invalidPlan("Controller plan must be one JSON object.")
            }
            root = object
        } catch let error as CertificationControllerError {
            throw error
        } catch {
            throw CertificationControllerError.invalidPlan("Controller plan is not valid JSON: \(error)")
        }
        try self.requireExactKeys(root, self.rootKeys, label: "controller plan")
        guard let controllerBuild = root["expected_controller_build"] as? [String: Any] else {
            throw CertificationControllerError.invalidPlan("expected_controller_build must be one object.")
        }
        try self.requireExactKeys(
            controllerBuild,
            self.controllerBuildKeys,
            label: "expected_controller_build"
        )
        guard let host = root["expected_host"] as? [String: Any] else {
            throw CertificationControllerError.invalidPlan("expected_host must be one object.")
        }
        try self.requireExactKeys(host, self.hostKeys, label: "expected_host")
        guard let target = root["target"] as? [String: Any],
              let bounds = target["bounds"] as? [String: Any],
              let point = target["click_point"] as? [String: Any]
        else {
            throw CertificationControllerError.invalidPlan("target, bounds, and click_point must be objects.")
        }
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
