import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
struct CaptureActionCommand: ApplicationResolvable, ErrorHandlingCommand, OutputFormattable,
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
            guard !self.command.isEmpty else {
                throw ValidationError("Pass the action command after --")
            }

            let scope = try await resolveScope()
            let options = try buildOptions()
            let timing = try resolveActionTiming(durationLimit: options.duration)
            if scope.kind == .window, let identifier = scope.applicationIdentifier {
                try await focusIfNeeded(
                    appIdentifier: identifier,
                    windowID: scope.windowId,
                    windowMutationIdentity: scope.windowMutationIdentity
                )
            }

            let outputDir = try resolveOutputDirectory()
            let deps = WatchCaptureDependencies(
                screenCapture: services.screenCapture,
                screenService: self.services.screens,
                frameSource: nil
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
            let captureTask = self.startCaptureTask(session: session, scope: scope)

            do {
                if try await Self.waitForPreRollOrCaptureEnd(
                    milliseconds: timing.startupGateMs,
                    captureTask: captureTask
                ) != nil {
                    throw ValidationError("Capture ended before action started")
                }
                self.resolvedRuntime.beginInteractionMutation()
                let action = try await CaptureActionProcessRunner.run(
                    command: self.command,
                    timeoutSeconds: timing.actionTimeout
                )
                self.captureMutationDispatched = true
                try await Self.sleep(milliseconds: timing.postRollMs)
                session.requestStop()

                let capture = try await captureTask.value
                let validation = validateArtifacts(capture)
                let result = CaptureActionCommandResult(
                    success: action.succeeded && validation.ok,
                    action: action,
                    capture: capture,
                    validation: validation
                )
                self.output(result)
                self.logger.operationComplete(
                    "capture_action",
                    success: result.success,
                    metadata: ["frames_kept": capture.stats.framesKept]
                )
                if !result.success {
                    throw ExitCode(1)
                }
            } catch {
                session.requestStop()
                captureTask.cancel()
                _ = try? await captureTask.value
                throw error
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            handleError(error)
            self.logger.operationComplete(
                "capture_action",
                success: false,
                metadata: ["error": error.localizedDescription]
            )
            throw ExitCode(1)
        }
    }

    private func startCaptureTask(
        session: WatchCaptureSession,
        scope: CaptureScope
    ) -> Task<CaptureSessionResult, any Error> {
        let runSession: @MainActor @Sendable () async throws -> CaptureSessionResult = {
            try await session.run()
        }
        let enginePreference = liveCaptureEnginePreference(for: scope)
        return Task { @MainActor in
            if let engineAware = services.screenCapture as? any EngineAwareScreenCaptureServiceProtocol {
                try await engineAware.withCaptureEngine(enginePreference, operation: runSession)
            } else {
                try await runSession()
            }
        }
    }

    private func output(_ result: CaptureActionCommandResult) {
        if self.jsonOutput {
            let error = result.success
                ? nil
                : ErrorInfo(message: result.failureMessage, code: .VALIDATION_ERROR)
            let envelope = ResultEnvelope(
                success: result.success,
                data: result,
                messages: nil,
                debug_logs: self.outputLogger.getDebugLogs(),
                error: error
            )
            outputJSONCodable(envelope, logger: self.outputLogger)
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
        guard milliseconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
    }

    private static func waitForPreRollOrCaptureEnd(
        milliseconds: Int,
        captureTask: Task<CaptureSessionResult, any Error>
    ) async throws -> CaptureSessionResult? {
        try await withThrowingTaskGroup(of: CaptureActionStartupGate.self) { group in
            group.addTask {
                if milliseconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                }
                return .preRollElapsed
            }
            group.addTask {
                try await .captureEnded(captureTask.value)
            }

            guard let first = try await group.next() else {
                return nil
            }
            group.cancelAll()

            switch first {
            case .preRollElapsed:
                return nil
            case let .captureEnded(result):
                return result
            }
        }
    }
}

private struct CaptureActionTiming {
    let preRollMs: Int
    let postRollMs: Int
    let startupGateMs: Int
    let actionTimeout: TimeInterval
}

private enum CaptureActionStartupGate {
    case preRollElapsed
    case captureEnded(CaptureSessionResult)
}

struct CaptureActionCommandResult: Codable {
    let success: Bool
    let action: CaptureActionProcessResult
    let capture: CaptureSessionResult
    let validation: CaptureActionArtifactValidation

    var failureMessage: String {
        if self.action.timedOut {
            return "Action timed out after \(self.action.timeoutSeconds)s"
        }
        if !self.action.succeeded {
            return "Action exited with status \(self.action.exitCode)"
        }
        return "Capture artifact validation failed"
    }
}

struct CaptureActionArtifactValidation: Codable {
    let ok: Bool
    let checked: [String]
    let missing: [String]
}

struct CaptureActionProcessResult: Codable {
    let command: [String]
    let exitCode: Int32
    let timedOut: Bool
    let timeoutSeconds: TimeInterval
    let durationMs: Int
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool

    var succeeded: Bool {
        !self.timedOut && self.exitCode == 0
    }
}

@MainActor
extension CaptureActionCommand {
    private func validateArtifacts(_ result: CaptureSessionResult) -> CaptureActionArtifactValidation {
        var checked = [result.metadataFile, result.contactSheet.path]
        checked.append(contentsOf: result.frames.map(\.path))
        if let videoOut = result.videoOut {
            checked.append(videoOut)
        } else if let expectedVideoOut = CaptureCommandPathResolver.filePath(from: videoOut) {
            checked.append(expectedVideoOut)
        }

        var missing: [String] = []
        if result.frames.isEmpty {
            missing.append("frame files")
        }
        for path in checked where !Self.fileExistsAndIsNonEmpty(path) {
            missing.append(path)
        }
        return CaptureActionArtifactValidation(ok: missing.isEmpty, checked: checked, missing: missing)
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
