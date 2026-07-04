import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import PeekabooProtocols
import PeekabooVisualizer

private typealias AutomationDetectedElement = PeekabooAutomation.DetectedElement
import TachikomaMCP

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
        snapshot that tracks UI state.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5
        and anthropic/claude-opus-4-8.
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
                    Optional. Generate an annotated screenshot with interaction markers and IDs.
                    """,
                    default: false),
                "max_depth": SchemaBuilder.number(
                    description: "Optional. Maximum AX traversal depth. Env fallback: PEEKABOO_AX_MAX_DEPTH."),
                "max_elements": SchemaBuilder.number(
                    description: "Optional. Maximum AX elements to collect. Env fallback: PEEKABOO_AX_MAX_ELEMENTS."),
                "max_children": SchemaBuilder.number(
                    description: """
                    Optional. Maximum AX children per node. Env fallback: PEEKABOO_AX_MAX_CHILDREN.
                    Increase this for flat Qt/Electron panels with many sibling controls.
                    """),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request = SeeRequest(arguments: arguments)
        var newlyCreatedSnapshotID: String?
        var newlyCreatedSnapshotWasPending = false

        do {
            let selection = try await self.getOrCreateSnapshot(snapshotId: request.snapshotId)
            let snapshot = selection.snapshot
            newlyCreatedSnapshotID = selection.isNew ? snapshot.id : nil
            newlyCreatedSnapshotWasPending = selection.isNew && MCPToolContext.snapshotObservationStartedAt != nil
            let target = try ObservationTargetArgument.parse(request.appTarget)
            let observation = try await self.observeDesktop(
                target: target,
                path: request.path,
                annotate: request.annotate,
                traversalBudget: request.traversalBudget,
                snapshot: snapshot)
            let screenshotPath = try await self.registerObservationScreenshot(
                observation,
                snapshot: snapshot)
            let (elements, detectedElements) = try await self.detectUIElements(
                observation: observation,
                snapshot: snapshot)
            let annotatedPath = try await self.generateAnnotationIfNeeded(
                annotate: request.annotate,
                observation: observation,
                elements: elements,
                detectedElements: detectedElements,
                snapshot: snapshot)

            return try await self.buildToolResponse(
                snapshot: snapshot,
                elements: elements,
                output: ScreenshotOutput(
                    screenshotPath: screenshotPath,
                    annotatedPath: annotatedPath,
                    annotate: request.annotate),
                target: target,
                observation: observation)
        } catch {
            if let newlyCreatedSnapshotID {
                let preserveReservation = newlyCreatedSnapshotWasPending &&
                    PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: error)
                if !preserveReservation {
                    try? await self.context.snapshots.cleanSnapshot(snapshotId: newlyCreatedSnapshotID)
                    await UISnapshotManager.shared.removeSnapshot(id: newlyCreatedSnapshotID)
                }
            }
            self.logger.error("See tool execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to capture UI state: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getOrCreateSnapshot(snapshotId: String?) async throws -> (snapshot: UISnapshot, isNew: Bool) {
        if let snapshotId {
            // Try to get existing snapshot
            let hostHasSnapshot = try await self.context.snapshots.listSnapshots().contains { $0.id == snapshotId }
            if hostHasSnapshot,
               let existingSnapshot = await UISnapshotManager.shared.getSnapshot(id: snapshotId)
            {
                return (existingSnapshot, false)
            }
        }

        let observationStartedAt = MCPToolContext.snapshotObservationStartedAt
        let snapshotId = if let observationStartedAt {
            try await self.context.snapshots.createSnapshot(pendingAt: observationStartedAt)
        } else {
            try await self.context.snapshots.createSnapshot()
        }
        let snapshot = await UISnapshotManager.shared.createSnapshot(
            id: snapshotId,
            at: observationStartedAt ?? Date(),
            pending: observationStartedAt != nil)
        return (snapshot, true)
    }

    private func observeDesktop(
        target: ObservationTargetArgument,
        path: String?,
        annotate: Bool,
        traversalBudget: AXTraversalBudget,
        snapshot: UISnapshot) async throws -> DesktopObservationResult
    {
        try await self.context.desktopObservation.observe(DesktopObservationRequest(
            target: target.observationTarget,
            detection: DesktopDetectionOptions(mode: .accessibility, traversalBudget: traversalBudget),
            output: DesktopObservationOutputOptions(
                path: path,
                saveRawScreenshot: true,
                saveAnnotatedScreenshot: annotate,
                saveSnapshot: true,
                snapshotID: snapshot.id)))
    }

    private func registerObservationScreenshot(
        _ observation: DesktopObservationResult,
        snapshot: UISnapshot) async throws -> String
    {
        guard let screenshotPath = observation.files.rawScreenshotPath else {
            throw OperationError.captureFailed(reason: "Observation did not produce a screenshot path")
        }
        await snapshot.setScreenshot(path: screenshotPath, metadata: observation.capture.metadata)
        return screenshotPath
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
            throw OperationError.captureFailed(reason: "Observation did not produce an annotated screenshot path")
        }
        await self.emitAnnotatedScreenshotVisualizer(
            annotatedPath: annotated,
            detectedElements: detectedElements,
            snapshot: snapshot)
        return annotated
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
        let elements = self.convertElements(detectedElements)
        self.logger.info("Detected \(elements.count) UI elements")
        await snapshot.setUIElements(elements)
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
        observation: DesktopObservationResult) async throws -> ToolResponse
    {
        let finalScreenshot = output.annotatedPath ?? output.screenshotPath
        let summaryText = await buildSummary(
            snapshot: snapshot,
            elements: elements,
            screenshotPath: finalScreenshot,
            truncationInfo: observation.elements?.metadata.truncationInfo,
            traversalBudget: observation.elements?.metadata.windowContext?.traversalBudget)

        var content: [MCP.Tool.Content] = [.text(text: summaryText, annotations: nil, _meta: nil)]
        if output.annotate, let annotatedPath = output.annotatedPath {
            let imageData = try Data(contentsOf: URL(fileURLWithPath: annotatedPath))
            content.append(.image(
                data: imageData.base64EncodedString(),
                mimeType: "image/png",
                annotations: nil,
                _meta: nil))
        }

        let baseMeta = self.makeMetadata(
            snapshot: snapshot,
            elements: elements,
            observation: observation)
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
        observation: DesktopObservationResult) -> Value
    {
        ObservationDiagnosticsMetadata.merge(observation, into: .object([
            "snapshot_id": .string(snapshot.id),
            "element_count": .double(Double(elements.count)),
            "actionable_count": .double(Double(elements.count(where: { $0.isActionable }))),
        ]))
    }

    // Removed getRolePrefix - no longer needed after refactoring to use main UIElement struct

    @MainActor
    private func emitElementDetectionVisualizer(from detected: [AutomationDetectedElement]) async {
        // Element bounds use global accessibility coordinates (top-left origin)
        // but the overlay windows are positioned in global AppKit coordinates
        // (bottom-left origin). Flip against the primary display — without this
        // the highlights render vertically mirrored across the screen.
        let screens = self.context.screens.listScreens()
        let primaryFrame = (screens.first(where: \.isPrimary) ?? screens.first)?.frame
        let map = Dictionary(uniqueKeysWithValues: detected.map { element in
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
        annotatedPath: String,
        detectedElements: [AutomationDetectedElement],
        snapshot: UISnapshot) async
    {
        guard !detectedElements.isEmpty else { return }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: annotatedPath)) else { return }
        let metadata = await snapshot.screenshotMetadata
        let globalDisplayWindowBounds = metadata?.windowInfo?.bounds
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
            imageData: data,
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
