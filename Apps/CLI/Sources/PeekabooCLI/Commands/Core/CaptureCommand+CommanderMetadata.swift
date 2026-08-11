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
                    help: "Capture engine: auto (default)|classic|cg|modern|sckit; modern, or auto fallback, " +
                        "owns in-process SCK for this process lifetime",
                    long: "capture-engine"
                ),
                .commandOption(
                    "duration",
                    help: "Duration; bare values are milliseconds (default 60s, max 180s)",
                    long: "duration"
                ),
                .commandOption(
                    "idleFps",
                    help: "Idle FPS (default 2; finite range 0.1...5)",
                    long: "idle-fps"
                ),
                .commandOption(
                    "activeFps",
                    help: "Active FPS (default 8; finite range 0.5...15; must be >= idle FPS)",
                    long: "active-fps"
                ),
                .commandOption(
                    "threshold",
                    help: "Whole-frame change percent to keep motion frames (default 2.5; 0 keeps all)",
                    long: "threshold"
                ),
                .commandOption("heartbeat", help: "Heartbeat interval (default 5s)", long: "heartbeat"),
                .commandOption("quiet", help: "Calm period before idle (default 1s)", long: "quiet"),
                .commandOption("maxFrames", help: "Soft frame cap (default 800)", long: "max-frames"),
                .commandOption("maxMb", help: "Soft size cap MB", long: "max-mb"),
                .commandOption("resolutionCap", help: "Cap longest side px (default 1440)", long: "resolution-cap"),
                .commandOption("diffStrategy", help: "Diff strategy fast|quality", long: "diff-strategy"),
                .commandOption("diffBudget", help: "Diff time budget", long: "diff-budget"),
                .commandOption("path", help: "Output directory", long: "path"),
                .commandOption(
                    "autoclean",
                    help: "Time before temp sessions auto-clean (default 7200s)",
                    long: "autoclean"
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
                .commandOption("every", help: "Sampling interval", long: "every"),
                .commandOption("start", help: "Trim start offset", long: "start"),
                .commandOption("end", help: "Trim end offset", long: "end"),
                .commandOption("maxFrames", help: "Soft frame cap", long: "max-frames"),
                .commandOption("maxMb", help: "Soft size cap MB", long: "max-mb"),
                .commandOption("resolutionCap", help: "Cap longest side px (default 1440)", long: "resolution-cap"),
                .commandOption("diffStrategy", help: "Diff strategy fast|quality", long: "diff-strategy"),
                .commandOption("diffBudget", help: "Diff time budget", long: "diff-budget"),
                .commandOption("path", help: "Output directory", long: "path"),
                .commandOption("autoclean", help: "Time before temp sessions auto-clean", long: "autoclean"),
                .commandOption("videoOut", help: "Optional MP4 output path", long: "video-out"),
            ],
            flags: [
                .commandFlag("noDiff", help: "Keep all sampled frames", long: "no-diff"),
            ]
        )
    }
}
