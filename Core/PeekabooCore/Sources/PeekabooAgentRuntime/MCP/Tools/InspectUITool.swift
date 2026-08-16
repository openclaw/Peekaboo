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
        need a visual screenshot. Inspection does not focus the target by default. For visual layout
        or when AX text is incomplete, use `see`. The CLI equivalent is `peekaboo see --tree --no-screenshot`.
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
                "window_id": SchemaBuilder.integer(
                    description: """
                    Optional. Exact CoreGraphics window ID. Requires an application or PID app_target; Peekaboo
                    verifies the window belongs to that owner. Numeric app_target suffixes remain window indexes.
                    """,
                    minimum: 1,
                    maximum: Int(UInt32.max)),
                "snapshot": SchemaBuilder.string(
                    description: """
                    Optional. Snapshot ID for UI automation tracking. A new snapshot is created when absent.
                    """),
                "web_focus": SchemaBuilder.boolean(
                    description: "Optional. Allow an AXPress retry on sparse Chromium/Tauri web content.",
                    default: false),
                "max_depth": SchemaBuilder.integer(
                    description: "Optional. Maximum AX traversal depth. Env fallback: PEEKABOO_AX_MAX_DEPTH.",
                    minimum: 1),
                "max_elements": SchemaBuilder.integer(
                    description: "Optional. Maximum AX elements to collect. Env fallback: PEEKABOO_AX_MAX_ELEMENTS.",
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
        let request: InspectUIRequest
        do {
            request = try InspectUIRequest(arguments: arguments)
        } catch {
            return Self.failureResponse(error)
        }
        var newlyCreatedSnapshotID: String?
        var newlyCreatedSnapshotWasPending = false
        var activeSnapshotID: String?
        var observationActionResult: UIAutomationActionResult<ElementDetectionResult>?

        do {
            let target = try self.parseTarget(request.appTarget, windowIDValue: request.windowIDValue)
            let selection = try await self.getOrCreateSnapshot(snapshotId: request.snapshotId)
            let snapshot = selection.snapshot
            newlyCreatedSnapshotID = selection.isNew ? snapshot.id : nil
            newlyCreatedSnapshotWasPending = selection.isNew && MCPToolContext.snapshotObservationStartedAt != nil
            activeSnapshotID = snapshot.id
            let windowContext = try self.makeWindowContext(
                for: target,
                webFocus: request.webFocus,
                traversalBudget: request.traversalBudget)

            let actionResult = try await self.context.automation.inspectAccessibilityTreeResult(
                windowContext: windowContext)
            try ObservationActionResultSemantics.requirePublishableOutcome(
                actionResult.outcome,
                targetIdentity: actionResult.targetIdentity,
                operation: "Inspect UI",
                requiresOutcome: request.webFocus)
            let result = actionResult.payload
            let resolvedTarget = try ObservationActionResultSemantics.coalescedTarget(
                actionTarget: actionResult.targetIdentity,
                payload: result,
                outcome: actionResult.outcome,
                operation: "Inspect UI",
                requiresTarget: request.webFocus && target.requiresStableMutationTarget)
            let validatedActionResult = UIAutomationActionResult(
                payload: result,
                outcome: actionResult.outcome,
                targetIdentity: resolvedTarget)
            observationActionResult = validatedActionResult
            try Self.requireUsableAXOnlyEvidence(result)
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

            var metadataValues: [String: Value] = [
                "snapshot_id": .string(snapshot.id),
                "element_count": .double(Double(snapshotResult.elements.all.count)),
                "actionable_count": .double(Double(snapshotResult.elements.all.count(where: \.isEnabled))),
                "used_cache": .bool(snapshotResult.metadata.method.contains("cached")),
                "truncated": .bool(snapshotResult.metadata.truncationInfo?.isTruncated == true),
            ]
            if let completedAt = snapshotResult.metadata.desktopMutationCompletedAt {
                metadataValues["desktop_mutation_completed_at"] =
                    .double(completedAt.timeIntervalSinceReferenceDate)
            }
            if let allowed = snapshotResult.metadata.desktopMutationPreservationAllowed {
                metadataValues["desktop_mutation_preservation_allowed"] = .bool(allowed)
            }
            let metadata = try ObservationActionResultSupport.metadata(
                merging: metadataValues,
                result: validatedActionResult)

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
            let presentedError = ObservationActionResultSupport.preservingFailure(
                error,
                after: observationActionResult,
                operation: "inspect_ui")
            if let newlyCreatedSnapshotID {
                let preserveReservation = newlyCreatedSnapshotWasPending &&
                    PendingSnapshotCleanupPolicy.shouldPreserveReservation(after: presentedError)
                if !preserveReservation {
                    try? await self.context.snapshots.cleanSnapshot(snapshotId: newlyCreatedSnapshotID)
                    await self.context.uiSnapshots.removeSnapshot(id: newlyCreatedSnapshotID)
                }
            }
            self.logger.error("Inspect UI tool execution failed: \(presentedError.localizedDescription)")
            if let failure = presentedError as? DesktopActionFailure {
                return try await MCPDesktopActionFailureHandler.response(
                    for: failure,
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: activeSnapshotID,
                    additionalFields: ObservationActionResultSupport.standardErrorFields(error))
            }
            return Self.failureResponse(presentedError)
        }
    }

    // MARK: - Private Helpers

    private static func requireUsableAXOnlyEvidence(_ result: ElementDetectionResult) throws {
        guard result.elements.all.isEmpty,
              let truncationInfo = result.metadata.truncationInfo,
              truncationInfo.isTruncated
        else { return }

        let message = truncationInfo.automationToolRemediationMessage(
            budget: result.metadata.windowContext?.traversalBudget)
        if truncationInfo.deadlineReached {
            throw PeekabooError.timeout(message)
        }
        if truncationInfo.incompleteAccessibilityRead,
           result.metadata.windowContext?.windowID != nil
        {
            throw PeekabooError.accessibilityIncomplete(message)
        }
        throw PeekabooError.operationError(message: message)
    }

    private static func failureResponse(_ error: any Error) -> ToolResponse {
        let code: StandardErrorCode? = if let error = error as? PeekabooError {
            switch error {
            case .accessibilityIncomplete:
                .accessibilityIncomplete
            case .timeout:
                .timeout
            default:
                nil
            }
        } else {
            nil
        }
        let metadata: Value? = code.map { code in
            .object([
                "error_code": .string(code.rawValue),
                "retry_safe": .bool(true),
                "mutation_dispatched": .bool(false),
            ])
        }
        return ToolResponse.error(
            "Failed to inspect UI: \(error.localizedDescription)",
            meta: metadata)
    }

    private func getOrCreateSnapshot(snapshotId: String?) async throws -> (snapshot: UISnapshot, isNew: Bool) {
        if let snapshotId {
            let hostHasSnapshot = try await self.context.snapshots.listSnapshots().contains { $0.id == snapshotId }
            guard hostHasSnapshot else {
                throw PeekabooError.snapshotNotFound(
                    "Snapshot '\(snapshotId)' was not found. Omit the `snapshot` argument and run `inspect_ui` again.")
            }
            guard let existingSnapshot = await self.context.uiSnapshots.getSnapshot(id: snapshotId) else {
                throw PeekabooError.snapshotNotFound(
                    "Snapshot '\(snapshotId)' is not available in this process. " +
                        "Omit the `snapshot` argument and run `inspect_ui` again.")
            }
            return (existingSnapshot, false)
        }
        let observationStartedAt = MCPToolContext.snapshotObservationStartedAt
        let snapshotId = if let observationStartedAt {
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

    private func parseTarget(_ rawTarget: String?, windowIDValue: Value?) throws -> ObservationTargetArgument {
        guard let rawTarget,
              !rawTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            if windowIDValue != nil {
                return try ObservationTargetArgument.parse(nil, windowIDValue: windowIDValue)
            }
            return .frontmost
        }

        let target = try ObservationTargetArgument.parse(rawTarget, windowIDValue: windowIDValue)
        switch target {
        case .screen, .menubar:
            throw PeekabooError.invalidInput(
                "inspect_ui supports frontmost, AppName, AppName:WindowTitle, PID:PROCESS_ID, and " +
                    "PID:PROCESS_ID:WindowTitle targets. Use `see` for screen or menu bar targets.")
        case .frontmost, .application, .pid:
            return target
        case .windowID:
            throw PeekabooError.invalidInput(
                "inspect_ui window_id requires app_target to identify an application or PID")
        }
    }

    private func makeWindowContext(
        for target: ObservationTargetArgument,
        webFocus: Bool,
        traversalBudget: AXTraversalBudget) throws -> WindowContext
    {
        switch target {
        case .frontmost:
            return WindowContext(shouldFocusWebContent: webFocus, traversalBudget: traversalBudget)
        case let .application(identifier, window):
            let selection = try self.windowSelectionFields(window)
            return WindowContext(
                applicationName: identifier,
                windowTitle: selection.title,
                windowID: selection.id,
                shouldFocusWebContent: webFocus,
                traversalBudget: traversalBudget)
        case let .pid(pid, window):
            let selection = try self.windowSelectionFields(window)
            return WindowContext(
                applicationProcessId: pid,
                windowTitle: selection.title,
                windowID: selection.id,
                shouldFocusWebContent: webFocus,
                traversalBudget: traversalBudget)
        case .windowID:
            throw PeekabooError.invalidInput(
                "inspect_ui window_id requires app_target to identify an application or PID")
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
