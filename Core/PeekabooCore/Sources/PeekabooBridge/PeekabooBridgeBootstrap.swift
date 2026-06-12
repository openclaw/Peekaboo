import Foundation

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
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
        maxMessageBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10) -> PeekabooBridgeHost
    {
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: hostKind,
            allowlistedTeams: allowlistedTeams,
            allowlistedBundles: allowlistedBundles,
            allowedOperations: allowedOperations,
            daemonControl: daemonControl)
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
        allowedOperations: Set<PeekabooBridgeOperation> = PeekabooBridgeOperation.remoteDefaultAllowlist,
        maxMessageBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10) async throws -> PeekabooBridgeHost
    {
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: hostKind,
            allowlistedTeams: allowlistedTeams,
            allowlistedBundles: allowlistedBundles,
            allowedOperations: allowedOperations,
            daemonControl: daemonControl)
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
