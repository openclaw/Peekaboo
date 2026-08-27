import Commander
import CoreGraphics
import Dispatch
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

@MainActor
struct CaptureActionExecutionDependencies {
    typealias FrameSourceFactory = @MainActor (CaptureScope) -> (any CaptureFrameSource)?
    typealias HostIdentityProvider = @MainActor () throws -> PeekabooBridgeAuthenticatedHostIdentity
    typealias ProcessRunner = @MainActor (
        [String],
        TimeInterval,
        @escaping @Sendable (UInt64) -> Void
    ) async throws -> CaptureActionProcessResult

    static let live = CaptureActionExecutionDependencies(
        frameSourceFactory: { _ in nil },
        processRunner: { command, timeoutSeconds, onLaunch in
            try await CaptureActionProcessRunner.run(
                command: command,
                timeoutSeconds: timeoutSeconds,
                onLaunch: onLaunch
            )
        },
        hostIdentityProvider: nil
    )

    let frameSourceFactory: FrameSourceFactory
    let processRunner: ProcessRunner
    let hostIdentityProvider: HostIdentityProvider?

    init(
        frameSourceFactory: @escaping FrameSourceFactory,
        processRunner: @escaping ProcessRunner,
        hostIdentityProvider: HostIdentityProvider? = nil
    ) {
        self.frameSourceFactory = frameSourceFactory
        self.processRunner = processRunner
        self.hostIdentityProvider = hostIdentityProvider
    }
}

@MainActor
struct CaptureActionCommand: ActionOutputFormattable, ApplicationResolvable, ErrorHandlingCommand, OutputFormattable,
RuntimeOptionsConfigurable, InjectedRuntimeBackedCommand {
    var app: String?
    var pid: Int32?
    var mode: String?
    var windowTitle: String?
    var windowIndex: Int?
    var screenIndex: Int?
    var region: String?
    var captureFocus: LiveCaptureFocus = .background
    var captureEngine: String?

    var durationLimit: CLIDuration?
    var preRoll: CLIDuration?
    var postRoll: CLIDuration?
    var actionTimeout: CLIDuration?
    var idleFps: Double?
    var activeFps: Double?
    var threshold: Double?
    var heartbeat: CLIDuration?
    var quiet: CLIDuration?
    var highlightChanges = false
    var maxFrames: Int?
    var maxMb: Int?
    var resolutionCap: Double?
    var diffStrategy: String?
    var diffBudget: CLIDuration?

    var path: String?
    var autoclean: CLIDuration?
    var videoOut: String?
    var command: [String] = []

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()
    var captureMutationDispatched = false
    var captureFocusOutcome: DesktopActionOutcome?
    var childCommandDispatched = false
    var childCommandCompleted = false
    var executionDependencies = CaptureActionExecutionDependencies.live

    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "action",
                abstract: "Capture around a child command with pre/post-roll",
                discussion: """
                Starts adaptive live capture, runs a child command, keeps post-roll, then
                stops capture and verifies the resulting artifacts.

                Examples:
                  peekaboo capture action --duration-limit 10s -- echo smoke
                  peekaboo capture action --mode area --region 0,0,640,360 -- ./test-flow.sh
                """,
                version: "1.0.0"
            )
        }
    }

    func withCaptureFocusMutation(_ operation: () async throws -> Void) async rethrows {
        try await self.resolvedRuntime.withCaptureFocusMutation(operation)
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        self.logger.operationStart("capture_action", metadata: ["mode": self.mode ?? "auto"])

        do {
            let result = try await self.executeActionCapture()
            self.output(result)
            self.logger.operationComplete(
                "capture_action",
                success: result.success,
                metadata: ["frames_kept": result.capture.stats.framesKept]
            )
            if !result.success {
                throw ExitCode(1)
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            let reportedError = self.canonicalFailure(after: error)
            handleError(reportedError)
            self.logger.operationComplete(
                "capture_action",
                success: false,
                metadata: ["error": reportedError.localizedDescription]
            )
            throw ExitCode(1)
        }
    }

    mutating func executeActionCapture() async throws -> CaptureActionCommandResult {
        guard !self.command.isEmpty else {
            throw ValidationError("Pass the action command after --")
        }
        self.captureFocusOutcome = nil
        self.childCommandDispatched = false
        self.childCommandCompleted = false

        let scope = try await resolveScope()
        let options = try buildOptions()
        let timing = try resolveActionTiming(durationLimit: options.duration)
        let requestedEngine = liveCaptureEnginePreference(for: scope)
        let captureHostIdentity = try await captureHostIdentity()
        let runID = UUID().uuidString
        if scope.kind == .window, let identifier = scope.applicationIdentifier {
            let focusOutcome = try await focusIfNeeded(
                appIdentifier: identifier,
                windowID: scope.windowId,
                windowMutationIdentity: scope.windowMutationIdentity
            )
            self.recordCaptureFocusOutcome(focusOutcome)
        }

        let outputDir = try resolveOutputDirectory()
        let deps = WatchCaptureDependencies(
            screenCapture: services.screenCapture,
            screenService: self.services.screens,
            frameSource: self.executionDependencies.frameSourceFactory(scope)
        )
        let config = WatchCaptureConfiguration(
            scope: scope,
            options: options,
            outputRoot: outputDir,
            autoclean: WatchAutocleanConfig(
                minutes: self.autoclean.map { Int(($0.seconds / 60).rounded()) } ?? 120,
                managed: self.path == nil
            ),
            sourceKind: .live,
            videoIn: nil,
            videoOut: CaptureCommandPathResolver.filePath(from: self.videoOut),
            keepAllFrames: false
        )
        let session = WatchCaptureSession(dependencies: deps, configuration: config)
        let captureStartedAtUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let captureStartedNs = DispatchTime.now().uptimeNanoseconds
        let captureTask = self.startCaptureTask(
            session: session,
            enginePreference: requestedEngine,
            captureStartedNs: captureStartedNs
        )

        do {
            if try await Self.waitForPreRollOrCaptureEnd(
                milliseconds: timing.startupGateMs,
                captureTask: captureTask
            ) != nil {
                throw ValidationError("Capture ended before action started")
            }
            self.resolvedRuntime.beginInteractionMutation()
            let dispatchState = CaptureActionDispatchState()
            let action: CaptureActionProcessResult
            do {
                action = try await self.executionDependencies.processRunner(
                    self.command,
                    timing.actionTimeout
                ) { dispatchState.markDispatched(at: $0) }
                self.captureMutationDispatched = self.captureMutationDispatched || dispatchState.wasDispatched
                self.childCommandDispatched = self.childCommandDispatched || dispatchState.wasDispatched
                self.childCommandCompleted = true
            } catch {
                self.captureMutationDispatched = self.captureMutationDispatched || dispatchState.wasDispatched
                self.childCommandDispatched = self.childCommandDispatched || dispatchState.wasDispatched
                throw error
            }
            guard let actionStartedNs = dispatchState.dispatchedAtMonotonicNanoseconds else {
                throw CaptureActionProcessLaunchError(
                    message: "Action runner returned without admitting child dispatch"
                )
            }
            let actionStartedMs = Self.elapsedMilliseconds(
                since: captureStartedNs,
                endingAt: actionStartedNs
            )
            let actionCompletedMs = Self.elapsedMilliseconds(since: captureStartedNs)
            try await Self.sleep(milliseconds: timing.postRollMs)
            session.requestStop()

            let captureCompletion = try await captureTask.value
            try Task.checkCancellation()
            let capture = captureCompletion.result
            try await self.revalidateCaptureHostIdentity(captureHostIdentity)
            let samplingCompletedMs = captureCompletion.samplingCompletedMs
            let captureCompletedMs = captureCompletion.completedMs
            let artifactValidation = try self.validateArtifacts(capture)
            let requiredCaptureCompletedMs = actionCompletedMs + timing.postRollMs
            var validationFailures = artifactValidation.missing
            if samplingCompletedMs < requiredCaptureCompletedMs {
                validationFailures.append(
                    "capture ended before the action and requested post-roll completed"
                )
            }
            let validation = CaptureActionArtifactValidation(
                ok: validationFailures.isEmpty,
                checked: artifactValidation.checked,
                missing: validationFailures
            )
            let childOutcome = CaptureActionOutcomeSemantics.completedChildOutcome
            let outcome = CaptureActionOutcomeSemantics.aggregate(
                focusOutcome: self.captureFocusOutcome,
                childOutcome: childOutcome
            )
            let commandSucceeded = action.succeeded && validation.ok
            var manifestReceipt: CaptureActionManifestReceipt?
            if artifactValidation.ok {
                manifestReceipt = try self.publishActionManifest(
                    .init(
                        outputRoot: outputDir,
                        runID: runID,
                        captureStartedAtUnixMs: captureStartedAtUnixMs,
                        actionStartedMs: actionStartedMs,
                        actionCompletedMs: actionCompletedMs,
                        samplingCompletedMs: samplingCompletedMs,
                        captureCompletedMs: captureCompletedMs,
                        timing: timing,
                        options: options,
                        requestedEngine: requestedEngine,
                        action: action,
                        capture: capture,
                        captureHostIdentity: captureHostIdentity,
                        commandSucceeded: commandSucceeded,
                        validation: validation,
                        focusOutcome: self.captureFocusOutcome,
                        childOutcome: childOutcome,
                        outcome: outcome
                    )
                )
            }
            return CaptureActionCommandResult(
                commandSucceeded: commandSucceeded,
                focusOutcome: self.captureFocusOutcome,
                childOutcome: childOutcome,
                outcome: outcome,
                action: action,
                capture: capture,
                validation: validation,
                manifest: manifestReceipt
            )
        } catch {
            session.requestStop()
            captureTask.cancel()
            _ = try? await captureTask.value
            throw error
        }
    }

    private func publishActionManifest(
        _ context: CaptureActionManifestContext
    ) throws -> CaptureActionManifestReceipt {
        let integrityReceipt = try CaptureArtifactIntegrityValidator.validate(context.capture)
        try Task.checkCancellation()
        let artifacts = try CaptureActionManifestWriter.makeArtifacts(
            capture: context.capture,
            outputRoot: context.outputRoot,
            metadataSHA256: integrityReceipt.metadataSHA256
        )
        try Task.checkCancellation()
        let manifest = try CaptureActionManifest(
            schemaVersion: 1,
            runID: context.runID,
            timeline: .init(
                captureStartedAtUnixMs: context.captureStartedAtUnixMs,
                actionStartedMs: context.actionStartedMs,
                actionCompletedMs: context.actionCompletedMs,
                samplingCompletedMs: context.samplingCompletedMs,
                captureCompletedMs: context.captureCompletedMs
            ),
            request: .init(
                commandSHA256: CaptureActionManifestWriter.commandSHA256(self.command),
                commandArgumentCount: self.command.count,
                preRollMs: context.timing.preRollMs,
                postRollMs: context.timing.postRollMs,
                actionTimeoutSeconds: context.timing.actionTimeout,
                captureDurationLimitSeconds: context.options.duration,
                captureFocus: context.options.captureFocus,
                requestedCaptureEngine: context.requestedEngine
            ),
            action: .init(
                containmentScope: .processGroup,
                processIdentifier: context.action.processIdentifier,
                processStartIdentity: context.action.processStartIdentity,
                processStartIdentityDecimal: String(context.action.processStartIdentity),
                exitCode: context.action.exitCode,
                timedOut: context.action.timedOut,
                processGroupCleaned: context.action.processGroupCleaned,
                durationMs: context.action.durationMs,
                stdout: CaptureActionManifestWriter.stream(
                    context.action.stdout,
                    truncated: context.action.stdoutTruncated
                ),
                stderr: CaptureActionManifestWriter.stream(
                    context.action.stderr,
                    truncated: context.action.stderrTruncated
                )
            ),
            capture: .init(
                scope: context.capture.scope,
                executionRoute: self.services.executionHost,
                hostDescription: self.resolvedRuntime.hostDescription,
                remoteSocketPath: self.resolvedRuntime.selectedRemoteSocketPath,
                hostIdentity: context.captureHostIdentity,
                observedCaptureEngines: Array(Set(context.capture.frames.compactMap(\.captureEngine))).sorted()
            ),
            artifacts: artifacts,
            result: .init(
                commandSucceeded: context.commandSucceeded,
                validation: context.validation,
                focusOutcome: context.focusOutcome,
                childOutcome: context.childOutcome,
                outcome: context.outcome
            )
        )
        return try CaptureActionManifestWriter.write(manifest, outputRoot: context.outputRoot)
    }

    private func startCaptureTask(
        session: WatchCaptureSession,
        enginePreference: CaptureEnginePreference,
        captureStartedNs: UInt64
    ) -> Task<CaptureActionCaptureCompletion, any Error> {
        let runSession: @MainActor @Sendable () async throws -> CaptureSessionResult = {
            try await session.run()
        }
        return Task { @MainActor in
            let result: CaptureSessionResult = if let engineAware = services
                .screenCapture as? any EngineAwareScreenCaptureServiceProtocol {
                try await engineAware.withCaptureEngine(enginePreference, operation: runSession)
            } else {
                try await runSession()
            }
            guard let samplingEndedNs = session.samplingEndedAtMonotonicNanoseconds else {
                throw ValidationError("capture session did not report its sampling completion boundary")
            }
            return CaptureActionCaptureCompletion(
                result: result,
                samplingCompletedMs: Self.elapsedMilliseconds(
                    since: captureStartedNs,
                    endingAt: samplingEndedNs
                ),
                completedMs: Self.elapsedMilliseconds(since: captureStartedNs)
            )
        }
    }

    private func output(_ result: CaptureActionCommandResult) {
        if self.jsonOutput {
            outputJSONCodable(self.jsonEnvelope(for: result), logger: self.outputLogger)
            return
        }

        print(
            "capture(action) sampled \(result.capture.stats.framesSampled) frames at " +
                "\(String(format: "%.2f", result.capture.stats.sampledFps)) FPS; " +
                "kept \(result.capture.stats.framesKept) at " +
                "\(String(format: "%.2f", result.capture.stats.keptFps)) FPS"
        )
        print("contact sheet: \(result.capture.contactSheet.path)")
        print("metadata: \(result.capture.metadataFile)")
        if let manifest = result.manifest {
            print("action manifest: \(manifest.path) (sha256: \(manifest.sha256))")
        }
        if let videoOut = result.capture.videoOut {
            print("video: \(videoOut)")
        }
        print("action exit: \(result.action.exitCode)")
        if result.action.timedOut {
            print("action timed out after \(String(format: "%.2f", result.action.timeoutSeconds))s")
        }
        if !result.validation.ok {
            print("artifact validation failed: \(result.validation.missing.joined(separator: ", "))")
        }
        for warning in result.capture.warnings {
            print("warning: \(warning.code.rawValue): \(warning.message)")
        }
    }

    func jsonEnvelope(for result: CaptureActionCommandResult) -> ResultEnvelope<CaptureActionCommandResult> {
        let projection = result.outcome?.projection
        let error = result.success
            ? nil
            : ErrorInfo(
                message: result.failureMessage,
                code: .VALIDATION_ERROR,
                retrySafe: projection?.retrySafe ?? false,
                mutationDispatched: projection?.mutationDispatched ?? true
            )
        return ResultEnvelope(
            success: result.success,
            effect: projection?.effect ?? .unverifiable,
            outcome: projection,
            data: result,
            messages: nil,
            debug_logs: self.outputLogger.getDebugLogs(),
            error: error
        )
    }

    private func buildOptions() throws -> CaptureOptions {
        let duration = max(1, min(durationLimit?.seconds ?? 60, 180))
        let cadence = try CaptureCadence.validated(idleFps: self.idleFps, activeFps: self.activeFps)
        let threshold = min(max(threshold ?? 2.5, 0), 100)
        let heartbeat = max(heartbeat?.seconds ?? 5, 0)
        let quiet = max(quiet?.roundedMilliseconds ?? 1000, 0)
        let maxFrames = max(maxFrames ?? 800, 1)
        let resolutionCap = resolutionCap ?? 1440
        let diffStrategy = try CaptureCommandOptionParser.diffStrategy(diffStrategy)
        let diffBudgetMs = self.diffBudget?.roundedMilliseconds ?? (diffStrategy == .quality ? 30 : nil)
        let maxMb = maxMb.flatMap { $0 > 0 ? $0 : nil }

        return CaptureOptions(
            duration: duration,
            idleFps: cadence.idleFps,
            activeFps: cadence.activeFps,
            changeThresholdPercent: threshold,
            heartbeatSeconds: heartbeat,
            quietMsToIdle: quiet,
            maxFrames: maxFrames,
            maxMegabytes: maxMb,
            highlightChanges: self.highlightChanges,
            captureFocus: self.captureFocus,
            resolutionCap: resolutionCap,
            diffStrategy: diffStrategy,
            diffBudgetMs: diffBudgetMs
        )
    }

    private func resolveActionTiming(durationLimit: TimeInterval) throws -> CaptureActionTiming {
        let preRoll = max(preRoll?.roundedMilliseconds ?? 250, 0)
        let postRoll = max(postRoll?.roundedMilliseconds ?? 500, 0)
        let rollSeconds = Double(preRoll + postRoll) / 1000.0
        guard rollSeconds < durationLimit else {
            throw ValidationError("--pre-roll + --post-roll must be less than --duration-limit")
        }
        let defaultActionTimeout = max(0.1, durationLimit - rollSeconds)
        let actionTimeout = max(
            0.1,
            min(actionTimeout?.seconds ?? defaultActionTimeout, durationLimit - rollSeconds)
        )
        return CaptureActionTiming(
            preRollMs: preRoll,
            postRollMs: postRoll,
            startupGateMs: max(preRoll, 100),
            actionTimeout: actionTimeout
        )
    }

    private func resolveOutputDirectory() throws -> URL {
        CaptureCommandPathResolver.outputDirectory(from: self.path)
    }

    private static func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation()
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        try Task.checkCancellation()
    }

    private static func elapsedMilliseconds(since start: UInt64) -> Int {
        self.elapsedMilliseconds(since: start, endingAt: DispatchTime.now().uptimeNanoseconds)
    }

    private static func elapsedMilliseconds(since start: UInt64, endingAt end: UInt64) -> Int {
        Int(end >= start ? (end - start) / 1_000_000 : 0)
    }

    private func captureHostIdentity() async throws -> CaptureActionManifest.AuthenticatedHostIdentity {
        let identity: PeekabooBridgeAuthenticatedHostIdentity
        if let provider = self.executionDependencies.hostIdentityProvider {
            identity = try provider()
        } else if self.services.executionHost == .remote {
            let selectedIdentity = if let provider = self.resolvedRuntime
                .selectedRemoteAuthenticatedHostIdentityProvider {
                await provider()
            } else {
                self.resolvedRuntime.selectedRemoteAuthenticatedHostIdentity
            }
            guard let selectedIdentity else {
                throw CaptureActionHostProvenanceError(
                    message: "capture action requires an authenticated identity from the selected remote capture host"
                )
            }
            identity = selectedIdentity
        } else {
            guard let currentIdentity = PeekabooBridgeAuthenticatedHostIdentity.current() else {
                throw CaptureActionHostProvenanceError(
                    message: "capture action requires an Apple-anchored, source-stamped Peekaboo executable"
                )
            }
            identity = currentIdentity
        }
        return try CaptureActionManifest.AuthenticatedHostIdentity(validating: identity)
    }

    private func revalidateCaptureHostIdentity(
        _ expected: CaptureActionManifest.AuthenticatedHostIdentity
    ) async throws {
        guard try await self.captureHostIdentity() == expected else {
            throw CaptureActionHostProvenanceError(
                message: "capture action host identity changed while capture was active"
            )
        }
    }

    mutating func recordCaptureFocusOutcome(_ outcome: DesktopActionOutcome?) {
        self.captureFocusOutcome = outcome
        self.captureMutationDispatched = self.captureMutationDispatched ||
            (outcome?.dispatchState.mutationDispatched == true)
    }

    private func canonicalFailure(after error: any Error) -> any Error {
        if error is DesktopActionFailure || error is PreDispatchActionError {
            return error
        }
        guard self.captureMutationDispatched else {
            let reason: DesktopActionOutcome.RefusalReason? = switch error {
            case is CancellationError: .requestCancelled
            case is CaptureActionHostProvenanceError: .runtimeIncompatible
            case let launchError as CaptureActionProcessLaunchError: launchError.refusalReason
            default: nil
            }
            return self.preDispatchActionError(for: error, reason: reason)
        }

        let outcome: DesktopActionOutcome
        if self.childCommandDispatched {
            let childOutcome = self.childCommandCompleted
                ? CaptureActionOutcomeSemantics.completedChildOutcome
                : CaptureActionOutcomeSemantics.uncertainChildOutcome
            outcome = CaptureActionOutcomeSemantics.failureAggregate(
                focusOutcome: self.captureFocusOutcome,
                childOutcome: childOutcome
            )
        } else if let focusOutcome = self.captureFocusOutcome,
                  focusOutcome.dispatchState.mutationDispatched {
            outcome = CaptureActionOutcomeSemantics.focusOnlyFailureOutcome(focusOutcome)
        } else {
            return self.preDispatchActionError(for: error, reason: .invalidRequest)
        }
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: self.childCommandDispatched
                ? "Capture action failed after its child command was released."
                : "Capture action failed after foreground focus changed desktop state.",
            hint: "Observe the affected target before deciding whether to retry.",
            causeDescription: error.localizedDescription
        )
        else {
            preconditionFailure("Capture action failure outcome must be non-confirmed")
        }
        return failure
    }

    private static func waitForPreRollOrCaptureEnd(
        milliseconds: Int,
        captureTask: Task<CaptureActionCaptureCompletion, any Error>
    ) async throws -> CaptureActionCaptureCompletion? {
        let race = CaptureActionStartupRace()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let preRollTask = Task {
                    do {
                        if milliseconds > 0 {
                            try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                        }
                        try Task.checkCancellation()
                        race.resolve(.success(nil))
                    } catch {
                        // Another branch or the parent cancellation owns the terminal result.
                    }
                }
                let captureWaitTask = Task {
                    do {
                        let result = try await captureTask.value
                        race.resolve(.success(result))
                    } catch {
                        race.resolve(.failure(error))
                    }
                }
                race.installTasks([preRollTask, captureWaitTask])
            }
        } onCancel: {
            race.resolve(.failure(CancellationError()))
        }
    }
}

private struct CaptureActionTiming {
    let preRollMs: Int
    let postRollMs: Int
    let startupGateMs: Int
    let actionTimeout: TimeInterval
}

private struct CaptureActionCaptureCompletion: Sendable {
    let result: CaptureSessionResult
    let samplingCompletedMs: Int
    let completedMs: Int
}

private struct CaptureActionManifestContext {
    let outputRoot: URL
    let runID: String
    let captureStartedAtUnixMs: Int64
    let actionStartedMs: Int
    let actionCompletedMs: Int
    let samplingCompletedMs: Int
    let captureCompletedMs: Int
    let timing: CaptureActionTiming
    let options: CaptureOptions
    let requestedEngine: CaptureEnginePreference
    let action: CaptureActionProcessResult
    let capture: CaptureSessionResult
    let captureHostIdentity: CaptureActionManifest.AuthenticatedHostIdentity
    let commandSucceeded: Bool
    let validation: CaptureActionArtifactValidation
    let focusOutcome: DesktopActionOutcome?
    let childOutcome: DesktopActionOutcome
    let outcome: DesktopActionOutcome?
}

private final nonisolated class CaptureActionDispatchState: @unchecked Sendable {
    private let lock = NSLock()
    private var dispatched = false
    private var dispatchedAtNs: UInt64?

    var wasDispatched: Bool {
        self.lock.withLock { self.dispatched }
    }

    var dispatchedAtMonotonicNanoseconds: UInt64? {
        self.lock.withLock { self.dispatchedAtNs }
    }

    func markDispatched(at monotonicNanoseconds: UInt64) {
        self.lock.withLock {
            self.dispatched = true
            if self.dispatchedAtNs == nil {
                self.dispatchedAtNs = monotonicNanoseconds
            }
        }
    }
}

private final nonisolated class CaptureActionStartupRace: @unchecked Sendable {
    typealias Resolution = Result<CaptureActionCaptureCompletion?, any Error>

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CaptureActionCaptureCompletion?, any Error>?
    private var resolution: Resolution?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<CaptureActionCaptureCompletion?, any Error>) {
        self.lock.lock()
        if let resolution = self.resolution {
            self.lock.unlock()
            continuation.resume(with: resolution)
            return
        }
        self.continuation = continuation
        self.lock.unlock()
    }

    func installTasks(_ tasks: [Task<Void, Never>]) {
        self.lock.lock()
        if self.resolution != nil {
            self.lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }
        self.tasks = tasks
        self.lock.unlock()
    }

    func resolve(_ resolution: Resolution) {
        self.lock.lock()
        guard self.resolution == nil else {
            self.lock.unlock()
            return
        }
        self.resolution = resolution
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks.removeAll()
        self.lock.unlock()

        tasks.forEach { $0.cancel() }
        continuation?.resume(with: resolution)
    }
}

enum CaptureActionOutcomeSemantics {
    static let childDelivery = DesktopActionOutcome.Delivery(
        mechanism: .capturePipeline,
        mode: .background
    )

    static var completedChildOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            route: .local,
            delivery: self.childDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one
        )
    }

    static var uncertainChildOutcome: DesktopActionOutcome {
        .indeterminate(
            route: .local,
            delivery: self.childDelivery,
            evidence: .completionUnknown,
            unitCount: .one
        )
    }

    static func aggregate(
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome
    ) -> DesktopActionOutcome? {
        var sequence = DesktopActionSequenceAccumulator()
        if let focusOutcome {
            sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
        }
        sequence.record(.reportedOutcome(childOutcome, defaultDispatchedUnitCount: .one))
        let resolution = sequence.successResolution()
        if let outcome = resolution.outcome {
            return outcome
        }
        return nil
    }

    static func focusOnlyFailureOutcome(_ focusOutcome: DesktopActionOutcome) -> DesktopActionOutcome {
        .indeterminate(
            route: focusOutcome.route,
            delivery: focusOutcome.delivery,
            evidence: .completionUnknown,
            unitCount: focusOutcome.dispatchState.unitCount ?? .one
        )
    }

    static func failureAggregate(
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome
    ) -> DesktopActionOutcome {
        if let aggregate = self.aggregate(focusOutcome: focusOutcome, childOutcome: childOutcome) {
            return aggregate
        }
        guard let focusOutcome else { return childOutcome }
        let focusUnits = focusOutcome.dispatchState.unitCount?.rawValue ?? 1
        let childUnits = childOutcome.dispatchState.unitCount?.rawValue ?? 1
        let (combinedUnits, unitCountOverflow) = focusUnits.addingReportingOverflow(childUnits)
        let unitCount = unitCountOverflow ? nil : DesktopActionOutcome.DispatchUnitCount(combinedUnits)
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .composite,
            mode: focusOutcome.delivery?.mode == .foreground || childOutcome.delivery?.mode == .foreground
                ? .foreground
                : .background
        )
        let hasSingleRoute = focusOutcome.route == childOutcome.route
        return .indeterminate(
            route: childOutcome.route,
            delivery: hasSingleRoute ? delivery : nil,
            evidence: .completionUnknown,
            unitCount: unitCount
        )
    }

    static func isCanonicalChildOutcome(_ outcome: DesktopActionOutcome) -> Bool {
        (outcome == self.completedChildOutcome || outcome == self.uncertainChildOutcome) &&
            outcome.delivery == self.childDelivery
    }

    static func isCanonicalAggregate(
        _ outcome: DesktopActionOutcome?,
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome
    ) -> Bool {
        self.isCanonicalChildOutcome(childOutcome) &&
            outcome == self.aggregate(focusOutcome: focusOutcome, childOutcome: childOutcome)
    }
}

struct CaptureActionCommandResult: Codable {
    let commandSucceeded: Bool
    let focusOutcome: DesktopActionOutcome?
    let childOutcome: DesktopActionOutcome
    let outcome: DesktopActionOutcome?
    let action: CaptureActionProcessResult
    let capture: CaptureSessionResult
    let validation: CaptureActionArtifactValidation
    let manifest: CaptureActionManifestReceipt?

    var success: Bool {
        self.commandSucceeded
    }

    init(
        commandSucceeded: Bool,
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome,
        outcome: DesktopActionOutcome?,
        action: CaptureActionProcessResult,
        capture: CaptureSessionResult,
        validation: CaptureActionArtifactValidation,
        manifest: CaptureActionManifestReceipt?
    ) {
        precondition(
            CaptureActionOutcomeSemantics.isCanonicalAggregate(
                outcome,
                focusOutcome: focusOutcome,
                childOutcome: childOutcome
            ),
            "Capture action results require canonical focus and child outcomes"
        )
        precondition(childOutcome == CaptureActionOutcomeSemantics.completedChildOutcome)
        precondition(capture.options.captureFocus != .background || focusOutcome == nil)
        precondition(validation.isCanonical)
        precondition(
            commandSucceeded == (action.succeeded && validation.ok && manifest != nil),
            "Capture action success must match action, validation, and manifest state"
        )
        self.commandSucceeded = commandSucceeded
        self.focusOutcome = focusOutcome
        self.childOutcome = childOutcome
        self.outcome = outcome
        self.action = action
        self.capture = capture
        self.validation = validation
        self.manifest = manifest
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case focusOutcome
        case childOutcome
        case outcome
        case action
        case capture
        case validation
        case manifest
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedSuccess = try container.decode(Bool.self, forKey: .success)
        self.focusOutcome = try container.decodeIfPresent(DesktopActionOutcome.self, forKey: .focusOutcome)
        self.childOutcome = try container.decode(DesktopActionOutcome.self, forKey: .childOutcome)
        self.outcome = try container.decodeIfPresent(DesktopActionOutcome.self, forKey: .outcome)
        self.action = try container.decode(CaptureActionProcessResult.self, forKey: .action)
        self.capture = try container.decode(CaptureSessionResult.self, forKey: .capture)
        self.validation = try container.decode(CaptureActionArtifactValidation.self, forKey: .validation)
        self.manifest = try container.decodeIfPresent(CaptureActionManifestReceipt.self, forKey: .manifest)
        let expectedSuccess = self.action.succeeded && self.validation.ok && self.manifest != nil
        guard self.validation.isCanonical,
              CaptureActionOutcomeSemantics.isCanonicalAggregate(
                  self.outcome,
                  focusOutcome: self.focusOutcome,
                  childOutcome: self.childOutcome
              ),
              self.childOutcome == CaptureActionOutcomeSemantics.completedChildOutcome,
              self.capture.options.captureFocus != .background || self.focusOutcome == nil,
              encodedSuccess == expectedSuccess
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Capture action fields contradict canonical result semantics"
            )
        }
        self.commandSucceeded = encodedSuccess
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.success, forKey: .success)
        try container.encodeIfPresent(self.focusOutcome, forKey: .focusOutcome)
        try container.encode(self.childOutcome, forKey: .childOutcome)
        try container.encodeIfPresent(self.outcome, forKey: .outcome)
        try container.encode(self.action, forKey: .action)
        try container.encode(self.capture, forKey: .capture)
        try container.encode(self.validation, forKey: .validation)
        try container.encodeIfPresent(self.manifest, forKey: .manifest)
    }

    var failureMessage: String {
        if self.action.timedOut {
            return "Action timed out after \(self.action.timeoutSeconds)s"
        }
        if !self.action.processGroupCleaned {
            return "Action process group could not be fully terminated"
        }
        if !self.action.succeeded {
            return "Action exited with status \(self.action.exitCode)"
        }
        if let failure = self.validation.missing.first {
            return "Capture validation failed: \(failure)"
        }
        return "Capture validation failed"
    }
}

struct CaptureActionArtifactValidation: Codable {
    let ok: Bool
    let checked: [String]
    let missing: [String]

    var isCanonical: Bool {
        self.ok == self.missing.isEmpty &&
            !self.checked.isEmpty &&
            Set(self.checked).count == self.checked.count
    }
}

nonisolated struct CaptureActionProcessResult: Codable, Sendable {
    let command: [String]
    let processIdentifier: pid_t
    let processStartIdentity: UInt64
    let processStartIdentityDecimal: String
    let exitCode: Int32
    let timedOut: Bool
    let processGroupCleaned: Bool
    let timeoutSeconds: TimeInterval
    let durationMs: Int
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    init(
        command: [String],
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        exitCode: Int32,
        timedOut: Bool,
        processGroupCleaned: Bool,
        timeoutSeconds: TimeInterval,
        durationMs: Int,
        stdout: String,
        stderr: String,
        stdoutTruncated: Bool,
        stderrTruncated: Bool
    ) {
        precondition(processIdentifier > 0 && processStartIdentity > 0)
        self.command = command
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = String(processStartIdentity)
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.processGroupCleaned = processGroupCleaned
        self.timeoutSeconds = timeoutSeconds
        self.durationMs = durationMs
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case processIdentifier
        case processStartIdentity
        case processStartIdentityDecimal
        case exitCode
        case timedOut
        case processGroupCleaned
        case timeoutSeconds
        case durationMs
        case stdout
        case stderr
        case stdoutTruncated
        case stderrTruncated
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processIdentifier = try container.decode(pid_t.self, forKey: .processIdentifier)
        let processStartIdentity = try container.decode(UInt64.self, forKey: .processStartIdentity)
        let processStartIdentityDecimal = try container.decode(
            String.self,
            forKey: .processStartIdentityDecimal
        )
        let timeoutSeconds = try container.decode(TimeInterval.self, forKey: .timeoutSeconds)
        let durationMs = try container.decode(Int.self, forKey: .durationMs)
        guard processIdentifier > 0,
              processStartIdentity > 0,
              processStartIdentityDecimal == String(processStartIdentity),
              timeoutSeconds.isFinite,
              timeoutSeconds >= 0,
              durationMs >= 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Capture action process result has invalid custody fields"
            )
        }
        self.command = try container.decode([String].self, forKey: .command)
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = processStartIdentityDecimal
        self.exitCode = try container.decode(Int32.self, forKey: .exitCode)
        self.timedOut = try container.decode(Bool.self, forKey: .timedOut)
        self.processGroupCleaned = try container.decode(Bool.self, forKey: .processGroupCleaned)
        self.timeoutSeconds = timeoutSeconds
        self.durationMs = durationMs
        self.stdout = try container.decode(String.self, forKey: .stdout)
        self.stderr = try container.decode(String.self, forKey: .stderr)
        self.stdoutTruncated = try container.decode(Bool.self, forKey: .stdoutTruncated)
        self.stderrTruncated = try container.decode(Bool.self, forKey: .stderrTruncated)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.command, forKey: .command)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(self.processStartIdentity, forKey: .processStartIdentity)
        try container.encode(self.processStartIdentityDecimal, forKey: .processStartIdentityDecimal)
        try container.encode(self.exitCode, forKey: .exitCode)
        try container.encode(self.timedOut, forKey: .timedOut)
        try container.encode(self.processGroupCleaned, forKey: .processGroupCleaned)
        try container.encode(self.timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(self.durationMs, forKey: .durationMs)
        try container.encode(self.stdout, forKey: .stdout)
        try container.encode(self.stderr, forKey: .stderr)
        try container.encode(self.stdoutTruncated, forKey: .stdoutTruncated)
        try container.encode(self.stderrTruncated, forKey: .stderrTruncated)
    }

    var succeeded: Bool {
        !self.timedOut && self.processGroupCleaned && self.exitCode == 0
    }
}

@MainActor
extension CaptureActionCommand {
    func validateArtifacts(_ result: CaptureSessionResult) throws -> CaptureActionArtifactValidation {
        var checked = [result.metadataFile, result.contactSheet.path]
        checked.append(contentsOf: result.frames.map(\.path))
        var failures: [String] = []
        do {
            try CaptureArtifactIntegrityValidator.validate(result)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            failures.append(error.localizedDescription)
        }

        let captureArtifactPaths = Set(checked.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        let resolvedVideoOut = result.videoOut ?? CaptureCommandPathResolver.filePath(from: self.videoOut)
        if let resolvedVideoOut {
            let canonicalVideoOut = URL(fileURLWithPath: resolvedVideoOut).standardizedFileURL.path
            if captureArtifactPaths.contains(canonicalVideoOut) {
                failures.append("video output aliases a capture-owned artifact: \(resolvedVideoOut)")
            } else {
                checked.append(resolvedVideoOut)
                if !Self.fileExistsAndIsNonEmpty(resolvedVideoOut) {
                    failures.append(resolvedVideoOut)
                }
            }
        }
        return CaptureActionArtifactValidation(ok: failures.isEmpty, checked: checked, missing: failures)
    }

    private static func fileExistsAndIsNonEmpty(_ path: String) -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: path),
              let attributes = try? manager.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }
}

@MainActor
extension CaptureActionCommand {
    func resolveScope() async throws -> CaptureScope {
        let mode = try resolveMode()
        let selector = try self.validatedCaptureWindowSelector(allowMissingTarget: true)
        switch mode {
        case .screen:
            let displayInfo = try await displayInfo(for: screenIndex)
            return CaptureScope(
                kind: .screen,
                screenIndex: displayInfo?.index,
                displayUUID: displayInfo?.uuid,
                windowId: nil,
                applicationIdentifier: nil,
                windowIndex: nil,
                region: nil
            )
        case .frontmost:
            return CaptureScope(kind: .frontmost)
        case .window:
            guard selector.hasOwnerInput else {
                throw ValidationError("Window capture requires --app or --pid")
            }
            let identifier = try resolveApplicationIdentifier()
            let windowReference = try await resolveExactCaptureWindowReference(
                selector: selector,
                applicationIdentifier: identifier,
                services: self.services,
                operation: "Capture action"
            )
            return CaptureScope(
                kind: .window,
                screenIndex: nil,
                displayUUID: nil,
                windowId: windowReference.windowID,
                windowMutationIdentity: windowReference.identity,
                applicationIdentifier: identifier,
                windowIndex: windowReference.windowIndex,
                region: nil
            )
        case .area:
            let rect = try parseRegion()
            return CaptureScope(kind: .region, region: rect)
        case .multi:
            throw ValidationError("capture action does not support multi-mode captures")
        }
    }

    func resolveMode() throws -> LiveCaptureMode {
        if let explicit = mode {
            let normalized = explicit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "region" {
                return .area
            }
            guard let mode = LiveCaptureMode(rawValue: normalized) else {
                throw ValidationError(
                    "Unsupported capture action mode '\(explicit)'. Use screen, window, frontmost, or area."
                )
            }
            return mode
        }
        if self.region != nil {
            return .area
        }
        if self.app != nil || self.pid != nil || self.windowTitle != nil || self.windowIndex != nil {
            return .window
        }
        return .frontmost
    }

    func parseRegion() throws -> CGRect {
        guard let region = region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !region.isEmpty
        else {
            throw PeekabooError.invalidInput("Region must be provided when --mode area is set")
        }
        let parts = region
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 4,
              let x = Double(parts[0]),
              let y = Double(parts[1]),
              let width = Double(parts[2]),
              let height = Double(parts[3])
        else {
            throw PeekabooError.invalidInput("Region must be x,y,width,height")
        }
        guard width > 0, height > 0 else {
            throw PeekabooError.invalidInput("Region width and height must be greater than zero")
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func liveCaptureEnginePreference(for scope: CaptureScope) -> CaptureEnginePreference {
        let value = (captureEngine ?? self.resolvedRuntime.configuration.captureEnginePreference)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch value {
        case "modern", "modern-only", "sckit", "sc", "screen-capture-kit", "sck":
            return .modern
        case "classic", "cg", "legacy", "legacy-only", "false", "0", "no":
            return .legacy
        default:
            return scope.kind == .region ? .legacy : .auto
        }
    }

    private func displayInfo(for index: Int?) async throws -> (index: Int, uuid: String)? {
        guard let index else { return nil }
        let screens = self.services.screens.listScreens()
        guard let match = screens.first(where: { $0.index == index }) else {
            throw PeekabooError.invalidInput("Screen index \(index) not found")
        }
        return (index, "\(match.displayID)")
    }
}

extension CaptureActionCommand: ParsableCommand {}
extension CaptureActionCommand: AsyncRuntimeCommand {}

extension CaptureActionCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        let live = CaptureLiveCommand.commanderSignature()
        let options = live.options.filter { $0.label != "duration" } + [
            .commandOption(
                "durationLimit",
                help: "Hard capture limit; bare values are milliseconds (default 60s, max 180s)",
                long: "duration-limit"
            ),
            .commandOption("preRoll", help: "Capture time before running the action", long: "pre-roll"),
            .commandOption("postRoll", help: "Capture time after the action exits", long: "post-roll"),
            .commandOption(
                "actionTimeout",
                help: "Action timeout; bare values are milliseconds (defaults to remaining duration)",
                long: "action-timeout"
            ),
            .commandOption(
                "command",
                help: "Command to run; usually pass after --",
                long: "command",
                parsing: .remaining
            ),
        ]
        return CommandSignature(
            arguments: live.arguments + [
                .make(
                    label: "command...",
                    help: "Command to run; usually pass after --",
                    isOptional: true,
                    parsing: .remaining
                ),
            ],
            options: options,
            flags: live.flags,
            optionGroups: live.optionGroups
        )
    }
}

@MainActor
extension CaptureActionCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.mode = values.singleOption("mode")
        self.windowTitle = values.singleOption("windowTitle")
        self.windowIndex = try values.decodeOption("windowIndex", as: Int.self)
        self.screenIndex = try values.decodeOption("screenIndex", as: Int.self)
        self.region = values.singleOption("region")
        if let parsedFocus: LiveCaptureFocus = try values.decodeOptionEnum("captureFocus") {
            self.captureFocus = parsedFocus
        }
        self.captureEngine = values.singleOption("captureEngine")
        self.durationLimit = try values.decodeOption("durationLimit", as: CLIDuration.self)
        self.preRoll = try values.decodeOption("preRoll", as: CLIDuration.self)
        self.postRoll = try values.decodeOption("postRoll", as: CLIDuration.self)
        self.actionTimeout = try values.decodeOption("actionTimeout", as: CLIDuration.self)
        self.idleFps = try values.decodeOption("idleFps", as: Double.self)
        self.activeFps = try values.decodeOption("activeFps", as: Double.self)
        self.threshold = try values.decodeOption("threshold", as: Double.self)
        self.heartbeat = try values.decodeOption("heartbeat", as: CLIDuration.self)
        self.quiet = try values.decodeOption("quiet", as: CLIDuration.self)
        self.maxFrames = try values.decodeOption("maxFrames", as: Int.self)
        self.maxMb = try values.decodeOption("maxMb", as: Int.self)
        self.resolutionCap = try values.decodeOption("resolutionCap", as: Double.self)
        self.diffStrategy = values.singleOption("diffStrategy")
        self.diffBudget = try values.decodeOption("diffBudget", as: CLIDuration.self)
        if values.flag("highlightChanges") {
            self.highlightChanges = true
        }
        self.path = values.singleOption("path")
        self.autoclean = try values.decodeOption("autoclean", as: CLIDuration.self)
        self.videoOut = values.singleOption("videoOut")
        let optionCommand = values.optionValues("command")
        if !values.positional.isEmpty, !optionCommand.isEmpty {
            throw ValidationError("Provide the action command after -- or with --command, not both")
        }
        self.command = values.positional.isEmpty ? optionCommand : values.positional
    }
}
