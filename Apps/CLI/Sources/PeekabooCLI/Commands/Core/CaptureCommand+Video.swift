import AVFoundation
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

// MARK: Video capture

private enum CaptureVideoInputError: LocalizedError, ResultEnvelopeError {
    case invalidOption(String)
    case missingFile(String)
    case unreadableFile(String)
    case nonFileInput(String)

    nonisolated var errorDescription: String? {
        switch self {
        case let .invalidOption(message):
            "Invalid input: \(message)"
        case let .missingFile(path):
            "Input video file does not exist: \(path)"
        case let .unreadableFile(path):
            "Input video file is not readable: \(path)"
        case let .nonFileInput(path):
            "Input video path is not a regular file: \(path)"
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        .INVALID_INPUT
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeRetrySafe: Bool? {
        true
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        false
    }

    nonisolated var envelopeHint: String? {
        switch self {
        case let .invalidOption(message):
            if message.hasPrefix("sample-fps") {
                "Use --sample-fps with a finite value greater than 0."
            } else {
                "Correct the video sampling options and retry."
            }
        case .missingFile, .unreadableFile, .nonFileInput:
            "Check the path and pass an existing readable video file."
        }
    }
}

@MainActor
struct CaptureVideoCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable,
InjectedRuntimeBackedCommand {
    @Argument(help: "Input video file") var input: String
    @Option(name: .long, help: "Sample FPS (default 2). Mutually exclusive with --every") var sampleFps: Double?
    @Option(name: .customLong("every"), help: "Sampling interval (mutually exclusive with --sample-fps)")
    var every: CLIDuration?
    @Option(name: .customLong("start"), help: "Trim start offset") var start: CLIDuration?
    @Option(name: .customLong("end"), help: "Trim end offset") var end: CLIDuration?
    @Flag(name: .long, help: "Keep all sampled frames (disable diff/keep filtering)") var noDiff = false
    @Option(name: .long, help: "Max frames before stopping") var maxFrames: Int?
    @Option(name: .long, help: "Max megabytes before stopping") var maxMb: Int?
    @Option(name: .long, help: "Resolution cap (largest dimension, default 1440)") var resolutionCap: Double?
    @Option(name: .long, help: "Diff strategy: fast|quality (default fast)") var diffStrategy: String?
    @Option(name: .customLong("diff-budget"), help: "Diff time budget before falling back to fast")
    var diffBudget: CLIDuration?
    @Option(name: .long, help: "Output directory") var path: String?
    @Option(name: .customLong("autoclean"), help: "Time before temp sessions auto-clean (default 7200s)")
    var autoclean: CLIDuration?
    @Option(name: .long, help: "Optional MP4 output path (built from kept frames)") var videoOut: String?

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        try self.validateBeforeRuntime()
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        self.logger.operationStart("capture_video", metadata: ["input": self.input])

        do {
            let outputDir = try self.resolveOutputDirectory()
            let options = try self.buildOptions()
            let videoURL = self.inputVideoURL()
            let frameSource = try await VideoFrameSource(
                url: videoURL,
                sampleFps: self.sampleFps,
                everyMs: self.every?.roundedMilliseconds,
                startMs: self.start?.roundedMilliseconds,
                endMs: self.end?.roundedMilliseconds,
                resolutionCap: self.resolutionCap.map { CGFloat($0) }
            )

            let deps = WatchCaptureDependencies(
                screenCapture: self.services.screenCapture,
                screenService: self.services.screens,
                frameSource: frameSource
            )
            let config = WatchCaptureConfiguration(
                scope: CaptureScope(kind: .frontmost),
                options: options,
                outputRoot: outputDir,
                autoclean: WatchAutocleanConfig(
                    minutes: self.autoclean.map { Int(($0.seconds / 60).rounded()) } ?? 120,
                    managed: self.path == nil
                ),
                sourceKind: .video,
                videoIn: videoURL.path,
                videoOut: CaptureCommandPathResolver.filePath(from: self.videoOut),
                keepAllFrames: self.noDiff,
                videoOptions: CaptureVideoOptionsSnapshot(
                    sampleFps: self.every == nil ? self.sampleFps ?? 2.0 : nil,
                    everyMs: self.every?.roundedMilliseconds,
                    effectiveFps: frameSource.effectiveFPS,
                    startMs: self.start?.roundedMilliseconds,
                    endMs: self.end?.roundedMilliseconds,
                    keepAllFrames: self.noDiff
                )
            )
            let session = WatchCaptureSession(dependencies: deps, configuration: config)
            let result = try await session.run()
            self.output(result)
            self.logger.operationComplete(
                "capture_video",
                success: true,
                metadata: ["frames_kept": result.stats.framesKept]
            )
        } catch let validation as Commander.ValidationError {
            // Surface validation issues directly so tests can assert on them without the generic ExitCode wrapper.
            self.handleError(validation)
            self.logger.operationComplete(
                "capture_video",
                success: false,
                metadata: ["error": validation.localizedDescription]
            )
            throw validation
        } catch {
            self.handleError(error)
            self.logger.operationComplete(
                "capture_video",
                success: false,
                metadata: ["error": error.localizedDescription]
            )
            throw ExitCode(1)
        }
    }

    func validateBeforeRuntime() throws {
        if self.sampleFps != nil, self.every != nil {
            throw ValidationError("--sample-fps and --every are mutually exclusive")
        }
        do {
            try VideoFrameRequestValidator.validate(
                sampleFps: self.sampleFps,
                everyMs: self.every?.roundedMilliseconds,
                startMs: self.start?.roundedMilliseconds,
                endMs: self.end?.roundedMilliseconds,
                resolutionCap: self.resolutionCap
            )
        } catch let PeekabooError.invalidInput(message) {
            throw CaptureVideoInputError.invalidOption(message)
        }
        _ = try self.buildOptions()

        let videoURL = self.inputVideoURL()
        let resolvedVideoURL = videoURL.resolvingSymlinksInPath()
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolvedVideoURL.path, isDirectory: &isDirectory) else {
            throw CaptureVideoInputError.missingFile(videoURL.path)
        }
        guard !isDirectory.boolValue else {
            throw CaptureVideoInputError.nonFileInput(videoURL.path)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedVideoURL.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw CaptureVideoInputError.nonFileInput(videoURL.path)
        }
        guard FileManager.default.isReadableFile(atPath: resolvedVideoURL.path) else {
            throw CaptureVideoInputError.unreadableFile(videoURL.path)
        }
    }

    func buildOptions() throws -> CaptureOptions {
        let maxFrames = max(self.maxFrames ?? 10000, 1)
        let resolutionCap = self.resolutionCap ?? 1440
        let diffStrategy = try CaptureCommandOptionParser.diffStrategy(self.diffStrategy)
        let diffBudgetMs = self.diffBudget?.roundedMilliseconds ?? (diffStrategy == .quality ? 30 : nil)
        let maxMb = self.maxMb.flatMap { $0 > 0 ? $0 : nil }
        return CaptureOptions(
            duration: 3600,
            idleFps: 60,
            activeFps: 60,
            changeThresholdPercent: 2.5,
            heartbeatSeconds: 5,
            quietMsToIdle: 1000,
            maxFrames: maxFrames,
            maxMegabytes: maxMb,
            highlightChanges: false,
            captureFocus: .background,
            resolutionCap: resolutionCap,
            diffStrategy: diffStrategy,
            diffBudgetMs: diffBudgetMs
        )
    }

    func resolveOutputDirectory() throws -> URL {
        CaptureCommandPathResolver.outputDirectory(from: self.path)
    }

    func inputVideoURL() -> URL {
        CaptureCommandPathResolver.fileURL(from: self.input)
    }

    private func output(_ result: LiveCaptureSessionResult) {
        let meta = CaptureMetaSummary.make(from: result)
        if self.jsonOutput {
            outputSuccessCodable(data: result, logger: self.outputLogger)
            return
        }
        print("""
        🎥 capture(video) kept \(result.stats.framesKept) frames (dropped \(result.stats
            .framesDropped), decode failures \(result.stats.decodeFailures)), contact sheet: \(meta.contactPath)
        """)
        for frame in result.frames {
            print("🖼️  \(frame.reason.rawValue) t=\(frame.timestampMs)ms → \(frame.path)")
        }
        for warning in result.warnings {
            print("⚠️  \(warning.code.rawValue): \(warning.message)")
        }
    }
}

extension CaptureVideoCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "video",
                abstract: "Ingest a video, sample frames, and build contact sheet",
                version: "1.0.0"
            )
        }
    }
}

extension CaptureVideoCommand: AsyncRuntimeCommand {}
extension CaptureVideoCommand: PreRuntimeValidatingCommand {}

@MainActor
extension CaptureVideoCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.input = try values.requiredPositional(0, label: "input")
        self.sampleFps = try values.decodeOption("sampleFps", as: Double.self)
        self.every = try values.decodeOption("every", as: CLIDuration.self)
        self.start = try values.decodeOption("start", as: CLIDuration.self)
        self.end = try values.decodeOption("end", as: CLIDuration.self)
        if values.flag("noDiff") {
            self.noDiff = true
        }
        self.maxFrames = try values.decodeOption("maxFrames", as: Int.self)
        self.maxMb = try values.decodeOption("maxMb", as: Int.self)
        self.resolutionCap = try values.decodeOption("resolutionCap", as: Double.self)
        self.diffStrategy = values.singleOption("diffStrategy")
        self.diffBudget = try values.decodeOption("diffBudget", as: CLIDuration.self)
        self.path = values.singleOption("path")
        self.autoclean = try values.decodeOption("autoclean", as: CLIDuration.self)
        self.videoOut = values.singleOption("videoOut")
    }
}
