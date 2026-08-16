import AppKit
import Commander
import CoreGraphics
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation

/// Capture a screenshot and build an interactive UI map
@available(macOS 14.0, *)
struct SeeCommand: ApplicationResolvable, ErrorHandlingCommand, PreRuntimeValidatingCommand,
RuntimeBackedCommand {
    @Option(
        help: "Application name or bundle ID; mutually exclusive with --pid (also: menubar, frontmost)"
    )
    var app: String?

    @Option(name: .long, help: "Target application by process ID; mutually exclusive with --app")
    var pid: Int32?

    @Option(help: "Window title selector; requires --app or --pid")
    var windowTitle: String?

    @Option(help: "Window index selector; requires --app or --pid")
    var windowIndex: Int?

    @Option(
        name: .long,
        help:
        "CoreGraphics window ID; may be used without --app/--pid (from `peekaboo window list --json`)"
    )
    var windowId: Int?

    @Option(help: "Capture mode (screen, window, frontmost, multi, area)")
    var mode: PeekabooCore.CaptureMode?

    @Option(help: "Region for area captures as x,y,width,height in global display coordinates")
    var region: String?

    @Option(help: "Crop an exact --window-id as x,y,width,height in window-local logical points")
    var roi: String?

    @Option(help: "Image format: png or jpg")
    var format: PeekabooCore.ImageFormat = .png

    @Flag(help: "Capture at native Retina scale (default stores 1x logical resolution)")
    var retina = false

    @Option(
        names: [
            .automatic, .customLong("save"), .customLong("output"),
            .customShort("o", allowingJoined: false),
        ],
        help: "Output path for screenshot (aliases: --save, --output, -o)"
    )
    var path: String?

    @Option(
        name: .long,
        help:
        "Specific screen index to capture (0-based). If not specified, captures all screens when in screen mode"
    )
    var screenIndex: Int?

    @Flag(help: "Generate annotated screenshot with interaction markers")
    var annotate = false

    @Flag(
        help: "Skip element detection; exact --window-id captures still publish a coordinate receipt"
    )
    var noElements = false

    @Flag(help: "Add host-local Vision OCR text to the accessibility element map")
    var ocr = false

    @Flag(help: "Print the accessibility text tree")
    var tree = false

    @Flag(help: "Skip image capture; requires --tree")
    var noScreenshot = false

    @Flag(name: .long, help: "Capture menu bar popovers via window list + OCR")
    var menubar = false

    @Option(help: "Analyze captured content with AI")
    var analyze: String?

    @Option(
        name: .long,
        help: """
        Overall timeout (bare values are milliseconds; default: 20s, or 60s with --analyze).
        Increase this if element detection regularly times out for large/complex windows.
        """
    )
    var timeout: CLIDuration?

    @Option(
        name: .long,
        help: """
        Capture engine: auto|modern|sckit|classic|cg (default: auto).
        modern/sckit force ScreenCaptureKit; classic/cg force CGWindowList;
        auto tries CGWindowList then falls back when allowed. The preference is sent to the
        selected Bridge host; add --no-remote to explicitly capture in the caller process.
        """
    )
    var captureEngine: String?

    @Flag(help: "Allow an AXPress web-content focus retry for sparse Chromium/Tauri trees")
    var webFocus = false

    @Flag(help: "Deprecated no-op; web-content focus retries are disabled by default")
    var noWebFocus = false

    @Option(name: .long, help: "Maximum AX traversal depth (env: PEEKABOO_AX_MAX_DEPTH)")
    var depth: Int?

    @Option(name: .long, help: "Maximum AX elements to collect (env: PEEKABOO_AX_MAX_ELEMENTS)")
    var maxElements: Int?

    @Option(name: .long, help: "Maximum AX children per node (env: PEEKABOO_AX_MAX_CHILDREN)")
    var maxChildren: Int?

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    var verbose: Bool {
        self.runtime?.configuration.verbose ?? self.runtimeOptions.verbose
    }

    var configuredCaptureEnginePreference: String? {
        self.runtime?.configuration.captureEnginePreference
    }

    var captureFocus: PeekabooCore.CaptureFocus {
        .background
    }

    var requiresExactObservationTarget: Bool {
        self.pid != nil || self.windowId != nil
    }

    func withCaptureFocusMutation(_ operation: () async throws -> Void) async rethrows {
        try await self.resolvedRuntime.withCaptureFocusMutation(operation)
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let commandStartedAt = Date()
        let logger = self.logger
        let overallTimeout = self.overallTimeoutSeconds
        let mutationCoordinator = runtime.toolSnapshotMutationCoordinator
        let snapshotManager = runtime.services.snapshots

        logger.operationStart(
            "see_command",
            metadata: [
                "app": self.app ?? "none",
                "mode": self.mode?.rawValue ?? "auto",
                "annotate": self.annotate,
                "menubar": self.menubar,
                "hasAnalyzePrompt": self.analyze != nil,
            ]
        )

        do {
            try self.validateBeforeRuntime()
            if let requiredHostFailure = runtime.requiredHostFailure {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: requiredHostFailure
                )
            }
            if self.usesPixelOnlyCapture {
                try await self.runPixelOnlyCapture()
                logger.operationComplete("see_command", metadata: ["success": true, "pixelOnly": true])
                return
            }
        } catch {
            logger.operationComplete(
                "see_command", success: false, metadata: ["error": error.localizedDescription]
            )
            self.handleSeeError(error)
            throw ExitCode.failure
        }

        let commandCopy = self
        let mayMutateDuringObservation = commandCopy.webFocus || commandCopy.menubar
        let actionProgress = mayMutateDuringObservation ? DesktopObservationActionProgress() : nil

        do {
            if mayMutateDuringObservation {
                runtime.beginInteractionMutation(preservingSnapshotsCreatedAfterBoundary: true)
            }
            let observationStartedAt = Date()
            let observationDeadline = observationStartedAt.addingTimeInterval(overallTimeout)
            let scope =
                mayMutateDuringObservation
                    ? MCPToolSnapshotMutationScope(
                        toolName: "see",
                        startedAt: observationStartedAt,
                        effect: .mutationProducingFreshObservation
                    )
                    : nil
            let reservationTimeout = try Self.remainingObservationTimeout(
                until: observationDeadline,
                overallTimeout: overallTimeout
            )
            let snapshotID = try await Self.withWallClockTimeout(
                seconds: reservationTimeout,
                timeoutErrorSeconds: overallTimeout
            ) {
                if scope != nil {
                    try await snapshotManager.createSnapshot(pendingAt: observationStartedAt)
                } else {
                    try await snapshotManager.createSnapshot()
                }
            }
            defer {
                if snapshotManager.copiesScreenshotArtifactsIntoStorage {
                    commandCopy.cleanupTemporaryScreenshotOutput(snapshotID: snapshotID)
                }
            }
            var observationCompleted = false
            var executionReceipt = SeeExecutionReceipt.none
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
                    try await DesktopObservationActionProgressContext.$current.withValue(actionProgress) {
                        try await commandCopy.prepareResult(
                            startTime: commandStartedAt,
                            logger: logger,
                            snapshotID: snapshotID,
                            observationTimeoutSeconds: preparationTimeout
                        )
                    }
                }
                observationCompleted = true
                executionReceipt = context.receipt

                if let scope {
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
                }

                try Task.checkCancellation()
                try commandCopy.renderResults(context: context)
                commandCopy.emitAnnotationStatus(context: context)
                logger.operationComplete(
                    "see_command",
                    metadata: [
                        "executionTimeMs": Int(Date().timeIntervalSince(commandStartedAt) * 1000),
                        "success": true,
                    ]
                )
            } catch {
                if scope == nil || observationCompleted
                    || !PendingSnapshotCleanupPolicy
                    .shouldPreserveReservation(after: error) {
                    try? await self.services.snapshots.cleanSnapshot(snapshotId: snapshotID)
                }
                if let scope {
                    _ = await mutationCoordinator.completeMutation(
                        scope.completed(at: Date(), preserving: nil),
                        succeeded: false
                    )
                }
                let projected = commandCopy.failurePreservingConditionalTimeout(
                    error,
                    progress: actionProgress?.latestReceipt
                )
                throw executionReceipt.preservingFailure(projected, operation: "see result publication")
            }
        } catch {
            logger.operationComplete(
                "see_command",
                success: false,
                metadata: [
                    "error": error.localizedDescription,
                ]
            )
            self.handleSeeError(error)
            throw ExitCode.failure
        }
    }

    var usesPixelOnlyCapture: Bool {
        self.noElements || self.streamsImageToStdout || self.determineMode() == .multi
            || self.determineMode() == .area
    }

    func validateMergedOptions() throws {
        try self.validateCaptureEngineOption()
        let resolvedMode = self.determineMode()
        let forcesPixelOnlyMode = resolvedMode == .area || resolvedMode == .multi
        try self.validateExactWindowIdentifier()
        try self.validatePresentationOptions(
            resolvedMode: resolvedMode,
            forcesPixelOnlyMode: forcesPixelOnlyMode
        )
        try self.validateROIOptions(resolvedMode: resolvedMode)
        try self.validateInteractionTargetSelectors()
        let windowSelectorCount = [
            self.windowTitle != nil, self.windowIndex != nil, self.windowId != nil,
        ]
            .count(where: { $0 })
        try self.validateSpecialCaptureTargets(windowSelectorCount: windowSelectorCount)
        guard !self.menubar else { return }
        try self.validateTarget(
            for: resolvedMode,
            windowSelectorCount: windowSelectorCount
        )
    }

    func validateBeforeRuntime() throws {
        try self.validateBeforeRuntime(environment: ProcessInfo.processInfo.environment)
    }

    func validateBeforeRuntime(environment: [String: String]) throws {
        try self.validateMergedOptions()
        try self.validateExplicitLocalProcessTarget(environment: environment)
    }

    private func validateExplicitLocalProcessTarget(environment: [String: String]) throws {
        guard let processIdentifier = try self.resolveExplicitPIDObservationTarget() else { return }
        guard processIdentifier > 0 else {
            throw ValidationError("--pid must be greater than 0")
        }
        guard
            RuntimeHostResolver.remoteIsolationRequested(
                options: self.runtimeOptions,
                environment: environment
            )
        else { return }
        guard let application = NSRunningApplication(processIdentifier: processIdentifier),
              !application.isTerminated
        else {
            throw ValidationError("No running application found for --pid \(processIdentifier).")
        }
    }

    private func validateCaptureEngineOption() throws {
        try ObservationCommandSupport.validateCaptureEngineValue(
            self.captureEngine ?? self.configuredCaptureEnginePreference
        )
    }

    private func validatePresentationOptions(
        resolvedMode: PeekabooCore.CaptureMode,
        forcesPixelOnlyMode: Bool
    ) throws {
        if self.tree, self.noElements {
            throw ValidationError("--tree cannot be combined with --no-elements")
        }
        if self.ocr, self.noElements {
            throw ValidationError("--ocr cannot be combined with --no-elements")
        }
        if self.ocr, self.noScreenshot {
            throw ValidationError("--ocr cannot be combined with --no-screenshot")
        }
        if self.ocr, forcesPixelOnlyMode || self.streamsImageToStdout {
            throw ValidationError(
                "--ocr requires screenshot-backed element detection for frontmost or app/window targets"
            )
        }
        if self.noScreenshot, !self.tree {
            throw ValidationError("--no-screenshot requires --tree")
        }
        if self.noScreenshot, self.annotate || self.analyze != nil {
            throw ValidationError("--no-screenshot cannot be combined with --annotate or --analyze")
        }
        if self.noScreenshot,
           resolvedMode == .screen || forcesPixelOnlyMode || self.screenIndex != nil || self.menubar
           || self.app?.lowercased() == "menubar" {
            throw ValidationError(
                "--no-screenshot supports frontmost or app/window accessibility targets only"
            )
        }
        if self.noElements, self.annotate {
            throw ValidationError("--annotate requires element detection")
        }
        if self.streamsImageToStdout, self.tree || self.annotate || self.noScreenshot || self.menubar {
            throw ValidationError(
                "--path - is screenshot-only and cannot be combined with tree or annotation output"
            )
        }
        if forcesPixelOnlyMode, self.tree || self.annotate {
            throw ValidationError("area and multi capture modes do not support --tree or --annotate")
        }
        if self.menubar, self.noElements || forcesPixelOnlyMode {
            throw ValidationError(
                "--menubar requires element detection; use --app menubar for screenshot-only capture"
            )
        }
        if self.region != nil, self.mode != nil, self.mode != .area {
            throw ValidationError("--region can only be combined with --mode area")
        }
    }

    private func validateSpecialCaptureTargets(windowSelectorCount: Int) throws {
        if let appAlias = self.app?.lowercased(), appAlias == "frontmost" || appAlias == "menubar" {
            let allowedModes: Set<PeekabooCore.CaptureMode> =
                appAlias == "frontmost"
                    ? [.window, .frontmost]
                    : [.window]
            let hasConflictingMode = self.mode.map { !allowedModes.contains($0) } ?? false
            if hasConflictingMode || self.region != nil || self.screenIndex != nil
                || windowSelectorCount > 0 || self.menubar {
                throw ValidationError("--app \(appAlias) cannot be combined with another capture target")
            }
        }
        if self.menubar {
            if self.mode != nil || self.pid != nil || self.region != nil || self.screenIndex != nil
                || windowSelectorCount > 0 {
                throw ValidationError("--menubar cannot be combined with another capture target")
            }
        }
    }

    private func validateTarget(
        for resolvedMode: PeekabooCore.CaptureMode,
        windowSelectorCount: Int
    ) throws {
        let hasProcessTarget = self.app != nil || self.pid != nil
        switch resolvedMode {
        case .screen:
            if hasProcessTarget || windowSelectorCount > 0 || self.region != nil {
                throw ValidationError("screen mode accepts only --screen-index as a capture target")
            }
        case .area:
            if self.region == nil {
                throw ValidationError("area mode requires --region x,y,width,height")
            }
            if hasProcessTarget || windowSelectorCount > 0 || self.screenIndex != nil {
                throw ValidationError("area mode cannot be combined with app, window, or screen targets")
            }
        case .frontmost:
            let usesFrontmostAlias = self.app?.lowercased() == "frontmost"
            if self.pid != nil || windowSelectorCount > 0 || self.screenIndex != nil || self.region != nil
                || (self.app != nil && !usesFrontmostAlias) {
                throw ValidationError("frontmost mode cannot be combined with another capture target")
            }
        case .window:
            if self.screenIndex != nil || self.region != nil {
                throw ValidationError("window mode cannot be combined with screen or area targets")
            }
        case .multi:
            if windowSelectorCount > 0 || self.screenIndex != nil || self.region != nil {
                throw ValidationError(
                    "multi mode accepts an optional app or pid, but not window, screen, or area targets"
                )
            }
        }
    }

    func validateInteractionTargetSelectors() throws {
        do {
            try InteractionTargetSelector(
                applicationIdentifier: self.app,
                processIdentifier: self.pid.map(Int.init),
                windowID: self.windowId,
                windowTitle: self.windowTitle,
                windowIndex: self.windowIndex
            )
            .validate(policy: .interaction)
        } catch let error as InteractionTargetSelector.ValidationError {
            throw InteractionTargetOptions.validationError(for: error)
        }
    }

    private func runPixelOnlyCapture() async throws {
        try self.validateStdoutStreamingOptions()
        let coordinateReceiptID: String? =
            if self.publishesPixelCoordinateReceipt {
                try await self.services.snapshots.createExplicitSnapshot()
            } else {
                nil
            }

        var captures: [ImageCapturedFile] = []
        do {
            captures = try await self.performPixelCapture(snapshotID: coordinateReceiptID)
            try self.validatePixelCaptureForPublishing(captures)
            if self.streamsImageToStdout {
                try self.outputImageToStdout(captures)
            } else if let prompt = self.analyze, let firstCapture = captures.first {
                let analysis = try await self.analyzeImage(firstCapture.imageData, with: prompt)
                try self.outputResultsWithAnalysis(captures, analysis: analysis)
            } else {
                try self.outputResults(captures)
            }
        } catch {
            if let coordinateReceiptID {
                try? await self.services.snapshots.cleanSnapshot(snapshotId: coordinateReceiptID)
            }
            let receipt = SeeExecutionReceipt.combining(captures.map(\.receipt))
            throw receipt.preservingFailure(error, operation: "see pixel capture")
        }
    }

    var publishesPixelCoordinateReceipt: Bool {
        self.noElements && self.windowId != nil && !self.streamsImageToStdout
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

    var overallTimeoutSeconds: TimeInterval {
        Self.detectionTimeoutSeconds(
            configuredTimeoutSeconds: self.timeout?.seconds,
            analyze: self.analyze
        )
    }

    private func prepareResult(
        startTime: Date,
        logger: Logger,
        snapshotID: String,
        observationTimeoutSeconds: TimeInterval
    ) async throws -> SeeCommandRenderContext {
        // ScreenCaptureService performs the authoritative permission check inside each capture path.
        // Avoid duplicating that TCC probe here; `see` is often called in latency-sensitive loops.

        // Perform capture and element detection
        logger.verbose("Starting capture and detection phase", category: "Capture")
        let captureResult = try await performCaptureWithDetection(
            snapshotID: snapshotID,
            observationTimeoutSeconds: observationTimeoutSeconds
        )
        try captureResult.receipt.requirePublishableOutcome(
            operation: "See",
            requiresOutcome: self.webFocus || self.menubar
        )
        SeeCommandPreparationContext.didCapture?()
        logger.verbose(
            "Capture completed successfully", category: "Capture",
            metadata: [
                "snapshotId": captureResult.snapshotId,
                "elementCount": captureResult.elements.all.count,
                "screenshotSize": captureResult.screenshotData?.count ?? 0,
            ]
        )

        do {
            try Task.checkCancellation()
            // Generate annotated screenshot if requested
            var annotatedPath = captureResult.annotatedPath
            var annotatedData = captureResult.annotatedData
            let annotationsAllowed = self.allowsAnnotationForCurrentCapture()
            if self.annotate, !annotationsAllowed {
                self.logger.info(
                    "Annotation is disabled for full screen captures due to performance constraints"
                )
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
                    annotatedData = try Data(contentsOf: URL(fileURLWithPath: annotatedPath))
                }
                logger.operationComplete(
                    "generate_annotations",
                    metadata: [
                        "annotatedPath": annotatedPath ?? "none",
                    ]
                )
            }
            // Perform AI analysis if requested
            var analysisResult: SeeAnalysisData?
            if let prompt = analyze {
                guard let screenshotData = captureResult.screenshotData else {
                    throw CaptureError.captureFailure(
                        "Observation completed without verified screenshot bytes"
                    )
                }
                // Pre-analysis diagnostics
                let fileSize = screenshotData.count
                logger.verbose(
                    "Starting AI analysis",
                    category: "AI",
                    metadata: [
                        "imagePath": captureResult.screenshotPath,
                        "imageSizeBytes": fileSize,
                        "promptLength": prompt.count,
                    ]
                )
                logger.operationStart("ai_analysis", metadata: ["promptPreview": String(prompt.prefix(80))])
                logger.startTimer("ai_generate")
                analysisResult = try await self.performAnalysisDetailed(
                    imageData: screenshotData,
                    prompt: prompt
                )
                try Task.checkCancellation()
                logger.stopTimer("ai_generate")
                logger.operationComplete(
                    "ai_analysis",
                    success: analysisResult != nil,
                    metadata: [
                        "provider": analysisResult?.provider ?? "unknown",
                        "model": analysisResult?.model ?? "unknown",
                    ]
                )
            }

            let menuBarSummary = self.jsonOutput ? await self.fetchMenuBarSummaryIfEnabled() : nil
            try Task.checkCancellation()

            let executionTime = Date().timeIntervalSince(startTime)
            let presentationElements = DesktopObservationROIProcessor.presentationElements(
                captureResult.elements,
                viewport: captureResult.coordinateContext?.viewport
            )
            return SeeCommandRenderContext(
                snapshotId: captureResult.snapshotId,
                screenshotPath: captureResult.screenshotPath,
                screenshotData: captureResult.screenshotData,
                annotatedPath: annotatedPath,
                annotatedData: annotatedData,
                metadata: captureResult.metadata,
                elements: presentationElements,
                coordinateContext: captureResult.coordinateContext,
                analysis: analysisResult,
                executionTime: executionTime,
                observation: captureResult.observation,
                menuBar: menuBarSummary,
                receipt: captureResult.receipt
            )
        } catch {
            throw captureResult.receipt.preservingFailure(error, operation: "see result preparation")
        }
    }

    func captureROI() throws -> CaptureRegionOfInterest? {
        guard let roi else { return nil }
        do {
            let parsed = try CaptureRegionOfInterest.parse(roi)
            if let windowId, let exactWindowID = CGWindowID(exactly: windowId) {
                try DesktopObservationROIProcessor.validateRequest(
                    parsed,
                    target: .windowID(exactWindowID)
                )
            } else if windowId != nil {
                throw ValidationError("--window-id must be between 1 and \(UInt32.max)")
            }
            return parsed
        } catch let error as CaptureROIError {
            throw ValidationError(error.localizedDescription)
        }
    }

    private func validateExactWindowIdentifier() throws {
        guard let windowId else { return }
        guard windowId > 0, UInt32(exactly: windowId) != nil else {
            throw ValidationError("--window-id must be between 1 and \(UInt32.max)")
        }
    }

    private func validateROIOptions(resolvedMode: PeekabooCore.CaptureMode) throws {
        guard self.roi != nil else { return }
        guard self.windowId != nil else {
            throw ValidationError("--roi requires an exact --window-id")
        }
        guard !self.noElements, !self.noScreenshot, !self.streamsImageToStdout else {
            throw ValidationError(
                "--roi requires a snapshot-producing see capture with element detection"
            )
        }
        guard resolvedMode == .window, self.region == nil, self.screenIndex == nil, !self.menubar else {
            throw ValidationError("--roi supports exact window capture only")
        }
        _ = try self.captureROI()
    }

    private func emitAnnotationStatus(context: SeeCommandRenderContext) {
        let annotationsAllowed = self.allowsAnnotationForCurrentCapture()
        if self.annotate, annotationsAllowed, context.annotatedPath == nil, !self.jsonOutput {
            print("\(AgentDisplayTokens.Status.warning)  No interactive UI elements found to annotate")
        } else if self.annotate, annotationsAllowed, let annotatedPath = context.annotatedPath,
                  !self.jsonOutput {
            let interactableElements = context.elements.all.filter(\.isEnabled)
            print(
                "📝 Created annotated screenshot with \(interactableElements.count) interactive elements"
            )
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
                        description:
                        "Capture the frontmost window, print structured output, and save annotations."
                    ),
                    CommandUsageExample(
                        command: "peekaboo see --app Safari --window-title \"Login\" --json "
                            + "--path /tmp/safari-login.png",
                        description: "Target a specific Safari window to collect fresh element IDs and "
                            + "keep the capture artifact in /tmp."
                    ),
                    CommandUsageExample(
                        command:
                        "peekaboo see --mode screen --screen-index 0 --analyze 'Summarize the dashboard'",
                        description: "Capture a display and immediately send it to the configured AI provider."
                    ),
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension SeeCommand: AsyncRuntimeCommand {}

extension SeeCommand: ActionOutputFormattable, OutputFormattable {
    var defaultEffect: ActionEffect? {
        self.webFocus || self.menubar || self.captureFocus != .background ? .unverifiable : nil
    }
}

@MainActor
extension SeeCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.windowTitle = values.singleOption("windowTitle")
        self.windowIndex = try values.decodeOption("windowIndex", as: Int.self)
        self.windowId = try values.decodeOption("windowId", as: Int.self)
        if let parsedMode: PeekabooCore.CaptureMode = try values.decodeOptionEnum(
            "mode", caseInsensitive: false
        ) {
            self.mode = parsedMode
        }
        self.region = values.singleOption("region")
        self.roi = values.singleOption("roi")
        let parsedFormat: PeekabooCore.ImageFormat? = try values.decodeOptionEnum("format")
        if let parsedFormat {
            self.format = parsedFormat
        }
        self.path = values.singleOption("path")
        if let path = self.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            let ext = URL(fileURLWithPath: expanded).pathExtension.lowercased()
            let inferred: PeekabooCore.ImageFormat? =
                switch ext {
                case "jpg", "jpeg": .jpg
                case "png": .png
                default: nil
                }
            if let parsedFormat, let inferred, parsedFormat != inferred {
                throw CommanderBindingError.invalidArgument(
                    label: "path",
                    value: path,
                    reason: "Conflicts with --format \(parsedFormat.rawValue). "
                        + "Use a .\(parsedFormat.fileExtension) path (or omit --format)."
                )
            }
            if parsedFormat == nil, let inferred {
                self.format = inferred
            }
        }
        self.screenIndex = try values.decodeOption("screenIndex", as: Int.self)
        self.captureEngine = values.singleOption("captureEngine")
        self.annotate = values.flag("annotate")
        self.analyze = values.singleOption("analyze")
        self.timeout = try values.decodeOption("timeout", as: CLIDuration.self)
        self.depth = try values.decodeOption("depth", as: Int.self)
        self.maxElements = try values.decodeOption("maxElements", as: Int.self)
        self.maxChildren = try values.decodeOption("maxChildren", as: Int.self)
        self.webFocus = values.flag("webFocus")
        self.noWebFocus = values.flag("noWebFocus")
        self.menubar = values.flag("menubar")
        self.retina = values.flag("retina")
        self.noElements = values.flag("noElements")
        self.ocr = values.flag("ocr")
        self.tree = values.flag("tree")
        self.noScreenshot = values.flag("noScreenshot")
    }
}

extension SeeCommand: RuntimeOptionsConfigurable {
    mutating func setRuntimeOptions(_ options: CommandRuntimeOptions) {
        self.runtimeOptions = options
    }
}
