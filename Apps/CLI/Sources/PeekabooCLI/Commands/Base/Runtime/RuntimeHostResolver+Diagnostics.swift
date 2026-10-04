import PeekabooBridge

extension RuntimeHostResolver {
    static func observedRequiredHostFailure(
        explicitSocket: String?,
        rejections: [RemoteCandidateEvaluation]
    ) -> String? {
        var reasons: [String] = []
        for evaluation in rejections {
            guard let reason = self.rejectionReason(evaluation), !reasons.contains(reason) else { continue }
            reasons.append(reason)
        }
        guard !reasons.isEmpty else { return nil }
        let summary = "No compatible Bridge host is available. Attempted hosts were rejected for: " +
            reasons.joined(separator: "; ") + ". "
        if rejections.contains(where: { $0.requirementFailure == .producerBoundSnapshotReferences }) {
            return summary + producerBoundSnapshotFailure(explicitSocket: explicitSocket)
        }
        return summary + "Check the selected host's permissions, enabled operations, and negotiated capabilities, " +
            "or pass --no-remote to explicitly run locally."
    }

    private static func rejectionReason(_ evaluation: RemoteCandidateEvaluation) -> String? {
        switch evaluation.rejection {
        case .protocolVersionMismatch:
            "the required Bridge protocol version"
        case let .hostKindMismatch(expected):
            "the required \(expected.rawValue) host kind"
        case let .missingPermissions(permissions):
            "missing host permissions (" +
                BridgeCapabilityPolicy.missingPermissionNames(permissions).joined(separator: ", ") + ")"
        case .requirementsNotMet:
            switch evaluation.requirementFailure {
            case let .capability(requirement): "unmet \(requirement) requirement"
            case .producerBoundSnapshotReferences: "authenticated, producer-bound snapshot requirements"
            case nil: "command capability requirements"
            }
        case .reusableDaemonUnavailable:
            "reusable daemon availability"
        case .historicalDaemonInvalid:
            "historical daemon validation"
        case .reusableDaemonIdentityUnavailable:
            "reusable daemon process identity"
        case nil:
            nil
        }
    }
}

func producerBoundSnapshotFailure(explicitSocket: String?) -> String {
    let version = PeekabooBridgeConstants.producerBoundSnapshotReferencesVersion
    let requirement = "This command requires authenticated, producer-bound snapshots " +
        "(Bridge protocol \(version.major).\(version.minor) or newer), including attestedOperationReceipts " +
        "and producerBoundSnapshotReferences capabilities. "
    guard explicitSocket != nil else {
        return requirement + "Check the automatically discovered hosts' negotiated protocol, " +
            "receipt and snapshot capabilities, and enabled snapshot operations."
    }
    return requirement + "Use a current signed Peekaboo host " +
        "on its standard socket or canonical build-scoped daemon socket, or remove --bridge-socket " +
        "for automatic host selection. Custom sockets without a host-signing policy cannot negotiate " +
        "authenticated snapshots; updating the binary alone does not establish that trust."
}
