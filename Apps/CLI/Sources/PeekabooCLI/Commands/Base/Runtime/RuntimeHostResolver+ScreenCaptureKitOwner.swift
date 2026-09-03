import AppKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

@MainActor
extension RuntimeHostResolver {
    static func explicitCaptureHandshakeCache(
        options: CommandRuntimeOptions,
        environment: [String: String],
        dependencies: Dependencies
    ) async throws -> RemoteHandshakeCache? {
        guard options.requiresScreenCaptureKitOwnerCapability,
              !options.usesPerToolSnapshotInvalidation,
              options.requiresScreenCapturePermission || options.requiresSilentCapture,
              !self.remoteIsolationRequested(options: options, environment: environment),
              let socket = BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment)
        else { return nil }
        let cache = dependencies.makeRemoteHandshakeCache()
        try await self.validateExplicitCaptureReadiness(
            socketPath: socket, options: options, environment: environment, cache: cache
        )
        return cache
    }

    static func validateExplicitCaptureReadiness(
        socketPath: String,
        options: CommandRuntimeOptions,
        environment: [String: String],
        cache: RemoteHandshakeCache
    ) async throws {
        let candidate = ImplicitRemoteCandidate(
            socketPath: socketPath,
            requireReusableDaemon: false,
            requiredHostKind: nil,
            requiresValidatedHistoricalDaemon: false
        )
        let response: PeekabooBridgeHandshakeResponse
        do {
            response = try await cache.handshake(candidate, identity: cache.identity).response
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return
        }
        guard self.captureEnginePreferenceForOwnership(options: options, environment: environment) != .legacy,
              let diagnostic = BridgeCapabilityPolicy.screenCaptureKitReadinessRefusal(for: response)
        else { return }
        throw self.readinessRefusal(diagnostic, handshake: response, socketPath: socketPath)
    }

    static func readinessRefusal(
        _ diagnostic: ScreenCaptureKitOwnershipDiagnostic,
        handshake: PeekabooBridgeHandshakeResponse,
        socketPath: String
    ) -> PreDispatchActionError {
        let identified = diagnostic.selectingHost(.init(
            processIdentifier: handshake.hostIdentity?.processIdentifier,
            processStartIdentity: handshake.hostIdentity?.processStartIdentity,
            socketPath: socketPath,
            buildIdentity: self.safeDiagnosticBuildIdentity(handshake.build),
            codeSignatureHash: handshake.hostIdentity?.codeSignatureHash
        ))
        let hint = BridgeCapabilityPolicy.supportsClassicCaptureWithoutScreenCaptureKit(for: handshake)
            ? "Explicit --capture-engine classic can use this same socket without in-process ScreenCaptureKit."
            : "This host has not proven a classic capture path without in-process ScreenCaptureKit."
        return PreDispatchActionError(
            message: identified.userMessage,
            code: .CAPTURE_FAILED,
            hint: hint,
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: identified
        )
    }

    typealias LocalServiceFactory = @MainActor (CommandRuntimeOptions) -> any PeekabooServiceProviding
    typealias RemoteServiceFactory = @MainActor (
        PeekabooBridgeClient, PeekabooBridgeHandshakeResponse, CommandRuntimeOptions
    ) -> any PeekabooServiceProviding
    typealias ScreenCaptureKitOwnerClaim = () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt
    typealias ScreenCaptureKitOwnerInspector = () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt?
    typealias RemoteCandidatePlanner = @MainActor (
        _ options: CommandRuntimeOptions,
        _ environment: [String: String]
    ) async throws -> RemoteCandidatePlan
    typealias ScreenCaptureKitSafetyInspector = @MainActor @Sendable (
        _ options: CommandRuntimeOptions,
        _ environment: [String: String],
        _ candidates: [ImplicitRemoteCandidate]?,
        _ handshakeCache: RemoteHandshakeCache
    ) async throws -> ScreenCaptureKitOwnerUnawareHost?
    typealias ScreenCaptureKitSafetyRecorder = @MainActor (ScreenCaptureKitOwnerUnawareHost) -> Void
    typealias ScreenCaptureKitHandshake = @MainActor @Sendable (
        ImplicitRemoteCandidate,
        PeekabooBridgeClientIdentity
    ) async throws -> PeekabooBridgeHandshakeResponse
    typealias ScreenCaptureKitExternalHostInspector = @MainActor @Sendable (String) ->
        ScreenCaptureKitExternalHostPresence
    typealias RemoteHandshakeCacheFactory = @MainActor () -> RemoteHandshakeCache

    struct Dependencies {
        let makeLocalServices: LocalServiceFactory
        let claimScreenCaptureKitOwner: ScreenCaptureKitOwnerClaim
        let inspectScreenCaptureKitOwner: ScreenCaptureKitOwnerInspector
        let inspectScreenCaptureKitSafety: ScreenCaptureKitSafetyInspector
        let recordScreenCaptureKitSafetyBlocker: ScreenCaptureKitSafetyRecorder
        let remoteCandidatePlan: RemoteCandidatePlanner
        let snapshotAffinityProbe: SnapshotAffinityProbe
        let makeRemoteHandshakeCache: RemoteHandshakeCacheFactory
        let makeRemoteServices: RemoteServiceFactory

        init(
            makeLocalServices: @escaping LocalServiceFactory,
            claimScreenCaptureKitOwner: @escaping ScreenCaptureKitOwnerClaim,
            inspectScreenCaptureKitOwner: @escaping ScreenCaptureKitOwnerInspector,
            inspectScreenCaptureKitSafety: @escaping ScreenCaptureKitSafetyInspector = { _, _, _, _ in nil },
            recordScreenCaptureKitSafetyBlocker: @escaping ScreenCaptureKitSafetyRecorder = { _ in },
            remoteCandidatePlan: @escaping RemoteCandidatePlanner = RuntimeHostResolver.remoteCandidatePlan,
            snapshotAffinityProbe: @escaping SnapshotAffinityProbe = RuntimeHostResolver.liveSnapshotAffinityProbe,
            makeRemoteHandshakeCache: @escaping RemoteHandshakeCacheFactory = { RemoteHandshakeCache() },
            makeRemoteServices: @escaping RemoteServiceFactory = {
                RuntimeHostResolver.remoteServices(client: $0, handshake: $1, options: $2)
            }
        ) {
            self.makeLocalServices = makeLocalServices
            self.claimScreenCaptureKitOwner = claimScreenCaptureKitOwner
            self.inspectScreenCaptureKitOwner = inspectScreenCaptureKitOwner
            self.inspectScreenCaptureKitSafety = inspectScreenCaptureKitSafety
            self.recordScreenCaptureKitSafetyBlocker = recordScreenCaptureKitSafetyBlocker
            self.remoteCandidatePlan = remoteCandidatePlan
            self.snapshotAffinityProbe = snapshotAffinityProbe
            self.makeRemoteHandshakeCache = makeRemoteHandshakeCache
            self.makeRemoteServices = makeRemoteServices
        }

        static let live = Dependencies(
            makeLocalServices: RuntimeServiceFactory.makeLocalServices,
            claimScreenCaptureKitOwner: { try ScreenCaptureKitOwnerLease().claim().receipt },
            inspectScreenCaptureKitOwner: { try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld() },
            inspectScreenCaptureKitSafety: { options, environment, candidates, handshakeCache in
                let resolvedCandidates: [ImplicitRemoteCandidate]
                if let suppliedCandidates = candidates {
                    resolvedCandidates = suppliedCandidates
                } else {
                    let plan = try await RuntimeHostResolver.remoteCandidatePlan(
                        options: options,
                        environment: environment
                    )
                    resolvedCandidates = RuntimeHostResolver.screenCaptureKitSafetyCandidates(
                        from: plan,
                        options: options
                    )
                }
                return try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                    candidates: resolvedCandidates,
                    identity: handshakeCache.identity,
                    handshakeCache: handshakeCache
                )
            },
            recordScreenCaptureKitSafetyBlocker: { host in
                ScreenCaptureKitOwnerLease.registerPotentialUncoordinatedHost(
                    socketPath: host.socketPath,
                    processIdentifier: host.processIdentifier,
                    processStartIdentity: host.processStartIdentity,
                    buildIdentity: host.buildIdentity
                )
            }
        )
    }

    struct RemoteResolutionContext {
        let options: CommandRuntimeOptions
        let environment: [String: String]
        let candidatePlan: RemoteCandidatePlan
        let identity: PeekabooBridgeClientIdentity
        let handshakeCache: RemoteHandshakeCache
        let snapshotInvalidationRemoteSocketPaths: [String]
        let preferredScreenCaptureKitOwner: ScreenCaptureKitOwnerLease.OwnerReceipt?
        let makeLocalServices: LocalServiceFactory
        let inspectScreenCaptureKitSafety: ScreenCaptureKitSafetyInspector
        let recordScreenCaptureKitSafetyBlocker: ScreenCaptureKitSafetyRecorder
        var makeRemoteServices: RemoteServiceFactory = {
            RuntimeHostResolver.remoteServices(client: $0, handshake: $1, options: $2)
        }

        func resolveRemoteServices(
            candidates: [ImplicitRemoteCandidate],
            requiredProtocolVersion: PeekabooBridgeProtocolVersion? = nil,
            requiredOwner: ScreenCaptureKitOwnerLease.OwnerReceipt? = nil,
            permissionRejections: inout [String]
        ) async throws -> Resolution? {
            try await RuntimeHostResolver.resolveRemoteServices(
                candidates: candidates,
                identity: self.identity,
                options: self.options,
                requiredProtocolVersion: requiredProtocolVersion,
                requiredOwner: requiredOwner,
                snapshotInvalidationRemoteSocketPaths: self.snapshotInvalidationRemoteSocketPaths,
                permissionRejections: &permissionRejections,
                makeRemoteServices: self.makeRemoteServices,
                handshakeCache: self.handshakeCache
            )
        }
    }

    struct ScreenCaptureKitOwnerUnawareHost: Equatable {
        let socketPath: String
        let processIdentifier: pid_t?
        let processStartIdentity: UInt64?
        let buildIdentity: String?

        init(
            socketPath: String,
            processIdentifier: pid_t?,
            processStartIdentity: UInt64?,
            buildIdentity: String? = nil
        ) {
            self.socketPath = socketPath
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.buildIdentity = buildIdentity
        }
    }

    enum ScreenCaptureKitExternalHostPresence: Equatable {
        case absent
        case present(
            processIdentifier: pid_t?,
            processStartIdentity: UInt64?,
            buildIdentity: String?
        )

        var identity: (
            processIdentifier: pid_t?,
            processStartIdentity: UInt64?,
            buildIdentity: String?
        )? {
            switch self {
            case .absent:
                nil
            case let .present(processIdentifier, processStartIdentity, buildIdentity):
                (processIdentifier, processStartIdentity, buildIdentity)
            }
        }
    }

    struct ScreenCaptureKitExternalApplication: Equatable {
        let bundleIdentifier: String?
        let bundleName: String?
        let localizedName: String?
        let processIdentifier: pid_t
        let isTerminated: Bool
        let buildIdentity: String?
    }

    enum ScreenCaptureKitSafetyDisposition {
        case refuse
        case deferLocalRuntime
        case deferToolCapture
        case routeAutomaticCapture
    }

    static func requiresCallerLocalModernOwnerClaim(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        self.remoteIsolationRequested(options: options, environment: environment) &&
            options.requiresScreenCapturePermission &&
            self.captureEnginePreferenceForOwnership(options: options, environment: environment) == .modern
    }

    static func requiresCallerLocalScreenCaptureKitSafetyCheck(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        if options.usesPerToolSnapshotInvalidation {
            // Dynamic capture-capable tools can issue request-local auto/modern capture regardless
            // of startup preference. An explicit environment allow-list may prove none are exposed.
            return options.dynamicToolScreenCaptureReachable
        }
        return (options.requiresScreenCapturePermission || options.requiresSilentCapture) &&
            self.captureEnginePreferenceForOwnership(options: options, environment: environment) != .legacy
    }

    static func shouldPreferScreenCaptureKitOwnerHost(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        guard !self.remoteIsolationRequested(options: options, environment: environment) else { return false }
        if options.usesPerToolSnapshotInvalidation {
            return options.dynamicToolScreenCaptureReachable
        }
        let preference = self.captureEnginePreferenceForOwnership(options: options, environment: environment)
        return options.requiresScreenCapturePermission &&
            options.transportsCaptureEnginePreference &&
            preference != .legacy
    }

    static func canRouteAutomaticCaptureAroundAuxiliaryOwnerUnawareHost(
        _ host: ScreenCaptureKitOwnerUnawareHost,
        plan: RemoteCandidatePlan,
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        guard self.captureEnginePreferenceForOwnership(options: options, environment: environment) == .auto,
              options.requiresScreenCapturePermission,
              options.transportsCaptureEnginePreference,
              options.requiresScreenCaptureKitOwnerCapability
        else {
            return false
        }

        let hostPath = NSString(string: host.socketPath).standardizingPath
        return !plan.candidates.contains {
            NSString(string: $0.socketPath).standardizingPath == hostPath
        }
    }

    static func screenCaptureKitSafetyDisposition(
        for host: ScreenCaptureKitOwnerUnawareHost,
        plan: RemoteCandidatePlan,
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> ScreenCaptureKitSafetyDisposition {
        if options.usesPerToolSnapshotInvalidation,
           options.dynamicToolScreenCaptureReachable,
           !options.requiresScreenCapturePermission {
            return plan.explicitSocket == nil ? .deferLocalRuntime : .deferToolCapture
        }
        if self.canRouteAutomaticCaptureAroundAuxiliaryOwnerUnawareHost(
            host,
            plan: plan,
            options: options,
            environment: environment
        ) {
            return .routeAutomaticCapture
        }
        return .refuse
    }

    static func screenCaptureKitHostMatchesOwner(
        handshake: PeekabooBridgeHandshakeResponse,
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt
    ) -> Bool {
        let capabilities = handshake.hostCapabilities ?? []
        guard BridgeCapabilityPolicy.supportsScreenCaptureKitProcessOwnership(for: handshake),
              capabilities.contains(PeekabooBridgeHostCapability.hostGenerationIdentity),
              let hostIdentity = handshake.hostIdentity,
              hostIdentity.processIdentifier == owner.processIdentifier,
              hostIdentity.processStartIdentity == owner.processStartIdentity
        else {
            return false
        }
        if let codeSignatureHash = owner.codeSignatureHash {
            return capabilities.contains(PeekabooBridgeHostCapability.codeSignatureBuildIdentity) &&
                hostIdentity.codeSignatureHash == codeSignatureHash
        }
        return true
    }

    static func screenCaptureKitOwnerIsCurrentProcess(
        _ owner: ScreenCaptureKitOwnerLease.OwnerReceipt
    ) -> Bool {
        owner.processIdentifier == getpid() &&
            SystemIdentityResolver.processStartIdentity(getpid()) == owner.processStartIdentity
    }

    static func screenCaptureKitOwnerCandidates(
        from runtimeCandidates: [ImplicitRemoteCandidate]
    ) -> [ImplicitRemoteCandidate] {
        var candidates = runtimeCandidates
        var seen = Set(runtimeCandidates.map { NSString(string: $0.socketPath).standardizingPath })
        for socketPath in [
            PeekabooBridgeConstants.peekabooSocketPath,
            PeekabooBridgeConstants.claudeSocketPath,
            PeekabooBridgeConstants.clawdbotSocketPath,
        ] {
            let standardized = NSString(string: socketPath).standardizingPath
            guard seen.insert(standardized).inserted else { continue }
            candidates.append(ImplicitRemoteCandidate(
                socketPath: socketPath,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            ))
        }
        return candidates
    }

    static func screenCaptureKitSafetyCandidates(
        from plan: RemoteCandidatePlan,
        options: CommandRuntimeOptions
    ) -> [ImplicitRemoteCandidate] {
        var paths = plan.candidates.map(\.socketPath)
        if options.usesPersistentDynamicCaptureRuntime,
           plan.explicitSocket?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // Scope only caller-side socket discovery. The selected host must advertise process
            // ownership here, and every real SCK leaf then rescans all same-user potential Peekaboo
            // processes through ScreenCaptureKitOwnerLease before dispatch. Omitted sockets therefore
            // cannot contribute authority or escape the canonical process-level safety scan.
            return self.screenCaptureKitSafetyCandidates(paths: paths)
        }
        paths.append(plan.daemonSocketPath)
        if let buildScopedDaemonSocketPath = plan.buildScopedDaemonSocketPath {
            paths.append(buildScopedDaemonSocketPath)
        }
        paths.append(contentsOf: plan.historicalBuildScopedDaemonSocketPaths)
        paths.append(contentsOf: [
            PeekabooBridgeConstants.peekabooSocketPath,
            PeekabooBridgeConstants.claudeSocketPath,
            PeekabooBridgeConstants.clawdbotSocketPath,
        ])

        return self.screenCaptureKitSafetyCandidates(paths: paths)
    }

    private static func screenCaptureKitSafetyCandidates(
        paths: [String]
    ) -> [ImplicitRemoteCandidate] {
        var seen = Set<String>()
        return paths.compactMap { path in
            let standardized = NSString(string: path).standardizingPath
            guard !standardized.isEmpty, seen.insert(standardized).inserted else { return nil }
            return ImplicitRemoteCandidate(
                socketPath: standardized,
                requireReusableDaemon: false,
                requiredHostKind: nil,
                requiresValidatedHistoricalDaemon: false
            )
        }
    }

    static func ownerRefusal(
        error: any Error,
        callerLocal: Bool,
        selectedSocket: String? = nil
    ) -> PreDispatchActionError {
        var diagnostic = ScreenCaptureKitOwnershipDiagnostic.capturing(error, stage: .admission)
        if let selectedSocket {
            diagnostic = diagnostic.selectingHost(.init(socketPath: selectedSocket))
        }
        let route = selectedSocket.map { "Selected socket: \($0). " }
            ?? (callerLocal ? "Selected route: caller-local. " : "Selected socket: automatic resolution. ")
        return PreDispatchActionError(
            message: route + diagnostic.userMessage,
            code: .CAPTURE_FAILED,
            hint: "Use a host that proves the required capture contract and satisfies process ownership.",
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: diagnostic
        )
    }

    static func ownerCapabilityRefusal(
        host: ScreenCaptureKitOwnerUnawareHost,
        selectedSocket: String?
    ) -> PreDispatchActionError {
        let ownerSocket = NSString(string: host.socketPath).standardizingPath
        let selectedSocketText = selectedSocket ?? "automatic resolution"
        let evidence = ScreenCaptureKitOwnershipDiagnostic.ProcessEvidence(
            processIdentifier: host.processIdentifier,
            processStartIdentity: host.processStartIdentity,
            socketPath: ownerSocket,
            buildIdentity: self.safeDiagnosticBuildIdentity(host.buildIdentity)
        )
        let diagnostic = ScreenCaptureKitOwnershipDiagnostic(
            kind: .uncoordinatedHosts,
            stage: .admission,
            message: "Safe ScreenCaptureKit ownership support cannot be proven for the Bridge host at " +
                "owner socket \(ownerSocket). Selected socket: \(selectedSocketText). No capture was dispatched.",
            blockers: [evidence]
        )
        return PreDispatchActionError(
            message: diagnostic.userMessage,
            code: .CAPTURE_FAILED,
            hint: "Use a host that proves the required capture contract. Classic capture on this unproven " +
                "socket cannot be assumed safe.",
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: diagnostic
        )
    }

    static func dynamicToolCapturePreflightRefusal(
        host: ScreenCaptureKitOwnerUnawareHost,
        selectedSocket: String?
    ) -> MCPToolCapturePreflightRefusal {
        let refusal = self.ownerCapabilityRefusal(host: host, selectedSocket: selectedSocket)
        let sessionGuidance = "This capture refusal is fixed for the lifetime of this MCP or Agent session. " +
            "Noncapture tools remain available; classic capture still requires proof from the selected host."
        return MCPToolCapturePreflightRefusal(
            message: refusal.localizedDescription,
            hint: [refusal.hint, sessionGuidance].compactMap(\.self).joined(separator: " ")
        )
    }

    static func firstScreenCaptureKitOwnerUnawareHost(
        candidates: [ImplicitRemoteCandidate],
        identity: PeekabooBridgeClientIdentity,
        handshakeCache: RemoteHandshakeCache? = nil,
        handshake: ScreenCaptureKitHandshake? = nil,
        externalHostPresence: @escaping ScreenCaptureKitExternalHostInspector = {
            RuntimeHostResolver.knownExternalHostPresence(socketPath: $0)
        }
    ) async throws -> ScreenCaptureKitOwnerUnawareHost? {
        for candidate in candidates {
            try Task.checkCancellation()
            let response: PeekabooBridgeHandshakeResponse
            do {
                if let handshake {
                    response = try await handshake(candidate, identity)
                } else if let handshakeCache {
                    response = try await handshakeCache.handshake(candidate, identity: identity).response
                } else {
                    response = try await PeekabooBridgeClient(socketPath: candidate.socketPath)
                        .handshake(client: identity, requestedHost: nil)
                }
                try Task.checkCancellation()
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let presence = externalHostPresence(candidate.socketPath)
                if self.isDefinitiveScreenCaptureKitSocketAbsence(error),
                   presence == .absent {
                    continue
                }
                let knownIdentity = presence.identity
                return ScreenCaptureKitOwnerUnawareHost(
                    socketPath: candidate.socketPath,
                    processIdentifier: knownIdentity?.processIdentifier,
                    processStartIdentity: knownIdentity?.processStartIdentity,
                    buildIdentity: knownIdentity?.buildIdentity
                )
            }
            guard !BridgeCapabilityPolicy.supportsScreenCaptureKitProcessOwnership(for: response),
                  response.supportedOperations.contains(.captureScreen) ||
                  response.supportedOperations.contains(.desktopObservation)
            else {
                continue
            }
            let externalIdentity = externalHostPresence(candidate.socketPath).identity
            let handshakeProcessIdentifier = response.hostIdentity?.processIdentifier
            let processIdentifier = handshakeProcessIdentifier ?? externalIdentity?.processIdentifier
            let externalIdentityMatches = handshakeProcessIdentifier == nil ||
                handshakeProcessIdentifier == externalIdentity?.processIdentifier
            let processStartIdentity = response.hostIdentity?.processStartIdentity ?? {
                guard externalIdentityMatches else { return nil }
                return externalIdentity?.processStartIdentity
            }()
            return ScreenCaptureKitOwnerUnawareHost(
                socketPath: candidate.socketPath,
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                buildIdentity: response.build ?? (externalIdentityMatches ? externalIdentity?.buildIdentity : nil)
            )
        }
        return nil
    }

    private static func isDefinitiveScreenCaptureKitSocketAbsence(_ error: any Error) -> Bool {
        if let error = error as? POSIXError {
            return error.code == .ENOENT || error.code == .ECONNREFUSED || error.code == .ENAMETOOLONG
        }
        let error = error as NSError
        guard error.domain == NSPOSIXErrorDomain,
              let rawCode = Int32(exactly: error.code),
              let code = POSIXErrorCode(rawValue: rawCode)
        else { return false }
        return code == .ENOENT || code == .ECONNREFUSED || code == .ENAMETOOLONG
    }

    private static func knownExternalHostPresence(socketPath: String) -> ScreenCaptureKitExternalHostPresence {
        let applications = NSWorkspace.shared.runningApplications.map { application in
            ScreenCaptureKitExternalApplication(
                bundleIdentifier: application.bundleIdentifier,
                bundleName: application.bundleURL?.deletingPathExtension().lastPathComponent,
                localizedName: application.localizedName,
                processIdentifier: application.processIdentifier,
                isTerminated: application.isTerminated,
                buildIdentity: self.externalHostBuildIdentity(application)
            )
        }
        return self.knownExternalHostPresence(
            socketPath: socketPath,
            applications: applications,
            processStartIdentity: SystemIdentityResolver.processStartIdentity
        )
    }

    static func knownExternalHostPresence(
        socketPath: String,
        applications: [ScreenCaptureKitExternalApplication],
        processStartIdentity: (pid_t) -> UInt64?
    ) -> ScreenCaptureKitExternalHostPresence {
        let standardizedPath = NSString(string: socketPath).standardizingPath
        let identityFragments: [String]
        let exactBundleIdentifiers: Set<String>
        if standardizedPath == NSString(string: PeekabooBridgeConstants.claudeSocketPath).standardizingPath {
            identityFragments = ["anthropic.claude", "claude"]
            exactBundleIdentifiers = ["com.anthropic.claudefordesktop"]
        } else if standardizedPath == NSString(string: PeekabooBridgeConstants.clawdbotSocketPath).standardizingPath {
            identityFragments = ["clawdbot", "openclaw"]
            exactBundleIdentifiers = [
                "com.clawdis.mac",
                "com.clawdis.mac.debug",
                "com.clawdbot.mac",
                "com.clawdbot.mac.debug",
                "bot.molt.mac",
                "bot.molt.mac.debug",
                "ai.openclaw.mac",
                "ai.openclaw.mac.debug",
            ]
        } else {
            return .absent
        }

        let broadMatches = applications.filter { application in
            let values = [
                application.bundleIdentifier?.lowercased(),
                application.bundleName?.lowercased(),
                application.localizedName?.lowercased(),
            ].compactMap(\.self)
            return identityFragments.contains { fragment in values.contains(where: { $0.contains(fragment) }) }
        }
        guard !broadMatches.isEmpty else { return .absent }

        let exactMatches = applications.filter { application in
            guard let bundleIdentifier = application.bundleIdentifier?.lowercased() else { return false }
            return exactBundleIdentifiers.contains(bundleIdentifier)
        }
        guard exactMatches.count == 1,
              let application = exactMatches.first,
              !application.isTerminated,
              application.processIdentifier > 0
        else {
            return .present(processIdentifier: nil, processStartIdentity: nil, buildIdentity: nil)
        }

        let processIdentifier = application.processIdentifier
        guard let firstGeneration = processStartIdentity(processIdentifier),
              !application.isTerminated,
              processStartIdentity(processIdentifier) == firstGeneration
        else {
            return .present(processIdentifier: nil, processStartIdentity: nil, buildIdentity: nil)
        }
        return .present(
            processIdentifier: processIdentifier,
            processStartIdentity: firstGeneration,
            buildIdentity: application.buildIdentity
        )
    }

    private static func externalHostBuildIdentity(_ application: NSRunningApplication) -> String? {
        guard let bundleURL = application.bundleURL,
              let information = Bundle(url: bundleURL)?.infoDictionary
        else { return nil }
        let shortVersion = information["CFBundleShortVersionString"] as? String
        let buildVersion = information["CFBundleVersion"] as? String
        switch (shortVersion, buildVersion) {
        case let (shortVersion?, buildVersion?) where shortVersion != buildVersion:
            return "\(shortVersion) (\(buildVersion))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildVersion?):
            return buildVersion
        default:
            return nil
        }
    }

    static func ownerRefusal(
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt,
        callerLocal: Bool
    ) -> PreDispatchActionError {
        let ownerText = self.ownerDescription(owner)
        let message = if callerLocal {
            "Caller-local ScreenCaptureKit is already owned by another Peekaboo process (\(ownerText)). " +
                "Selected route: caller-local; owner socket: unavailable in the process ownership receipt. " +
                "No capture was dispatched."
        } else {
            "ScreenCaptureKit is owned by another Peekaboo process (\(ownerText)), but no compatible " +
                "Bridge host for that exact process generation is available. Selected socket: automatic " +
                "resolution; owner socket: unavailable in the process ownership receipt. No capture was dispatched."
        }
        let hint = "Use a Bridge socket served by exactly \(ownerText) with the required capture contract."
        return PreDispatchActionError(
            message: message,
            code: .CAPTURE_FAILED,
            hint: hint,
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: self.ownerDiagnostic(owner)
        )
    }

    static func ownerRefusal(
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt,
        explicitSocket: String
    ) -> PreDispatchActionError {
        let ownerText = self.ownerDescription(owner)
        let selectedSocket = NSString(string: explicitSocket).standardizingPath
        return PreDispatchActionError(
            message: "Selected socket: \(selectedSocket). The ScreenCaptureKit owner is \(ownerText), but its " +
                "owner socket is unavailable in the process ownership receipt. No capture was dispatched.",
            code: .CAPTURE_FAILED,
            hint: "Change or remove --bridge-socket to select the exact owner host with the required capture contract.",
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: self.ownerDiagnostic(owner)
        )
    }

    static func ownerExactBuildConflict(
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt,
        requiredSocket: String
    ) -> PreDispatchActionError {
        let ownerText = self.ownerDescription(owner)
        let selectedSocket = NSString(string: requiredSocket).standardizingPath
        return PreDispatchActionError(
            message: "ScreenCaptureKit owner \(ownerText) does not serve selected socket \(selectedSocket); " +
                "the owner socket is unavailable in the process ownership receipt. No capture was dispatched.",
            code: .CAPTURE_FAILED,
            hint: "The selected socket must match the owner generation and required build for this stateful request.",
            reason: .runtimeIncompatible,
            screenCaptureKitOwnershipDiagnostic: self.ownerDiagnostic(owner)
        )
    }

    private static func ownerDiagnostic(
        _ owner: ScreenCaptureKitOwnerLease.OwnerReceipt
    ) -> ScreenCaptureKitOwnershipDiagnostic {
        .init(
            kind: .ownedByAnotherProcess,
            stage: .admission,
            message: "The required ScreenCaptureKit owner host is unavailable for this route.",
            blockers: [.init(
                processIdentifier: owner.processIdentifier,
                processStartIdentity: owner.processStartIdentity,
                buildIdentity: self.safeDiagnosticBuildIdentity(owner.buildIdentity),
                codeSignatureHash: self.safeDiagnosticBuildIdentity(owner.codeSignatureHash)
            )]
        )
    }

    private static func ownerDescription(_ owner: ScreenCaptureKitOwnerLease.OwnerReceipt) -> String {
        let base = "PID \(owner.processIdentifier), generation \(owner.processStartIdentity)"
        if let buildIdentity = self.safeDiagnosticBuildIdentity(owner.buildIdentity) {
            return "\(base), build \(buildIdentity)"
        }
        if let codeSignatureHash = self.safeDiagnosticBuildIdentity(owner.codeSignatureHash) {
            return "\(base), build CDHash \(codeSignatureHash)"
        }
        return base
    }

    /// Build strings cross a process boundary. Keep useful version/hash evidence while refusing
    /// paths, control characters, shell metacharacters, and unbounded host-provided text.
    private static func safeDiagnosticBuildIdentity(_ rawValue: String?) -> String? {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 128
        else { return nil }
        let permittedPunctuation = Set(" ._:+-()[]".unicodeScalars.map(\.value))
        guard value.unicodeScalars.allSatisfy({ scalar in
            let codePoint = scalar.value
            return (codePoint >= 48 && codePoint <= 57) ||
                (codePoint >= 65 && codePoint <= 90) ||
                (codePoint >= 97 && codePoint <= 122) ||
                permittedPunctuation.contains(codePoint)
        }) else { return nil }
        return value
    }

    static func captureEnginePreferenceForOwnership(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> CaptureEnginePreference {
        ObservationCommandSupport.captureEnginePreference(
            cliValue: options.captureEnginePreference ?? CommandRuntimeOptions.captureEnginePreference(
                environment: environment
            ),
            configuredValue: nil
        )
    }
}
