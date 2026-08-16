import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooProtocols
import PeekabooVisualizer
import TachikomaMCP

private typealias AutomationDetectedElement = PeekabooAutomation.DetectedElement

/// MCP tool for capturing UI state and element detection
public struct SeeTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "SeeTool")
    private let context: MCPToolContext

    public let name = "see"

    public var description: String {
        """
        Captures a screenshot of the active UI and generates an element map.

        Returns opaque Peekaboo element IDs that can be passed unchanged to interaction commands.
        Do not infer an element's role or type from the shape of its ID. Creates or updates a
        snapshot that tracks UI state. Observation is background-only and does not focus the target
        unless `web_focus` is explicitly enabled for sparse embedded web content.
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "app_target": SchemaBuilder.string(
                    description: """
                    Optional. Specifies the capture target (same as image tool).
                    For example:
                    Omit or use an empty string (e.g., '') for all screens.
                    Use 'screen:INDEX' (e.g., 'screen:0') for a specific display.
                    Use 'frontmost' for all windows of the current foreground application.
                    Use 'AppName' (e.g., 'Safari') for all windows of that application.
                    Use 'PID:PROCESS_ID' (e.g., 'PID:663') to target a specific process by its PID.
                    """),
                "window_id": SchemaBuilder.integer(
                    description: """
                    Optional. Exact CoreGraphics window ID. May be used alone; when app_target names an application
                    or PID, Peekaboo also verifies owner agreement. Numeric app_target suffixes remain window indexes.
                    """,
                    minimum: 1,
                    maximum: Int(UInt32.max)),
                "path": SchemaBuilder.string(
                    description: """
                    Optional. Path to save the screenshot. If omitted, a temporary file is used.
                    """),
                "snapshot": SchemaBuilder.string(
                    description: """
                    Optional. Snapshot ID for UI automation tracking. A new snapshot is created when absent.
                    """),
                "annotate": SchemaBuilder.boolean(
                    description: """
                    Optional. Add interaction markers and IDs to the returned screenshot.
                    """,
                    default: false),
                "ocr": SchemaBuilder.boolean(
                    description: """
                    Optional. Add text recognized locally on the selected host with Apple Vision to the accessibility
                    element map. OCR text is non-actionable and does not replace accessible controls.
                    """,
                    default: false),
                "roi": SchemaBuilder.string(
                    description: """
                    Optional. Crop the exact window as x,y,width,height in window-local logical points. Requires
                    window_id, creates a fresh snapshot, and returns ROI-local element bounds plus a coordinate
                    context for image_pixels or normalized clicks.
                    """),
                "web_focus": SchemaBuilder.boolean(
                    description: "Optional. Allow an AXPress retry on sparse Chromium/Tauri web content.",
                    default: false),
                "max_depth": SchemaBuilder.integer(
                    description: "Optional. Maximum AX traversal depth. Env fallback: PEEKABOO_AX_MAX_DEPTH.",
                    minimum: 1),
                "max_elements": SchemaBuilder.integer(
                    description:
                    "Optional. Maximum AX elements to collect. Env fallback: PEEKABOO_AX_MAX_ELEMENTS.",
                    minimum: 1),
                "max_children": SchemaBuilder.integer(
                    description: """
                    Optional. Maximum AX children per node. Env fallback: PEEKABOO_AX_MAX_CHILDREN.
                    Increase this for flat Qt/Electron panels with many sibling controls.
                    """,
                    minimum: 1),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request = try SeeRequest(arguments: arguments)
        var newlyCreatedSnapshotID: String?
        var newlyCreatedSnapshotWasPending = false
        var activeSnapshotID: String?
        var observationActionResult: UIAutomationActionResult<DesktopObservationResult>?

        do {
            let target = try ObservationTargetArgument.parse(
                request.appTarget,
                windowIDValue: request.windowIDValue)
            let captureArtifact = try SeeCaptureArtifact(requestedPath: request.path)
            defer { captureArtifact.cleanup() }

            let selection = try await self.getOrCreateSnapshot(snapshotId: request.snapshotId)
            let snapshot = selection.snapshot
            newlyCreatedSnapshotID = selection.isNew ? snapshot.id : nil
            newlyCreatedSnapshotWasPending =
                selection.isNew && MCPToolContext.snapshotObservationStartedAt != nil
            activeSnapshotID = snapshot.id
            let actionResult = try await self.observeDesktop(
                target: target,
                request: request,
                path: captureArtifact.observationPath,
                snapshot: snapshot)
            try ObservationActionResultSemantics.requirePublishableOutcome(
                actionResult.outcome,
                targetIdentity: actionResult.targetIdentity,
                operation: "See",
                requiresOutcome: request.webFocus)
            let observation = actionResult.payload
            let resolvedTarget = try ObservationActionResultSemantics.coalescedTarget(
                actionTarget: actionResult.targetIdentity,
                payload: observation,
                outcome: actionResult.outcome,
                operation: "See",
                requiresTarget: request.webFocus && target.requiresStableMutationTarget)
            let validatedActionResult = UIAutomationActionResult(
                payload: observation,
                outcome: actionResult.outcome,
                targetIdentity: resolvedTarget)
            observationActionResult = validatedActionResult
            let (elements, detectedElements) = try await self.detectUIElements(
                observation: observation,
                snapshot: snapshot)
            _ = try await self.generateAnnotationIfNeeded(
                annotate: request.annotate,
                observation: observation,
                elements: elements,
                detectedElements: detectedElements,
                snapshot: snapshot)
            let responseImages = try self.responseImageData(
                observation: observation,
                annotate: request.annotate,
                captureArtifact: captureArtifact)
            let publishedPaths = try captureArtifact.publish(
                rawData: responseImages.raw,
                annotatedData: responseImages.annotated)
            await self.registerObservationScreenshot(
                path: publishedPaths.rawPath,
                observation: observation,
                snapshot: snapshot)

            return try await self.buildToolResponse(
                snapshot: snapshot,
                elements: elements,
                output: ScreenshotOutput(
                    screenshotPath: publishedPaths.rawPath,
                    annotatedPath: publishedPaths.annotatedPath,
                    imageData: responseImages.annotated ?? responseImages.raw),
                target: target,
                actionResult: validatedActionResult)
        } catch {
            let presentedError = ObservationActionResultSupport.preservingFailure(
                error,
                after: observationActionResult,
                operation: "see")
            if let newlyCreatedSnapshotID {
                let preserveReservation =
                    newlyCreatedSnapshotWasPending
                        && PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: presentedError)
                if !preserveReservation {
                    try? await self.context.snapshots.cleanSnapshot(snapshotId: newlyCreatedSnapshotID)
                    await self.context.uiSnapshots.removeSnapshot(id: newlyCreatedSnapshotID)
                }
            }
            self.logger.error("See tool execution failed: \(presentedError.localizedDescription)")
            if let failure = presentedError as? DesktopActionFailure {
                return try await MCPDesktopActionFailureHandler.response(
                    for: failure,
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: activeSnapshotID,
                    additionalFields: ObservationActionResultSupport.standardErrorFields(error))
            }
            return ToolResponse.error(
                "Failed to capture UI state: \(presentedError.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getOrCreateSnapshot(snapshotId: String?) async throws -> (
        snapshot: UISnapshot, isNew: Bool)
    {
        if let snapshotId {
            // Try to get existing snapshot
            let hostHasSnapshot = try await self.context.snapshots.listSnapshots().contains {
                $0.id == snapshotId
            }
            if hostHasSnapshot,
               let existingSnapshot = await self.context.uiSnapshots.getSnapshot(id: snapshotId)
            {
                return (existingSnapshot, false)
            }
        }

        let observationStartedAt = MCPToolContext.snapshotObservationStartedAt
        let snapshotId =
            if let observationStartedAt {
                try await self.context.snapshots.createSnapshot(pendingAt: observationStartedAt)
            } else {
                try await self.context.snapshots.createSnapshot()
            }
        let snapshot = await self.context.uiSnapshots.createSnapshot(
            id: snapshotId,
            at: observationStartedAt ?? Date(),
            pending: observationStartedAt != nil)
        return (snapshot, true)
    }

    private func observeDesktop(
        target: ObservationTargetArgument,
        request: SeeRequest,
        path: String?,
        snapshot: UISnapshot) async throws -> UIAutomationActionResult<DesktopObservationResult>
    {
        try await self.context.desktopObservation.observeResult(
            DesktopObservationRequest(
                target: target.observationTarget,
                capture: DesktopCaptureOptions(visualizerMode: .none, roi: request.roi),
                detection: DesktopDetectionOptions(
                    mode: request.ocr ? .accessibilityAndOCR : .accessibility,
                    allowWebFocusFallback: request.webFocus,
                    preferOCR: false,
                    traversalBudget: request.traversalBudget),
                output: DesktopObservationOutputOptions(
                    path: path,
                    saveRawScreenshot: true,
                    saveAnnotatedScreenshot: request.annotate,
                    saveSnapshot: true,
                    snapshotID: snapshot.id)))
    }

    private func registerObservationScreenshot(
        path: String,
        observation: DesktopObservationResult,
        snapshot: UISnapshot) async
    {
        await snapshot.setScreenshot(
            path: path,
            metadata: observation.capture.metadata,
            context: observation.elements?.metadata.windowContext ?? observation.target.detectionContext)
    }

    private func generateAnnotationIfNeeded(
        annotate: Bool,
        observation: DesktopObservationResult,
        elements: [UIElement],
        detectedElements: [AutomationDetectedElement],
        snapshot: UISnapshot) async throws -> String?
    {
        guard annotate else { return nil }
        guard let annotated = observation.files.annotatedScreenshotPath else {
            throw OperationError.captureFailed(
                reason: "Observation did not produce an annotated screenshot path")
        }
        if Self.shouldEmitAnnotationOverlay(captureFocus: .background) {
            try await self.emitAnnotatedScreenshotVisualizer(
                imageData: observation.verifiedAnnotatedScreenshotData(),
                detectedElements: detectedElements,
                snapshot: snapshot)
        }
        return annotated
    }

    static func shouldEmitAnnotationOverlay(captureFocus: CaptureFocus) -> Bool {
        captureFocus == .foreground
    }

    private func responseImageData(
        observation: DesktopObservationResult,
        annotate: Bool,
        captureArtifact: SeeCaptureArtifact) throws -> (raw: Data, annotated: Data?)
    {
        guard Self.sameFile(observation.files.rawScreenshotPath, captureArtifact.observationPath) else {
            throw OperationError.captureFailed(reason: "Observation did not produce a screenshot path")
        }
        let rawData = try observation.verifiedRawScreenshotData()
        guard annotate else {
            return (rawData, nil)
        }
        guard
            Self.sameFile(
                observation.files.annotatedScreenshotPath, captureArtifact.observationAnnotatedPath)
        else {
            return (rawData, nil)
        }
        return try (
            rawData,
            observation.verifiedAnnotatedScreenshotData())
    }

    private static func sameFile(_ reportedPath: String?, _ expectedPath: String) -> Bool {
        guard let reportedPath else { return false }
        return URL(fileURLWithPath: reportedPath).standardizedFileURL
            == URL(fileURLWithPath: expectedPath).standardizedFileURL
    }

    private func detectUIElements(
        observation: DesktopObservationResult,
        snapshot: UISnapshot) async throws -> ([UIElement], [AutomationDetectedElement])
    {
        guard let detectionResult = observation.elements else {
            return ([], [])
        }

        let detectedElements = await MainActor.run { detectionResult.elements.all }
        await self.emitElementDetectionVisualizer(from: detectedElements)
        let storedElements = self.convertElements(detectedElements)
        let elements = DesktopObservationROIProcessor.presentationElements(
            storedElements,
            viewport: observation.capture.metadata.viewport)
        self.logger.info("Detected \(elements.count) UI elements")
        await snapshot.setUIElements(storedElements)
        return (elements, detectedElements)
    }

    private func convertElements(_ detected: [AutomationDetectedElement]) -> [UIElement] {
        DetectedElementSnapshotConverter.convert(detected)
    }

    private func buildToolResponse(
        snapshot: UISnapshot,
        elements: [UIElement],
        output: ScreenshotOutput,
        target: ObservationTargetArgument,
        actionResult: UIAutomationActionResult<DesktopObservationResult>) async throws -> ToolResponse
    {
        let observation = actionResult.payload
        let finalScreenshot = output.annotatedPath ?? output.screenshotPath
        let summaryText = await buildSummary(
            snapshot: snapshot,
            elements: elements,
            screenshotPath: finalScreenshot,
            truncationInfo: observation.elements?.metadata.truncationInfo,
            traversalBudget: observation.elements?.metadata.windowContext?.traversalBudget)

        var content: [MCP.Tool.Content] = [.text(text: summaryText, annotations: nil, _meta: nil)]
        content.append(
            .image(
                data: output.imageData.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil))

        let baseMeta = try self.makeMetadata(
            snapshot: snapshot,
            elements: elements,
            observation: observation,
            actionResult: actionResult)
        var summary = ToolEventSummary(
            targetApp: snapshot.applicationName,
            windowTitle: snapshot.windowTitle,
            actionDescription: "See",
            notes: String(describing: target))
        summary.captureApp = snapshot.applicationName
        summary.captureWindow = snapshot.windowTitle

        let mergedMeta = ToolEventSummary.merge(summary: summary, into: baseMeta)
        return ToolResponse(content: content, meta: mergedMeta)
    }

    private func makeMetadata(
        snapshot: UISnapshot,
        elements: [UIElement],
        observation: DesktopObservationResult,
        actionResult: UIAutomationActionResult<DesktopObservationResult>) throws -> Value
    {
        let diagnostics = ObservationDiagnosticsMetadata.merge(
            observation,
            into: .object([
                "snapshot_id": .string(snapshot.id),
                "coordinate_context": CaptureCoordinateContextMetadata.value(
                    for: observation.capture.metadata,
                    referenceID: snapshot.id),
                "element_count": .double(Double(elements.count)),
                "actionable_count": .double(Double(elements.count(where: { $0.isActionable }))),
            ]))
        let fields: [String: Value] =
            if case let .object(fields) = diagnostics {
                fields
            } else {
                [:]
            }
        return try ObservationActionResultSupport.metadata(
            merging: fields,
            result: actionResult) ?? diagnostics
    }

    // Removed getRolePrefix - no longer needed after refactoring to use main UIElement struct

    /// Element boxes are opt-in, and this sender-side gate is the single default-off
    /// decision: skip persisting/dispatching the event entirely unless
    /// `PEEKABOO_VISUAL_ELEMENT_BOXES` or `visualizer.elementDetectionEnabled` in
    /// `~/.peekaboo/config.json` turns them on. The Mac app's settings toggle writes
    /// this same config key, so one switch governs both processes; the renderer draws
    /// whatever event it receives once the master visualizer switch is on.
    static func elementDetectionVisualsEnabled(
        environment: [String: String],
        configuration: PeekabooAutomation.Configuration?) -> Bool
    {
        switch environment["PEEKABOO_VISUAL_ELEMENT_BOXES"]?.lowercased() {
        case "1", "true", "yes", "on":
            true
        case "0", "false", "no", "off":
            false
        default:
            configuration?.visualizer?.elementDetectionEnabled ?? false
        }
    }

    @MainActor
    private func emitElementDetectionVisualizer(from detected: [AutomationDetectedElement]) async {
        // Pick up config edits made after this (possibly long-lived MCP) process started,
        // e.g. the Mac app writing the toggle into config.json. Cheap: a stat unless it changed.
        ConfigurationManager.shared.reloadConfigurationIfChanged()
        guard
            Self.elementDetectionVisualsEnabled(
                environment: ProcessInfo.processInfo.environment,
                configuration: ConfigurationManager.shared.getConfiguration())
        else {
            return
        }

        // Element bounds use global accessibility coordinates (top-left origin)
        // but the overlay windows are positioned in global AppKit coordinates
        // (bottom-left origin). Flip against the primary display — without this
        // the highlights render vertically mirrored across the screen.
        let screens = self.context.screens.listScreens()
        let primaryFrame = (screens.first(where: \.isPrimary) ?? screens.first)?.frame
        let map = Dictionary(
            uniqueKeysWithValues: detected.map { element in
                (
                    element.id,
                    VisualizerScreenGeometry.appKitRect(
                        fromGlobalDisplay: element.bounds,
                        primaryScreenFrame: primaryFrame))
            })
        _ = await VisualizationClient.shared.showElementDetection(elements: map)
    }

    @MainActor
    private func emitAnnotatedScreenshotVisualizer(
        imageData: Data,
        detectedElements: [AutomationDetectedElement],
        snapshot: UISnapshot) async
    {
        guard !detectedElements.isEmpty else { return }
        let metadata = await snapshot.screenshotMetadata
        let globalDisplayWindowBounds =
            metadata?.windowInfo?.bounds
                ?? metadata?.displayInfo?.bounds
                ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screens = self.context.screens.listScreens()
        let primaryFrame = (screens.first(where: \.isPrimary) ?? screens.first)?.frame
        let windowBounds = VisualizerScreenGeometry.appKitRect(
            fromGlobalDisplay: globalDisplayWindowBounds,
            primaryScreenFrame: primaryFrame)
        let protocolElements = VisualizerBoundsConverter.makeVisualizerElements(
            from: detectedElements,
            primaryScreenFrame: primaryFrame)
        _ = await VisualizationClient.shared.showAnnotatedScreenshot(
            imageData: imageData,
            elements: protocolElements,
            windowBounds: windowBounds)
    }

    @MainActor
    private func buildSummary(
        snapshot: UISnapshot,
        elements: [UIElement],
        screenshotPath: String,
        truncationInfo: DetectionTruncationInfo?,
        traversalBudget: AXTraversalBudget?) async -> String
    {
        await SeeSummaryBuilder(
            snapshot: snapshot,
            elements: elements,
            screenshotPath: screenshotPath,
            truncationInfo: truncationInfo,
            traversalBudget: traversalBudget)
            .build()
    }
}
