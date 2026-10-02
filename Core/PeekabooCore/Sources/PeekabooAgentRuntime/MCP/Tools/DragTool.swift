import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for performing drag and drop operations between UI elements or coordinates
public struct DragTool: MCPTool {
    let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "DragTool")
    let context: MCPToolContext

    public let name = "drag"

    public var description: String {
        """
        Perform drag and drop operations between UI elements or coordinates.
        Supports element queries, specific IDs, or raw coordinates for both start and end points.
        Background drag requires an explicit fresh snapshot and a bounded linear path inside its exact window.
        Coordinates are global logical points. Cross-window drops and shared cursor input require foreground=true.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "from": SchemaBuilder.string(
                    description: "Optional. Start element ID or query"),
                "from_coords": SchemaBuilder.string(
                    description: "Optional. Start coordinates in format 'x,y' (e.g., '100,200')"),
                "to": SchemaBuilder.string(
                    description: "Optional. End element ID or query"),
                "to_coords": SchemaBuilder.string(
                    description: "Optional. End coordinates in format 'x,y' (e.g., '300,400')"),
                "to_app": SchemaBuilder.string(
                    description: "Optional. Target application name when dragging between apps"),
                "snapshot": SchemaBuilder.string(
                    description: "Required in background mode: an explicit fresh exact-window snapshot from `see` " +
                        "or `inspect_ui`. Foreground mode may use the latest snapshot."),
                "duration": SchemaBuilder.integer(
                    description: "Optional. Duration in milliseconds (default: 500)",
                    default: 500),
                "steps": SchemaBuilder.integer(
                    description: "Optional. Number of intermediate steps (default: 10)",
                    default: 10),
                "profile": SchemaBuilder.string(
                    description: "Optional. Movement profile. Use 'linear' (default) or 'human'.",
                    enum: ["linear", "human"],
                    default: "linear"),
                "modifiers": SchemaBuilder.string(
                    description: "Optional. Comma-separated modifiers (cmd, shift, alt, ctrl)"),
                "button": SchemaBuilder.string(
                    description: "Optional. Mouse button to hold during drag.",
                    enum: ["left", "right"],
                    default: "left"),
                "foreground": SchemaBuilder.boolean(
                    description: "Optional. Confirm foreground use of the shared physical cursor. Default: false."),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request: DragRequest
        do {
            request = try DragRequest(arguments: arguments)
        } catch let error as DragToolError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message, reason: .invalidRequest)
        } catch {
            return ToolResponse.error(error.localizedDescription)
        }

        var completedAction: UIAutomationActionResult<Void>?
        do {
            let startTime = Date()
            let fromPoint = try await self.resolveLocation(
                target: request.fromTarget,
                snapshotId: request.snapshotId,
                parameterName: "from",
                background: !request.foreground)
            let toPoint = try await self.resolveLocation(
                target: request.toTarget,
                snapshotId: request.snapshotId,
                parameterName: "to",
                background: !request.foreground)

            guard fromPoint.point != toPoint.point else {
                return ToolResponse.error("Start and end points must be different")
            }

            let setupFocus: MCPInteractionFocusResult? = if request.foreground {
                try await self.focusTargetIfNeeded(request: request, from: fromPoint, to: toPoint)
            } else {
                nil
            }

            let distance = hypot(toPoint.point.x - fromPoint.point.x, toPoint.point.y - fromPoint.point.y)
            let movement = request.profile.resolveParameters(
                smooth: true,
                durationOverride: request.durationOverride,
                stepsOverride: request.stepsOverride,
                defaultDuration: 500,
                defaultSteps: 20,
                distance: distance)

            let actionResult: UIAutomationActionResult<Void>
            do {
                if !request.foreground {
                    guard let service = self.context.automation as? any ExactWindowDragServiceProtocol,
                          service.supportsExactWindowDrag,
                          let snapshotID = request.snapshotId,
                          let snapshot = await self.getSnapshot(id: snapshotID),
                          let target = try snapshot.targetReceipt().requireIdentity().exactWindow
                    else {
                        throw DragToolError(
                            "Background drag requires a capable host and a fresh exact-window snapshot.")
                    }
                    let drag = ExactWindowDragRequest(
                        snapshotID: snapshotID,
                        target: target,
                        from: fromPoint.point,
                        to: toPoint.point,
                        durationMilliseconds: movement.duration,
                        steps: movement.steps,
                        button: request.button == .right ? .right : .left)
                    try drag.validate()
                    actionResult = try await self.context.snapshots.withSnapshotMutation(
                        snapshotId: snapshotID,
                        targetIdentity: DesktopTargetIdentity(exactWindow: target),
                        operation: {
                            try await service.dragExactWindow(drag, boundTo: nil)
                        },
                        outcome: { $0.outcome })
                } else {
                    let pointerAction = try await MCPGlobalPointerActionResult.drag(
                        automation: self.context.automation,
                        request: DragOperationRequest(
                            from: fromPoint.point,
                            to: toPoint.point,
                            duration: movement.duration,
                            steps: movement.steps,
                            modifiers: request.modifiers,
                            button: request.button,
                            profile: movement.profile))
                    actionResult = try MCPGlobalPointerActionResult.compose(
                        setupFocus: setupFocus,
                        pointerAction: pointerAction,
                        operation: "Drag",
                        route: MCPGlobalPointerActionResult.route(for: self.context))
                }
            } catch {
                if !request.foreground {
                    throw error
                }
                let failure = MCPGlobalPointerActionResult.failure(
                    error,
                    setupFocus: setupFocus,
                    operation: "Drag",
                    route: MCPGlobalPointerActionResult.route(for: self.context))
                return try await MCPDesktopActionFailureHandler.response(
                    for: failure,
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: request.snapshotId)
            }

            completedAction = actionResult
            let executionTime = Date().timeIntervalSince(startTime)
            let invalidatedSnapshotID = await MCPDesktopActionSnapshotInvalidator.invalidate(
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: request.snapshotId,
                outcome: actionResult.outcome)
            return try self.buildResponse(
                from: fromPoint,
                to: toPoint,
                context: DragResponseContext(
                    movement: movement,
                    executionTime: executionTime,
                    request: request,
                    actionResult: actionResult,
                    invalidatedSnapshotID: invalidatedSnapshotID))
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: request.snapshotId)
        } catch let error as CoordinateParseError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message, reason: .invalidRequest)
        } catch let error as DragToolError {
            return MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
                message: error.message, reason: .invalidRequest)
        } catch {
            if let completedAction, let outcome = completedAction.outcome,
               let failure = DesktopActionFailure(
                   outcome: outcome,
                   message: "Drag dispatched, but its response could not be completed.",
                   hint: "Observe the exact target before any retry.",
                   causeDescription: error.localizedDescription,
                   targetReceipt: completedAction.actionTargetReceipt)
            {
                return try await MCPDesktopActionFailureHandler.response(
                    for: failure, uiSnapshots: self.context.uiSnapshots, snapshotID: request.snapshotId)
            }
            self.logger.error("Drag execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform drag operation: \(error.localizedDescription)")
        }
    }
}
