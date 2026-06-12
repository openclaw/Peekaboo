import Foundation
import MCP
import os.log
import PeekabooAutomation
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
        Includes focus options for handling windows in different spaces.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
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
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified"),
                "duration": SchemaBuilder.number(
                    description: "Optional. Duration in milliseconds (default: 500)",
                    default: 500),
                "steps": SchemaBuilder.number(
                    description: "Optional. Number of intermediate steps (default: 10)",
                    default: 10),
                "profile": SchemaBuilder.string(
                    description: "Optional. Movement profile. Use 'linear' (default) or 'human'.",
                    enum: ["linear", "human"],
                    default: "linear"),
                "modifiers": SchemaBuilder.string(
                    description: "Optional. Comma-separated modifiers (cmd, shift, alt, ctrl)"),
                "auto_focus": SchemaBuilder.boolean(
                    description: "Optional. Auto-focus target window (default: true)",
                    default: true),
                "bring_to_current_space": SchemaBuilder.boolean(
                    description: "Optional. Bring window to current space",
                    default: false),
                "space_switch": SchemaBuilder.boolean(
                    description: "Optional. Allow switching spaces",
                    default: false),
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
            return ToolResponse.error(error.message)
        }

        do {
            let startTime = Date()
            let fromPoint = try await self.resolveLocation(
                target: request.fromTarget,
                snapshotId: request.snapshotId,
                parameterName: "from")
            let toPoint = try await self.resolveLocation(
                target: request.toTarget,
                snapshotId: request.snapshotId,
                parameterName: "to")

            guard fromPoint.point != toPoint.point else {
                return ToolResponse.error("Start and end points must be different")
            }

            try await self.focusTargetAppIfNeeded(request: request)
            self.logSpaceIntentIfNeeded(request: request)

            let distance = hypot(toPoint.point.x - fromPoint.point.x, toPoint.point.y - fromPoint.point.y)
            let movement = request.profile.resolveParameters(
                smooth: true,
                durationOverride: request.durationOverride,
                stepsOverride: request.stepsOverride,
                defaultDuration: 500,
                defaultSteps: 20,
                distance: distance)

            try await self.context.automation.drag(
                DragOperationRequest(
                    from: fromPoint.point,
                    to: toPoint.point,
                    duration: movement.duration,
                    steps: movement.steps,
                    modifiers: request.modifiers,
                    profile: movement.profile))

            let executionTime = Date().timeIntervalSince(startTime)
            return self.buildResponse(
                from: fromPoint,
                to: toPoint,
                movement: movement,
                executionTime: executionTime,
                request: request)
        } catch let error as CoordinateParseError {
            return ToolResponse.error(error.message)
        } catch let error as DragToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("Drag execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Failed to perform drag operation: \(error.localizedDescription)")
        }
    }
}
