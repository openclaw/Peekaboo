import Foundation
import PeekabooAutomationKit

@MainActor
public enum PeekabooBridgeBootstrap {
    @discardableResult
    public static func startHost(
        services: any PeekabooBridgeServiceProviding,
        hostKind: PeekabooBridgeHostKind,
        socketPath: String,
        allowlistedTeams: Set<String>,
        allowlistedBundles: Set<String>,
        daemonControl: (any PeekabooDaemonControlProviding)? = nil,
        automationActivityObserver: (@Sendable (pid_t) -> Void)? = nil,
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
        hostIdentity: PeekabooBridgeHostIdentity? = .current(),
        hostCapabilities: Set<String> = [],
        maxMessageBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10) -> PeekabooBridgeHost
    {
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: hostKind,
            allowlistedTeams: allowlistedTeams,
            allowlistedBundles: allowlistedBundles,
            allowedOperations: allowedOperations,
            hostIdentity: hostIdentity,
            hostCapabilities: hostCapabilities,
            daemonControl: daemonControl,
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
            automationActivityObserver: automationActivityObserver)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            maxMessageBytes: maxMessageBytes,
            allowedTeamIDs: allowlistedTeams,
            requestTimeoutSec: requestTimeoutSec)
        Task {
            await host.start()
        }
        return host
    }

    @discardableResult
    public static func startHostChecked(
        services: any PeekabooBridgeServiceProviding,
        hostKind: PeekabooBridgeHostKind,
        socketPath: String,
        allowlistedTeams: Set<String>,
        allowlistedBundles: Set<String>,
        daemonControl: (any PeekabooDaemonControlProviding)? = nil,
        automationActivityObserver: (@Sendable (pid_t) -> Void)? = nil,
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
        hostIdentity: PeekabooBridgeHostIdentity? = .current(),
        hostCapabilities: Set<String> = [],
        maxMessageBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10) async throws -> PeekabooBridgeHost
    {
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: hostKind,
            allowlistedTeams: allowlistedTeams,
            allowlistedBundles: allowlistedBundles,
            allowedOperations: allowedOperations,
            hostIdentity: hostIdentity,
            hostCapabilities: hostCapabilities,
            daemonControl: daemonControl,
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
            automationActivityObserver: automationActivityObserver)
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            maxMessageBytes: maxMessageBytes,
            allowedTeamIDs: allowlistedTeams,
            requestTimeoutSec: requestTimeoutSec)
        try await host.startChecked()
        return host
    }
}
