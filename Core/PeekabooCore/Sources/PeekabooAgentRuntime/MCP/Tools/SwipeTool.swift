import Foundation
import MCP
import os.log
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for performing swipe/drag gestures
public struct SwipeTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "SwipeTool")
    private let context: MCPToolContext

    public let name = "swipe"

    public var description: String {
        """
        Performs a swipe/drag gesture from one point to another.
        Useful for dragging elements, swiping through content, or gesture-based interactions.
        Creates smooth movement with configurable duration.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "from": SchemaBuilder.string(
                    description: "Starting coordinates in format 'x,y' (e.g., '100,200')."),
                "to": SchemaBuilder.string(
                    description: "Ending coordinates in format 'x,y' (e.g., '300,400')."),
                "duration": SchemaBuilder.number(
                    description: "Optional. Duration of the swipe in milliseconds. Default: 500.",
                    default: 500),
                "steps": SchemaBuilder.number(
                    description: "Optional. Number of intermediate steps for smooth movement. Default: 10.",
                    default: 10),
                "profile": SchemaBuilder.string(
                    description: "Optional. Movement profile. Use 'linear' (default) or 'human'.",
                    enum: ["linear", "human"],
                    default: "linear"),
            ],
            required: ["from", "to"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        // Parse required parameters
        guard let fromString = arguments.getString("from") else {
            return ToolResponse.error("'from' parameter is required")
        }

        guard let toString = arguments.getString("to") else {
            return ToolResponse.error("'to' parameter is required")
        }

        let profileName = (arguments.getString("profile") ?? "linear").lowercased()
        guard let profile = MovementProfileOption(rawValue: profileName) else {
            return ToolResponse.error("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
        }

        let durationProvided = arguments.getValue(for: "duration") != nil
        let stepsProvided = arguments.getValue(for: "steps") != nil
        let durationOverride = durationProvided ? arguments.getNumber("duration").map(Int.init) : nil
        let stepsOverride = stepsProvided ? arguments.getNumber("steps").map(Int.init) : nil

        if let duration = durationOverride {
            guard duration > 0 else {
                return ToolResponse.error("Duration must be greater than 0")
            }
            guard duration <= 30000 else {
                return ToolResponse.error("Duration must be 30 seconds or less to prevent excessive delays")
            }
        }

        if let steps = stepsOverride {
            guard steps > 0 else {
                return ToolResponse.error("Steps must be greater than 0")
            }
            guard steps <= 100 else {
                return ToolResponse.error("Steps must be 100 or less to prevent excessive processing")
            }
        }

        do {
            return try await self.performSwipe(
                fromString: fromString,
                toString: toString,
                durationOverride: durationOverride,
                stepsOverride: stepsOverride,
                profile: profile)
        } catch let coordinateError as CoordinateParseError {
            return ToolResponse.error(coordinateError.message)
        } catch {
            self.logger.error("Swipe execution failed: \(error)")
            return ToolResponse.error("Failed to perform swipe: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private struct CoordinateParseError: Swift.Error {
        let message: String
    }

    private func performSwipe(
        fromString: String,
        toString: String,
        durationOverride: Int?,
        stepsOverride: Int?,
        profile: MovementProfileOption) async throws -> ToolResponse
    {
        let startTime = Date()
        let fromPoint = try self.parseCoordinates(fromString, parameterName: "from")
        let toPoint = try self.parseCoordinates(toString, parameterName: "to")

        guard fromPoint != toPoint else {
            throw CoordinateParseError(message: "'from' and 'to' coordinates must be different")
        }

        let distance = hypot(toPoint.x - fromPoint.x, toPoint.y - fromPoint.y)
        let movement = profile.resolveParameters(
            smooth: true,
            durationOverride: durationOverride,
            stepsOverride: stepsOverride,
            defaultDuration: 500,
            defaultSteps: 10,
            distance: distance)

        let automation = self.context.automation
        try await automation.drag(
            DragOperationRequest(
                from: fromPoint,
                to: toPoint,
                duration: movement.duration,
                steps: movement.steps,
                modifiers: nil,
                profile: movement.profile))

        let executionTime = Date().timeIntervalSince(startTime)
        return self.buildResponse(
            from: fromPoint,
            to: toPoint,
            movement: movement,
            executionTime: executionTime)
    }

    private func buildResponse(
        from fromPoint: CGPoint,
        to toPoint: CGPoint,
        movement: MovementParameters,
        executionTime: TimeInterval) -> ToolResponse
    {
        let deltaX = toPoint.x - fromPoint.x
        let deltaY = toPoint.y - fromPoint.y
        let distance = sqrt(deltaX * deltaX + deltaY * deltaY)
        let distanceText = String(format: "%.1f", distance)
        let durationText = String(format: "%.2f", executionTime)

        let message = """
        \(AgentDisplayTokens.Status.success) Performed swipe from
        (\(Int(fromPoint.x)), \(Int(fromPoint.y))) to
        (\(Int(toPoint.x)), \(Int(toPoint.y))) over \(movement.duration)ms
        with \(movement.steps) steps (\(movement.profileName) profile, distance: \(distanceText)px) in \(durationText)s
        """

        let metaDict: [String: Value] = [
            "from": .object([
                "x": .double(Double(fromPoint.x)),
                "y": .double(Double(fromPoint.y)),
            ]),
            "to": .object([
                "x": .double(Double(toPoint.x)),
                "y": .double(Double(toPoint.y)),
            ]),
            "duration": .double(Double(movement.duration)),
            "steps": .double(Double(movement.steps)),
            "profile": .string(movement.profileName),
            "distance": .double(distance),
            "execution_time": .double(executionTime),
        ]

        let summary = ToolEventSummary(
            actionDescription: "Swipe",
            coordinates: ToolEventSummary.Coordinates(x: Double(toPoint.x), y: Double(toPoint.y)),
            pointerProfile: movement.profileName,
            pointerDistance: Double(distance),
            pointerDirection: pointerDirection(from: fromPoint, to: toPoint),
            pointerDurationMs: Double(movement.duration),
            notes: "from (\(Int(fromPoint.x)), \(Int(fromPoint.y))) to (\(Int(toPoint.x)), \(Int(toPoint.y)))")

        let metaValue = ToolEventSummary.merge(summary: summary, into: .object(metaDict))

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: metaValue)
    }

    private func parseCoordinates(_ coordString: String, parameterName: String) throws -> CGPoint {
        let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        guard parts.count == 2 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates format. Use 'x,y' (e.g., '100,200')")
        }

        guard let x = Double(parts[0]), let y = Double(parts[1]) else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates. Both x and y must be valid numbers")
        }

        // Validate coordinates are reasonable (not negative, not extremely large)
        guard x >= 0, y >= 0 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates. Both x and y must be non-negative")
        }

        guard x <= 10000, y <= 10000 else {
            throw CoordinateParseError(
                message: "Invalid \(parameterName) coordinates. Both x and y must be 10000 or less")
        }

        return CGPoint(x: x, y: y)
    }
}
