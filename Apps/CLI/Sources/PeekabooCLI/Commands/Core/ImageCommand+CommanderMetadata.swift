import Commander

extension ImageCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "app",
                    help: "Target application name, bundle ID, 'PID:12345', 'menubar', or 'frontmost'",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID",
                    long: "pid"
                ),
                .commandOption(
                    "path",
                    help: "Output path for saved image, or '-' to write one image to stdout",
                    long: "path"
                ),
                .commandOption(
                    "mode",
                    help: "Capture mode (screen, window, frontmost, multi, area)",
                    long: "mode"
                ),
                .commandOption(
                    "windowTitle",
                    help: "Capture window with specific title",
                    long: "window-title"
                ),
                .commandOption(
                    "windowIndex",
                    help: "Window index to capture",
                    long: "window-index"
                ),
                .commandOption(
                    "windowId",
                    help: "Capture window by CoreGraphics window id (window_id from `peekaboo window list --json`)",
                    long: "window-id"
                ),
                .commandOption(
                    "screenIndex",
                    help: "Screen index for screen captures",
                    long: "screen-index"
                ),
                .commandOption(
                    "region",
                    help: "Region for area captures as x,y,width,height in global display coordinates",
                    long: "region"
                ),
                .commandOption(
                    "captureEngine",
                    help: "Capture engine: auto|classic|cg|modern|sckit (defaults to auto)",
                    long: "capture-engine"
                ),
                .commandOption(
                    "format",
                    help: "Image format (png or jpg)",
                    long: "format"
                ),
                .commandOption(
                    "captureFocus",
                    help: "Focus behavior: background (default), foreground (activate target), or legacy auto",
                    long: "capture-focus"
                ),
                .commandOption(
                    "analyze",
                    help: "Analyze the captured image with AI",
                    long: "analyze"
                ),
            ],
            flags: [
                .commandFlag(
                    "retina",
                    help: "Capture at native Retina resolution instead of 1x logical",
                    long: "retina"
                ),
            ]
        )
    }
}
