import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

private typealias ToolScrollDirection = PeekabooFoundation.ScrollDirection

/// MCP tool for scrolling UI elements or at current mouse position
public struct ScrollTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "ScrollTool")
    private let context: MCPToolContext

    public let name = "scroll"

    public var description: String {
        """
        Scrolls the mouse wheel in any direction.
        Can target specific elements or scroll at current mouse position.
        Supports smooth scrolling and configurable speed.
        \(PeekabooMCPVersion.banner) using openai/gpt-5.5
        and anthropic/claude-opus-4-8
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "direction": SchemaBuilder.string(
                    description: "Scroll direction: up (content moves up), down (content moves down), left, or right.",
                    enum: ["up", "down", "left", "right"]),
                "on": SchemaBuilder.string(
                    description: "Optional. Element ID to scroll on (from `see` or `inspect_ui`). " +
                        "If not specified, scrolls at current mouse position."),
                "snapshot": SchemaBuilder.string(
                    description: "Optional. Snapshot ID from `see` or `inspect_ui`. " +
                        "Uses latest snapshot if not specified."),
                "amount": SchemaBuilder.number(
                    description: "Optional. Number of scroll ticks/lines. Default: 3.",
                    default: 3),
                "delay": SchemaBuilder.number(
                    description: "Optional. Delay between scroll ticks in milliseconds. Default: 2.",
                    default: 2),
                "smooth": SchemaBuilder.boolean(
                    description: "Optional. Use smooth scrolling with smaller increments.",
                    default: false),
            ],
            required: ["direction"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try self.parseRequest(arguments: arguments)
            return try await self.performScroll(request: request)
        } catch let error as ScrollToolValidationError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("Scroll execution failed: \(error)")
            return ToolResponse.error("Failed to perform scroll: \(error.localizedDescription)")
        }
    }

    // MARK: - Private Helpers

    private func parseScrollDirection(_ direction: String) -> ToolScrollDirection? {
        switch direction.lowercased() {
        case "up":
            .up
        case "down":
            .down
        case "left":
            .left
        case "right":
            .right
        default:
            nil
        }
    }

    private func getSnapshot(id: String?) async -> UISnapshot? {
        await UISnapshotManager.shared.getSnapshot(id: id)
    }

    private func parseRequest(arguments: ToolArguments) throws -> ScrollToolRequest {
        guard let directionString = arguments.getString("direction") else {
            throw ScrollToolValidationError("Direction is required")
        }

        guard let direction = self.parseScrollDirection(directionString) else {
            throw ScrollToolValidationError("Invalid direction. Must be one of: up, down, left, right")
        }

        let amount = Int(arguments.getNumber("amount") ?? 3)
        guard amount > 0 else {
            throw ScrollToolValidationError("Amount must be greater than 0")
        }
        guard amount <= 50 else {
            throw ScrollToolValidationError("Amount must be 50 or less to prevent excessive scrolling")
        }

        return ScrollToolRequest(
            direction: direction,
            elementId: arguments.getString("on"),
            snapshotId: arguments.getString("snapshot"),
            amount: amount,
            delay: Int(arguments.getNumber("delay") ?? 2),
            smooth: arguments.getBool("smooth") ?? false)
    }

    @MainActor
    private func performScroll(request: ScrollToolRequest) async throws -> ToolResponse {
        let automation = self.context.automation
        let startTime = Date()

        let target = try await self.resolveTargetDescription(request: request)
        let serviceRequest = ScrollRequest(
            direction: request.direction,
            amount: request.amount,
            target: target.elementId,
            smooth: request.smooth,
            delay: request.delay,
            snapshotId: target.snapshotId)
        try await automation.scroll(serviceRequest)

        let invalidatedSnapshotId = await UISnapshotManager.shared.invalidateActiveSnapshot(id: target.snapshotId)
        let executionTime = Date().timeIntervalSince(startTime)
        let scrollDescription = request.smooth ? "smooth scroll" : "scroll"
        let duration = String(format: "%.2f", executionTime) + "s"
        let message = "\(AgentDisplayTokens.Status.success) Performed \(scrollDescription) \(request.direction) " +
            "(\(request.amount) ticks) \(target.description) in \(duration)"

        let summary = ToolEventSummary(
            targetApp: target.appName,
            actionDescription: request.smooth ? "Smooth scroll" : "Scroll",
            scrollDirection: request.direction.rawValue,
            scrollAmount: Double(request.amount),
            notes: target.description)
        var baseMeta: [String: Value] = [:]
        if let invalidatedSnapshotId {
            baseMeta["invalidated_snapshot"] = .string(invalidatedSnapshotId)
            baseMeta["requires_fresh_observation"] = .bool(true)
        }
        let meta = baseMeta.isEmpty ? nil : Value.object(baseMeta)
        return ToolResponse.text(message, meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    @MainActor
    private func resolveTargetDescription(request: ScrollToolRequest) async throws -> ScrollTargetDescription {
        guard let elementId = request.elementId else {
            return ScrollTargetDescription(
                elementId: nil,
                description: "at current mouse position",
                appName: nil,
                snapshotId: request.snapshotId)
        }

        guard let snapshot = await self.getSnapshot(id: request.snapshotId) else {
            throw ScrollToolValidationError("No active snapshot. Run 'see' or 'inspect_ui' first to capture UI state.")
        }

        guard let element = await snapshot.getElement(byId: elementId) else {
            throw ScrollToolValidationError(
                "Element '\(elementId)' not found in current snapshot. Run 'see' or 'inspect_ui' to update UI state.")
        }

        let label = element.title ?? element.label ?? "untitled"
        let description = "on \(element.role): \(label)"
        return ScrollTargetDescription(
            elementId: elementId,
            description: description,
            appName: snapshot.applicationName,
            snapshotId: snapshot.id)
    }
}

private struct ScrollToolRequest {
    let direction: ToolScrollDirection
    let elementId: String?
    let snapshotId: String?
    let amount: Int
    let delay: Int
    let smooth: Bool
}

private struct ScrollTargetDescription {
    let elementId: String?
    let description: String
    let appName: String?
    let snapshotId: String?
}

private struct ScrollToolValidationError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
