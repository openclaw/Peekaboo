import Foundation
import PeekabooBridge
import PeekabooCore

struct BridgeStatusReport: Codable {
    let remoteSkipped: Bool
    let remoteSkipReason: String?
    let selected: BridgeSelectionReport
    let candidates: [BridgeCandidateReport]
    let client: BridgeClientReport

    /// The candidate summary prints `perm: SR=… AX=… AS=… ES=…`, so a denial is visible but its remedy
    /// is not: the grant belongs to the host app behind the socket, never the CLI or terminal. Report
    /// every denied permission, otherwise an AX/ES denial reads as unexplained.
    var bridgeDeniedPermissionsHint: String? {
        guard let candidate = self.candidates.first(where: { !$0.deniedPermissionNames.isEmpty }) else {
            return nil
        }
        let hostKind = candidate.hostKind ?? "Bridge host"
        let denied = candidate.deniedPermissionNames.joined(separator: ", ")
        var hint = "Hint: \(hostKind) at \(candidate.socketPath) does not have \(denied). Grant it to " +
            "that host app — granting the CLI or your terminal will not change this status."
        if candidate.deniedPermissionNames.contains("Screen Recording") {
            hint += " For capture, --no-remote --capture-engine cg works when the caller process already " +
                "has permission."
        }
        return hint
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

    var hostKind: String? {
        if case let .success(handshake) = self.result {
            return handshake.hostKind.rawValue
        }
        return nil
    }

    /// Covers every permission `humanSummary` reports as SR/AX/AS/ES, so no denial the summary shows
    /// can appear without a matching grant hint. Names match the `peekaboo permissions` labels where
    /// they exist; AppleScript has no entry there and uses its System Settings name.
    var deniedPermissionNames: [String] {
        guard case let .success(handshake) = self.result, let status = handshake.permissions else {
            return []
        }
        var denied: [String] = []
        if !status.screenRecording { denied.append("Screen Recording") }
        if !status.accessibility { denied.append("Accessibility") }
        if !status.appleScript { denied.append("Automation (AppleScript)") }
        if !status.postEvent { denied.append("Event Synthesizing") }
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
                let appleScript = status.appleScript ? "Y" : "N"
                let eventSynthesizing = status.postEvent ? "Y" : "N"
                return "perm: SR=\(sr) AX=\(ax) AS=\(appleScript) ES=\(eventSynthesizing)"
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

    init(from handshake: PeekabooBridgeHandshakeResponse) {
        self.negotiatedVersion = handshake.negotiatedVersion
        self.hostKind = handshake.hostKind
        self.build = handshake.build
        self.supportedOperations = handshake.supportedOperations
        self.permissions = handshake.permissions
        self.enabledOperations = handshake.enabledOperations
        self.permissionTags = handshake.permissionTags
    }
}

struct BridgeCandidateErrorReport: Codable {
    let kind: String
    let code: String?
    let message: String
    let details: String?
    let hint: String?

    static func bridgeEnvelope(_ envelope: PeekabooBridgeErrorEnvelope) -> BridgeCandidateErrorReport {
        let hint: String? = switch envelope.code {
        case .unauthorizedClient:
            "Client not signed by an allowed TeamID. For local dev, set " +
                "PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS=1 in the host."
        case .decodingFailed:
            "Host returned a non-Bridge response. This commonly means you hit a different socket protocol " +
                "or the host closed early due to code-sign checks."
        case .internalError:
            "Host closed the connection without a valid response. This commonly indicates code-sign checks " +
                "or a mismatched Bridge protocol."
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

    static func other(_ error: any Error) -> BridgeCandidateErrorReport {
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
            if let socketPath {
                return "remote \(kind) via \(socketPath)\(buildSuffix)"
            }
            return "remote \(kind)\(buildSuffix)"
        }
    }
}
