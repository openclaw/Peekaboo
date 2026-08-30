import Commander
import CoreGraphics
import Darwin
import Dispatch
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

private struct CaptureActionPublicationIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
}

private struct CaptureActionPublicationProbeDirectory {
    let url: URL
    let identity: CaptureActionPublicationIdentity
}

@MainActor
struct CaptureActionExecutionDependencies {
    typealias FrameSourceFactory = @MainActor (CaptureScope) -> (any CaptureFrameSource)?
    typealias LegacyProcessRunner = @MainActor (
        [String],
        TimeInterval,
        @escaping @Sendable (UInt64) -> Void
    ) async throws -> CaptureActionProcessResult
    typealias HostIdentityProvider = @MainActor () throws -> PeekabooBridgeAuthenticatedHostIdentity
    typealias ProcessRunner = @MainActor (
        [String],
        TimeInterval,
        UInt64,
        @escaping @Sendable (UInt64) -> Void
    ) async throws -> CaptureActionProcessResult

    static let live = CaptureActionExecutionDependencies(
        frameSourceFactory: { _ in nil },
        deadlineProcessRunner: { command, timeoutSeconds, completionDeadlineNanoseconds, onLaunch in
            try await CaptureActionProcessRunner.run(
                command: command,
                timeoutSeconds: timeoutSeconds,
                completionDeadlineNanoseconds: completionDeadlineNanoseconds,
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
        processRunner: @escaping LegacyProcessRunner,
        hostIdentityProvider: HostIdentityProvider? = nil
    ) {
        self.frameSourceFactory = frameSourceFactory
        self.processRunner = { command, timeoutSeconds, _, onLaunch in
            try await processRunner(command, timeoutSeconds, onLaunch)
        }
        self.hostIdentityProvider = hostIdentityProvider
    }

    init(
        frameSourceFactory: @escaping FrameSourceFactory,
        deadlineProcessRunner: @escaping ProcessRunner,
        hostIdentityProvider: HostIdentityProvider? = nil
    ) {
        self.frameSourceFactory = frameSourceFactory
        self.processRunner = deadlineProcessRunner
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
        let (outputDir, resolvedVideoOut) = try self.resolveOutputPathsBeforeDispatch()
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

        let session = self.makeCaptureSession(
            scope: scope,
            options: options,
            outputDir: outputDir,
            resolvedVideoOut: resolvedVideoOut
        )
        let captureStartedAtUnixMs = Int64(Date().timeIntervalSince1970 * 1000)
        let captureStartedNs = DispatchTime.now().uptimeNanoseconds
        let captureDeadlineNs = try CaptureActionTiming.captureDeadline(
            captureStartedNs: captureStartedNs,
            durationLimit: options.duration
        )
        let actionCompletionDeadlineNs = try timing.actionCompletionDeadline(
            captureDeadlineNs: captureDeadlineNs
        )
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
                    timing.actionTimeout,
                    actionCompletionDeadlineNs
                ) { dispatchState.markDispatched(at: $0) }
                self.recordChildDispatch(dispatchState)
                self.childCommandCompleted = true
            } catch {
                self.recordChildDispatch(dispatchState)
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
            let resumedAtNs = DispatchTime.now().uptimeNanoseconds
            let actionCompletedNs = action.completedAtMonotonicNanoseconds ?? resumedAtNs
            guard actionCompletedNs >= actionStartedNs, actionCompletedNs <= resumedAtNs else {
                throw CaptureActionProcessLaunchError(
                    message: "Action runner returned an invalid completion boundary"
                )
            }
            let actionCompletedMs = Self.elapsedMilliseconds(
                since: captureStartedNs,
                endingAt: actionCompletedNs
            )
            let postRollDeadlineNs = try timing.postRollDeadline(startingAtNs: actionCompletedNs)
            guard postRollDeadlineNs <= captureDeadlineNs else {
                throw ValidationError("Action completion left insufficient time for the requested post-roll")
            }
            try await Self.sleep(untilMonotonicNanoseconds: postRollDeadlineNs)
            session.requestStop()

            let captureCompletion = try await captureTask.value
            try Task.checkCancellation()
            let capture = captureCompletion.result
            try await self.revalidateCaptureHostIdentity(captureHostIdentity)
            let samplingCompletedMs = captureCompletion.samplingCompletedMs
            let captureCompletedMs = captureCompletion.completedMs
            let artifactValidation = try self.validateArtifacts(capture)
            let validation = Self.validatePostRollCoverage(
                artifactValidation: artifactValidation,
                samplingCompletedMs: samplingCompletedMs,
                actionCompletedMs: actionCompletedMs,
                postRollMs: timing.postRollMs
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

    private mutating func recordChildDispatch(_ dispatchState: CaptureActionDispatchState) {
        self.captureMutationDispatched = self.captureMutationDispatched || dispatchState.wasDispatched
        self.childCommandDispatched = self.childCommandDispatched || dispatchState.wasDispatched
    }

    private static func validatePostRollCoverage(
        artifactValidation: CaptureActionArtifactValidation,
        samplingCompletedMs: Int,
        actionCompletedMs: Int,
        postRollMs: Int
    ) -> CaptureActionArtifactValidation {
        let requiredCaptureCompletedMs = actionCompletedMs + postRollMs
        var validationFailures = artifactValidation.missing
        if samplingCompletedMs < requiredCaptureCompletedMs {
            validationFailures.append(
                "capture ended before the action and requested post-roll completed"
            )
        }
        return CaptureActionArtifactValidation(
            ok: validationFailures.isEmpty,
            checked: artifactValidation.checked,
            missing: validationFailures
        )
    }

    private func makeCaptureSession(
        scope: CaptureScope,
        options: CaptureOptions,
        outputDir: URL,
        resolvedVideoOut: String?
    ) -> WatchCaptureSession {
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
            videoOut: resolvedVideoOut,
            keepAllFrames: false
        )
        return WatchCaptureSession(dependencies: deps, configuration: config)
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
}

// MARK: - Capture configuration and publication custody

extension CaptureActionCommand {
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
        return try CaptureActionTiming.resolve(
            durationLimit: durationLimit,
            preRollMs: preRoll,
            postRollMs: postRoll,
            requestedActionTimeout: self.actionTimeout?.seconds
        )
    }

    private func resolveOutputDirectory() throws -> URL {
        CaptureCommandPathResolver.outputDirectory(from: self.path)
    }

    private func resolveOutputPathsBeforeDispatch() throws -> (URL, String?) {
        let outputDirectory = try self.resolveOutputDirectory()
        let videoOut = CaptureCommandPathResolver.filePath(from: self.videoOut)
        try self.validateOutputPathsBeforeDispatch(outputDirectory: outputDirectory, videoOut: videoOut)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Self.validateExclusiveRenameSupport(in: outputDirectory)
        if let videoOut {
            let videoDirectory = URL(fileURLWithPath: videoOut).deletingLastPathComponent()
            try Self.validateExclusiveRenameSupport(in: videoDirectory)
            try Self.validateVideoOutputIsAbsent(videoOut)
        }
        return (outputDirectory, videoOut)
    }

    static func validateVideoOutputIsAbsent(_ path: String) throws {
        var information = stat()
        let result = URL(fileURLWithPath: path).withUnsafeFileSystemRepresentation { representation in
            guard let representation else {
                errno = EINVAL
                return Int32(-1)
            }
            return lstat(representation, &information)
        }
        let failure = errno
        guard result != 0 else {
            throw ValidationError("--video-out must not already exist before capture starts: \(path)")
        }
        guard failure == ENOENT else {
            throw ValidationError("Could not preflight --video-out before capture starts: \(path)")
        }
    }

    private func validateOutputPathsBeforeDispatch(
        outputDirectory: URL,
        videoOut: String?
    ) throws {
        guard let videoOut else { return }
        let outputRoot = outputDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let videoURL = URL(fileURLWithPath: videoOut).standardizedFileURL.resolvingSymlinksInPath()
        let reservedNames = [
            CaptureActionManifestWriter.fileName,
            "contact.png",
            "metadata.json",
        ]
        let aliasesReservedPath = reservedNames.contains { name in
            Self.pathsMayAlias(outputRoot.appendingPathComponent(name), videoURL)
        }
        let aliasesFramePath = Self.pathsMayAlias(videoURL.deletingLastPathComponent(), outputRoot) &&
            videoURL.lastPathComponent.lowercased().hasPrefix("keep-") &&
            videoURL.pathExtension.lowercased() == "png"
        guard !Self.pathsMayAlias(videoURL, outputRoot), !aliasesReservedPath, !aliasesFramePath else {
            throw ValidationError(
                "--video-out must not resolve to a capture-owned artifact under --path: \(videoOut)"
            )
        }
    }

    static func validateExclusiveRenameSupport(
        in directory: URL,
        renameExclusively: (URL, URL) -> Int32 = Self.renameExclusively
    ) throws {
        let parent = directory.standardizedFileURL.resolvingSymlinksInPath()
        let probeDirectory = try Self.createPublicationProbeDirectory(in: parent)
        let source = probeDirectory.url.appendingPathComponent("source")
        let destination = probeDirectory.url.appendingPathComponent("destination")
        let descriptor = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return open(path, O_CREAT | O_EXCL | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            _ = Self.removePublicationProbeDirectoryIfEmpty(probeDirectory)
            throw ValidationError(
                "Capture output directory must exist and support private temporary files: \(parent.path)"
            )
        }
        var sourceInformation = stat()
        let sourceIdentity = fstat(descriptor, &sourceInformation) == 0
            ? CaptureActionPublicationIdentity(device: sourceInformation.st_dev, inode: sourceInformation.st_ino)
            : nil
        close(descriptor)
        guard let sourceIdentity else {
            _ = Self.removePublicationProbeDirectoryIfEmpty(probeDirectory)
            throw ValidationError("Capture output publication probe could not retain file identity: \(parent.path)")
        }

        guard renameExclusively(source, destination) == 0 else {
            let code = errno
            _ = Self.removePublicationProbeFile(at: source, expected: sourceIdentity)
            _ = Self.removePublicationProbeDirectoryIfEmpty(probeDirectory)
            throw ValidationError(
                "Capture output filesystem must support atomic no-replace publication (errno \(code)): " +
                    parent.path
            )
        }
        guard Self.removePublicationProbeFile(at: destination, expected: sourceIdentity),
              Self.removePublicationProbeDirectoryIfEmpty(probeDirectory)
        else {
            throw ValidationError("Capture output publication preflight cleanup failed: \(parent.path)")
        }
    }

    private static func createPublicationProbeDirectory(
        in parent: URL
    ) throws -> CaptureActionPublicationProbeDirectory {
        for _ in 0..<4 {
            let url = parent.appendingPathComponent(
                ".peekaboo-rename-probe-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            let created = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return mkdir(path, S_IRWXU)
            }
            if created == 0 {
                var information = stat()
                let inspected = url.withUnsafeFileSystemRepresentation { path in
                    guard let path else { return Int32(-1) }
                    return lstat(path, &information)
                }
                guard inspected == 0,
                      information.st_mode & S_IFMT == S_IFDIR,
                      information.st_uid == geteuid(),
                      information.st_mode & (S_IRWXG | S_IRWXO) == 0
                else {
                    _ = url.withUnsafeFileSystemRepresentation { path in
                        guard let path else { return Int32(-1) }
                        return rmdir(path)
                    }
                    throw ValidationError("Capture output publication probe is not owner-private: \(url.path)")
                }
                return CaptureActionPublicationProbeDirectory(
                    url: url,
                    identity: CaptureActionPublicationIdentity(
                        device: information.st_dev,
                        inode: information.st_ino
                    )
                )
            }
            guard errno == EEXIST else {
                throw ValidationError("Capture output publication probe could not be created: \(parent.path)")
            }
        }
        throw ValidationError("Capture output publication probe name could not be reserved: \(parent.path)")
    }

    private static func removePublicationProbeFile(
        at url: URL,
        expected: CaptureActionPublicationIdentity?
    ) -> Bool {
        var information = stat()
        let inspected = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        if inspected != 0 {
            return errno == ENOENT
        }
        guard information.st_mode & S_IFMT == S_IFREG,
              expected == nil || expected == CaptureActionPublicationIdentity(
                  device: information.st_dev,
                  inode: information.st_ino
              )
        else {
            return false
        }
        let removed = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return unlink(path)
        }
        return removed == 0 || errno == ENOENT
    }

    private static func removePublicationProbeDirectoryIfEmpty(
        _ directory: CaptureActionPublicationProbeDirectory
    ) -> Bool {
        var information = stat()
        let inspected = directory.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &information)
        }
        if inspected != 0 {
            return errno == ENOENT
        }
        guard information.st_mode & S_IFMT == S_IFDIR,
              directory.identity == CaptureActionPublicationIdentity(
                  device: information.st_dev,
                  inode: information.st_ino
              )
        else {
            return false
        }
        let removed = directory.url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return rmdir(path)
        }
        return removed == 0 || errno == ENOENT
    }

    private static func pathsMayAlias(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let right = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        return left.compare(right, options: [.caseInsensitive]) == .orderedSame
    }

    private nonisolated static func renameExclusively(_ source: URL, _ destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
    }

    private static func sleep(milliseconds: Int) async throws {
        try Task.checkCancellation()
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        try Task.checkCancellation()
    }

    private static func sleep(untilMonotonicNanoseconds deadlineNs: UInt64) async throws {
        try Task.checkCancellation()
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if deadlineNs > nowNs {
            try await Task.sleep(nanoseconds: deadlineNs - nowNs)
        }
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

struct CaptureActionTiming {
    let preRollMs: Int
    let postRollMs: Int
    let startupGateMs: Int
    let actionTimeout: TimeInterval

    static func resolve(
        durationLimit: TimeInterval,
        preRollMs: Int,
        postRollMs: Int,
        requestedActionTimeout: TimeInterval?
    ) throws -> Self {
        let startupGateMs = max(preRollMs, 100)
        let (fixedMilliseconds, overflowed) = startupGateMs.addingReportingOverflow(postRollMs)
        let fixedSeconds = Double(fixedMilliseconds) / 1000.0 +
            CaptureActionProcessRunner.completionReserveSeconds
        let availableActionSeconds = durationLimit - fixedSeconds
        guard !overflowed,
              durationLimit.isFinite,
              availableActionSeconds >= 0.1,
              requestedActionTimeout?.isFinite != false
        else {
            throw ValidationError(
                "--duration-limit must reserve startup/pre-roll, post-roll, and child process-group cleanup"
            )
        }
        return Self(
            preRollMs: preRollMs,
            postRollMs: postRollMs,
            startupGateMs: startupGateMs,
            actionTimeout: max(0.1, min(requestedActionTimeout ?? availableActionSeconds, availableActionSeconds))
        )
    }

    static func captureDeadline(captureStartedNs: UInt64, durationLimit: TimeInterval) throws -> UInt64 {
        let durationNs = try self.nanoseconds(seconds: durationLimit)
        let (deadlineNs, overflowed) = captureStartedNs.addingReportingOverflow(durationNs)
        guard !overflowed else {
            throw ValidationError("--duration-limit overflowed the capture deadline")
        }
        return deadlineNs
    }

    func actionCompletionDeadline(captureDeadlineNs: UInt64) throws -> UInt64 {
        let postRollNs = try Self.nanoseconds(milliseconds: self.postRollMs)
        guard captureDeadlineNs > postRollNs else {
            throw ValidationError("--post-roll exceeds the capture deadline")
        }
        return captureDeadlineNs - postRollNs
    }

    func postRollFits(startingAtNs: UInt64, captureDeadlineNs: UInt64) -> Bool {
        guard let deadlineNs = try? self.postRollDeadline(startingAtNs: startingAtNs) else { return false }
        return deadlineNs <= captureDeadlineNs
    }

    func postRollDeadline(startingAtNs: UInt64) throws -> UInt64 {
        let postRollNs = try Self.nanoseconds(milliseconds: self.postRollMs)
        let (deadlineNs, overflowed) = startingAtNs.addingReportingOverflow(postRollNs)
        guard !overflowed else {
            throw ValidationError("--post-roll overflowed the capture deadline")
        }
        return deadlineNs
    }

    private static func nanoseconds(seconds: TimeInterval) throws -> UInt64 {
        guard seconds.isFinite,
              seconds >= 0,
              seconds <= Double(UInt64.max) / 1_000_000_000.0
        else {
            throw ValidationError("Capture timing cannot be represented as a monotonic deadline")
        }
        return UInt64((seconds * 1_000_000_000.0).rounded(.down))
    }

    private static func nanoseconds(milliseconds: Int) throws -> UInt64 {
        guard milliseconds >= 0 else {
            throw ValidationError("Capture timing cannot be negative")
        }
        let (value, overflowed) = UInt64(milliseconds).multipliedReportingOverflow(by: 1_000_000)
        guard !overflowed else {
            throw ValidationError("Capture timing overflowed its monotonic deadline")
        }
        return value
    }
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
                help: "Action timeout within the capture/cleanup budget; bare values are milliseconds",
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
