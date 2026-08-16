import CoreGraphics
import Foundation
import MCP
import os.log
import PeekabooFoundation
import TachikomaMCP

/// MCP tool for moving the mouse cursor
public struct MoveTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "MoveTool")
    let context: MCPToolContext

    public let name = "move"

    public var description: String {
        """
        Move the mouse cursor to a specific position or UI element.
        Supports absolute coordinates, UI element targeting, or centering on screen.
        This always changes the shared physical cursor and requires foreground=true.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.6, anthropic/claude-opus-5
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "to": SchemaBuilder.string(
                    description: "Optional. Coordinates in format 'x,y' (e.g., '100,200') " +
                        "or 'center' to center on screen."),
                "coordinates": SchemaBuilder.string(
                    description: "Optional. Alias for 'to' - coordinates in format 'x,y' (e.g., '100,200')."),
                "id": SchemaBuilder.string(
                    description: "Optional. Element ID to move to (from `see` or `inspect_ui` output)."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
                "center": SchemaBuilder.boolean(
                    description: "Optional. Move to center of screen.",
                    default: false),
                "smooth": SchemaBuilder.boolean(
                    description: "Optional. Use smooth animated movement.",
                    default: false),
                "duration": SchemaBuilder.integer(
                    description: "Optional. Duration in milliseconds for smooth movement. Default: 500.",
                    default: 500),
                "steps": SchemaBuilder.integer(
                    description: "Optional. Number of steps for smooth movement. Default: 10.",
                    default: 10),
                "profile": SchemaBuilder.string(
                    description: "Optional. Movement profile. Use 'linear' (default) or 'human' for natural paths.",
                    enum: ["linear", "human"],
                    default: "linear"),
                "foreground": SchemaBuilder.boolean(
                    description: "Required. Confirm foreground use of the shared physical cursor."),
            ],
            required: ["foreground"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let request: MoveRequest
        do {
            request = try self.parseRequest(arguments: arguments)
        } catch let error as MoveToolValidationError {
            return ToolResponse.error(error.message)
        } catch let coordinateError as CoordinateParseError {
            return ToolResponse.error(coordinateError.message)
        }

        do {
            let startTime = Date()
            let target = try await self.resolveMoveTarget(request: request)
            let setupFocus = try await self.focusTargetIfNeeded(target)
            let movement: MovementExecution
            do {
                movement = try await self.performMovement(
                    to: target.location,
                    request: request,
                    setupFocus: setupFocus)
            } catch {
                let failure = MCPGlobalPointerActionResult.failure(
                    error,
                    setupFocus: setupFocus,
                    operation: "Cursor move",
                    route: MCPGlobalPointerActionResult.route(for: self.context))
                return try await MCPDesktopActionFailureHandler.response(
                    for: failure,
                    uiSnapshots: self.context.uiSnapshots,
                    snapshotID: request.snapshotId)
            }
            let executionTime = Date().timeIntervalSince(startTime)
            let invalidatedSnapshotID = await MCPDesktopActionSnapshotInvalidator.invalidate(
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: request.snapshotId,
                outcome: movement.actionResult.outcome)
            return try self.buildResponse(
                target: target,
                movement: movement,
                executionTime: executionTime,
                invalidatedSnapshotID: invalidatedSnapshotID)
        } catch let failure as DesktopActionFailure {
            return try await MCPDesktopActionFailureHandler.response(
                for: failure,
                uiSnapshots: self.context.uiSnapshots,
                snapshotID: request.snapshotId)
        } catch {
            self.logger.error("Mouse movement execution failed: \(error)")
            return ToolResponse.error("Failed to move mouse: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers
}
