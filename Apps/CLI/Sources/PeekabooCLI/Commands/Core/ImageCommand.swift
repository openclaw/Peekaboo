import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

private typealias CaptureMode = PeekabooCore.CaptureMode
private typealias ImageFormat = PeekabooCore.ImageFormat
private typealias CaptureFocus = PeekabooCore.CaptureFocus

@MainActor
struct ImageCommand: ApplicationResolvable, ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Option(name: .long, help: "Target application name, bundle ID, 'PID:12345', 'menubar', or 'frontmost'")
    var app: String?

    @Option(name: .long, help: "Target application by process ID")
    var pid: Int32?

    @Option(name: .long, help: "Output path for saved image, or '-' to write one image to stdout")
    var path: String?

    @Option(name: .long, help: "Capture mode (screen, window, frontmost, multi, area)")
    var mode: PeekabooCore.CaptureMode?

    @Option(name: .long, help: "Capture window with specific title")
    var windowTitle: String?

    @Option(name: .long, help: "Window index to capture")
    var windowIndex: Int?

    @Option(
        name: .long,
        help: "Target window by CoreGraphics window id (window_id from `peekaboo window list --json`)"
    )
    var windowId: Int?

    @Option(name: .long, help: "Screen index for screen captures")
    var screenIndex: Int?

    @Option(name: .long, help: "Region for area captures as x,y,width,height in global display coordinates")
    var region: String?

    @Flag(name: .long, help: "Capture at native Retina scale (default stores 1x logical resolution)")
    var retina: Bool = false

    @Option(
        name: .long,
        help: """
        Capture engine: auto|modern|sckit|classic|cg (default: auto).
        modern/sckit force ScreenCaptureKit; classic/cg force CGWindowList;
        auto tries CGWindowList then falls back when allowed.
        """
    )
    var captureEngine: String?

    @Option(name: .long, help: "Image format: png or jpg")
    var format: PeekabooCore.ImageFormat = .png

    @Option(
        name: .long,
        help: "Focus behavior: background (default), foreground (activate target), or legacy auto"
    )
    var captureFocus: PeekabooCore.CaptureFocus = .background

    @Option(name: .long, help: "Analyze the captured image with AI")
    var analyze: String?
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

    var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    func withCaptureFocusMutation(_ operation: () async throws -> Void) async rethrows {
        try await self.resolvedRuntime.withCaptureFocusMutation(operation)
    }

    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }

    var outputLogger: Logger {
        self.logger
    }

    var configuredCaptureEnginePreference: String? {
        self.resolvedRuntime.configuration.captureEnginePreference
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        let startMetadata: [String: Any] = [
            "mode": mode?.rawValue ?? "auto",
            "app": self.app ?? "none",
            "pid": self.pid ?? 0,
            "hasAnalyzePrompt": self.analyze != nil,
        ]
        self.logger.operationStart("image_command", metadata: startMetadata)

        do {
            try validateStdoutStreamingOptions()

            // ScreenCaptureService performs the authoritative permission check inside each capture path.
            // Avoid preflighting here too; it adds fixed latency to every one-shot screenshot.
            let captures = try await CrossProcessOperationGate.withExclusiveOperation(
                named: CrossProcessOperationGate.desktopObservationName
            ) {
                try await performCapture()
            }

            if streamsImageToStdout {
                try outputImageToStdout(captures)
            } else if let prompt = analyze, let firstFile = captures.first?.file {
                let analysis = try await analyzeImage(at: firstFile.path, with: prompt)
                outputResultsWithAnalysis(captures, analysis: analysis)
            } else {
                outputResults(captures)
            }

            self.logger.operationComplete("image_command", success: true)
        } catch {
            handleError(error)
            self.logger.operationComplete(
                "image_command",
                success: false,
                metadata: ["error": error.localizedDescription]
            )
            throw ExitCode(1)
        }
    }
}

@MainActor
extension ImageCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "image",
                abstract: "Capture screenshots",
                version: "1.0.0"
            )
        }
    }
}

extension ImageCommand: AsyncRuntimeCommand {}

@MainActor
extension ImageCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        path = values.singleOption("path")
        if let parsedMode: CaptureMode = try values.decodeOptionEnum("mode") {
            self.mode = parsedMode
        }
        self.windowTitle = values.singleOption("windowTitle")
        self.windowIndex = try values.decodeOption("windowIndex", as: Int.self)
        self.windowId = try values.decodeOption("windowId", as: Int.self)
        self.screenIndex = try values.decodeOption("screenIndex", as: Int.self)
        self.region = values.singleOption("region")
        self.captureEngine = values.singleOption("captureEngine")
        let parsedFormat: ImageFormat? = try values.decodeOptionEnum("format")
        if let parsedFormat {
            self.format = parsedFormat
        }
        if let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let ext = URL(fileURLWithPath: expanded).pathExtension.lowercased()
            let inferred: ImageFormat? = if ext == "jpg" || ext == "jpeg" {
                .jpg
            } else if ext == "png" {
                .png
            } else {
                nil
            }
            if let parsedFormat, let inferred, parsedFormat != inferred {
                throw CommanderBindingError.invalidArgument(
                    label: "path",
                    value: path,
                    reason: "Conflicts with --format \(parsedFormat.rawValue). " +
                        "Use a .\(parsedFormat.fileExtension) path (or omit --format)."
                )
            }
            if parsedFormat == nil, let inferred {
                self.format = inferred
            }
        }
        if let parsedFocus: CaptureFocus = try values.decodeOptionEnum("captureFocus") {
            self.captureFocus = parsedFocus
        }
        self.analyze = values.singleOption("analyze")
        self.retina = values.flag("retina")
    }
}
