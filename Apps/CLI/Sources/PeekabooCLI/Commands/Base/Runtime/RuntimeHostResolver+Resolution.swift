import Darwin
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore

extension RuntimeHostResolver {
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
