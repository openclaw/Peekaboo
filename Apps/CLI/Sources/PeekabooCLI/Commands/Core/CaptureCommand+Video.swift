import AVFoundation
import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

// MARK: Video capture

@MainActor
struct CaptureVideoCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Input video file") var input: String
    @Option(name: .long, help: "Sample FPS (default 2). Mutually exclusive with --every-ms") var sampleFps: Double?
    @Option(name: .long, help: "Sample every N milliseconds (mutually exclusive with --sample-fps)") var everyMs: Int?
    @Option(name: .long, help: "Trim start in ms") var startMs: Int?
    @Option(name: .long, help: "Trim end in ms") var endMs: Int?
    @Flag(name: .long, help: "Keep all sampled frames (disable diff/keep filtering)") var noDiff = false
    @Option(name: .long, help: "Max frames before stopping") var maxFrames: Int?
    @Option(name: .long, help: "Max megabytes before stopping") var maxMb: Int?
    @Option(name: .long, help: "Resolution cap (largest dimension, default 1440)") var resolutionCap: Double?
    @Option(name: .long, help: "Diff strategy: fast|quality (default fast)") var diffStrategy: String?
    @Option(name: .long, help: "Diff time budget ms before falling back to fast") var diffBudgetMs: Int?
    @Option(name: .long, help: "Output directory") var path: String?
    @Option(name: .long, help: "Minutes before temp sessions auto-clean (default 120)") var autocleanMinutes: Int?
    @Option(name: .long, help: "Optional MP4 output path (built from kept frames)") var videoOut: String?

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    private var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    var jsonOutput: Bool {
        self.resolvedRuntime.configuration.jsonOutput
    }

    var outputLogger: Logger {
        self.logger
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        self.logger.operationStart("capture_video", metadata: ["input": self.input])

        do {
            if self.sampleFps != nil, self.everyMs != nil {
                throw ValidationError("--sample-fps and --every-ms are mutually exclusive")
            }
            let outputDir = try self.resolveOutputDirectory()
            let options = try self.buildOptions()
            let videoURL = self.inputVideoURL()
            let frameSource = try await VideoFrameSource(
                url: videoURL,
                sampleFps: self.sampleFps,
                everyMs: self.everyMs,
                startMs: self.startMs,
                endMs: self.endMs,
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
                autoclean: WatchAutocleanConfig(minutes: self.autocleanMinutes ?? 120, managed: self.path == nil),
                sourceKind: .video,
                videoIn: videoURL.path,
                videoOut: CaptureCommandPathResolver.filePath(from: self.videoOut),
                keepAllFrames: self.noDiff,
                videoOptions: CaptureVideoOptionsSnapshot(
                    sampleFps: self.everyMs == nil ? self.sampleFps ?? 2.0 : nil,
                    everyMs: self.everyMs,
                    effectiveFps: frameSource.effectiveFPS,
                    startMs: self.startMs,
                    endMs: self.endMs,
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

    func buildOptions() throws -> CaptureOptions {
        let maxFrames = max(self.maxFrames ?? 10000, 1)
        let resolutionCap = self.resolutionCap ?? 1440
        let diffStrategy = try CaptureCommandOptionParser.diffStrategy(self.diffStrategy)
        let diffBudgetMs = self.diffBudgetMs ?? (diffStrategy == .quality ? 30 : nil)
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
            .framesDropped)), contact sheet: \(meta.contactPath)
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

@MainActor
extension CaptureVideoCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.input = try values.requiredPositional(0, label: "input")
        self.sampleFps = try values.decodeOption("sampleFps", as: Double.self)
        self.everyMs = try values.decodeOption("everyMs", as: Int.self)
        self.startMs = try values.decodeOption("startMs", as: Int.self)
        self.endMs = try values.decodeOption("endMs", as: Int.self)
        if values.flag("noDiff") {
            self.noDiff = true
        }
        self.maxFrames = try values.decodeOption("maxFrames", as: Int.self)
        self.maxMb = try values.decodeOption("maxMb", as: Int.self)
        self.resolutionCap = try values.decodeOption("resolutionCap", as: Double.self)
        self.diffStrategy = values.singleOption("diffStrategy")
        self.diffBudgetMs = try values.decodeOption("diffBudgetMs", as: Int.self)
        self.path = values.singleOption("path")
        self.autocleanMinutes = try values.decodeOption("autocleanMinutes", as: Int.self)
        self.videoOut = values.singleOption("videoOut")
    }
}
