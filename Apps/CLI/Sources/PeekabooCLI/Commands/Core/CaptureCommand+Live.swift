import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
struct CaptureLiveCommand: ApplicationResolvable, ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable,
InjectedRuntimeBackedCommand {
    // Targeting
    @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'") var app: String?
    @Option(name: .long, help: "Target application by process ID") var pid: Int32?
    @Option(
        name: .long,
        help: "Capture mode (screen, window, frontmost, area; region alias accepted)"
    ) var mode: String?
    @Option(name: .long, help: "Capture window with specific title") var windowTitle: String?
    @Option(name: .long, help: "Window index to capture") var windowIndex: Int?
    @Option(name: .long, help: "Screen index for screen captures") var screenIndex: Int?
    @Option(name: .long, help: "Region to capture as x,y,width,height (global display coordinates)") var region: String?
    @Option(
        name: .long,
        help: "Focus behavior: background (default), foreground (activate target), " +
            "or legacy auto"
    ) var captureFocus: LiveCaptureFocus =
        .background
    @Option(
        name: .long,
        help: """
        Capture engine: auto|modern|sckit|classic|cg (default: auto).
        modern/sckit force ScreenCaptureKit; classic/cg force CGWindowList;
        auto tries CGWindowList then falls back when allowed.
        """
    ) var captureEngine: String?

    // Behavior
    @Option(name: .long, help: "Duration (bare values are milliseconds; default 60s, max 180s)")
    var duration: CLIDuration?
    @Option(name: .long, help: "Idle FPS during quiet periods (default 2, range 0.1...5)") var idleFps: Double?
    @Option(name: .long, help: "Active FPS during motion (default 8, range 0.5...15; must be >= idle)")
    var activeFps: Double?
    @Option(name: .long, help: "Whole-frame change percent to keep motion frames (default 2.5; 0 keeps all)")
    var threshold: Double?
    @Option(
        name: .customLong("heartbeat"),
        help: "Heartbeat keyframe interval (default 5s, 0 disables)"
    ) var heartbeat: CLIDuration?
    @Option(name: .customLong("quiet"), help: "Calm period before returning to idle (default 1s)")
    var quiet: CLIDuration?
    @Flag(name: .long, help: "Overlay motion boxes on kept frames") var highlightChanges = false
    @Option(name: .long, help: "Max frames before stopping (soft cap, default 800)") var maxFrames: Int?
    @Option(name: .long, help: "Max megabytes before stopping (soft cap, optional)") var maxMb: Int?
    @Option(name: .long, help: "Resolution cap (largest dimension, default 1440)") var resolutionCap: Double?
    @Option(name: .long, help: "Diff strategy: fast|quality (default fast)") var diffStrategy: String?
    @Option(
        name: .customLong("diff-budget"),
        help: "Diff time budget in milliseconds before falling back to fast " +
            "(default 30 when quality)"
    ) var diffBudget: CLIDuration?

    /// Output
    @Option(name: .long, help: "Output directory (defaults to temp capture session)") var path: String?
    @Option(name: .customLong("autoclean"), help: "Time before temp sessions auto-clean (default 7200s)")
    var autoclean: CLIDuration?
    @Option(name: .long, help: "Optional MP4 output path (built from kept frames)") var videoOut: String?

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()
    var captureMutationDispatched = false

    func withCaptureFocusMutation(_ operation: () async throws -> Void) async rethrows {
        try await self.resolvedRuntime.withCaptureFocusMutation(operation)
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        self.logger.operationStart("capture_live", metadata: ["mode": self.mode ?? "auto"])

        do {
            // The capture service performs the authoritative permission check inside
            // the serialized capture transaction; an extra CLI-side SCK probe can race
            // with concurrent screenshot commands and report transient TCC denial.
            let scope = try await resolveScope()
            let options = try buildOptions()
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
            let runSession: @MainActor @Sendable () async throws -> CaptureSessionResult = {
                try await session.run()
            }
            let enginePreference = liveCaptureEnginePreference(for: scope)
            let result: CaptureSessionResult = if let engineAware = services.screenCapture
                as? any EngineAwareScreenCaptureServiceProtocol {
                try await engineAware.withCaptureEngine(enginePreference, operation: runSession)
            } else {
                try await runSession()
            }
            output(result)
            self.logger.operationComplete(
                "capture_live",
                success: true,
                metadata: ["frames_kept": result.stats.framesKept]
            )
        } catch {
            handleError(error)
            self.logger.operationComplete(
                "capture_live",
                success: false,
                metadata: ["error": error.localizedDescription]
            )
            throw ExitCode(1)
        }
    }
}

extension CaptureLiveCommand {
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
            // Live region capture samples repeatedly; CoreGraphics area capture is faster
            // and avoids SCK continuation leaks when observation commands overlap.
            return scope.kind == .region ? .legacy : .auto
        }
    }
}
