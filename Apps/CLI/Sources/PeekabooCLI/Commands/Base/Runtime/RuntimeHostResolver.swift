import Darwin
import Foundation
import PeekabooAutomation
import PeekabooBridge
import PeekabooCore

@MainActor
enum RuntimeHostResolver {
    static func resolveServices(options: CommandRuntimeOptions)
    async -> (services: any PeekabooServiceProviding, hostDescription: String) {
        let environment = ProcessInfo.processInfo.environment
        let envNoRemote = environment["PEEKABOO_NO_REMOTE"]
        guard options.preferRemote,
              envNoRemote == nil,
              options.inputStrategy == nil,
              !RuntimeInputPolicyResolver.hasEnvironmentOverride(environment: environment),
              !RuntimeInputPolicyResolver.hasConfigOverride(
                  input: PeekabooAutomation.ConfigurationManager.shared.getConfiguration()?.input
              )
        else {
            return (
                services: RuntimeServiceFactory.makeLocalServices(options: options),
                hostDescription: "local (in-process)"
            )
        }

        let explicitSocket = BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment)

        let daemonSocketPath = DaemonLaunchPolicy.daemonSocketPath(environment: environment)
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: Host.current().name
        )

        if let explicitSocket, !explicitSocket.isEmpty {
            if let resolved = await self.resolveRemoteServices(
                candidates: [explicitSocket],
                identity: identity,
                options: options,
                requireReusableDaemon: false
            ) {
                return resolved
            }
        } else {
            if let resolved = await self.resolveRemoteServices(
                candidates: [daemonSocketPath],
                identity: identity,
                options: options,
                requireReusableDaemon: true
            ) {
                return resolved
            }
            if DaemonLaunchPolicy.shouldMigrateLegacyDaemon(targetSocketPath: daemonSocketPath),
               let resolved = await self.resolveRemoteServices(
                   candidates: [PeekabooBridgeConstants.peekabooSocketPath],
                   identity: identity,
                   options: options,
                   requireReusableDaemon: false,
                   requiredHostKind: .gui
               ) {
                return resolved
            }
        }

        if options.autoStartDaemon,
           DaemonLaunchPolicy.shouldAutoStartDaemon(options: options, environment: environment),
           let resolvedDaemonSocket = await DaemonLaunchPolicy.startOnDemandDaemon(
               socketPath: daemonSocketPath,
               environment: environment
           ),
           let resolved = await self.resolveRemoteServices(
               candidates: [resolvedDaemonSocket],
               identity: identity,
               options: options,
               requireReusableDaemon: true
           ) {
            return resolved
        }

        return (
            services: RuntimeServiceFactory.makeLocalServices(options: options),
            hostDescription: "local (in-process)"
        )
    }

    private static func resolveRemoteServices(
        candidates: [String],
        identity: PeekabooBridgeClientIdentity,
        options: CommandRuntimeOptions,
        requireReusableDaemon: Bool,
        requiredHostKind: PeekabooBridgeHostKind? = nil
    )
    async -> (services: any PeekabooServiceProviding, hostDescription: String)? {
        for socketPath in candidates {
            let client = PeekabooBridgeClient(socketPath: socketPath)
            do {
                let handshake = try await client.handshake(client: identity, requestedHost: nil)
                guard requiredHostKind == nil || handshake.hostKind == requiredHostKind else {
                    continue
                }
                guard BridgeCapabilityPolicy.supportsRemoteRequirements(for: handshake, options: options) else {
                    continue
                }
                if requireReusableDaemon,
                   await DaemonControlClient(socketPath: socketPath).fetchReusableDaemonStatus() == nil {
                    continue
                }

                let targetedHotkeyAvailability = BridgeCapabilityPolicy.targetedHotkeyAvailability(for: handshake)
                let targetedTypeAvailability = BridgeCapabilityPolicy.targetedTypeAvailability(for: handshake)
                let targetedClickAvailability = BridgeCapabilityPolicy.targetedClickAvailability(for: handshake)
                let hostDescription = "remote \(handshake.hostKind.rawValue) via \(socketPath)" +
                    (handshake.build.map { " (build \($0))" } ?? "")
                return (
                    services: RemotePeekabooServices(
                        client: client,
                        supportsTargetedHotkeys: targetedHotkeyAvailability.isEnabled,
                        targetedHotkeyUnavailableReason: targetedHotkeyAvailability.unavailableReason,
                        targetedHotkeyRequiresEventSynthesizingPermission:
                        targetedHotkeyAvailability.missingPermissions.contains(.postEvent),
                        supportsTargetedTypeActions: targetedTypeAvailability.isEnabled,
                        targetedTypeUnavailableReason: targetedTypeAvailability.unavailableReason,
                        targetedTypeRequiresEventSynthesizingPermission:
                        targetedTypeAvailability.missingPermissions.contains(.postEvent),
                        supportsTargetedClicks: targetedClickAvailability.isEnabled,
                        targetedClickUnavailableReason: targetedClickAvailability.unavailableReason,
                        targetedClickRequiresEventSynthesizingPermission:
                        targetedClickAvailability.missingPermissions.contains(.postEvent),
                        supportsInspectAccessibilityTree: BridgeCapabilityPolicy.supportsInspectAccessibilityTree(
                            for: handshake
                        ),
                        supportsPostEventPermissionRequest: BridgeCapabilityPolicy.supportsPostEventPermissionRequest(
                            for: handshake
                        ),
                        supportsElementActions: BridgeCapabilityPolicy.supportsElementActions(for: handshake),
                        supportsDesktopObservation: BridgeCapabilityPolicy.supportsDesktopObservation(for: handshake),
                        allowLocalApplicationFallback: handshake.hostKind == .onDemand
                    ),
                    hostDescription: hostDescription
                )
            } catch {
                continue
            }
        }
        return nil
    }
}
