import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore

extension RuntimeHostResolver {
    /// Reuses fully authenticated handshakes only within one runtime-resolution attempt.
    /// Candidate requirements are reapplied before selection, and the retained client keeps the
    /// listener identity and operation session that every later request revalidates before writing.
    @MainActor
    final class RemoteHandshakeCache {
        struct Entry {
            let client: PeekabooBridgeClient
            let response: PeekabooBridgeHandshakeResponse
        }

        let identity: PeekabooBridgeClientIdentity
        let trustedHostTeamIDs: Set<String>?
        let clientFactory: (@MainActor (String) -> PeekabooBridgeClient)?
        private var entriesBySocketPath: [String: Entry] = [:]

        convenience init() {
            self.init(identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                teamIdentifier: nil,
                processIdentifier: getpid(),
                hostname: Host.current().name
            ))
        }

        init(
            identity: PeekabooBridgeClientIdentity,
            trustedHostTeamIDs: Set<String>? = nil,
            clientFactory: (@MainActor (String) -> PeekabooBridgeClient)? = nil
        ) {
            self.identity = identity
            self.trustedHostTeamIDs = trustedHostTeamIDs
            self.clientFactory = clientFactory
        }

        func handshake(
            _ candidate: ImplicitRemoteCandidate,
            identity: PeekabooBridgeClientIdentity
        ) async throws -> Entry {
            guard self.isBound(to: identity) else {
                throw POSIXError(.EINVAL)
            }
            let socketPath = Self.standardizedSocketPath(candidate.socketPath)
            if let entry = self.entriesBySocketPath[socketPath] {
                return entry
            }

            let client = self.clientFactory?(candidate.socketPath) ?? PeekabooBridgeClient(
                socketPath: candidate.socketPath,
                trustedHostTeamIDs: self.trustedHostTeamIDs
            )
            let response = try await client.handshake(client: self.identity, requestedHost: nil)
            let entry = Entry(client: client, response: response)
            self.entriesBySocketPath[socketPath] = entry
            return entry
        }

        func entry(
            for candidate: ImplicitRemoteCandidate,
            identity: PeekabooBridgeClientIdentity
        ) -> Entry? {
            guard self.isBound(to: identity) else { return nil }
            return self.entriesBySocketPath[Self.standardizedSocketPath(candidate.socketPath)]
        }

        private func isBound(to identity: PeekabooBridgeClientIdentity) -> Bool {
            self.identity.bundleIdentifier == identity.bundleIdentifier &&
                self.identity.teamIdentifier == identity.teamIdentifier &&
                self.identity.processIdentifier == identity.processIdentifier &&
                self.identity.hostname == identity.hostname
        }

        private static func standardizedSocketPath(_ socketPath: String) -> String {
            NSString(string: socketPath).standardizingPath
        }
    }

    struct ImplicitRemoteCandidate: Equatable, Sendable {
        let socketPath: String
        let requireReusableDaemon: Bool
        let requiredHostKind: PeekabooBridgeHostKind?
        let requiresValidatedHistoricalDaemon: Bool
    }

    struct RemoteCandidatePlan {
        let explicitSocket: String?
        let daemonSocketPath: String
        let runtimeBuildIdentity: String
        let buildScopedDaemonSocketPath: String?
        let historicalBuildScopedDaemonSocketPaths: [String]
        let candidates: [ImplicitRemoteCandidate]
    }

    struct RemoteCandidateValidation {
        let reusableDaemonStatus: PeekabooDaemonStatus?
    }

    enum RemoteCandidateRejection: Equatable {
        case protocolVersionMismatch
        case hostKindMismatch(expected: PeekabooBridgeHostKind)
        case missingPermissions(Set<PeekabooBridgePermissionKind>)
        case requirementsNotMet
        case reusableDaemonUnavailable
        case historicalDaemonInvalid
        case reusableDaemonIdentityUnavailable
    }

    struct RemoteCandidateEvaluation {
        let validation: RemoteCandidateValidation?
        let rejection: RemoteCandidateRejection?

        static func accepted(_ validation: RemoteCandidateValidation) -> Self {
            Self(validation: validation, rejection: nil)
        }

        static func rejected(_ rejection: RemoteCandidateRejection) -> Self {
            Self(validation: nil, rejection: rejection)
        }
    }

    enum InitialRoutingDecision: Equatable {
        case local(snapshotInvalidationRemoteSocketPaths: [String])
        case remote
    }

    struct Resolution {
        let services: any PeekabooServiceProviding
        let hostDescription: String
        let selectedRemoteSocketPath: String?
        let selectedRemoteHostProcessIdentifier: pid_t?
        var selectedRemoteHostIdentity: PeekabooBridgeHostIdentity?
        var selectedRemoteAuthenticatedHostIdentity: PeekabooBridgeAuthenticatedHostIdentity?
        var selectedRemoteAuthenticatedHostIdentityProvider:
            (@Sendable () async -> PeekabooBridgeAuthenticatedHostIdentity?)?
        let snapshotInvalidationRemoteSocketPaths: [String]
        let applicationRelaunchAllowed: Bool
        let requiredHostFailure: String?
        var captureEngineSafetyOverride: CaptureEnginePreference?
        var toolCapturePreflightRefusal: MCPToolCapturePreflightRefusal?
    }
}

extension RuntimeHostResolver {
    static func evaluateRemoteCandidate(
        _ candidate: ImplicitRemoteCandidate,
        handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions,
        requiredProtocolVersion: PeekabooBridgeProtocolVersion? = nil,
        fetchReusableDaemonStatus: (String) async -> PeekabooDaemonStatus? = { socketPath in
            try? await DaemonControlClient(socketPath: socketPath).fetchReusableDaemonStatus()
        }
    ) async -> RemoteCandidateEvaluation {
        guard requiredProtocolVersion == nil || handshake.negotiatedVersion == requiredProtocolVersion else {
            return .rejected(.protocolVersionMismatch)
        }
        if let requiredHostKind = candidate.requiredHostKind,
           handshake.hostKind != requiredHostKind {
            return .rejected(.hostKindMismatch(expected: requiredHostKind))
        }
        let missingPermissions = BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
            for: handshake,
            options: options
        )
        guard missingPermissions.isEmpty else {
            return .rejected(.missingPermissions(missingPermissions))
        }
        guard BridgeCapabilityPolicy.supportsRemoteRequirements(for: handshake, options: options) else {
            return .rejected(.requirementsNotMet)
        }

        let requiresReusableHost = candidate.requireReusableDaemon ||
            options.requiresApplicationRelaunch ||
            options.requiresSurvivingApplicationHost
        let reusableDaemonStatus: PeekabooDaemonStatus? = if requiresReusableHost {
            await fetchReusableDaemonStatus(candidate.socketPath)
        } else {
            nil
        }
        guard !requiresReusableHost || reusableDaemonStatus != nil else {
            return .rejected(.reusableDaemonUnavailable)
        }

        if candidate.requiresValidatedHistoricalDaemon {
            guard let reusableDaemonStatus,
                  DaemonControlResolver.isValidatedHistoricalTarget(
                      status: reusableDaemonStatus,
                      socketPath: candidate.socketPath
                  ),
                  DaemonControlPlanner.supportsCurrentDaemon(reusableDaemonStatus)
            else {
                return .rejected(.historicalDaemonInvalid)
            }
        }
        if options.requiresApplicationRelaunch || options.requiresSurvivingApplicationHost,
           reusableDaemonStatus?.pid == nil {
            return .rejected(.reusableDaemonIdentityUnavailable)
        }
        return .accepted(RemoteCandidateValidation(reusableDaemonStatus: reusableDaemonStatus))
    }
}
