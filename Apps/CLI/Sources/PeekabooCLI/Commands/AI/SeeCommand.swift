import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Capture a screenshot and build an interactive UI map
@available(macOS 14.0, *)
struct SeeCommand: ApplicationResolvable, ErrorHandlingCommand, RuntimeOptionsConfigurable {
    @Option(help: "Application name to capture, or special values: 'menubar', 'frontmost'")
    var app: String?

    @Option(name: .long, help: "Target application by process ID")
    var pid: Int32?

    @Option(help: "Specific window title to capture")
    var windowTitle: String?

    @Option(
        name: .long,
        help: "Target window by CoreGraphics window id (window_id from `peekaboo window list --json`)"
    )
    var windowId: Int?

    @Option(help: "Capture mode (screen, window, frontmost)")
    var mode: PeekabooCore.CaptureMode?

    @Option(
        names: [.automatic, .customLong("save"), .customLong("output"), .customShort("o", allowingJoined: false)],
        help: "Output path for screenshot (aliases: --save, --output, -o)"
    )
    var path: String?

    @Option(
        name: .long,
        help: "Specific screen index to capture (0-based). If not specified, captures all screens when in screen mode"
    )
    var screenIndex: Int?

    @Flag(help: "Generate annotated screenshot with interaction markers")
    var annotate = false

    @Flag(name: .long, help: "Capture menu bar popovers via window list + OCR")
    var menubar = false

    @Option(help: "Analyze captured content with AI")
    var analyze: String?

    @Option(
        name: .long,
        help: """
        Overall timeout in seconds (default: 20, or 60 when --analyze is set).
        Increase this if element detection regularly times out for large/complex windows.
        """
    )
    var timeoutSeconds: Int?

    @Option(
        name: .long,
        help: """
        Capture engine: auto|modern|sckit|classic|cg (default: auto).
        modern/sckit force ScreenCaptureKit; classic/cg force CGWindowList;
        auto tries CGWindowList then falls back when allowed.
        """
    )
    var captureEngine: String?

    @Flag(help: "Skip web-content focus fallback when no text fields are detected")
    var noWebFocus = false

    @Option(name: .long, help: "Maximum AX traversal depth (env: PEEKABOO_AX_MAX_DEPTH)")
    var maxDepth: Int?

    @Option(name: .long, help: "Maximum AX elements to collect (env: PEEKABOO_AX_MAX_ELEMENTS)")
    var maxElements: Int?

    @Option(name: .long, help: "Maximum AX children per node (env: PEEKABOO_AX_MAX_CHILDREN)")
    var maxChildren: Int?

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }

    var verbose: Bool {
        self.runtime?.configuration.verbose ?? self.runtimeOptions.verbose
    }

    var logger: Logger {
        self.resolvedRuntime.logger
    }

    var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    var outputLogger: Logger {
        self.logger
    }

    var configuredCaptureEnginePreference: String? {
        self.runtime?.configuration.captureEnginePreference
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let commandStartedAt = Date()
        let logger = self.logger
        let overallTimeout = TimeInterval(self.timeoutSeconds ?? ((self.analyze == nil) ? 20 : 60))
        let mutationCoordinator = runtime.toolSnapshotMutationCoordinator
        let snapshotManager = runtime.services.snapshots

        logger.operationStart("see_command", metadata: [
            "app": self.app ?? "none",
            "mode": self.mode?.rawValue ?? "auto",
            "annotate": self.annotate,
            "menubar": self.menubar,
            "hasAnalyzePrompt": self.analyze != nil,
        ])

        let commandCopy = self

        do {
            runtime.beginInteractionMutation(preservingSnapshotsCreatedAfterBoundary: true)
            try await CrossProcessOperationGate.withExclusiveOperation(
                named: CrossProcessOperationGate.desktopObservationName
            ) {
                let observationStartedAt = Date()
                let observationDeadline = observationStartedAt.addingTimeInterval(overallTimeout)
                let scope = MCPToolSnapshotMutationScope(
                    toolName: "see",
                    startedAt: observationStartedAt,
                    effect: .mutationProducingFreshObservation
                )
                let reservationTimeout = try Self.remainingObservationTimeout(
                    until: observationDeadline,
                    overallTimeout: overallTimeout
                )
                let snapshotID = try await Self.withWallClockTimeout(
                    seconds: reservationTimeout,
                    timeoutErrorSeconds: overallTimeout
                ) {
                    try await snapshotManager.createSnapshot(pendingAt: observationStartedAt)
                }
                var observationCompleted = false
                do {
                    let preparationTimeout = try Self.remainingObservationTimeout(
                        until: observationDeadline,
                        overallTimeout: overallTimeout
                    )
                    let context = try await Self.withWallClockTimeout(
                        seconds: preparationTimeout,
                        timeoutErrorSeconds: overallTimeout,
                        interactionMutationTracker: runtime.observationTimeoutMutationTracker
                    ) {
                        try await commandCopy.prepareResult(
                            startTime: commandStartedAt,
                            logger: logger,
                            snapshotID: snapshotID
                        )
                    }
                    observationCompleted = true

                    let publicationTimeout = try Self.remainingObservationTimeout(
                        until: observationDeadline,
                        overallTimeout: overallTimeout
                    )
                    let published = try await Self.withWallClockTimeout(
                        seconds: publicationTimeout,
                        timeoutErrorSeconds: overallTimeout
                    ) {
                        await mutationCoordinator.completeMutation(
                            scope.completed(
                                at: Date(),
                                preserving: snapshotID,
                                confirmedMutationCompletedAt: context.metadata.desktopMutationCompletedAt,
                                observationPreservationAllowed: context.metadata
                                    .desktopMutationPreservationAllowed
                            ),
                            succeeded: true
                        )
                    }
                    guard published else {
                        throw PeekabooError.operationError(
                            message: "Failed to publish the refreshed UI snapshot"
                        )
                    }

                    try Task.checkCancellation()
                    try commandCopy.renderResults(context: context)
                    commandCopy.emitAnnotationStatus(context: context)
                    logger.operationComplete("see_command", metadata: [
                        "executionTimeMs": Int(Date().timeIntervalSince(commandStartedAt) * 1000),
                        "success": true,
                    ])
                } catch {
                    if observationCompleted || !PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: error) {
                        try? await self.services.snapshots.cleanSnapshot(snapshotId: snapshotID)
                    }
                    _ = await mutationCoordinator.completeMutation(
                        scope.completed(at: Date(), preserving: nil),
                        succeeded: false
                    )
                    throw error
                }
            }
        } catch {
            logger.operationComplete(
                "see_command",
                success: false,
                metadata: [
                    "error": error.localizedDescription,
                ]
            )
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private static func remainingObservationTimeout(
        until deadline: Date,
        overallTimeout: TimeInterval
    ) throws -> TimeInterval {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw CaptureError.detectionTimedOut(overallTimeout)
        }
        return remaining
    }

    private func prepareResult(
        startTime: Date,
        logger: Logger,
        snapshotID: String
    ) async throws -> SeeCommandRenderContext {
        // ScreenCaptureService performs the authoritative permission check inside each capture path.
        // Avoid duplicating that TCC probe here; `see` is often called in latency-sensitive loops.

        // Perform capture and element detection
        logger.verbose("Starting capture and detection phase", category: "Capture")
        let captureResult = try await performCaptureWithDetection(snapshotID: snapshotID)
        try Task.checkCancellation()
        logger.verbose("Capture completed successfully", category: "Capture", metadata: [
            "snapshotId": captureResult.snapshotId,
            "elementCount": captureResult.elements.all.count,
            "screenshotSize": self.getFileSize(captureResult.screenshotPath) ?? 0,
        ])

        // Generate annotated screenshot if requested
        var annotatedPath = captureResult.annotatedPath
        let annotationsAllowed = self.allowsAnnotationForCurrentCapture()
        if self.annotate, !annotationsAllowed {
            self.logger.info("Annotation is disabled for full screen captures due to performance constraints")
        }
        if self.annotate, annotatedPath == nil, annotationsAllowed {
            logger.operationStart("generate_annotations")
            annotatedPath = try await self.generateAnnotatedScreenshot(
                snapshotId: captureResult.snapshotId,
                originalPath: captureResult.screenshotPath
            )
            try Task.checkCancellation()
            if let annotatedPath,
               annotatedPath != captureResult.screenshotPath {
                try await self.services.snapshots.storeAnnotatedScreenshot(
                    snapshotId: captureResult.snapshotId,
                    annotatedScreenshotPath: annotatedPath
                )
                try Task.checkCancellation()
            }
            logger.operationComplete("generate_annotations", metadata: [
                "annotatedPath": annotatedPath ?? "none",
            ])
        }
        // Perform AI analysis if requested
        var analysisResult: SeeAnalysisData?
        if let prompt = analyze {
            // Pre-analysis diagnostics
            let fileSize = (try? FileManager.default
                .attributesOfItem(atPath: captureResult.screenshotPath)[.size] as? Int) ?? 0
            logger.verbose(
                "Starting AI analysis",
                category: "AI",
                metadata: [
                    "imagePath": captureResult.screenshotPath,
                    "imageSizeBytes": fileSize,
                    "promptLength": prompt.count
                ]
            )
            logger.operationStart("ai_analysis", metadata: ["promptPreview": String(prompt.prefix(80))])
            logger.startTimer("ai_generate")
            analysisResult = try await self.performAnalysisDetailed(
                imagePath: captureResult.screenshotPath,
                prompt: prompt
            )
            try Task.checkCancellation()
            logger.stopTimer("ai_generate")
            logger.operationComplete(
                "ai_analysis",
                success: analysisResult != nil,
                metadata: [
                    "provider": analysisResult?.provider ?? "unknown",
                    "model": analysisResult?.model ?? "unknown"
                ]
            )
        }

        let menuBarSummary = self.jsonOutput ? await self.fetchMenuBarSummaryIfEnabled() : nil
        try Task.checkCancellation()

        let executionTime = Date().timeIntervalSince(startTime)
        return SeeCommandRenderContext(
            snapshotId: captureResult.snapshotId,
            screenshotPath: captureResult.screenshotPath,
            annotatedPath: annotatedPath,
            metadata: captureResult.metadata,
            elements: captureResult.elements,
            analysis: analysisResult,
            executionTime: executionTime,
            observation: captureResult.observation,
            menuBar: menuBarSummary
        )
    }

    private func emitAnnotationStatus(context: SeeCommandRenderContext) {
        let annotationsAllowed = self.allowsAnnotationForCurrentCapture()
        if self.annotate, annotationsAllowed, context.annotatedPath == nil, !self.jsonOutput {
            print("\(AgentDisplayTokens.Status.warning)  No interactive UI elements found to annotate")
        } else if self.annotate, annotationsAllowed, let annotatedPath = context.annotatedPath, !self.jsonOutput {
            let interactableElements = context.elements.all.filter(\.isEnabled)
            print("📝 Created annotated screenshot with \(interactableElements.count) interactive elements")
            self.logger.verbose("Annotated screenshot path: \(annotatedPath)")
        }
    }

    func getFileSize(_ path: String) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int
    }

    func allowsAnnotationForCurrentCapture() -> Bool {
        if self.app?.lowercased() == "menubar" {
            return false
        }

        return switch self.determineMode() {
        case .screen, .multi:
            false
        case .window, .frontmost:
            true
        case .area:
            false
        }
    }
}

@MainActor
extension SeeCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            let definition = VisionToolDefinitions.see.commandConfiguration
            return CommandDescription(
                commandName: definition.commandName,
                abstract: definition.abstract,
                discussion: definition.discussion,
                usageExamples: [
                    CommandUsageExample(
                        command: "peekaboo see --json --annotate --path /tmp/see.png",
                        description: "Capture the frontmost window, print structured output, and save annotations."
                    ),
                    CommandUsageExample(
                        command: "peekaboo see --app Safari --window-title \"Login\" --json --path /tmp/safari-login.png",
                        description: "Target a specific Safari window to collect fresh element IDs and keep the capture artifact in /tmp."
                    ),
                    CommandUsageExample(
                        command: "peekaboo see --mode screen --screen-index 0 --analyze 'Summarize the dashboard'",
                        description: "Capture a display and immediately send it to the configured AI provider."
                    )
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension SeeCommand: AsyncRuntimeCommand {}

@MainActor
extension SeeCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.windowTitle = values.singleOption("windowTitle")
        self.windowId = try values.decodeOption("windowId", as: Int.self)
        if let parsedMode: PeekabooCore.CaptureMode = try values.decodeOptionEnum("mode", caseInsensitive: false) {
            guard parsedMode != .area else {
                throw CommanderBindingError.invalidArgument(
                    label: "mode",
                    value: parsedMode.rawValue,
                    reason: "`see` supports screen, window, frontmost, or multi"
                )
            }
            self.mode = parsedMode
        }
        self.path = values.singleOption("path")
        self.screenIndex = try values.decodeOption("screenIndex", as: Int.self)
        self.captureEngine = values.singleOption("captureEngine")
        self.annotate = values.flag("annotate")
        self.analyze = values.singleOption("analyze")
        self.timeoutSeconds = try values.decodeOption("timeoutSeconds", as: Int.self)
        self.noWebFocus = values.flag("noWebFocus")
        self.menubar = values.flag("menubar")
    }
}
