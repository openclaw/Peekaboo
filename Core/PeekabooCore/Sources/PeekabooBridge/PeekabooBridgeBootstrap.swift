import Foundation
import PeekabooAutomationKit

@MainActor
public enum PeekabooBridgeBootstrap {
    struct HostConfiguration {
        let hostKind: PeekabooBridgeHostKind
        let socketPath: String
        let allowlistedTeams: Set<String>
        let allowlistedBundles: Set<String>
        let daemonControl: (any PeekabooDaemonControlProviding)?
        let automationActivityObserver: (@Sendable (pid_t) -> Void)?
        let allowedOperations: Set<PeekabooBridgeOperation>
        let hostIdentity: PeekabooBridgeHostIdentity?
        let hostCapabilities: Set<String>
        let desktopMutationWatermarkStore: DesktopMutationWatermarkStore
        let maxMessageBytes: Int
        let requestTimeoutSec: TimeInterval
        let requestDrainTimeoutSec: TimeInterval
    }

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
        let host = self.makeHost(
            services: services,
            configuration: HostConfiguration(
                hostKind: hostKind,
                socketPath: socketPath,
                allowlistedTeams: allowlistedTeams,
                allowlistedBundles: allowlistedBundles,
                daemonControl: daemonControl,
                automationActivityObserver: automationActivityObserver,
                allowedOperations: allowedOperations,
                hostIdentity: hostIdentity,
                hostCapabilities: hostCapabilities,
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
                maxMessageBytes: maxMessageBytes,
                requestTimeoutSec: requestTimeoutSec,
                requestDrainTimeoutSec: 1.0)).host
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
        let host = self.makeHost(
            services: services,
            configuration: HostConfiguration(
                hostKind: hostKind,
                socketPath: socketPath,
                allowlistedTeams: allowlistedTeams,
                allowlistedBundles: allowlistedBundles,
                daemonControl: daemonControl,
                automationActivityObserver: automationActivityObserver,
                allowedOperations: allowedOperations,
                hostIdentity: hostIdentity,
                hostCapabilities: hostCapabilities,
                desktopMutationWatermarkStore: DesktopMutationWatermarkStore(),
                maxMessageBytes: maxMessageBytes,
                requestTimeoutSec: requestTimeoutSec,
                requestDrainTimeoutSec: 1.0)).host
        try await host.startChecked()
        return host
    }

    static func makeHost(
        services: any PeekabooBridgeServiceProviding,
        configuration: HostConfiguration) -> (host: PeekabooBridgeHost, capabilities: Set<String>)
    {
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: configuration.hostKind,
            allowlistedTeams: configuration.allowlistedTeams,
            allowlistedBundles: configuration.allowlistedBundles,
            allowedOperations: configuration.allowedOperations,
            hostIdentity: configuration.hostIdentity,
            hostCapabilities: configuration.hostCapabilities,
            servingSocketPath: configuration.socketPath,
            daemonControl: configuration.daemonControl,
            desktopMutationWatermarkStore: configuration.desktopMutationWatermarkStore,
            automationActivityObserver: configuration.automationActivityObserver)
        let host = PeekabooBridgeHost(
            socketPath: configuration.socketPath,
            server: server,
            maxMessageBytes: configuration.maxMessageBytes,
            allowedTeamIDs: configuration.allowlistedTeams,
            requestTimeoutSec: configuration.requestTimeoutSec,
            requestDrainTimeoutSec: configuration.requestDrainTimeoutSec)
        return (host, server.hostCapabilities)
    }
}
