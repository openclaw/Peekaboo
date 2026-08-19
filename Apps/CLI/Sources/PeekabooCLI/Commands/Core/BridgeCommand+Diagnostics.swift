import Foundation
import PeekabooAutomation
import PeekabooBridge
import Security

struct BridgeDiagnostics {
    typealias CandidateProbe = @Sendable (
        _ socketPath: String,
        _ identity: PeekabooBridgeClientIdentity
    ) async throws -> PeekabooBridgeHandshakeResponse

    nonisolated static let maxConcurrentProbes = 8
    nonisolated static let probeTimeoutSeconds: TimeInterval = 1

    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    @MainActor
    func run(runtimeOptions: CommandRuntimeOptions) async throws -> BridgeStatusReport {
        let environment = ProcessInfo.processInfo.environment
        let effectiveOptions = runtimeOptions.applyingEnvironmentOverrides(environment: environment)
        let configurationInput = PeekabooAutomation.ConfigurationManager.shared.getConfiguration()?.input
        let remoteSkipReason = Self.remoteSkipReason(
            runtimeOptions: effectiveOptions,
            environment: environment,
            configurationInput: configurationInput
        )

        let identity = Self.currentClientIdentity()

        if let remoteSkipReason {
            let candidates = Self.diagnosticSocketPaths(
                runtimeOptions: effectiveOptions,
                environment: environment
            )
            self.logger.debug("Bridge status: remote skipped (\(remoteSkipReason))")
            return BridgeStatusReport(
                remoteSkipped: true,
                remoteSkipReason: remoteSkipReason,
                selected: .local(),
                candidates: candidates.map { BridgeCandidateReport(socketPath: $0, result: .skipped) },
                client: .init(identity: identity)
            )
        }

        let candidatePlan = await RuntimeHostResolver.remoteCandidatePlan(
            options: effectiveOptions,
            environment: environment
        )
        let runtimeCandidates = candidatePlan.candidates
        let candidates = Self.diagnosticSocketPaths(
            runtimeCandidateSocketPaths: runtimeCandidates.map(\.socketPath),
            hasExplicitSocket: candidatePlan.explicitSocket != nil
        )
        var runtimeCandidateByPath: [String: RuntimeHostResolver.ImplicitRemoteCandidate] = [:]
        for candidate in runtimeCandidates {
            let path = NSString(string: candidate.socketPath).standardizingPath
            if runtimeCandidateByPath[path] == nil {
                runtimeCandidateByPath[path] = candidate
            }
        }

        let probeResults = try await Self.probeCandidates(
            socketPaths: candidates,
            identity: identity
        )

        var results: [BridgeCandidateReport] = []
        var selected: BridgeSelectionReport?

        for probeResult in probeResults {
            let socketPath = probeResult.socketPath
            let candidatePath = NSString(string: socketPath).standardizingPath
            let runtimeCandidate = runtimeCandidateByPath[candidatePath]
            switch probeResult.outcome {
            case let .success(handshake):
                let report = BridgeHandshakeReport(from: handshake)
                self.logger.debug(
                    "Bridge status: handshake OK \(handshake.hostKind.rawValue) via \(socketPath)",
                    category: "Bridge"
                )
                var rejection: BridgeCandidateRejectionReport?
                if selected == nil,
                   let runtimeCandidate {
                    let evaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
                        runtimeCandidate,
                        handshake: handshake,
                        options: effectiveOptions
                    )
                    if evaluation.validation != nil {
                        selected = .remote(socketPath: socketPath, handshake: report)
                    } else if let reason = evaluation.rejection {
                        rejection = .runtime(reason, handshake: handshake)
                    }
                }
                results.append(.init(
                    socketPath: socketPath,
                    result: .success(report),
                    selectionEligible: runtimeCandidate != nil,
                    rejection: rejection
                ))
            case let .failure(error):
                if let errorCode = error.code {
                    self.logger.debug(
                        "Bridge status: handshake error \(errorCode) via \(socketPath): \(error.message)",
                        category: "Bridge"
                    )
                } else {
                    self.logger.debug(
                        "Bridge status: handshake error via \(socketPath): \(error.details ?? error.message)",
                        category: "Bridge"
                    )
                }
                results.append(.init(
                    socketPath: socketPath,
                    result: .failure(error),
                    selectionEligible: runtimeCandidate != nil,
                    rejection: runtimeCandidate == nil ? nil : .bridgeFailure(error)
                ))
            }
        }

        if let explicitSocket = candidatePlan.explicitSocket, selected == nil {
            let standardizedSocket = NSString(string: explicitSocket).standardizingPath
            let candidateFailure = results.first { candidate in
                NSString(string: candidate.socketPath).standardizingPath == standardizedSocket
            }.flatMap { candidate -> BridgeCandidateErrorReport? in
                guard case let .failure(error) = candidate.result else { return nil }
                return error
            }
            throw BridgeExplicitSocketUnavailableError(
                socketPath: standardizedSocket,
                failureMessage: candidateFailure?.message,
                failureHint: candidateFailure?.hint
            )
        }

        return BridgeStatusReport(
            remoteSkipped: false,
            remoteSkipReason: nil,
            selected: selected ?? .local(),
            candidates: results,
            client: .init(identity: identity)
        )
    }

    nonisolated static func probeCandidates(
        socketPaths: [String],
        identity: PeekabooBridgeClientIdentity,
        maxConcurrentProbes: Int = Self.maxConcurrentProbes,
        probe: @escaping CandidateProbe = Self.liveProbe
    ) async throws -> [BridgeDiagnosticProbeResult] {
        guard !socketPaths.isEmpty else { return [] }
        precondition(maxConcurrentProbes > 0, "Bridge probe concurrency must be positive")
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(
            of: (Int, BridgeDiagnosticProbeOutcome).self,
            returning: [BridgeDiagnosticProbeResult].self
        ) { group in
            defer { group.cancelAll() }

            func enqueue(_ index: Int) {
                let socketPath = socketPaths[index]
                group.addTask {
                    do {
                        let handshake = try await probe(socketPath, identity)
                        return (index, .success(handshake))
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let envelope as PeekabooBridgeErrorEnvelope {
                        return (index, .failure(.bridgeEnvelope(envelope)))
                    } catch {
                        return (index, .failure(.other(error)))
                    }
                }
            }

            let initialProbeCount = min(socketPaths.count, maxConcurrentProbes)
            for index in 0..<initialProbeCount {
                enqueue(index)
            }

            var nextIndex = initialProbeCount
            var orderedResults = [BridgeDiagnosticProbeResult?](repeating: nil, count: socketPaths.count)
            while let (index, outcome) = try await group.next() {
                try Task.checkCancellation()
                orderedResults[index] = BridgeDiagnosticProbeResult(
                    socketPath: socketPaths[index],
                    outcome: outcome
                )
                if nextIndex < socketPaths.count {
                    enqueue(nextIndex)
                    nextIndex += 1
                }
            }

            return orderedResults.compactMap(\.self)
        }
    }

    private nonisolated static func liveProbe(
        socketPath: String,
        identity: PeekabooBridgeClientIdentity
    ) async throws -> PeekabooBridgeHandshakeResponse {
        let client = PeekabooBridgeClient(
            socketPath: socketPath,
            requestTimeoutSec: Self.probeTimeoutSeconds
        )
        do {
            return try await client.handshake(
                client: identity,
                requestedHost: nil,
                overallTimeoutSec: Self.probeTimeoutSeconds
            )
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
            throw PeekabooBridgeErrorEnvelope(
                code: .timeout,
                message: "Bridge diagnostic handshake timed out after \(Self.probeTimeoutSeconds)s",
                details: "The host at \(socketPath) did not answer before the diagnostic deadline."
            )
        }
    }

    static func remoteSkipReason(
        runtimeOptions: CommandRuntimeOptions,
        environment: [String: String],
        configurationInput: PeekabooAutomation.Configuration.InputConfig?
    ) -> String? {
        let decision = RuntimeHostResolver.initialRoutingDecision(
            options: runtimeOptions,
            environment: environment,
            configurationInput: configurationInput,
            knownSnapshotInvalidationRemoteSocketPaths: []
        )
        guard case .local = decision else { return nil }

        if environment["PEEKABOO_NO_REMOTE"] != nil {
            return "PEEKABOO_NO_REMOTE"
        }
        if runtimeOptions.remoteIsolationRequested {
            return "--no-remote"
        }
        if RuntimeHostResolver.inputPolicyRequiresLocal(
            options: runtimeOptions,
            environment: environment,
            configurationInput: configurationInput
        ) {
            return "input strategy policy"
        }
        return "local runtime policy"
    }

    static func runtimeCandidateSocketPaths(
        runtimeOptions: CommandRuntimeOptions,
        environment: [String: String],
        historicalBuildScopedDaemonSocketPaths: [String] = []
    ) -> [String] {
        if let explicitPath = BridgeSocketResolver.explicitBridgeSocket(
            options: runtimeOptions,
            environment: environment
        ) {
            return [explicitPath]
        }

        let daemonPath = DaemonLaunchPolicy.daemonSocketPath(environment: environment)
        let buildScopedPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: daemonPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        )
        return RuntimeHostResolver.implicitRemoteCandidates(
            options: runtimeOptions,
            daemonSocketPath: daemonPath,
            buildScopedDaemonSocketPath: buildScopedPath,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
        ).map(\.socketPath)
    }

    static func diagnosticSocketPaths(
        runtimeOptions: CommandRuntimeOptions,
        environment: [String: String],
        historicalBuildScopedDaemonSocketPaths: [String] = []
    ) -> [String] {
        let runtimePaths = self.runtimeCandidateSocketPaths(
            runtimeOptions: runtimeOptions,
            environment: environment,
            historicalBuildScopedDaemonSocketPaths: historicalBuildScopedDaemonSocketPaths
        )
        return self.diagnosticSocketPaths(
            runtimeCandidateSocketPaths: runtimePaths,
            hasExplicitSocket: BridgeSocketResolver.explicitBridgeSocket(
                options: runtimeOptions,
                environment: environment
            ) != nil
        )
    }

    private static func diagnosticSocketPaths(
        runtimeCandidateSocketPaths runtimePaths: [String],
        hasExplicitSocket: Bool
    ) -> [String] {
        if hasExplicitSocket {
            return runtimePaths
        }
        let additionalPaths = [
            PeekabooBridgeConstants.peekabooSocketPath,
            PeekabooBridgeConstants.claudeSocketPath,
            PeekabooBridgeConstants.clawdbotSocketPath,
        ]
        return runtimePaths + additionalPaths.filter { !runtimePaths.contains($0) }
    }

    static func currentClientIdentity() -> PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: self.currentTeamIdentifier(),
            processIdentifier: getpid(),
            hostname: Host.current().name
        )
    }

    private static func currentTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let sCode = staticCode
        else { return nil }

        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(sCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any]
        else { return nil }

        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

struct BridgeDiagnosticProbeResult: Sendable {
    let socketPath: String
    let outcome: BridgeDiagnosticProbeOutcome
}

enum BridgeDiagnosticProbeOutcome: Sendable {
    case success(PeekabooBridgeHandshakeResponse)
    case failure(BridgeCandidateErrorReport)
}
