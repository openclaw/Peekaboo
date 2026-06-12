import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

/// MCP tool for pausing execution
public struct SleepTool: MCPTool {
    public let name = "sleep"
    public let description = """
    Pauses execution for a specified duration.
    Useful for waiting between UI actions or allowing animations to complete.
    \(PeekabooMCPVersion.banner) using openai/gpt-5.5, anthropic/claude-opus-4-8
    """

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "duration": SchemaBuilder.number(
                    description: "Sleep duration in milliseconds."),
            ],
            required: ["duration"])
    }

    public init() {}

    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        // Extract duration using the helper method
        guard let duration = arguments.getNumber("duration") else {
            return ToolResponse.error("Missing required parameter: duration")
        }

        // Validate duration
        guard duration > 0 else {
            return ToolResponse.error("Duration must be positive")
        }

        // Convert to reasonable integer value
        let milliseconds = Int(duration)
        guard milliseconds <= 600_000 else { // Max 10 minutes
            return ToolResponse.error("Duration cannot exceed 600000ms (10 minutes)")
        }

        let startTime = Date()

        // Perform sleep
        try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)

        let actualDuration = Date().timeIntervalSince(startTime) * 1000 // Convert to ms
        let seconds = Double(milliseconds) / 1000.0

        let summaryText =
            "\(AgentDisplayTokens.Status.success) Paused for \(seconds)s " +
            "(requested: \(milliseconds)ms, actual: \(Int(actualDuration))ms)"
        let summaryMeta = ToolEventSummary(
            actionDescription: "Sleep",
            waitDurationMs: actualDuration,
            waitReason: nil)
        return ToolResponse.text(summaryText, meta: ToolEventSummary.merge(summary: summaryMeta, into: nil))
    }
}
