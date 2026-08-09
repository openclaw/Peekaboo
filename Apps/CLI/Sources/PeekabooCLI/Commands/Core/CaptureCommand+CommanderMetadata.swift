import Commander

extension CaptureCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(options: [], flags: [])
    }
}

extension CaptureLiveCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("app", help: "Target application name, bundle ID, or 'PID:12345'", long: "app"),
                .commandOption("pid", help: "Target application by process ID", long: "pid"),
                .commandOption(
                    "mode",
                    help: "Capture mode (screen, window, frontmost, area; region alias accepted)",
                    long: "mode"
                ),
                .commandOption("windowTitle", help: "Capture window with specific title", long: "window-title"),
                .commandOption("windowIndex", help: "Window index to capture", long: "window-index"),
                .commandOption("screenIndex", help: "Screen index for screen captures", long: "screen-index"),
                .commandOption("region", help: "Region to capture: x,y,width,height", long: "region"),
                .commandOption(
                    "captureFocus",
                    help: "Focus behavior: background (default), foreground (activate target), or legacy auto",
                    long: "capture-focus"
                ),
                .commandOption(
                    "captureEngine",
                    help: "Capture engine: auto|classic|cg|modern|sckit (defaults to auto)",
                    long: "capture-engine"
                ),
                .commandOption("duration", help: "Duration seconds (default 60, max 180)", long: "duration"),
                .commandOption("idleFps", help: "Idle FPS (default 2)", long: "idle-fps"),
                .commandOption("activeFps", help: "Active FPS (default 8, max 15)", long: "active-fps"),
                .commandOption("threshold", help: "Change threshold percent (default 2.5)", long: "threshold"),
                .commandOption("heartbeatSec", help: "Heartbeat interval seconds (default 5)", long: "heartbeat-sec"),
                .commandOption("quietMs", help: "Calm period before idle (default 1000)", long: "quiet-ms"),
                .commandOption("maxFrames", help: "Soft frame cap (default 800)", long: "max-frames"),
                .commandOption("maxMb", help: "Soft size cap MB", long: "max-mb"),
                .commandOption("resolutionCap", help: "Cap longest side px (default 1440)", long: "resolution-cap"),
                .commandOption("diffStrategy", help: "Diff strategy fast|quality", long: "diff-strategy"),
                .commandOption("diffBudgetMs", help: "Diff budget ms", long: "diff-budget-ms"),
                .commandOption("path", help: "Output directory", long: "path"),
                .commandOption(
                    "autocleanMinutes",
                    help: "Minutes before temp sessions auto-clean (default 120)",
                    long: "autoclean-minutes"
                ),
                .commandOption("videoOut", help: "Optional MP4 output path", long: "video-out"),
            ],
            flags: [
                .commandFlag("highlightChanges", help: "Overlay motion boxes", long: "highlight-changes"),
            ]
        )
    }
}

extension CaptureVideoCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "input",
                    help: "Input video file",
                    isOptional: false
                ),
            ],
            options: [
                .commandOption("sampleFps", help: "Sample FPS (default 2)", long: "sample-fps"),
                .commandOption("everyMs", help: "Sample every N ms", long: "every-ms"),
                .commandOption("startMs", help: "Trim start ms", long: "start-ms"),
                .commandOption("endMs", help: "Trim end ms", long: "end-ms"),
                .commandOption("maxFrames", help: "Soft frame cap", long: "max-frames"),
                .commandOption("maxMb", help: "Soft size cap MB", long: "max-mb"),
                .commandOption("resolutionCap", help: "Cap longest side px (default 1440)", long: "resolution-cap"),
                .commandOption("diffStrategy", help: "Diff strategy fast|quality", long: "diff-strategy"),
                .commandOption("diffBudgetMs", help: "Diff budget ms", long: "diff-budget-ms"),
                .commandOption("path", help: "Output directory", long: "path"),
                .commandOption("autocleanMinutes", help: "Autoclean minutes", long: "autoclean-minutes"),
                .commandOption("videoOut", help: "Optional MP4 output path", long: "video-out"),
            ],
            flags: [
                .commandFlag("noDiff", help: "Keep all sampled frames", long: "no-diff"),
            ]
        )
    }
}

extension CaptureWatchAlias: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CaptureLiveCommand.commanderSignature()
    }
}
