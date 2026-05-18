import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for inspecting UI text and control state via the accessibility tree without capturing a screenshot.
public struct InspectUITool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "InspectUITool")
    private let context: MCPToolContext

    public let name = "inspect_ui"

    public var description: String {
        """
        Inspects the accessibility tree of the active UI and returns visible text, labels,
        buttons, text fields, and control state. No screenshot is captured.

        Use this when you only need to read UI text or discover interactive elements and do not
        need a visual screenshot. For visual layout or when AX text is incomplete, use `see`.
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "app_target": SchemaBuilder.string(
                    description: """
                    Optional. Specifies the app/window to inspect via Accessibility.
                    Omit, use an empty string, or use 'frontmost' for the current foreground application.
                    Use 'AppName' (e.g., 'Safari') for a specific application.
                    Use 'PID:PROCESS_ID' to target a specific process.
                    Use 'AppName:WindowTitle' or 'PID:PROCESS_ID:WindowTitle' for a specific window title.
                    Screen and menu bar targets require screenshots; use `see` for those.
                    """),
                "snapshot": SchemaBuilder.string(
                    description: """
                    Optional. Snapshot ID for UI automation tracking. A new snapshot is created when absent.
                    """),
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
        let request = InspectUIRequest(arguments: arguments)

        do {
            let snapshot = try await self.getOrCreateSnapshot(snapshotId: request.snapshotId)
            let target = try self.parseTarget(request.appTarget)
            let windowContext = try self.makeWindowContext(for: target, traversalBudget: request.traversalBudget)

            let result = try await self.context.automation.inspectAccessibilityTree(
                windowContext: windowContext)
            let snapshotResult = self.bindResult(result, to: snapshot.id)

            try await self.context.snapshots.storeDetectionResult(
                snapshotId: snapshot.id,
                result: snapshotResult)

            await snapshot.setTargetMetadata(from: snapshotResult.metadata.windowContext)
            await snapshot.setUIElements(self.convertElements(snapshotResult.elements.all))

            let summaryText = await self.buildSummary(
                snapshot: snapshot,
                result: snapshotResult,
                target: target)

            let metadata: Value = .object([
                "snapshot_id": .string(snapshot.id),
                "element_count": .double(Double(snapshotResult.elements.all.count)),
                "actionable_count": .double(Double(snapshotResult.elements.all.count(where: \.isEnabled))),
                "used_cache": .bool(snapshotResult.metadata.method.contains("cached")),
                "truncated": .bool(snapshotResult.metadata.truncationInfo?.isTruncated == true),
            ])

            var summary = ToolEventSummary(
                targetApp: snapshotResult.metadata.windowContext?.applicationName,
                windowTitle: snapshotResult.metadata.windowContext?.windowTitle,
                actionDescription: "Inspect UI",
                notes: String(describing: target))
            summary.captureApp = snapshotResult.metadata.windowContext?.applicationName
            summary.captureWindow = snapshotResult.metadata.windowContext?.windowTitle

            let mergedMeta = ToolEventSummary.merge(summary: summary, into: metadata)

            return ToolResponse(
                content: [.text(text: summaryText, annotations: nil, _meta: nil)],
                meta: mergedMeta)
        } catch {
            self.logger.error("Inspect UI tool execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to inspect UI: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func getOrCreateSnapshot(snapshotId: String?) async throws -> UISnapshot {
        if let snapshotId {
            if let existingSnapshot = await UISnapshotManager.shared.getSnapshot(id: snapshotId) {
                return existingSnapshot
            }
        }
        return await UISnapshotManager.shared.createSnapshot()
    }

    private func parseTarget(_ rawTarget: String?) throws -> ObservationTargetArgument {
        guard let rawTarget,
              !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return .frontmost
        }

        let target = try ObservationTargetArgument.parse(rawTarget)
        switch target {
        case .screen, .menubar:
            throw PeekabooError.invalidInput(
                "inspect_ui supports frontmost, AppName, AppName:WindowTitle, PID:PROCESS_ID, and " +
                    "PID:PROCESS_ID:WindowTitle targets. Use `see` for screen or menu bar targets.")
        case .frontmost, .application, .pid:
            return target
        }
    }

    private func makeWindowContext(
        for target: ObservationTargetArgument,
        traversalBudget: AXTraversalBudget) throws -> WindowContext
    {
        switch target {
        case .frontmost:
            return WindowContext(shouldFocusWebContent: true, traversalBudget: traversalBudget)
        case let .application(identifier, window):
            let selection = try self.windowSelectionFields(window)
            return WindowContext(
                applicationName: identifier,
                windowTitle: selection.title,
                windowID: selection.id,
                shouldFocusWebContent: true,
                traversalBudget: traversalBudget)
        case let .pid(pid, window):
            let selection = try self.windowSelectionFields(window)
            return WindowContext(
                applicationProcessId: pid,
                windowTitle: selection.title,
                windowID: selection.id,
                shouldFocusWebContent: true,
                traversalBudget: traversalBudget)
        case .screen, .menubar:
            throw PeekabooError.invalidInput("inspect_ui cannot inspect screen or menu bar targets. Use `see` instead.")
        }
    }

    private func windowSelectionFields(_ selection: WindowSelection) throws -> (title: String?, id: Int?) {
        switch selection {
        case .automatic:
            return (nil, nil)
        case let .title(title):
            return (title, nil)
        case let .id(windowID):
            return (nil, Int(windowID))
        case .index:
            throw PeekabooError.invalidInput(
                "inspect_ui does not support window index targets. Use a window title or `see` instead.")
        }
    }

    private func convertElements(_ detected: [DetectedElement]) -> [UIElement] {
        DetectedElementSnapshotConverter.convert(detected)
    }

    private func bindResult(_ result: ElementDetectionResult, to snapshotId: String) -> ElementDetectionResult {
        guard result.snapshotId != snapshotId else {
            return result
        }

        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: result.screenshotPath,
            elements: result.elements,
            metadata: result.metadata)
    }

    @MainActor
    private func buildSummary(
        snapshot: UISnapshot,
        result: ElementDetectionResult,
        target: ObservationTargetArgument) async -> String
    {
        await InspectUISummaryBuilder(
            snapshot: snapshot,
            result: result,
            target: target)
            .build()
    }
}
