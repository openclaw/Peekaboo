import Commander
import CryptoKit
import Darwin
import Foundation
import PeekabooBridge
import PeekabooCore

extension BridgeCommand {
    @MainActor
    struct ValidateSubcommand: ParsableCommand {
        static let commandDescription = CommandDescription(
            commandName: "validate",
            abstract: "Verify one exported protocol 1.29 receipt bundle",
            discussion: """
            Authenticate the exact live Bridge listener, then verify the listener, logical session,
            terminal operation, canonical request/response, target, and outcome evidence in one
            private exported receipt bundle.

            The command never prints command payloads or the listener's private archive location.
            Standard Peekaboo socket paths use the built-in release-team policy. A custom socket
            requires at least one explicit --trusted-host-team-id.

            Examples:
              peekaboo bridge receipt validate --bundle /private/path/receipt.json \\
                --bridge-socket ~/Library/Application\\ Support/Peekaboo/bridge.sock
              peekaboo bridge receipt validate --bundle /private/path/receipt.json \\
                --bridge-socket /private/path/bridge.sock --trusted-host-team-id TEAMID --json
            """
        )

        @Option(name: .long, help: "Private exported protocol 1.29 receipt bundle")
        var bundle = ""

        var bridgeSocket = ""

        @Option(
            name: .customLong("trusted-host-team-id"),
            help: "Trusted signing Team ID for a custom socket; repeat to allow more than one"
        )
        var trustedHostTeamIDs: [String] = []

        var jsonOutput = false

        mutating func run() async throws {
            let report = try await BridgeReceiptVerifier.validate(
                bundlePath: self.bundle,
                bridgeSocket: self.bridgeSocket,
                trustedHostTeamIDs: self.trustedHostTeamIDs
            )
            if self.jsonOutput {
                let logger = Logger.shared
                logger.setJsonOutputMode(true)
                outputSuccessCodable(data: report, logger: logger)
                return
            }

            print("Bridge receipt bundle valid")
            print("  Trust:     authenticated live listener")
            print("  Protocol:  >= \(report.minimumProtocolVersion)")
            print("  Request:   \(report.requestID)")
            print("  Session:   \(report.sessionID) sequence \(report.sessionSequence)")
            print("  Operation: \(report.operation)")
        }
    }
}

@MainActor
extension BridgeCommand.ValidateSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.bundle = try values.requireOption("bundle", as: String.self)
        self.bridgeSocket = try values.requireOption("bridge-socket", as: String.self)
        self.trustedHostTeamIDs = values.optionValues("trustedHostTeamIDs")
        self.jsonOutput = values.flag("jsonOutput")
    }
}

struct BridgeReceiptValidationReport: Codable, Equatable, Sendable {
    let valid: Bool
    let validatorID: String
    let trustSource: String
    let minimumProtocolVersion: String
    let requestID: String
    let sessionID: String
    let sessionSequence: String
    let predecessorSessionID: String?
    let operation: String
    let listenerInstanceID: String
    let listenerPublicKeySHA256: String
    let host: ProcessIdentity
    let hostSourceCommit: String?
    let hostProtocolVersion: String?
    let clientInstanceID: String
    let client: ProcessIdentity
    let requestSHA256: String
    let responseSHA256: String
    let bundleSHA256: String
    let terminalReceiptAttested: Bool
    let targetAttested: Bool
    let outcomeAttested: Bool
    let retentionBasis: String

    struct ProcessIdentity: Codable, Equatable, Sendable {
        let pid: Int32
        let startIdentity: String
        let codeSignatureHash: String

        enum CodingKeys: String, CodingKey {
            case pid
            case startIdentity = "start_identity"
            case codeSignatureHash = "code_signature_hash"
        }
    }

    enum CodingKeys: String, CodingKey {
        case valid
        case validatorID = "validator_id"
        case trustSource = "trust_source"
        case minimumProtocolVersion = "minimum_protocol_version"
        case requestID = "request_id"
        case sessionID = "session_id"
        case sessionSequence = "session_sequence"
        case predecessorSessionID = "predecessor_session_id"
        case operation
        case listenerInstanceID = "listener_instance_id"
        case listenerPublicKeySHA256 = "listener_public_key_sha256"
        case host
        case hostSourceCommit = "host_source_commit"
        case hostProtocolVersion = "host_protocol_version"
        case clientInstanceID = "client_instance_id"
        case client
        case requestSHA256 = "request_sha256"
        case responseSHA256 = "response_sha256"
        case bundleSHA256 = "bundle_sha256"
        case terminalReceiptAttested = "terminal_receipt_attested"
        case targetAttested = "target_attested"
        case outcomeAttested = "outcome_attested"
        case retentionBasis = "retention_basis"
    }
}

enum BridgeReceiptValidationError: LocalizedError, ResultEnvelopeError, Equatable, Sendable {
    case unsafeBundleFile(String)
    case invalidTrustedHostTeamID
    case missingTrustedHostTeamIDForCustomSocket
    case unsupportedProtocol
    case listenerTrustUnavailable
    case invalidBundleSchema
    case invalidBundle

    nonisolated var errorDescription: String? {
        switch self {
        case let .unsafeBundleFile(reason):
            "Receipt bundle file is unsafe: \(reason)"
        case .invalidTrustedHostTeamID:
            "Trusted host Team IDs must be nonempty values"
        case .missingTrustedHostTeamIDForCustomSocket:
            "Custom Bridge sockets require at least one explicit trusted host Team ID"
        case .unsupportedProtocol:
            "The exact Bridge listener did not negotiate protocol 1.29 receipt attestation"
        case .listenerTrustUnavailable:
            "The authenticated Bridge handshake did not provide a listener trust anchor"
        case .invalidBundleSchema:
            "Receipt bundle is incomplete or has an invalid protocol 1.29 schema"
        case .invalidBundle:
            "Receipt bundle validation failed"
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        switch self {
        case .unsafeBundleFile: .FILE_IO_ERROR
        case .invalidTrustedHostTeamID, .missingTrustedHostTeamIDForCustomSocket:
            .INVALID_ARGUMENT
        case .unsupportedProtocol, .listenerTrustUnavailable, .invalidBundleSchema, .invalidBundle:
            .VALIDATION_ERROR
        }
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeHint: String? {
        switch self {
        case .invalidTrustedHostTeamID:
            "Pass each intended Apple signing Team ID with --trusted-host-team-id."
        case .missingTrustedHostTeamIDForCustomSocket:
            "Pass at least one --trusted-host-team-id TEAMID for this custom --bridge-socket."
        case .unsupportedProtocol, .listenerTrustUnavailable:
            "Use the exact current signed Bridge socket that exported the bundle."
        case .invalidBundleSchema:
            "Fix the bundle schema or use the original owner-private bundle " +
                "exported by that authenticated Bridge listener."
        case .unsafeBundleFile, .invalidBundle:
            "Use the original owner-private bundle exported by that authenticated Bridge listener."
        }
    }
}

@MainActor
enum BridgeReceiptVerifier {
    typealias ClientFactory = @MainActor (
        _ socketPath: String,
        _ requestTimeoutSec: TimeInterval,
        _ trustedHostTeamIDs: Set<String>
    ) -> PeekabooBridgeClient

    /// Request and response payloads can each approach the 64 MiB wire ceiling, and the
    /// exported bundle base64-encodes both. Keep a bounded but non-truncating audit envelope.
    private static let maximumBundleBytes: Int64 = 256 * 1024 * 1024
    private static let handshakeTimeoutSeconds: TimeInterval = 3

    static func validate(
        bundlePath: String,
        bridgeSocket: String,
        trustedHostTeamIDs: [String],
        makeClient: ClientFactory = { socketPath, requestTimeoutSec, teams in
            PeekabooBridgeClient(
                socketPath: socketPath,
                requestTimeoutSec: requestTimeoutSec,
                trustedHostTeamIDs: teams
            )
        }
    ) async throws -> BridgeReceiptValidationReport {
        let expandedBundlePath = (bundlePath as NSString).expandingTildeInPath
        let expandedBridgeSocket = (bridgeSocket as NSString).expandingTildeInPath
        let teams = try self.trustedHostTeamIDs(
            for: expandedBridgeSocket,
            explicitValues: trustedHostTeamIDs
        )
        let data = try self.readPrivateBundle(at: expandedBundlePath)
        let bundle = try self.decodeBundle(data)
        let client = makeClient(expandedBridgeSocket, self.handshakeTimeoutSeconds, teams)
        let handshake = try await client.handshake(
            client: BridgeDiagnostics.currentClientIdentity(),
            overallTimeoutSec: self.handshakeTimeoutSeconds
        )
        let trustAnchor = try self.trustAnchor(from: handshake)
        return try self.validate(
            data: data,
            bundle: bundle,
            trustAnchor: trustAnchor,
            hostSourceCommit: handshake.hostIdentity?.sourceCommit,
            hostProtocolVersion: "\(handshake.negotiatedVersion.major).\(handshake.negotiatedVersion.minor)"
        )
    }

    static func validate(
        data: Data,
        trustAnchor: PeekabooBridgeOperationReceiptTrustAnchor
    ) throws -> BridgeReceiptValidationReport {
        try self.validate(
            data: data,
            bundle: self.decodeBundle(data),
            trustAnchor: trustAnchor,
            hostSourceCommit: nil,
            hostProtocolVersion: nil
        )
    }

    static func trustAnchor(
        from handshake: PeekabooBridgeHandshakeResponse
    ) throws -> PeekabooBridgeOperationReceiptTrustAnchor {
        guard handshake.negotiatedVersion >= PeekabooBridgeConstants.attestedOperationReceiptVersion else {
            throw BridgeReceiptValidationError.unsupportedProtocol
        }
        guard let attestation = handshake.operationAttestation else {
            throw BridgeReceiptValidationError.listenerTrustUnavailable
        }
        return .listenerAttestation(attestation)
    }

    private static func validate(
        data: Data,
        bundle: PeekabooBridgeOperationReceiptBundle,
        trustAnchor: PeekabooBridgeOperationReceiptTrustAnchor,
        hostSourceCommit: String?,
        hostProtocolVersion: String?
    ) throws -> BridgeReceiptValidationReport {
        do {
            try bundle.validate(trustAnchor: trustAnchor)
        } catch {
            throw BridgeReceiptValidationError.invalidBundle
        }
        let receipt = bundle.receipt.payload
        let listener = bundle.operationAttestation
        let client = receipt.client
        return BridgeReceiptValidationReport(
            valid: true,
            validatorID: "peekaboo-bridge-receipt-validate-v1",
            trustSource: "authenticated_live_listener",
            minimumProtocolVersion: "1.29",
            requestID: receipt.requestID.uuidString.lowercased(),
            sessionID: receipt.sessionID.uuidString.lowercased(),
            sessionSequence: String(receipt.sessionSequence.value),
            predecessorSessionID: bundle.operationSessionAttestation.predecessorSessionID?
                .uuidString.lowercased(),
            operation: receipt.operation.rawValue,
            listenerInstanceID: listener.listenerInstanceID.uuidString.lowercased(),
            listenerPublicKeySHA256: self.sha256(listener.publicKey),
            host: .init(
                pid: listener.host.processIdentifier,
                startIdentity: String(listener.host.processStartIdentity),
                codeSignatureHash: listener.host.codeSignatureHash
            ),
            hostSourceCommit: hostSourceCommit,
            hostProtocolVersion: hostProtocolVersion,
            clientInstanceID: receipt.clientInstanceID.uuidString.lowercased(),
            client: .init(
                pid: client.processIdentifier,
                startIdentity: String(client.processStartIdentity),
                codeSignatureHash: client.codeSignatureHash
            ),
            requestSHA256: receipt.requestSHA256,
            responseSHA256: receipt.responseSHA256,
            bundleSHA256: self.sha256(data),
            terminalReceiptAttested: true,
            targetAttested: receipt.target != nil,
            outcomeAttested: receipt.outcome != nil,
            retentionBasis: "exported_bundle"
        )
    }

    private static func decodeBundle(_ data: Data) throws -> PeekabooBridgeOperationReceiptBundle {
        do {
            return try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceiptBundle.self,
                from: data
            )
        } catch {
            throw BridgeReceiptValidationError.invalidBundleSchema
        }
    }

    static func trustedHostTeamIDs(
        for socketPath: String,
        explicitValues values: [String]
    ) throws -> Set<String> {
        let normalized = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard normalized.allSatisfy({ !$0.isEmpty }) else {
            throw BridgeReceiptValidationError.invalidTrustedHostTeamID
        }
        if !normalized.isEmpty {
            return Set(normalized)
        }
        guard let defaults = PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: socketPath),
              !defaults.isEmpty
        else {
            throw BridgeReceiptValidationError.missingTrustedHostTeamIDForCustomSocket
        }
        return defaults
    }

    private static func readPrivateBundle(at path: String) throws -> Data {
        guard !path.isEmpty, !path.utf8.contains(0) else {
            throw BridgeReceiptValidationError.unsafeBundleFile("path is empty or invalid")
        }
        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let reason = switch errno {
            case ENOENT: "file does not exist"
            case ELOOP: "symbolic links are not accepted"
            default: "file cannot be opened securely"
            }
            throw BridgeReceiptValidationError.unsafeBundleFile(reason)
        }
        defer { Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(),
              before.st_mode & 0o077 == 0,
              before.st_size > 0,
              before.st_size <= self.maximumBundleBytes
        else {
            throw BridgeReceiptValidationError.unsafeBundleFile(
                "file must be owner-private, regular, nonempty, and at most 256 MiB"
            )
        }
        try self.requireNoExtendedACL(descriptor: descriptor)

        let data = try self.readBundleContents(
            descriptor: descriptor,
            expectedSize: Int(before.st_size)
        )
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              Int64(data.count) == before.st_size
        else {
            throw BridgeReceiptValidationError.unsafeBundleFile("file changed while it was being read")
        }
        return data
    }

    private static func requireNoExtendedACL(descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw BridgeReceiptValidationError.unsafeBundleFile(
                "file access controls could not be inspected"
            )
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw BridgeReceiptValidationError.unsafeBundleFile(
            "extended access-control entries are not accepted"
        )
    }

    private static func readBundleContents(descriptor: Int32, expectedSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(expectedSize, 256 * 1024))
        while data.count < expectedSize {
            let remaining = expectedSize - data.count
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(remaining, bytes.count))
            }
            if readCount > 0 {
                data.append(contentsOf: buffer.prefix(readCount))
            } else if readCount == 0 {
                break
            } else if errno != EINTR {
                throw BridgeReceiptValidationError.unsafeBundleFile("file could not be read")
            }
        }
        guard data.count == expectedSize else {
            throw BridgeReceiptValidationError.unsafeBundleFile("file changed while it was being read")
        }

        var overflowByte: UInt8 = 0
        while true {
            let readCount = withUnsafeMutablePointer(to: &overflowByte) {
                Darwin.read(descriptor, $0, 1)
            }
            if readCount == 0 {
                return data
            }
            if readCount > 0 {
                throw BridgeReceiptValidationError.unsafeBundleFile("file changed while it was being read")
            }
            if errno != EINTR {
                throw BridgeReceiptValidationError.unsafeBundleFile("file could not be read")
            }
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
