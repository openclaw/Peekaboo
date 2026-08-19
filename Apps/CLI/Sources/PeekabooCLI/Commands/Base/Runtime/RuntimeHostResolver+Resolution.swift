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
        private var entriesBySocketPath: [String: Entry] = [:]

        convenience init() {
            self.init(identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: Bundle.main.bundleIdentifier,
                teamIdentifier: nil,
                processIdentifier: getpid(),
                hostname: Host.current().name
            ))
        }

        init(identity: PeekabooBridgeClientIdentity) {
            self.identity = identity
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

            let client = PeekabooBridgeClient(socketPath: candidate.socketPath)
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

    struct ImplicitRemoteCandidate: Equatable {
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
        let historicalBuildScopedDaemonTargets: [DaemonControlTarget]
        let historicalBuildScopedDaemonSocketPaths: [String]
        let candidates: [ImplicitRemoteCandidate]
    }

    struct RemoteCandidateValidation {
        let reusableDaemonStatus: PeekabooDaemonStatus?
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
        let snapshotInvalidationRemoteSocketPaths: [String]
        let applicationRelaunchAllowed: Bool
        let requiredHostFailure: String?
        var captureEngineSafetyOverride: CaptureEnginePreference?
        var toolCapturePreflightRefusal: MCPToolCapturePreflightRefusal?
    }
}
