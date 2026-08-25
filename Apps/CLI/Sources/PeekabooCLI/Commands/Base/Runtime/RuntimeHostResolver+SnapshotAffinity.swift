import Foundation
import PeekabooBridge
import PeekabooFoundation

extension RuntimeHostResolver {
    enum SnapshotAffinityProbeResult: Equatable, Sendable {
        case owner
        case missing
        case unavailable
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
        guard self.isSafeSnapshotReference(snapshotID) else {
            throw self.snapshotAffinityRefusal(
                snapshotID: snapshotID,
                message: "Snapshot reference is not one safe opaque snapshot ID.",
                reason: .invalidRequest
            )
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

        var owners: [ImplicitRemoteCandidate] = []
        var unavailableCount = 0
        for (_, candidate, result) in observations {
            switch result {
            case .owner:
                owners.append(candidate)
            case .missing:
                break
            case .unavailable:
                unavailableCount += 1
            }
        }
        if owners.count == 1, let owner = owners.first {
            return owner
        }
        if owners.count > 1 {
            let paths = owners
                .map { NSString(string: $0.socketPath).standardizingPath }
                .sorted()
                .joined(separator: ", ")
            throw self.snapshotAffinityRefusal(
                snapshotID: snapshotID,
                message: "Multiple authenticated Peekaboo hosts claim this snapshot: \(paths).",
                reason: .runtimeIncompatible
            )
        }

        let availability = unavailableCount == 0
            ? "No authenticated live Peekaboo host owns it; it may be expired, cleaned, or unknown."
            : "Its producing host may be stopped or unreachable, and no authenticated live host owns it."
        throw self.snapshotAffinityRefusal(
            snapshotID: snapshotID,
            message: availability,
            reason: .targetUnavailable
        )
    }

    static func resolveSnapshotAffinityServices(
        snapshotID: String,
        context: RemoteResolutionContext,
        permissionRejections: inout [String]
    ) async throws -> Resolution {
        let owner = try await self.resolveSnapshotAffinity(
            snapshotID: snapshotID,
            candidates: self.snapshotAffinityCandidates(from: context.candidatePlan),
            identity: context.identity,
            handshakeCache: context.handshakeCache
        )
        if let resolved = try await context.resolveRemoteServices(
            candidates: [owner],
            permissionRejections: &permissionRejections
        ) {
            return resolved
        }
        throw self.snapshotOwnerIncompatibleRefusal(snapshotID: snapshotID, candidate: owner)
    }

    private static func liveSnapshotAffinityProbe(
        _ candidate: ImplicitRemoteCandidate,
        _ snapshotID: String,
        _ identity: PeekabooBridgeClientIdentity,
        _ handshakeCache: RemoteHandshakeCache
    ) async throws -> SnapshotAffinityProbeResult {
        do {
            let entry = try await handshakeCache.handshake(candidate, identity: identity)
            guard BridgeCapabilityPolicy.supportsOperation(.getDetectionResult, for: entry.response) else {
                return .unavailable
            }
            let result = try await entry.client.getDetectionResult(snapshotId: snapshotID)
            return result.snapshotId == snapshotID ? .owner : .unavailable
        } catch let envelope as PeekabooBridgeErrorEnvelope where envelope.code == .notFound {
            return .missing
        } catch let error as CancellationError {
            throw error
        } catch {
            return .unavailable
        }
    }

    private static func isSafeSnapshotReference(_ snapshotID: String) -> Bool {
        !snapshotID.isEmpty &&
            snapshotID != "." &&
            snapshotID != ".." &&
            !snapshotID.contains("/") &&
            !snapshotID.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
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
        candidate: ImplicitRemoteCandidate
    ) -> PreDispatchActionError {
        let socketPath = NSString(string: candidate.socketPath).standardizingPath
        return PreDispatchActionError(
            message: "Snapshot '\(snapshotID)' is owned by the authenticated host at \(socketPath), but that " +
                "host cannot satisfy this command. No action was dispatched.",
            code: .BRIDGE_UNAVAILABLE,
            hint: "Update or relaunch that exact host, then run 'peekaboo see' again before retrying.",
            reason: .runtimeIncompatible
        )
    }
}
