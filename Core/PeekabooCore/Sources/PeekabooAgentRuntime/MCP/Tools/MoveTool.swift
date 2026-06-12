import CoreGraphics
import Foundation
import MCP
import os.log
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
        Can animate movement smoothly over a specified duration.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
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
                "duration": SchemaBuilder.number(
                    description: "Optional. Duration in milliseconds for smooth movement. Default: 500.",
                    default: 500),
                "steps": SchemaBuilder.number(
                    description: "Optional. Number of steps for smooth movement. Default: 10.",
                    default: 10),
                "profile": SchemaBuilder.string(
                    description: "Optional. Movement profile. Use 'linear' (default) or 'human' for natural paths.",
                    enum: ["linear", "human"],
                    default: "linear"),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try self.parseRequest(arguments: arguments)
            let startTime = Date()
            let target = try await self.resolveMoveTarget(request: request)
            let movement = try await self.performMovement(to: target.location, request: request)
            let executionTime = Date().timeIntervalSince(startTime)
            return self.buildResponse(
                target: target,
                movement: movement,
                executionTime: executionTime)
        } catch let error as MoveToolValidationError {
            return ToolResponse.error(error.message)
        } catch let coordinateError as CoordinateParseError {
            return ToolResponse.error(coordinateError.message)
        } catch {
            self.logger.error("Mouse movement execution failed: \(error)")
            return ToolResponse.error("Failed to move mouse: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers
}
