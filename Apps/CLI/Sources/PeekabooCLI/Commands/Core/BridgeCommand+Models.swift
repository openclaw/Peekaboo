import Foundation
import PeekabooBridge
import PeekabooCore

struct BridgeStatusReport: Codable {
    let remoteSkipped: Bool
    let remoteSkipReason: String?
    let selected: BridgeSelectionReport
    let candidates: [BridgeCandidateReport]
    let client: BridgeClientReport

    var localFallbackWarningLines: [String] {
        guard !self.remoteSkipped, self.selected.source == .local else { return [] }
        let rejectionLines = self.candidates.compactMap { candidate -> String? in
            guard candidate.selectionEligible, let rejection = candidate.rejection else { return nil }
            return "- \(candidate.socketPath) — \(rejection.code): \(rejection.message)"
        }
        guard !rejectionLines.isEmpty else { return [] }
        return [
            "Warning: eligible remote Bridge hosts were rejected; using local (in-process) fallback.",
        ] + rejectionLines
    }

    /// Every candidate summary prints `perm: SR=… AX=… ES=…`, so a denial is visible but its remedy
    /// is not: the grant belongs to the host app behind that socket, never the CLI or terminal. One hint
    /// per denied candidate — a single first-match hint leaves the other probed hosts unexplained.
    var bridgeDeniedPermissionsHints: [String] {
        self.candidates.compactMap { candidate in
            let denied = candidate.deniedPermissionNames
            guard !denied.isEmpty else { return nil }
            let hostKind = candidate.hostKind ?? "Bridge host"
            var hint = "Hint: \(hostKind) at \(candidate.socketPath) does not have " +
                "\(denied.joined(separator: ", ")). Grant it to that host app — granting the CLI or your " +
                "terminal will not change this status."
            if denied.contains("Screen Recording") {
                hint += " For capture, --no-remote --capture-engine cg works when the caller process " +
                    "already has permission."
            }
            return hint
        }
    }
}

struct BridgeClientReport: Codable {
    let bundleIdentifier: String?
    let teamIdentifier: String?
    let processIdentifier: pid_t
    let hostname: String?

    init(identity: PeekabooBridgeClientIdentity) {
        self.bundleIdentifier = identity.bundleIdentifier
        self.teamIdentifier = identity.teamIdentifier
        self.processIdentifier = identity.processIdentifier
        self.hostname = identity.hostname
    }

    var humanSummary: String {
        let bundle = self.bundleIdentifier ?? "<unknown bundle>"
        let team = self.teamIdentifier ?? "<unsigned>"
        return "pid=\(self.processIdentifier) bundle=\(bundle) team=\(team)"
    }
}

struct BridgeCandidateReport: Codable {
    let socketPath: String
    let result: BridgeCandidateResult
    let selectionEligible: Bool
    let rejection: BridgeCandidateRejectionReport?

    private enum CodingKeys: String, CodingKey {
        case socketPath
        case result
    }

    init(
        socketPath: String,
        result: BridgeCandidateResult,
        selectionEligible: Bool = false,
        rejection: BridgeCandidateRejectionReport? = nil
    ) {
        self.socketPath = socketPath
        self.result = result
        self.selectionEligible = selectionEligible
        self.rejection = rejection
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.socketPath = try container.decode(String.self, forKey: .socketPath)
        self.result = try container.decode(BridgeCandidateResult.self, forKey: .result)
        self.selectionEligible = false
        self.rejection = nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.socketPath, forKey: .socketPath)
        try container.encode(self.result, forKey: .result)
    }

    var hostKind: String? {
        if case let .success(handshake) = self.result {
            return handshake.hostKind.rawValue
        }
        return nil
    }

    /// Covers every permission `humanSummary` reports as SR/AX/ES, so no denial the summary shows
    /// can appear without a matching grant hint. Names match the `peekaboo permissions` labels.
    var deniedPermissionNames: [String] {
        guard case let .success(handshake) = self.result, let status = handshake.permissions else {
            return []
        }
        var denied: [String] = []
        if !status.screenRecording {
            denied.append("Screen Recording")
        }
        if !status.accessibility {
            denied.append("Accessibility")
        }
        if !status.postEvent {
            denied.append("Event Synthesizing")
        }
        return denied
    }

    var humanSummary: String {
        switch self.result {
        case .skipped:
            return "\(self.socketPath) — skipped"
        case let .success(handshake):
            let enabled = handshake.enabledOperations?.count
            let supported = handshake.supportedOperations.count
            let opsSummary = if let enabled {
                "ops: \(enabled)/\(supported) enabled"
            } else {
                "ops: \(supported)"
            }
            let permissionsSummary = handshake.permissions.map { status in
                let sr = status.screenRecording ? "Y" : "N"
                let ax = status.accessibility ? "Y" : "N"
                let eventSynthesizing = status.postEvent ? "Y" : "N"
                return "perm: SR=\(sr) AX=\(ax) ES=\(eventSynthesizing)"
            }
            if let permissionsSummary {
                return "\(self.socketPath) — OK (\(handshake.hostKind.rawValue), \(opsSummary), \(permissionsSummary))"
            }
            return "\(self.socketPath) — OK (\(handshake.hostKind.rawValue), \(opsSummary))"
        case let .failure(error):
            return "\(self.socketPath) — \(error.humanSummary)"
        }
    }
}

enum BridgeCandidateResult: Codable {
    case skipped
    case success(BridgeHandshakeReport)
    case failure(BridgeCandidateErrorReport)
}

struct BridgeHandshakeReport: Codable {
    let negotiatedVersion: PeekabooBridgeProtocolVersion
    let hostKind: PeekabooBridgeHostKind
    let build: String?
    let supportedOperations: [PeekabooBridgeOperation]
    let permissions: PermissionsStatus?
    let enabledOperations: [PeekabooBridgeOperation]?
    let permissionTags: [String: [PeekabooBridgePermissionKind]]
    let hostIdentity: PeekabooBridgeHostIdentity?
    let hostCapabilities: [String]?

    init(from handshake: PeekabooBridgeHandshakeResponse) {
        self.negotiatedVersion = handshake.negotiatedVersion
        self.hostKind = handshake.hostKind
        self.build = handshake.build
        self.supportedOperations = handshake.supportedOperations
        self.permissions = handshake.permissions
        self.enabledOperations = handshake.enabledOperations
        self.permissionTags = handshake.permissionTags
        self.hostIdentity = handshake.hostIdentity
        self.hostCapabilities = handshake.hostCapabilities
    }
}

struct BridgeCandidateErrorReport: Codable, Sendable {
    let kind: String
    let code: String?
    let message: String
    let details: String?
    let hint: String?

    nonisolated static func bridgeEnvelope(_ envelope: PeekabooBridgeErrorEnvelope) -> BridgeCandidateErrorReport {
        let hint: String? = switch envelope.code {
        case .unauthorizedClient:
            self.authorizationHint(for: envelope)
        case .decodingFailed:
            "Host returned a non-Bridge response. This commonly means you hit a different socket protocol " +
                "or the host closed early due to code-sign checks."
        case .internalError:
            "Host closed the connection without a valid response. This commonly indicates code-sign checks " +
                "or a mismatched Bridge protocol."
        case .timeout:
            "Inspect or restart this specific host; other diagnostic candidates were still probed."
        default:
            nil
        }
        return BridgeCandidateErrorReport(
            kind: "bridge",
            code: envelope.code.rawValue,
            message: envelope.message,
            details: envelope.details,
            hint: hint
        )
    }

    private nonisolated static func authorizationHint(for envelope: PeekabooBridgeErrorEnvelope) -> String {
        if envelope.message.hasPrefix("Bundle ") {
            return "Client bundle/signing identifier is not allowlisted for this host. Use the intended signed " +
                "client or explicitly add its identifier to the host's bundle allowlist; the unsigned-client " +
                "development override does not bypass bundle authorization."
        }
        return "Client is not signed by an allowed TeamID. Use the intended signed client. For local development " +
            "with a DEBUG host only, set PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 in the host."
    }

    nonisolated static func other(_ error: any Error) -> BridgeCandidateErrorReport {
        BridgeCandidateErrorReport(
            kind: "system",
            code: nil,
            message: error.localizedDescription,
            details: String(describing: error),
            hint: nil
        )
    }

    var humanSummary: String {
        if let code {
            return "\(code): \(self.message)"
        }
        return self.message
    }
}

struct BridgeCandidateRejectionReport {
    let code: String
    let message: String

    static func bridgeFailure(_ failure: BridgeCandidateErrorReport) -> Self? {
        guard failure.kind == "bridge", let code = failure.code else { return nil }
        return Self(code: code, message: failure.message)
    }

    static func runtime(
        _ rejection: RuntimeHostResolver.RemoteCandidateRejection,
        handshake: PeekabooBridgeHandshakeResponse
    ) -> Self {
        switch rejection {
        case .protocolVersionMismatch:
            return Self(
                code: "protocolVersionMismatch",
                message: "Host protocol does not match the required Bridge version."
            )
        case let .hostKindMismatch(expected):
            return Self(
                code: "hostKindMismatch",
                message: "Host kind \(handshake.hostKind.rawValue) does not match required " +
                    "\(expected.rawValue) role."
            )
        case let .missingPermissions(permissions):
            let names = BridgeCapabilityPolicy.missingPermissionNames(permissions)
            return Self(
                code: "missingPermissions",
                message: "Host is missing required \(names.joined(separator: ", "))."
            )
        case .requirementsNotMet:
            return Self(
                code: "requirementsNotMet",
                message: "Host does not support the Bridge capabilities required by this command."
            )
        case .reusableDaemonUnavailable:
            return Self(
                code: "reusableDaemonUnavailable",
                message: "Host did not prove it is a reusable Peekaboo daemon."
            )
        case .historicalDaemonInvalid:
            return Self(
                code: "historicalDaemonInvalid",
                message: "Historical daemon identity or compatibility validation failed."
            )
        case .reusableDaemonIdentityUnavailable:
            return Self(
                code: "reusableDaemonIdentityUnavailable",
                message: "Reusable daemon did not provide the required process identity."
            )
        }
    }
}

struct BridgeSelectionReport: Codable {
    enum Source: String, Codable {
        case remote
        case local
    }

    let source: Source
    let socketPath: String?
    let handshake: BridgeHandshakeReport?

    static func local() -> BridgeSelectionReport {
        BridgeSelectionReport(source: .local, socketPath: nil, handshake: nil)
    }

    static func remote(socketPath: String, handshake: BridgeHandshakeReport) -> BridgeSelectionReport {
        BridgeSelectionReport(source: .remote, socketPath: socketPath, handshake: handshake)
    }

    var humanSummary: String {
        switch self.source {
        case .local:
            return "local (in-process)"
        case .remote:
            let kind = self.handshake?.hostKind.rawValue ?? "remote"
            let buildSuffix = self.handshake?.build.map { " (build \($0))" } ?? ""
            let processSuffix = self.handshake?.hostIdentity.map { " pid=\($0.processIdentifier)" } ?? ""
            if let socketPath {
                return "remote \(kind) via \(socketPath)\(buildSuffix)\(processSuffix)"
            }
            return "remote \(kind)\(buildSuffix)\(processSuffix)"
        }
    }
}
