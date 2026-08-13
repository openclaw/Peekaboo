import AppKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore

@MainActor
extension RuntimeHostResolver {
    typealias LocalServiceFactory = @MainActor (CommandRuntimeOptions) -> any PeekabooServiceProviding
    typealias ScreenCaptureKitOwnerClaim = () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt
    typealias ScreenCaptureKitOwnerInspector = () throws -> ScreenCaptureKitOwnerLease.OwnerReceipt?
    typealias RemoteCandidatePlanner = @MainActor (
        _ options: CommandRuntimeOptions,
        _ environment: [String: String]
    ) async -> RemoteCandidatePlan
    typealias ScreenCaptureKitSafetyInspector = @MainActor @Sendable (
        _ options: CommandRuntimeOptions,
        _ environment: [String: String],
        _ candidates: [ImplicitRemoteCandidate]?
    ) async throws -> ScreenCaptureKitOwnerUnawareHost?
    typealias ScreenCaptureKitSafetyRecorder = @MainActor (ScreenCaptureKitOwnerUnawareHost) -> Void
    typealias ScreenCaptureKitHandshake = @MainActor @Sendable (
        ImplicitRemoteCandidate,
        PeekabooBridgeClientIdentity
    ) async throws -> PeekabooBridgeHandshakeResponse
    typealias ScreenCaptureKitExternalHostInspector = @MainActor @Sendable (String) -> Bool

    struct Dependencies {
        let makeLocalServices: LocalServiceFactory
        let claimScreenCaptureKitOwner: ScreenCaptureKitOwnerClaim
        let inspectScreenCaptureKitOwner: ScreenCaptureKitOwnerInspector
        let inspectScreenCaptureKitSafety: ScreenCaptureKitSafetyInspector
        let recordScreenCaptureKitSafetyBlocker: ScreenCaptureKitSafetyRecorder
        let remoteCandidatePlan: RemoteCandidatePlanner

        init(
            makeLocalServices: @escaping LocalServiceFactory,
            claimScreenCaptureKitOwner: @escaping ScreenCaptureKitOwnerClaim,
            inspectScreenCaptureKitOwner: @escaping ScreenCaptureKitOwnerInspector,
            inspectScreenCaptureKitSafety: @escaping ScreenCaptureKitSafetyInspector = { _, _, _ in nil },
            recordScreenCaptureKitSafetyBlocker: @escaping ScreenCaptureKitSafetyRecorder = { _ in },
            remoteCandidatePlan: @escaping RemoteCandidatePlanner = RuntimeHostResolver.remoteCandidatePlan
        ) {
            self.makeLocalServices = makeLocalServices
            self.claimScreenCaptureKitOwner = claimScreenCaptureKitOwner
            self.inspectScreenCaptureKitOwner = inspectScreenCaptureKitOwner
            self.inspectScreenCaptureKitSafety = inspectScreenCaptureKitSafety
            self.recordScreenCaptureKitSafetyBlocker = recordScreenCaptureKitSafetyBlocker
            self.remoteCandidatePlan = remoteCandidatePlan
        }

        static let live = Dependencies(
            makeLocalServices: RuntimeServiceFactory.makeLocalServices,
            claimScreenCaptureKitOwner: { try ScreenCaptureKitOwnerLease().claim().receipt },
            inspectScreenCaptureKitOwner: { try ScreenCaptureKitOwnerLease.currentOwnerReceiptIfHeld() },
            inspectScreenCaptureKitSafety: { options, environment, candidates in
                let resolvedCandidates: [ImplicitRemoteCandidate]
                if let suppliedCandidates = candidates {
                    resolvedCandidates = suppliedCandidates
                } else {
                    let plan = await RuntimeHostResolver.remoteCandidatePlan(
                        options: options,
                        environment: environment
                    )
                    resolvedCandidates = RuntimeHostResolver.screenCaptureKitSafetyCandidates(from: plan)
                }
                return try await RuntimeHostResolver.firstScreenCaptureKitOwnerUnawareHost(
                    candidates: resolvedCandidates,
                    identity: PeekabooBridgeClientIdentity(
                        bundleIdentifier: Bundle.main.bundleIdentifier,
                        teamIdentifier: nil,
                        processIdentifier: getpid(),
                        hostname: Host.current().name
                    )
                )
            },
            recordScreenCaptureKitSafetyBlocker: { host in
                ScreenCaptureKitOwnerLease.registerPotentialUncoordinatedHost(
                    socketPath: host.socketPath,
                    processIdentifier: host.processIdentifier,
                    processStartIdentity: host.processStartIdentity
                )
            }
        )
    }

    struct RemoteResolutionContext {
        let options: CommandRuntimeOptions
        let environment: [String: String]
        let candidatePlan: RemoteCandidatePlan
        let identity: PeekabooBridgeClientIdentity
        let snapshotInvalidationRemoteSocketPaths: [String]
        let preferredScreenCaptureKitOwner: ScreenCaptureKitOwnerLease.OwnerReceipt?
        let makeLocalServices: LocalServiceFactory
        let inspectScreenCaptureKitSafety: ScreenCaptureKitSafetyInspector
        let recordScreenCaptureKitSafetyBlocker: ScreenCaptureKitSafetyRecorder
    }

    struct ScreenCaptureKitOwnerUnawareHost: Equatable {
        let socketPath: String
        let processIdentifier: pid_t?
        let processStartIdentity: UInt64?
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
            // Dynamic tools can issue request-local auto/modern capture regardless of the runtime's
            // startup preference, so even an ambient classic value cannot suppress old-host discovery.
            return true
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
            return true
        }
        let preference = self.captureEnginePreferenceForOwnership(options: options, environment: environment)
        return options.requiresScreenCapturePermission &&
            options.transportsCaptureEnginePreference &&
            preference != .legacy
    }

    static func screenCaptureKitHostMatchesOwner(
        handshake: PeekabooBridgeHandshakeResponse,
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt
    ) -> Bool {
        let capabilities = handshake.hostCapabilities ?? []
        guard capabilities.contains(PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership),
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
        from plan: RemoteCandidatePlan
    ) -> [ImplicitRemoteCandidate] {
        var paths = plan.candidates.map(\.socketPath)
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
        callerLocal: Bool
    ) -> PreDispatchActionError {
        if let leaseError = error as? ScreenCaptureKitOwnerLease.LeaseError,
           case let .ownedByAnotherProcess(_, receipt) = leaseError {
            return self.ownerRefusal(owner: receipt, callerLocal: callerLocal)
        }
        return PreDispatchActionError(
            message: "Peekaboo could not establish safe ScreenCaptureKit process ownership. No capture was dispatched.",
            code: .CAPTURE_FAILED,
            hint: error.localizedDescription,
            reason: .runtimeIncompatible
        )
    }

    static func ownerCapabilityRefusal(
        host: ScreenCaptureKitOwnerUnawareHost
    ) -> PreDispatchActionError {
        let identity = if let processIdentifier = host.processIdentifier,
                          let processStartIdentity = host.processStartIdentity {
            "PID \(processIdentifier), generation \(processStartIdentity)"
        } else if let processIdentifier = host.processIdentifier {
            "PID \(processIdentifier)"
        } else {
            "an unknown process generation"
        }
        return PreDispatchActionError(
            message: "Bridge host \(identity) via \(host.socketPath) predates safe process-lifetime " +
                "ScreenCaptureKit ownership. No capture was dispatched.",
            code: .CAPTURE_FAILED,
            hint: "Update and relaunch Peekaboo, or verify and stop that exact host before retrying. " +
                "Peekaboo will not start a second ScreenCaptureKit owner while it remains live.",
            reason: .runtimeIncompatible
        )
    }

    static func firstScreenCaptureKitOwnerUnawareHost(
        candidates: [ImplicitRemoteCandidate],
        identity: PeekabooBridgeClientIdentity,
        handshake: @escaping ScreenCaptureKitHandshake = { candidate, identity in
            try await PeekabooBridgeClient(socketPath: candidate.socketPath)
                .handshake(client: identity, requestedHost: nil)
        },
        externalHostIsRunning: @escaping ScreenCaptureKitExternalHostInspector = {
            RuntimeHostResolver.isKnownExternalHostProcessRunning(socketPath: $0)
        }
    ) async throws -> ScreenCaptureKitOwnerUnawareHost? {
        for candidate in candidates {
            try Task.checkCancellation()
            let response: PeekabooBridgeHandshakeResponse
            do {
                response = try await handshake(candidate, identity)
                try Task.checkCancellation()
            } catch let error as CancellationError {
                throw error
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                if self.isDefinitiveScreenCaptureKitSocketAbsence(error),
                   !externalHostIsRunning(candidate.socketPath) {
                    continue
                }
                return ScreenCaptureKitOwnerUnawareHost(
                    socketPath: candidate.socketPath,
                    processIdentifier: nil,
                    processStartIdentity: nil
                )
            }
            guard !BridgeCapabilityPolicy.supportsScreenCaptureKitProcessOwnership(for: response),
                  response.supportedOperations.contains(.captureScreen) ||
                  response.supportedOperations.contains(.desktopObservation)
            else {
                continue
            }
            return ScreenCaptureKitOwnerUnawareHost(
                socketPath: candidate.socketPath,
                processIdentifier: response.hostIdentity?.processIdentifier,
                processStartIdentity: response.hostIdentity?.processStartIdentity
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

    private static func isKnownExternalHostProcessRunning(socketPath: String) -> Bool {
        let standardizedPath = NSString(string: socketPath).standardizingPath
        let identityFragments: [String]
        if standardizedPath == NSString(string: PeekabooBridgeConstants.claudeSocketPath).standardizingPath {
            identityFragments = ["anthropic.claude", "claude"]
        } else if standardizedPath == NSString(string: PeekabooBridgeConstants.clawdbotSocketPath).standardizingPath {
            identityFragments = ["clawdbot", "openclaw"]
        } else {
            return false
        }

        return NSWorkspace.shared.runningApplications.contains { application in
            let values = [
                application.bundleIdentifier?.lowercased(),
                application.bundleURL?.deletingPathExtension().lastPathComponent.lowercased(),
                application.localizedName?.lowercased(),
            ].compactMap(\.self)
            return identityFragments.contains { fragment in values.contains(where: { $0.contains(fragment) }) }
        }
    }

    static func ownerRefusal(
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt,
        callerLocal: Bool
    ) -> PreDispatchActionError {
        let ownerText = "PID \(owner.processIdentifier), generation \(owner.processStartIdentity)"
        let message = if callerLocal {
            "Caller-local ScreenCaptureKit is already owned by another Peekaboo process (\(ownerText)). " +
                "No capture was dispatched."
        } else {
            "ScreenCaptureKit is owned by another Peekaboo process (\(ownerText)), but no compatible " +
                "Bridge host for that exact process generation is available. No capture was dispatched."
        }
        let hint = if callerLocal {
            "Retry without --no-remote to use the selected owner host; otherwise verify and stop exactly " +
                "\(ownerText), or explicitly choose --capture-engine classic."
        } else {
            "Use a Bridge socket served by exactly \(ownerText); otherwise verify and stop that exact owner, " +
                "or explicitly choose --capture-engine classic."
        }
        return PreDispatchActionError(
            message: message,
            code: .CAPTURE_FAILED,
            hint: hint,
            reason: .runtimeIncompatible
        )
    }

    static func ownerRefusal(
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt,
        explicitSocket: String
    ) -> PreDispatchActionError {
        let ownerText = "PID \(owner.processIdentifier), generation \(owner.processStartIdentity)"
        return PreDispatchActionError(
            message: "The explicitly selected Bridge socket \(explicitSocket) is not served by the " +
                "ScreenCaptureKit owner (\(ownerText)). No capture was dispatched.",
            code: .CAPTURE_FAILED,
            hint: "Change or remove --bridge-socket to select the exact owner host; otherwise verify and stop " +
                "\(ownerText), or explicitly choose --capture-engine classic.",
            reason: .runtimeIncompatible
        )
    }

    static func ownerExactBuildConflict(
        owner: ScreenCaptureKitOwnerLease.OwnerReceipt,
        requiredSocket: String
    ) -> PreDispatchActionError {
        let ownerText = "PID \(owner.processIdentifier), generation \(owner.processStartIdentity)"
        return PreDispatchActionError(
            message: "ScreenCaptureKit owner \(ownerText) does not serve the current stateful build-scoped " +
                "runtime at \(requiredSocket). No capture was dispatched.",
            code: .CAPTURE_FAILED,
            hint: "Stop or upgrade the exact owner before retrying. Peekaboo will not violate process ownership " +
                "or route stateful snapshot work to a different build.",
            reason: .runtimeIncompatible
        )
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
