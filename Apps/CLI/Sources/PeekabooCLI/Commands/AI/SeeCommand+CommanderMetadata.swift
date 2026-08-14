import Commander

extension SeeCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "app",
                    help: "Application name or bundle ID; mutually exclusive with --pid (also: menubar, frontmost)",
                    long: "app"
                ),
                .commandOption(
                    "pid",
                    help: "Target application by process ID; mutually exclusive with --app",
                    long: "pid"
                ),
                .commandOption(
                    "windowTitle",
                    help: "Window title selector; requires --app or --pid",
                    long: "window-title"
                ),
                .commandOption(
                    "windowIndex",
                    help: "Window index selector; requires --app or --pid",
                    long: "window-index"
                ),
                .commandOption(
                    "windowId",
                    help: "CoreGraphics window ID; may be used without --app/--pid "
                        + "(from `peekaboo window list --json`)",
                    long: "window-id"
                ),
                .commandOption(
                    "mode",
                    help: "Capture mode (screen, window, frontmost, multi, area)",
                    long: "mode"
                ),
                .commandOption(
                    "region",
                    help: "Region for area captures as x,y,width,height",
                    long: "region"
                ),
                .commandOption(
                    "roi",
                    help: "Exact-window crop as x,y,width,height in window-local logical points",
                    long: "roi"
                ),
                .commandOption(
                    "format",
                    help: "Image format (png or jpg)",
                    long: "format"
                ),
                .make(
                    label: "path",
                    names: [
                        .long("path"),
                        .aliasLong("save"),
                        .aliasLong("output"),
                        .short("o"),
                    ],
                    help: "Output path for screenshot (aliases: --save, --output, -o)",
                    parsing: .singleValue
                ),
                .commandOption(
                    "captureEngine",
                    help: "Capture engine on the selected host: auto|classic|cg|modern|sckit; " +
                        "--no-remote --capture-engine modern requests caller-local ownership and refuses on contention",
                    long: "capture-engine"
                ),
                .commandOption(
                    "screenIndex",
                    help: "Specific screen index to capture (0-based)",
                    long: "screen-index"
                ),
                .commandOption(
                    "analyze",
                    help: "Analyze captured content with AI",
                    long: "analyze"
                ),
                .commandOption(
                    "timeout",
                    help: "Overall timeout; bare values are milliseconds (default: 20s, or 60s with --analyze)",
                    long: "timeout"
                ),
                .commandOption(
                    "depth",
                    help: "Maximum AX traversal depth (env: PEEKABOO_AX_MAX_DEPTH)",
                    long: "depth"
                ),
                .commandOption(
                    "maxElements",
                    help: "Maximum AX elements to collect (env: PEEKABOO_AX_MAX_ELEMENTS)",
                    long: "max-elements"
                ),
                .commandOption(
                    "maxChildren",
                    help: "Maximum AX children per node (env: PEEKABOO_AX_MAX_CHILDREN)",
                    long: "max-children"
                ),
            ],
            flags: [
                .commandFlag(
                    "annotate",
                    help: "Generate annotated screenshot with interaction markers",
                    long: "annotate"
                ),
                .commandFlag(
                    "retina",
                    help: "Capture at native Retina resolution instead of 1x logical",
                    long: "retina"
                ),
                .commandFlag(
                    "noElements",
                    help: "Skip element detection; exact --window-id captures still publish a coordinate receipt",
                    long: "no-elements"
                ),
                .commandFlag(
                    "ocr",
                    help: "Add host-local Vision OCR text to the accessibility element map",
                    long: "ocr"
                ),
                .commandFlag(
                    "tree",
                    help: "Print the accessibility text tree",
                    long: "tree"
                ),
                .commandFlag(
                    "noScreenshot",
                    help: "Skip image capture; requires --tree",
                    long: "no-screenshot"
                ),
                .commandFlag(
                    "menubar",
                    help: "Capture menu bar popovers via window list + OCR",
                    long: "menubar"
                ),
                .commandFlag(
                    "webFocus",
                    help: "Allow an AXPress web-content focus retry for sparse Chromium/Tauri trees",
                    long: "web-focus"
                ),
                .commandFlag(
                    "noWebFocus",
                    help: "Deprecated no-op; web-content focus retries are disabled by default",
                    long: "no-web-focus"
                ),
            ]
        )
    }
}
