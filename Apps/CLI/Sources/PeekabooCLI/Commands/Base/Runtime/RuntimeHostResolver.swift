import Darwin
import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore

@MainActor
enum RuntimeHostResolver {
    static func resolveServices(options: CommandRuntimeOptions) async throws -> Resolution {
        let environment = ProcessInfo.processInfo.environment
        let configurationInput = PeekabooAutomation.ConfigurationManager.shared.getConfiguration()?.input
        return try await self.resolveServices(
            options: options,
            environment: environment,
            configurationInput: configurationInput,
            dependencies: .live
        )
    }

    static func resolveServices(
        options: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?,
        dependencies: Dependencies
    ) async throws -> Resolution {
        var deferredScreenCaptureKitSafetyBlocker = false
        var captureEngineSafetyOverride: CaptureEnginePreference?
        var toolCapturePreflightRefusal: MCPToolCapturePreflightRefusal?
        var handshakeCache: RemoteHandshakeCache?
        if self.requiresCallerLocalModernOwnerClaim(options: options, environment: environment) {
            do {
                if let owner = try dependencies.inspectScreenCaptureKitOwner(),
                   !self.screenCaptureKitOwnerIsCurrentProcess(owner) {
                    throw self.ownerRefusal(owner: owner, callerLocal: true)
                }
            } catch let error as PreDispatchActionError {
                throw error
            } catch {
                throw self.ownerRefusal(error: error, callerLocal: true, selectedSocket: options.bridgeSocketPath)
            }
        }
        let safetyPlan: RemoteCandidatePlan?
        if self.requiresCallerLocalScreenCaptureKitSafetyCheck(options: options, environment: environment) {
            let plan = await dependencies.remoteCandidatePlan(options, environment)
            safetyPlan = plan
            let resolvedHandshakeCache = RemoteHandshakeCache()
            handshakeCache = resolvedHandshakeCache
            if let oldHost = try await dependencies.inspectScreenCaptureKitSafety(
                options,
                environment,
                self.screenCaptureKitSafetyCandidates(from: plan),
                resolvedHandshakeCache
            ) {
                // The live recorder installs an irreversible process-lifetime tombstone. One
                // discovered old host therefore blocks every later SCK leaf even if another old
                // host appears, disappears, or reuses the same socket before the runtime restarts.
                dependencies.recordScreenCaptureKitSafetyBlocker(oldHost)
                switch self.screenCaptureKitSafetyDisposition(
                    for: oldHost, plan: plan, options: options, environment: environment
                ) {
                case .refuse: throw self.ownerCapabilityRefusal(host: oldHost, selectedSocket: plan.explicitSocket)
                case .deferLocalRuntime:
                    toolCapturePreflightRefusal = self.dynamicToolCapturePreflightRefusal(
                        host: oldHost,
                        selectedSocket: plan.explicitSocket
                    )
                    deferredScreenCaptureKitSafetyBlocker = true
                case .deferToolCapture:
                    toolCapturePreflightRefusal = self.dynamicToolCapturePreflightRefusal(
                        host: oldHost,
                        selectedSocket: plan.explicitSocket
                    )
                case .routeAutomaticCapture:
                    // The blocker tombstone belongs to this caller process. Clamp the transported
                    // request so a different Bridge process cannot fall back from classic to SCK.
                    captureEngineSafetyOverride = .legacy
                }
            }
        } else {
            safetyPlan = nil
        }
        if self.requiresCallerLocalModernOwnerClaim(options: options, environment: environment) {
            do {
                _ = try dependencies.claimScreenCaptureKitOwner()
            } catch {
                throw self.ownerRefusal(error: error, callerLocal: true, selectedSocket: safetyPlan?.explicitSocket)
            }
        }

        guard self.shouldResolveKnownRemoteEndpoints(
            options: options,
            environment: environment,
            configurationInput: configurationInput
        )
        else {
            return Resolution(
                services: dependencies.makeLocalServices(options),
                hostDescription: "local (in-process)",
                selectedRemoteSocketPath: nil,
                selectedRemoteHostProcessIdentifier: nil,
                snapshotInvalidationRemoteSocketPaths: [],
                applicationRelaunchAllowed: true,
                requiredHostFailure: nil,
                captureEngineSafetyOverride: captureEngineSafetyOverride,
                toolCapturePreflightRefusal: toolCapturePreflightRefusal
            )
        }

        let candidatePlan = if let safetyPlan {
            safetyPlan
        } else {
            await dependencies.remoteCandidatePlan(options, environment)
        }
        let explicitSocket = candidatePlan.explicitSocket
        let daemonSocketPath = candidatePlan.daemonSocketPath
        let buildScopedDaemonSocketPath = candidatePlan.buildScopedDaemonSocketPath
        let historicalBuildScopedDaemonSocketPaths = candidatePlan.historicalBuildScopedDaemonSocketPaths
        let snapshotInvalidationRemoteSocketPaths = snapshotInvalidationRemoteSocketPaths(
            explicitSocket: explicitSocket,
            daemonSocketPath: daemonSocketPath,
            buildScopedDaemonSocketPath: buildScopedDaemonSocketPath,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
        )

        if deferredScreenCaptureKitSafetyBlocker {
            return Resolution(
                services: dependencies.makeLocalServices(options),
                hostDescription: "local (ScreenCaptureKit blocked by a pre-lease Bridge host)",
                selectedRemoteSocketPath: nil,
                selectedRemoteHostProcessIdentifier: nil,
                snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
                applicationRelaunchAllowed: true,
                requiredHostFailure: nil,
                captureEngineSafetyOverride: captureEngineSafetyOverride,
                toolCapturePreflightRefusal: toolCapturePreflightRefusal
            )
        }

        let preferredScreenCaptureKitOwner: ScreenCaptureKitOwnerLease.OwnerReceipt?
        if self.shouldPreferScreenCaptureKitOwnerHost(options: options, environment: environment) {
            do {
                preferredScreenCaptureKitOwner = try dependencies.inspectScreenCaptureKitOwner()
            } catch {
                let selectedSocket = candidatePlan.explicitSocket
                throw self.ownerRefusal(error: error, callerLocal: false, selectedSocket: selectedSocket)
            }
        } else {
            preferredScreenCaptureKitOwner = nil
        }

        if preferredScreenCaptureKitOwner == nil,
           case let .local(localSnapshotInvalidationPaths) = initialRoutingDecision(
               options: options,
               environment: environment,
               configurationInput: configurationInput,
               knownSnapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths
           ) {
            return Resolution(
                services: dependencies.makeLocalServices(options),
                hostDescription: "local (in-process)",
                selectedRemoteSocketPath: nil,
                selectedRemoteHostProcessIdentifier: nil,
                snapshotInvalidationRemoteSocketPaths: localSnapshotInvalidationPaths,
                applicationRelaunchAllowed: true,
                requiredHostFailure: nil,
                captureEngineSafetyOverride: captureEngineSafetyOverride,
                toolCapturePreflightRefusal: toolCapturePreflightRefusal
            )
        }

        let resolvedHandshakeCache = handshakeCache ?? RemoteHandshakeCache()
        var resolution = try await self.resolveRemoteRouting(context: RemoteResolutionContext(
            options: options,
            environment: environment,
            candidatePlan: candidatePlan,
            identity: resolvedHandshakeCache.identity,
            handshakeCache: resolvedHandshakeCache,
            snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
            preferredScreenCaptureKitOwner: preferredScreenCaptureKitOwner,
            makeLocalServices: dependencies.makeLocalServices,
            inspectScreenCaptureKitSafety: dependencies.inspectScreenCaptureKitSafety,
            recordScreenCaptureKitSafetyBlocker: dependencies.recordScreenCaptureKitSafetyBlocker
        ))
        resolution.captureEngineSafetyOverride = captureEngineSafetyOverride
        resolution.toolCapturePreflightRefusal = toolCapturePreflightRefusal
        return resolution
    }

    private static func resolveRemoteRouting(
        context: RemoteResolutionContext
    ) async throws -> Resolution {
        let options = context.options
        let candidatePlan = context.candidatePlan
        let explicitSocket = candidatePlan.explicitSocket
        let daemonSocketPath = candidatePlan.daemonSocketPath
        let runtimeBuildIdentity = candidatePlan.runtimeBuildIdentity
        let buildScopedDaemonSocketPath = candidatePlan.buildScopedDaemonSocketPath
        let snapshotInvalidationRemoteSocketPaths = context.snapshotInvalidationRemoteSocketPaths

        // Stateful implicit commands share in-memory snapshots across invocations. Establish
        // the exact daemon generation for this executable before considering compatible older
        // hosts; protocol equality alone cannot distinguish two builds that both speak 1.11.
        let prefersExactBuildScopedHost = self.prefersExactBuildScopedHost(
            options: options,
            explicitSocket: explicitSocket,
            buildScopedDaemonSocketPath: buildScopedDaemonSocketPath
        )
        var permissionRejections: [String] = []
        let ownerAwareCandidates = explicitSocket == nil
            ? self.screenCaptureKitOwnerCandidates(from: candidatePlan.candidates)
            : candidatePlan.candidates

        if explicitSocket != nil,
           self.captureEnginePreferenceForOwnership(options: options, environment: context.environment) == .legacy,
           options.requiresScreenCaptureKitOwnerCapability,
           let oldHost = try await context.inspectScreenCaptureKitSafety(
               options,
               context.environment,
               candidatePlan.candidates,
               context.handshakeCache
           ) {
            context.recordScreenCaptureKitSafetyBlocker(oldHost)
            throw self.ownerCapabilityRefusal(host: oldHost, selectedSocket: explicitSocket)
        }

        if let preferredScreenCaptureKitOwner = context.preferredScreenCaptureKitOwner {
            // An explicit socket remains authoritative: validate only that host against the
            // process-lifetime owner instead of silently rerouting to a different Bridge.
            if let resolved = try await context.resolveRemoteServices(
                candidates: ownerAwareCandidates,
                requiredOwner: preferredScreenCaptureKitOwner,
                permissionRejections: &permissionRejections
            ) {
                return await self.finalizeExactBuildScopedResolution(resolved, candidatePlan: candidatePlan)
            }
            if prefersExactBuildScopedHost, let buildScopedDaemonSocketPath {
                throw self.ownerExactBuildConflict(
                    owner: preferredScreenCaptureKitOwner,
                    requiredSocket: buildScopedDaemonSocketPath
                )
            }
            if let explicitSocket {
                throw self.ownerRefusal(
                    owner: preferredScreenCaptureKitOwner,
                    explicitSocket: explicitSocket
                )
            }
            throw self.ownerRefusal(
                owner: preferredScreenCaptureKitOwner,
                callerLocal: false
            )
        }

        if prefersExactBuildScopedHost, let buildScopedDaemonSocketPath {
            let exactCandidate = ImplicitRemoteCandidate(
                socketPath: buildScopedDaemonSocketPath,
                requireReusableDaemon: true,
                requiredHostKind: .onDemand,
                requiresValidatedHistoricalDaemon: false
            )
            if let resolved = try await context.resolveRemoteServices(
                candidates: [exactCandidate],
                requiredProtocolVersion: PeekabooBridgeConstants.protocolVersion,
                permissionRejections: &permissionRejections
            ) {
                return await self.finalizeExactBuildScopedResolution(resolved, candidatePlan: candidatePlan)
            }

            let exactHostExists = await DaemonControlClient(socketPath: buildScopedDaemonSocketPath)
                .fetchStatus() != nil
            if !exactHostExists,
               DaemonLaunchPolicy.shouldAutoStartDaemon(options: options, environment: context.environment),
               let resolvedDaemonSocket = try await DaemonLaunchPolicy.startOnDemandDaemon(
                   socketPath: buildScopedDaemonSocketPath,
                   environment: context.environment
               ),
               let resolved = try await context.resolveRemoteServices(
                   candidates: [ImplicitRemoteCandidate(
                       socketPath: resolvedDaemonSocket,
                       requireReusableDaemon: true,
                       requiredHostKind: .onDemand,
                       requiresValidatedHistoricalDaemon: false
                   )],
                   requiredProtocolVersion: PeekabooBridgeConstants.protocolVersion,
                   permissionRejections: &permissionRejections
               ) {
                return await self.finalizeExactBuildScopedResolution(resolved, candidatePlan: candidatePlan)
            }
        }

        if let resolved = try await context.resolveRemoteServices(
            candidates: candidatePlan.candidates,
            permissionRejections: &permissionRejections
        ) {
            return await self.finalizeExactBuildScopedResolution(resolved, candidatePlan: candidatePlan)
        }

        if let explicitSocket,
           !options.permitsExplicitSocketDiagnosticFallback,
           options.requiresStatelessClickVariants ||
           self.requiredHostFailure(explicitSocket: explicitSocket, options: options) == nil {
            throw BridgeExplicitSocketUnavailableError(
                socketPath: NSString(string: explicitSocket).standardizingPath
            )
        }

        if !prefersExactBuildScopedHost,
           DaemonLaunchPolicy.shouldAutoStartDaemon(options: options, environment: context.environment) {
            let rejectedDefaultSocketOccupant =
                await DaemonControlClient(socketPath: daemonSocketPath).fetchStatus() != nil
            let autoStartSocketPath = DaemonLaunchPolicy.autoStartSocketPath(
                daemonSocketPath: daemonSocketPath,
                defaultSocketWasOccupiedAndRejected: rejectedDefaultSocketOccupant,
                runtimeBuildIdentity: runtimeBuildIdentity
            )
            if let resolvedDaemonSocket = try await DaemonLaunchPolicy.startOnDemandDaemon(
                socketPath: autoStartSocketPath,
                environment: context.environment
            ),
                let resolved = try await context.resolveRemoteServices(
                    candidates: [ImplicitRemoteCandidate(
                        socketPath: resolvedDaemonSocket,
                        requireReusableDaemon: true,
                        requiredHostKind: nil,
                        requiresValidatedHistoricalDaemon: false
                    )],
                    permissionRejections: &permissionRejections
                ) {
                return await self.finalizeExactBuildScopedResolution(resolved, candidatePlan: candidatePlan)
            }
        }

        try Task.checkCancellation()
        return self.localFallbackResolution(
            options: options,
            explicitSocket: explicitSocket,
            snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
            permissionRejections: permissionRejections,
            makeLocalServices: context.makeLocalServices
        )
    }

    private static func localFallbackResolution(
        options: CommandRuntimeOptions,
        explicitSocket: String?,
        snapshotInvalidationRemoteSocketPaths: [String],
        permissionRejections: [String],
        makeLocalServices: LocalServiceFactory
    ) -> Resolution {
        // Name the hosts skipped for missing TCC permissions so a fallback is explainable
        // instead of silently selecting a permission-less bridge host.
        let rejectionSummary = permissionRejections.isEmpty
            ? ""
            : "; rejected " + permissionRejections.joined(separator: "; ")
        return Resolution(
            services: makeLocalServices(options),
            hostDescription: "local (in-process fallback\(rejectionSummary))",
            selectedRemoteSocketPath: nil,
            selectedRemoteHostProcessIdentifier: nil,
            snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
            applicationRelaunchAllowed: !options.requiresApplicationRelaunch,
            requiredHostFailure: self.requiredHostFailure(
                explicitSocket: explicitSocket,
                options: options
            )
        )
    }

    static func requiredHostFailure(explicitSocket: String?, options: CommandRuntimeOptions) -> String? {
        if options.requiresStatelessClickVariants {
            if !options.requiresBackgroundStatelessClickVariants {
                return "No compatible Bridge host negotiates protocol 1.30 middle/triple-click payloads. " +
                    "Update and relaunch Peekaboo before retrying."
            }
            return "No compatible Bridge host advertises protocol 1.30 middle/triple-click support. " +
                "Update and relaunch Peekaboo on the selected host, or pass --no-remote to run locally."
        }
        if options.requiresDesktopObservationOCR {
            return "No compatible Bridge host advertises desktopObservationOCR. Update and relaunch Peekaboo " +
                "on the selected host, or pass --no-remote to explicitly run Vision OCR in the caller process."
        }
        if explicitSocket != nil, options.requiresExactWindowROIObservation {
            return "The explicitly selected Bridge host does not support exact-window ROI observation; " +
                "protocol 1.21 with enabled observation and atomic snapshot publication is required."
        }
        if let failure = explicitSnapshotPublicationFailure(explicitSocket: explicitSocket, options: options) {
            return failure
        }
        if options.requiresCaptureEnginePreferenceHost {
            let engine = options.captureEnginePreference ?? "requested"
            return "Capture engine '\(engine)' could not be delivered to a compatible Bridge host. " +
                "Peekaboo will not switch capture or TCC ownership silently; start a current Bridge host, " +
                "or pass --no-remote to explicitly run capture in the caller process."
        }
        return nil
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
        let historicalBuildScopedDaemonTargets: [DaemonControlTarget] = if self.shouldDiscoverHistoricalDaemons(
            explicitSocket: explicitSocket,
            daemonSocketPath: daemonSocketPath
        ) {
            await DaemonControlResolver.validatedHistoricalTargets(
                daemonSocketPath: daemonSocketPath,
                currentBuildScopedSocketPath: buildScopedDaemonSocketPath
            )
        } else {
            []
        }
        let historicalBuildScopedDaemonSocketPaths = historicalBuildScopedDaemonTargets
            .filter { DaemonControlPlanner.supportsCurrentDaemon($0.status) }
            .map(\.client.socketPath)

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
            historicalBuildScopedDaemonTargets: historicalBuildScopedDaemonTargets,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths,
            candidates: candidates
        )
    }

    private static func finalizeExactBuildScopedResolution(
        _ resolution: Resolution,
        candidatePlan: RemoteCandidatePlan
    ) async -> Resolution {
        guard candidatePlan.explicitSocket == nil,
              let currentSocketPath = candidatePlan.buildScopedDaemonSocketPath,
              resolution.selectedRemoteSocketPath == NSString(string: currentSocketPath).standardizingPath
        else {
            return resolution
        }

        // Debug builds get generation-specific hosts. Once the current generation is usable,
        // retire only safely identified auto hosts already past their idle deadline so
        // ScreenCaptureKit state cannot pile up without interrupting long-lived clients.
        await DaemonControlResolver.stopIdleHistoricalAutoDaemons(
            candidatePlan.historicalBuildScopedDaemonTargets,
            daemonSocketPath: candidatePlan.daemonSocketPath,
            currentBuildScopedSocketPath: currentSocketPath
        )
        return resolution
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

    static func prefersExactBuildScopedHost(
        options: CommandRuntimeOptions,
        explicitSocket: String?,
        buildScopedDaemonSocketPath: String?
    ) -> Bool {
        guard explicitSocket == nil,
              buildScopedDaemonSocketPath != nil,
              !options.requiresApplicationLaunchOptions,
              !options.requiresHostApplicationInventory
        else {
            return false
        }
        return options.requiresScreenCapturePermission ||
            options.requiresInspectAccessibilityTree ||
            options.requiresBrowserMCP ||
            options.requiresImplicitSnapshotInvalidation ||
            options.usesPerToolSnapshotInvalidation
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
        // Once a build-scoped daemon exists it is the exact binary generation for this CLI.
        // Probe it before the canonical socket, which may still be occupied by a compatible
        // older daemon during migration.
        for socketPath in [buildScopedDaemonSocketPath, daemonSocketPath].compactMap(\.self) {
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

    static func resolveRemoteServices(
        candidates: [ImplicitRemoteCandidate],
        identity: PeekabooBridgeClientIdentity,
        options: CommandRuntimeOptions,
        requiredProtocolVersion: PeekabooBridgeProtocolVersion? = nil,
        requiredOwner: ScreenCaptureKitOwnerLease.OwnerReceipt? = nil,
        snapshotInvalidationRemoteSocketPaths: [String],
        permissionRejections: inout [String],
        handshake: ScreenCaptureKitHandshake? = nil,
        handshakeCache: RemoteHandshakeCache? = nil
    )
    async throws -> Resolution? {
        for candidate in candidates {
            try Task.checkCancellation()
            let socketPath = candidate.socketPath
            do {
                let client: PeekabooBridgeClient
                let handshakeResponse: PeekabooBridgeHandshakeResponse
                if let handshake {
                    client = PeekabooBridgeClient(socketPath: socketPath)
                    handshakeResponse = try await handshake(candidate, identity)
                } else if let cached = handshakeCache?.entry(for: candidate, identity: identity) {
                    client = cached.client
                    handshakeResponse = cached.response
                } else {
                    client = PeekabooBridgeClient(socketPath: socketPath)
                    handshakeResponse = try await client.handshake(client: identity, requestedHost: nil)
                }
                try Task.checkCancellation()
                let validation = await self.validateRemoteCandidate(
                    candidate,
                    handshake: handshakeResponse,
                    options: options,
                    requiredProtocolVersion: requiredProtocolVersion
                )
                try Task.checkCancellation()
                guard let validation else {
                    let missingPermissions = BridgeCapabilityPolicy.explicitlyMissingRemotePermissions(
                        for: handshakeResponse,
                        options: options
                    )
                    if !missingPermissions.isEmpty {
                        let permissionNames = BridgeCapabilityPolicy
                            .missingPermissionNames(missingPermissions)
                            .joined(separator: ", ")
                        permissionRejections.append(
                            "\(handshakeResponse.hostKind.rawValue) host via \(socketPath) missing \(permissionNames)"
                        )
                    }
                    continue
                }
                if let requiredOwner,
                   !self.screenCaptureKitHostMatchesOwner(handshake: handshakeResponse, owner: requiredOwner) {
                    continue
                }
                try Task.checkCancellation()
                let hostDescription = Self.remoteHostDescription(handshake: handshakeResponse, socketPath: socketPath)
                return Resolution(
                    services: Self.remoteServices(client: client, handshake: handshakeResponse, options: options),
                    hostDescription: hostDescription,
                    selectedRemoteSocketPath: NSString(string: socketPath).standardizingPath,
                    selectedRemoteHostProcessIdentifier: validation.reusableDaemonStatus?.pid ??
                        handshakeResponse.hostIdentity?.processIdentifier,
                    snapshotInvalidationRemoteSocketPaths: snapshotInvalidationRemoteSocketPaths,
                    applicationRelaunchAllowed: BridgeCapabilityPolicy.supportsApplicationRelaunch(
                        for: handshakeResponse
                    ),
                    requiredHostFailure: nil
                )
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                continue
            }
        }
        try Task.checkCancellation()
        return nil
    }

    static func validateRemoteCandidate(
        _ candidate: ImplicitRemoteCandidate,
        handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions,
        requiredProtocolVersion: PeekabooBridgeProtocolVersion? = nil,
        fetchReusableDaemonStatus: (String) async -> PeekabooDaemonStatus? = { socketPath in
            await DaemonControlClient(socketPath: socketPath).fetchReusableDaemonStatus()
        }
    ) async -> RemoteCandidateValidation? {
        await self.evaluateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: options,
            requiredProtocolVersion: requiredProtocolVersion,
            fetchReusableDaemonStatus: fetchReusableDaemonStatus
        ).validation
    }

    static func remoteServices(
        client: PeekabooBridgeClient,
        handshake: PeekabooBridgeHandshakeResponse,
        options: CommandRuntimeOptions
    ) -> RemotePeekabooServices {
        let targetedHotkey = BridgeCapabilityPolicy.targetedHotkeyAvailability(for: handshake)
        let targetedType = BridgeCapabilityPolicy.targetedTypeAvailability(for: handshake)
        let targetedClick = BridgeCapabilityPolicy.targetedClickAvailability(for: handshake)
        let supportsExactKeyboard = BridgeCapabilityPolicy.supportsExactWindowTargetedKeyboard(for: handshake)
        let observationCapabilities = BridgeCapabilityPolicy.observationCapabilities(
            for: handshake,
            options: options
        )
        return RemotePeekabooServices(
            client: client,
            supportsTargetedHotkeys: targetedHotkey.isEnabled,
            supportsProcessGenerationPinnedHotkeys:
            BridgeCapabilityPolicy.supportsProcessGenerationPinnedHotkeys(for: handshake),
            targetedHotkeyUnavailableReason: targetedHotkey.unavailableReason,
            targetedHotkeyRequiresEventSynthesizingPermission: targetedHotkey.missingPermissions.contains(.postEvent),
            supportsTargetedTypeActions: targetedType.isEnabled,
            supportsProcessGenerationPinnedInteractions: handshake.negotiatedVersion >=
                PeekabooBridgeConstants.processGenerationPinnedInteractionVersion,
            targetedTypeUnavailableReason: targetedType.unavailableReason,
            targetedTypeRequiresEventSynthesizingPermission: targetedType.missingPermissions.contains(.postEvent),
            supportsTargetedClicks: targetedClick.isEnabled,
            supportsStatelessClickVariants: BridgeCapabilityPolicy.supportsStatelessClickVariants(for: handshake),
            targetedClickUnavailableReason: targetedClick.unavailableReason,
            targetedClickRequiresEventSynthesizingPermission: targetedClick.missingPermissions.contains(.postEvent),
            supportsExactWindowTargetedClicks: BridgeCapabilityPolicy.supportsExactWindowTargetedClicks(for: handshake),
            supportsBackgroundWindowClose: BridgeCapabilityPolicy.supportsOperation(
                .backgroundCloseWindow,
                for: handshake
            ),
            supportsPinnedWindowMutations: BridgeCapabilityPolicy.supportsPinnedWindowMutations(for: handshake),
            supportsWindowRestore: BridgeCapabilityPolicy.supportsOperation(.restoreWindow, for: handshake),
            dialogCapabilities: Self.remoteDialogCapabilities(for: handshake),
            supportsTargetedScroll: BridgeCapabilityPolicy.supportsTargetedScroll(for: handshake),
            supportsInspectAccessibilityTree: BridgeCapabilityPolicy.supportsInspectAccessibilityTree(for: handshake),
            supportsExactWindowTargetedKeyboard: supportsExactKeyboard,
            exactWindowTargetedKeyboardUnavailableReason: supportsExactKeyboard
                ? nil
                : "Bridge host lacks atomic exact-window keyboard delivery",
            supportsExactWindowHeldPointerLifecycle:
            BridgeCapabilityPolicy.supportsExactWindowHeldPointerLifecycle(for: handshake),
            supportsPostEventPermissionRequest: BridgeCapabilityPolicy.supportsPostEventPermissionRequest(
                for: handshake
            ),
            supportsElementActions: BridgeCapabilityPolicy.supportsElementActions(for: handshake),
            supportsDesktopObservation: observationCapabilities.desktopObservation,
            supportsDesktopObservationOCR: observationCapabilities.desktopObservationOCR,
            supportsDesktopObservationCaptureEngine: observationCapabilities.desktopObservationCaptureEngine,
            supportsExactWindowROIObservation: observationCapabilities.exactWindowROIObservation,
            supportsImplicitLatestSnapshotInvalidation: BridgeCapabilityPolicy.supportsImplicitSnapshotInvalidation(
                for: handshake
            ),
            supportsSnapshotMutationLeases: BridgeCapabilityPolicy.supportsSnapshotMutationLeases(for: handshake),
            supportsExplicitSnapshotPublication: BridgeCapabilityPolicy.supportsExplicitSnapshotPublication(
                for: handshake
            ),
            supportsApplicationLaunchOptions: BridgeCapabilityPolicy.supportsApplicationLaunchOptions(for: handshake),
            supportsSafeBackgroundApplicationLaunchNoOp:
            BridgeCapabilityPolicy.supportsSafeBackgroundApplicationLaunchNoOp(for: handshake),
            supportsNewApplicationInstanceLaunch: BridgeCapabilityPolicy.supportsNewApplicationInstanceLaunch(
                for: handshake
            ),
            supportsApplicationWindowReadiness: BridgeCapabilityPolicy.supportsApplicationWindowReadiness(
                for: handshake
            ),
            supportsApplicationRelaunch: BridgeCapabilityPolicy.supportsApplicationRelaunch(for: handshake),
            supportsProcessGenerationPinnedApplicationQuit:
            BridgeCapabilityPolicy.supportsProcessGenerationPinnedApplicationQuit(for: handshake),
            supportsProcessGenerationPinnedApplicationActivation:
            BridgeCapabilityPolicy.supportsProcessGenerationPinnedApplicationActivation(for: handshake),
            supportsProcessGenerationPinnedApplicationHide:
            BridgeCapabilityPolicy.supportsProcessGenerationPinnedApplicationHide(for: handshake),
            allowLocalApplicationFallback: handshake.hostKind == .onDemand,
            desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
        )
    }

    private static func remoteHostDescription(
        handshake: PeekabooBridgeHandshakeResponse,
        socketPath: String
    ) -> String {
        "remote \(handshake.hostKind.rawValue) via \(socketPath)" +
            (handshake.build.map { " (build \($0))" } ?? "")
    }
}

private func explicitSnapshotPublicationFailure(
    explicitSocket: String?,
    options: CommandRuntimeOptions
) -> String? {
    guard explicitSocket != nil, options.requiresExplicitSnapshotPublication else { return nil }
    return "The explicitly selected Bridge host cannot publish an explicit-reference-only coordinate " +
        "receipt; protocol 1.26 is required. Update and relaunch Peekaboo on that host, or remove " +
        "--bridge-socket so Peekaboo can select a current host."
}
