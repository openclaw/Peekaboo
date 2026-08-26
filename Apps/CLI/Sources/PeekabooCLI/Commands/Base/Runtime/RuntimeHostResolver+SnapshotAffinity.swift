import Foundation
import PeekabooAgentRuntime
import PeekabooBridge
import PeekabooFoundation

extension RuntimeHostResolver {
    private enum SnapshotAffinityRemoteOwnerKey: Hashable {
        case attestedProcess(pid_t, UInt64, String)
        case endpoint(String)
    }

    enum SnapshotAffinityProbeResult: Equatable, Sendable {
        case owner
        case missing
        case incompatible
        case unavailable
    }

    enum SnapshotAffinityOwner: Equatable, Sendable {
        case local
        case remote([ImplicitRemoteCandidate])
    }

    typealias SnapshotAffinityProbe = @MainActor @Sendable (
        _ candidate: ImplicitRemoteCandidate,
        _ snapshotID: String,
        _ identity: PeekabooBridgeClientIdentity,
        _ handshakeCache: RemoteHandshakeCache
    ) async throws -> SnapshotAffinityProbeResult

    static func snapshotAffinityCandidates(from plan: RemoteCandidatePlan) -> [ImplicitRemoteCandidate] {
        if plan.explicitSocket != nil {
            return plan.candidates
        }

        var candidates = plan.candidates
        candidates.append(contentsOf: [
            plan.buildScopedDaemonSocketPath.map {
                ImplicitRemoteCandidate(
                    socketPath: $0,
                    requireReusableDaemon: true,
                    requiredHostKind: .onDemand,
                    requiresValidatedHistoricalDaemon: false
                )
            },
            ImplicitRemoteCandidate(
                socketPath: plan.daemonSocketPath,
                requireReusableDaemon: true,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            ),
            ImplicitRemoteCandidate(
                socketPath: PeekabooBridgeConstants.peekabooSocketPath,
                requireReusableDaemon: false,
                requiredHostKind: .gui,
                requiresValidatedHistoricalDaemon: false
            ),
            ImplicitRemoteCandidate(
                socketPath: PeekabooBridgeConstants.claudeSocketPath,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            ),
            ImplicitRemoteCandidate(
                socketPath: PeekabooBridgeConstants.clawdbotSocketPath,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            ),
        ].compactMap(\.self))
        candidates.append(contentsOf: plan.historicalBuildScopedDaemonSocketPaths.map {
            ImplicitRemoteCandidate(
                socketPath: $0,
                requireReusableDaemon: true,
                requiredHostKind: .onDemand,
                requiresValidatedHistoricalDaemon: true
            )
        })

        var seen = Set<String>()
        return candidates.filter {
            seen.insert(NSString(string: $0.socketPath).standardizingPath).inserted
        }
    }

    static func resolveSnapshotAffinity(
        snapshotID: String,
        candidates: [ImplicitRemoteCandidate],
        identity: PeekabooBridgeClientIdentity,
        handshakeCache: RemoteHandshakeCache,
        probe: @escaping SnapshotAffinityProbe = RuntimeHostResolver
            .liveSnapshotAffinityProbe
    ) async throws -> ImplicitRemoteCandidate {
        let owner = try await self.resolveSnapshotAffinityOwner(
            snapshotID: snapshotID,
            localServices: nil,
            candidates: candidates,
            identity: identity,
            handshakeCache: handshakeCache,
            probe: probe
        )
        guard case let .remote(candidates) = owner,
              let candidate = candidates.first
        else {
            preconditionFailure("Remote-only snapshot affinity unexpectedly selected local services")
        }
        return candidate
    }

    static func resolveSnapshotAffinityOwner(
        snapshotID: String,
        localServices: (any PeekabooServiceProviding)?,
        candidates: [ImplicitRemoteCandidate],
        identity: PeekabooBridgeClientIdentity,
        handshakeCache: RemoteHandshakeCache,
        probe: @escaping SnapshotAffinityProbe = RuntimeHostResolver.liveSnapshotAffinityProbe
    ) async throws -> SnapshotAffinityOwner {
        guard SnapshotReference(rawValue: snapshotID) != nil else {
            throw self.invalidSnapshotReferenceRefusal(snapshotID)
        }

        let tasks = candidates.enumerated().map { index, candidate in
            Task { @MainActor in
                try await (index, candidate, probe(candidate, snapshotID, identity, handshakeCache))
            }
        }
        let observations = try await withTaskCancellationHandler {
            defer {
                for task in tasks {
                    task.cancel()
                }
            }
            var results: [(Int, ImplicitRemoteCandidate, SnapshotAffinityProbeResult)] = []
            for task in tasks {
                try await results.append(task.value)
            }
            return results.sorted { $0.0 < $1.0 }
        } onCancel: {
            for task in tasks {
                task.cancel()
            }
        }
        try Task.checkCancellation()

        let localOwnsSnapshot = if let localServices {
            try await localServices.snapshots.ownsSnapshot(snapshotId: snapshotID)
        } else {
            false
        }
        var unavailableCount = 0
        var incompatibleCount = 0
        var remoteOwnerOrder: [SnapshotAffinityRemoteOwnerKey] = []
        var remoteOwnerCandidates: [SnapshotAffinityRemoteOwnerKey: [ImplicitRemoteCandidate]] = [:]
        for (_, candidate, result) in observations {
            switch result {
            case .owner:
                let key = self.snapshotAffinityRemoteOwnerKey(
                    candidate: candidate,
                    identity: identity,
                    handshakeCache: handshakeCache
                )
                if remoteOwnerCandidates[key] == nil {
                    remoteOwnerOrder.append(key)
                }
                remoteOwnerCandidates[key, default: []].append(candidate)
            case .missing:
                break
            case .incompatible:
                incompatibleCount += 1
            case .unavailable:
                unavailableCount += 1
            }
        }
        let ownerCount = (localOwnsSnapshot ? 1 : 0) + remoteOwnerOrder.count
        if ownerCount == 1 {
            if localOwnsSnapshot {
                return .local
            }
            if let key = remoteOwnerOrder.first,
               let candidates = remoteOwnerCandidates[key] {
                return .remote(candidates)
            }
        }
        if ownerCount > 1 {
            let localPaths = localOwnsSnapshot ? ["local"] : []
            let remotePaths = remoteOwnerOrder.flatMap { key in
                remoteOwnerCandidates[key, default: []].map {
                    NSString(string: $0.socketPath).standardizingPath
                }
            }
            let paths = (localPaths + remotePaths)
                .sorted()
                .joined(separator: ", ")
            throw self.snapshotAffinityRefusal(
                snapshotID: snapshotID,
                message: "Multiple authenticated Peekaboo hosts claim this snapshot: \(paths).",
                reason: .runtimeIncompatible
            )
        }

        let soleCandidatePath = candidates.count == 1
            ? candidates.first.map { NSString(string: $0.socketPath).standardizingPath }
            : nil
        let availability = if let soleCandidatePath, incompatibleCount > 0 {
            "The authenticated host at \(soleCandidatePath) cannot prove producer-bound snapshot ownership; update it."
        } else if let soleCandidatePath, unavailableCount > 0 {
            "The selected host at \(soleCandidatePath) is stopped or unreachable, and no other authenticated live " +
                "host may claim this reference."
        } else if let soleCandidatePath {
            "The authenticated host at \(soleCandidatePath) does not own it; it may be expired, cleaned, or unknown."
        } else if incompatibleCount > 0 {
            "One or more live hosts cannot prove producer-bound snapshot ownership; update them."
        } else if unavailableCount == 0 {
            "No authenticated live Peekaboo host owns it; it may be expired, cleaned, or unknown."
        } else {
            "Its producing host may be stopped or unreachable, and no authenticated live host owns it."
        }
        throw self.snapshotAffinityRefusal(
            snapshotID: snapshotID,
            message: availability,
            reason: .targetUnavailable
        )
    }

    private static func snapshotAffinityRemoteOwnerKey(
        candidate: ImplicitRemoteCandidate,
        identity: PeekabooBridgeClientIdentity,
        handshakeCache: RemoteHandshakeCache
    ) -> SnapshotAffinityRemoteOwnerKey {
        if let host = handshakeCache.entry(for: candidate, identity: identity)?.response.operationAttestation?.host {
            return .attestedProcess(
                host.processIdentifier,
                host.processStartIdentity,
                host.codeSignatureHash
            )
        }
        return .endpoint(NSString(string: candidate.socketPath).standardizingPath)
    }

    static func resolveSnapshotAffinityServices(
        snapshotID: String,
        localServices: (any PeekabooServiceProviding)?,
        context: RemoteResolutionContext,
        permissionRejections: inout [String],
        probe: @escaping SnapshotAffinityProbe = RuntimeHostResolver.liveSnapshotAffinityProbe
    ) async throws -> Resolution {
        let owner = try await self.resolveSnapshotAffinityOwner(
            snapshotID: snapshotID,
            localServices: localServices,
            candidates: self.snapshotAffinityCandidates(from: context.candidatePlan),
            identity: context.identity,
            handshakeCache: context.handshakeCache,
            probe: probe
        )
        switch owner {
        case .local:
            guard let localServices else {
                throw self.snapshotAffinityRefusal(
                    snapshotID: snapshotID,
                    message: "Local ownership was selected without local services.",
                    reason: .runtimeIncompatible
                )
            }
            return Resolution(
                services: localServices,
                hostDescription: "local (snapshot producer)",
                selectedRemoteSocketPath: nil,
                selectedRemoteHostProcessIdentifier: nil,
                snapshotInvalidationRemoteSocketPaths: context.snapshotInvalidationRemoteSocketPaths,
                applicationRelaunchAllowed: true,
                requiredHostFailure: nil
            )
        case let .remote(candidates):
            if let resolved = try await context.resolveRemoteServices(
                candidates: candidates,
                permissionRejections: &permissionRejections
            ) {
                return resolved
            }
            throw self.snapshotOwnerIncompatibleRefusal(snapshotID: snapshotID, candidates: candidates)
        }
    }

    static func liveSnapshotAffinityProbe(
        _ candidate: ImplicitRemoteCandidate,
        _ snapshotID: String,
        _ identity: PeekabooBridgeClientIdentity,
        _ handshakeCache: RemoteHandshakeCache
    ) async throws -> SnapshotAffinityProbeResult {
        do {
            let entry = try await handshakeCache.handshake(candidate, identity: identity)
            guard BridgeCapabilityPolicy.supportsProducerBoundSnapshotReferences(for: entry.response) else {
                return .incompatible
            }
            return try await entry.client.ownsSnapshot(snapshotId: snapshotID) ? .owner : .missing
        } catch let error as CancellationError {
            throw error
        } catch let envelope as PeekabooBridgeErrorEnvelope
            where envelope.code == .operationNotSupported ||
            envelope.code == .invalidRequest ||
            envelope.code == .decodingFailed ||
            envelope.code == .versionMismatch {
            return .incompatible
        } catch {
            return .unavailable
        }
    }

    private static func invalidSnapshotReferenceRefusal(_ snapshotID: String) -> PreDispatchActionError {
        PreDispatchActionError(
            message: "Snapshot reference '\(snapshotID)' is invalid. No action was dispatched.",
            code: .VALIDATION_ERROR,
            hint: "Use the exact ps1_ reference returned by a fresh 'peekaboo see'.",
            reason: .invalidRequest
        )
    }

    private static func snapshotAffinityRefusal(
        snapshotID: String,
        message: String,
        reason: DesktopActionOutcome.RefusalReason
    ) -> PreDispatchActionError {
        PreDispatchActionError(
            message: "Snapshot '\(snapshotID)' has no unique live host affinity. \(message) No action was dispatched.",
            code: .SNAPSHOT_NOT_FOUND,
            hint: "Run 'peekaboo see' again and use the fresh snapshot without changing Bridge hosts.",
            reason: reason
        )
    }

    private static func snapshotOwnerIncompatibleRefusal(
        snapshotID: String,
        candidates: [ImplicitRemoteCandidate]
    ) -> PreDispatchActionError {
        let socketPaths = candidates.map { NSString(string: $0.socketPath).standardizingPath }
            .joined(separator: ", ")
        return PreDispatchActionError(
            message: "Snapshot '\(snapshotID)' is owned by the authenticated host through \(socketPaths), but " +
                "none of those endpoints can satisfy this command. No action was dispatched.",
            code: .BRIDGE_UNAVAILABLE,
            hint: "Update or relaunch that exact host, then run 'peekaboo see' again before retrying.",
            reason: .runtimeIncompatible
        )
    }
}
