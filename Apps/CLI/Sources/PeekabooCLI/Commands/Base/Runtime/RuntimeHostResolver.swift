import Darwin
import Foundation
import PeekabooAutomation
import PeekabooBridge
import PeekabooCore

@MainActor
enum RuntimeHostResolver {
    struct Resolution {
        let services: any PeekabooServiceProviding
        let hostDescription: String
        let selectedRemoteSocketPath: String?
        let selectedRemoteHostProcessIdentifier: pid_t?
        let snapshotInvalidationRemoteSocketPaths: [String]
        let applicationRelaunchAllowed: Bool
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

    static func resolveServices(options: CommandRuntimeOptions) async -> Resolution {
        let environment = ProcessInfo.processInfo.environment
        let configurationInput = PeekabooAutomation.ConfigurationManager.shared.getConfiguration()?.input
        guard self.shouldResolveKnownRemoteEndpoints(
            options: options,
            environment: environment,
            configurationInput: configurationInput
        ) else {
            return Resolution(
                services: RuntimeServiceFactory.makeLocalServices(options: options),
                hostDescription: "local (in-process)",
                selectedRemoteSocketPath: nil,
                selectedRemoteHostProcessIdentifier: nil,
                snapshotInvalidationRemoteSocketPaths: [],
                applicationRelaunchAllowed: true
            )
        }

        let candidatePlan = await self.remoteCandidatePlan(options: options, environment: environment)
        let explicitSocket = candidatePlan.explicitSocket
        let daemonSocketPath = candidatePlan.daemonSocketPath
        let runtimeBuildIdentity = candidatePlan.runtimeBuildIdentity
        let buildScopedDaemonSocketPath = candidatePlan.buildScopedDaemonSocketPath
        let historicalBuildScopedDaemonSocketPaths = candidatePlan.historicalBuildScopedDaemonSocketPaths
        let snapshotInvalidationRemoteSocketPaths = snapshotInvalidationRemoteSocketPaths(
            explicitSocket: explicitSocket,
            daemonSocketPath: daemonSocketPath,
            buildScopedDaemonSocketPath: buildScopedDaemonSocketPath,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
        )

        if case let .local(localSnapshotInvalidationPaths) = initialRoutingDecision(
            options: options,
            environment: environment,
            configurationInput: configurationInput,
            knownSnapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths
        ) {
            return Resolution(
                services: RuntimeServiceFactory.makeLocalServices(options: options),
                hostDescription: "local (in-process)",
                selectedRemoteSocketPath: nil,
                selectedRemoteHostProcessIdentifier: nil,
                snapshotInvalidationRemoteSocketPaths: localSnapshotInvalidationPaths,
                applicationRelaunchAllowed: true
            )
        }

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: Host.current().name
        )

        var permissionRejections: [String] = []
        if let resolved = await resolveRemoteServices(
            candidates: candidatePlan.candidates,
            identity: identity,
            options: options,
            snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
            permissionRejections: &permissionRejections
        ) {
            return resolved
        }

        if DaemonLaunchPolicy.shouldAutoStartDaemon(options: options, environment: environment) {
            let rejectedDefaultSocketOccupant =
                await DaemonControlClient(socketPath: daemonSocketPath).fetchStatus() != nil
            let autoStartSocketPath = DaemonLaunchPolicy.autoStartSocketPath(
                daemonSocketPath: daemonSocketPath,
                defaultSocketWasOccupiedAndRejected: rejectedDefaultSocketOccupant,
                runtimeBuildIdentity: runtimeBuildIdentity
            )
            if let resolvedDaemonSocket = await DaemonLaunchPolicy.startOnDemandDaemon(
                socketPath: autoStartSocketPath,
                environment: environment
            ),
                let resolved = await resolveRemoteServices(
                    candidates: [ImplicitRemoteCandidate(
                        socketPath: resolvedDaemonSocket,
                        requireReusableDaemon: true,
                        requiredHostKind: nil,
                        requiresValidatedHistoricalDaemon: false
                    )],
                    identity: identity,
                    options: options,
                    snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
                    permissionRejections: &permissionRejections
                ) {
                return resolved
            }
        }

        // Name the hosts skipped for missing TCC permissions so a fallback is explainable
        // instead of the previous silent selection of a permission-less bridge host.
        let rejectionSummary = permissionRejections.isEmpty
            ? ""
            : "; rejected " + permissionRejections.joined(separator: "; ")
        return Resolution(
            services: RuntimeServiceFactory.makeLocalServices(options: options),
            hostDescription: "local (in-process fallback\(rejectionSummary))",
            selectedRemoteSocketPath: nil,
            selectedRemoteHostProcessIdentifier: nil,
            snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
            applicationRelaunchAllowed: !options.requiresApplicationRelaunch
        )
    }

    static func remoteRoutingAllowed(
        options: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?
    ) -> Bool {
        self.initialRoutingDecision(
            options: options,
            environment: environment,
            configurationInput: configurationInput,
            knownSnapshotInvalidationRemoteSocketPaths: []
        ) == .remote
    }

    static func remoteCandidatePlan(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) async -> RemoteCandidatePlan {
        let explicitSocket = BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment)
        let daemonSocketPath = DaemonLaunchPolicy.daemonSocketPath(environment: environment)
        let runtimeBuildIdentity = DaemonLaunchPolicy.runtimeBuildIdentity()
        let buildScopedDaemonSocketPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: daemonSocketPath,
            runtimeBuildIdentity: runtimeBuildIdentity
        )
        let historicalBuildScopedDaemonSocketPaths: [String] = if self.shouldDiscoverHistoricalDaemons(
            explicitSocket: explicitSocket,
            daemonSocketPath: daemonSocketPath
        ) {
            await DaemonControlResolver.validatedHistoricalTargets(
                daemonSocketPath: daemonSocketPath,
                currentBuildScopedSocketPath: buildScopedDaemonSocketPath
            )
            .filter { DaemonControlPlanner.supportsCurrentDaemon($0.status) }
            .map(\.client.socketPath)
        } else {
            []
        }

        let candidates: [ImplicitRemoteCandidate] = if let explicitSocket, !explicitSocket.isEmpty {
            [ImplicitRemoteCandidate(
                socketPath: explicitSocket,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            )]
        } else {
            self.implicitRemoteCandidates(
                options: options,
                daemonSocketPath: daemonSocketPath,
                buildScopedDaemonSocketPath: buildScopedDaemonSocketPath,
                historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
            )
        }

        return RemoteCandidatePlan(
            explicitSocket: explicitSocket,
            daemonSocketPath: daemonSocketPath,
            runtimeBuildIdentity: runtimeBuildIdentity,
            buildScopedDaemonSocketPath: buildScopedDaemonSocketPath,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths,
            candidates: candidates
        )
    }

    static func initialRoutingDecision(
        options: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?,
        knownSnapshotInvalidationRemoteSocketPaths: [String]
    ) -> InitialRoutingDecision {
        guard !self.remoteIsolationRequested(options: options, environment: environment) else {
            return .local(snapshotInvalidationRemoteSocketPaths: [])
        }

        if self.inputPolicyRequiresLocal(
            options: options,
            environment: environment,
            configurationInput: configurationInput
        ) {
            return .local(
                snapshotInvalidationRemoteSocketPaths: knownSnapshotInvalidationRemoteSocketPaths
            )
        }

        if !options.preferRemote,
           options.requiresImplicitSnapshotInvalidation || options.usesPerToolSnapshotInvalidation {
            return .local(
                snapshotInvalidationRemoteSocketPaths: knownSnapshotInvalidationRemoteSocketPaths
            )
        }

        guard options.preferRemote else {
            return .local(snapshotInvalidationRemoteSocketPaths: [])
        }

        return .remote
    }

    static func shouldResolveKnownRemoteEndpoints(
        options: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?
    ) -> Bool {
        guard !self.remoteIsolationRequested(options: options, environment: environment) else {
            return false
        }

        return options.preferRemote ||
            options.requiresImplicitSnapshotInvalidation ||
            options.usesPerToolSnapshotInvalidation ||
            self.inputPolicyRequiresLocal(
                options: options,
                environment: environment,
                configurationInput: configurationInput
            )
    }

    static func remoteIsolationRequested(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        options.remoteIsolationRequested || environment["PEEKABOO_NO_REMOTE"] != nil
    }

    static func snapshotInvalidationRemoteSocketPaths(
        explicitSocket: String?,
        daemonSocketPath: String,
        buildScopedDaemonSocketPath: String? = nil,
        historicalBuildScopedDaemonSocketPaths: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        var candidatePaths = [
            explicitSocket,
            PeekabooBridgeConstants.peekabooSocketPath,
            daemonSocketPath,
            buildScopedDaemonSocketPath,
        ]
            .compactMap(\.self)
        candidatePaths.append(contentsOf: historicalBuildScopedDaemonSocketPaths)
        return candidatePaths
            .map { NSString(string: $0).standardizingPath }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func shouldDiscoverHistoricalDaemons(
        explicitSocket: String?,
        daemonSocketPath: String
    ) -> Bool {
        explicitSocket == nil && DaemonLaunchPolicy.shouldMigrateLegacyDaemon(targetSocketPath: daemonSocketPath)
    }

    static func inputPolicyRequiresLocal(
        options: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?
    ) -> Bool {
        guard !options.requiresApplicationLaunchOptions,
              !options.requiresHostApplicationInventory
        else {
            return false
        }

        return options.inputStrategy != nil ||
            RuntimeInputPolicyResolver.hasEnvironmentOverride(environment: environment) ||
            RuntimeInputPolicyResolver.hasConfigOverride(input: configurationInput)
    }

    static func implicitRemoteCandidates(
        options: CommandRuntimeOptions,
        daemonSocketPath: String,
        buildScopedDaemonSocketPath: String? = nil,
        historicalBuildScopedDaemonSocketPaths: [String] = []
    ) -> [ImplicitRemoteCandidate] {
        var seenDaemonPaths = Set<String>()
        var daemons: [ImplicitRemoteCandidate] = []
        for socketPath in [daemonSocketPath, buildScopedDaemonSocketPath].compactMap(\.self) {
            guard seenDaemonPaths.insert(NSString(string: socketPath).standardizingPath).inserted else { continue }
            daemons.append(ImplicitRemoteCandidate(
                socketPath: socketPath,
                requireReusableDaemon: true,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            ))
        }
        for socketPath in historicalBuildScopedDaemonSocketPaths {
            guard seenDaemonPaths.insert(NSString(string: socketPath).standardizingPath).inserted else { continue }
            daemons.append(ImplicitRemoteCandidate(
                socketPath: socketPath,
                requireReusableDaemon: true,
                requiredHostKind: .onDemand,
                requiresValidatedHistoricalDaemon: true
            ))
        }
        let gui = ImplicitRemoteCandidate(
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )

        if options.requiresApplicationRelaunch || options.requiresSurvivingApplicationHost {
            return daemons
        }
        if options.requiresApplicationLaunchOptions || options.requiresHostApplicationInventory {
            return [gui] + daemons
        }
        if DaemonLaunchPolicy.shouldMigrateLegacyDaemon(targetSocketPath: daemonSocketPath) {
            return daemons + [gui]
        }
        return daemons
    }

    private static func resolveRemoteServices(
        candidates: [ImplicitRemoteCandidate],
        identity: PeekabooBridgeClientIdentity,
        options: CommandRuntimeOptions,
        snapshotInvalidationRemoteSocketPaths: [String],
        permissionRejections: inout [String]
    )
    async -> Resolution? {
        for candidate in candidates {
            let socketPath = candidate.socketPath
            let client = PeekabooBridgeClient(socketPath: socketPath)
            do {
                let handshake = try await client.handshake(client: identity, requestedHost: nil)
                guard let validation = await self.validateRemoteCandidate(
                    candidate,
                    handshake: handshake,
                    options: options
                ) else {
                    let missingPermissions = BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
                        for: handshake,
                        options: options
                    )
                    if !missingPermissions.isEmpty {
                        let permissionNames = BridgeCapabilityPolicy
                            .missingPermissionNames(missingPermissions)
                            .joined(separator: ", ")
                        permissionRejections.append(
                            "\(handshake.hostKind.rawValue) host via \(socketPath) missing \(permissionNames)"
                        )
                    }
                    continue
                }
                let reusableDaemonStatus = validation.reusableDaemonStatus

                let targetedHotkeyAvailability = BridgeCapabilityPolicy.targetedHotkeyAvailability(for: handshake)
                let targetedTypeAvailability = BridgeCapabilityPolicy.targetedTypeAvailability(for: handshake)
                let targetedClickAvailability = BridgeCapabilityPolicy.targetedClickAvailability(for: handshake)
                let hostDescription = "remote \(handshake.hostKind.rawValue) via \(socketPath)" +
                    (handshake.build.map { " (build \($0))" } ?? "")
                return Resolution(
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
                        supportsExactWindowTargetedClicks:
                        BridgeCapabilityPolicy.supportsExactWindowTargetedClicks(for: handshake),
                        supportsInspectAccessibilityTree: BridgeCapabilityPolicy.supportsInspectAccessibilityTree(
                            for: handshake
                        ),
                        supportsPostEventPermissionRequest: BridgeCapabilityPolicy.supportsPostEventPermissionRequest(
                            for: handshake
                        ),
                        supportsElementActions: BridgeCapabilityPolicy.supportsElementActions(for: handshake),
                        supportsDesktopObservation: BridgeCapabilityPolicy.supportsDesktopObservation(for: handshake),
                        supportsImplicitLatestSnapshotInvalidation:
                        BridgeCapabilityPolicy.supportsImplicitSnapshotInvalidation(for: handshake),
                        supportsApplicationLaunchOptions:
                        BridgeCapabilityPolicy.supportsApplicationLaunchOptions(for: handshake),
                        supportsApplicationRelaunch:
                        BridgeCapabilityPolicy.supportsApplicationRelaunch(for: handshake),
                        allowLocalApplicationFallback: handshake.hostKind == .onDemand,
                        desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
                    ),
                    hostDescription: hostDescription,
                    selectedRemoteSocketPath: NSString(string: socketPath).standardizingPath,
                    selectedRemoteHostProcessIdentifier: reusableDaemonStatus?.pid,
                    snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
                    applicationRelaunchAllowed: BridgeCapabilityPolicy.supportsApplicationRelaunch(for: handshake)
                )
            } catch {
                continue
            }
        }
        return nil
    }

    static func validateRemoteCandidate(
        _ candidate: ImplicitRemoteCandidate,
        handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions,
        fetchReusableDaemonStatus: (String) async -> PeekabooDaemonStatus? = { socketPath in
            await DaemonControlClient(socketPath: socketPath).fetchReusableDaemonStatus()
        }
    ) async -> RemoteCandidateValidation? {
        guard candidate.requiredHostKind == nil || handshake.hostKind == candidate.requiredHostKind else {
            return nil
        }
        guard BridgeCapabilityPolicy.supportsRemoteRequirements(for: handshake, options: options) else {
            return nil
        }

        let requiresReusableHost = candidate.requireReusableDaemon ||
            options.requiresApplicationRelaunch ||
            options.requiresSurvivingApplicationHost
        let reusableDaemonStatus: PeekabooDaemonStatus? = if requiresReusableHost {
            await fetchReusableDaemonStatus(candidate.socketPath)
        } else {
            nil
        }
        guard !requiresReusableHost || reusableDaemonStatus != nil else { return nil }

        if candidate.requiresValidatedHistoricalDaemon {
            guard let reusableDaemonStatus,
                  DaemonControlResolver.isValidatedHistoricalTarget(
                      status: reusableDaemonStatus,
                      socketPath: candidate.socketPath
                  ),
                  DaemonControlPlanner.supportsCurrentDaemon(reusableDaemonStatus)
            else {
                return nil
            }
        }
        if options.requiresApplicationRelaunch || options.requiresSurvivingApplicationHost,
           reusableDaemonStatus?.pid == nil {
            return nil
        }
        return RemoteCandidateValidation(reusableDaemonStatus: reusableDaemonStatus)
    }
}
