import Foundation
import MCP
import os.log
import PeekabooAutomation
import Tachikoma
import TachikomaMCP

/// MCP tool for executing complex automation tasks using an AI agent
public struct MCPAgentTool: MCPTool {
    private let logger = os.Logger(subsystem: "boo.peekaboo.mcp", category: "AgentTool")
    private let context: MCPToolContext

    public let name = "agent"

    public var description: String {
        """
        Execute complex automation tasks using the configured AI provider.
        The agent can understand natural language instructions and break them down into specific
        Peekaboo commands to accomplish complex workflows.

        Capabilities:
        - Natural Language Processing: Understands tasks described in plain English
        - Multi-step Automation: Breaks complex tasks into sequential steps
        - Visual Feedback: Can take screenshots to verify results
        - Context Awareness: Maintains session state across multiple actions
        - Error Recovery: Can adapt and retry when actions fail

        The agent has access to all Peekaboo automation tools including:
        - Screen capture and analysis
        - UI element interaction (click, type, scroll)
        - Application control (launch, quit, focus)
        - Window management (move, resize, close)
        - System interaction (hotkeys, shell commands)

        Example tasks:
        - "Open Safari and navigate to apple.com"
        - "Take a screenshot of the current window and save it to Desktop"
        - "Find the login button and click it, then type my credentials"
        - "Open TextEdit, write 'Hello World', and save the document"

        Requires a configured provider credential or local model runtime.
        \(PeekabooMCPVersion.banner)
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "task": SchemaBuilder.string(
                    description: "Task to perform in natural language (omit when only listing sessions)"),
                "model": SchemaBuilder.string(
                    description: """
                    OpenAI model to use (e.g., gpt-5.5, gpt-5-mini).
                    Call `list_models` first to see available presets and descriptions.
                    Choose 'FastChat' for quick responses, 'DeepAnalysis' for complex reasoning, etc.
                    If omitted, the tool auto-selects the first mode-compatible preset.
                    """),
                "quiet": SchemaBuilder.boolean(
                    description: "Quiet mode - only show final result",
                    default: false),
                "verbose": SchemaBuilder.boolean(
                    description: "Enable verbose output with full JSON debug information",
                    default: false),
                "dry_run": SchemaBuilder.boolean(
                    description: "Dry run - show planned steps without executing",
                    default: false),
                "max_steps": SchemaBuilder.integer(
                    description: "Maximum model/tool-loop turns before failing " +
                        "(\(AgentStepBudget.supportedRange.lowerBound)-" +
                        "\(AgentStepBudget.supportedRange.upperBound), default 20)"),
                "resume": SchemaBuilder.boolean(
                    description: "Resume the most recent session",
                    default: false),
                "resumeSession": SchemaBuilder.string(
                    description: "Resume a specific session by ID"),
                "listSessions": SchemaBuilder.boolean(
                    description: "List available sessions",
                    default: false),
                "noCache": SchemaBuilder.boolean(
                    description: "Disable session caching (always create new session)",
                    default: false),
            ],
            required: [])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        let input = try arguments.decode(AgentInput.self)
        self.logger.info("AgentTool executing with task: \(input.task ?? "none"), listSessions: \(input.listSessions)")

        if input.listSessions {
            return try await self.listSessionsResponse()
        }

        guard let task = input.task else {
            return ToolResponse.error("Missing required parameter: task")
        }

        do {
            let result = try await self.runAgentTask(task: task, input: input)
            return self.formatResult(result: result, input: input)
        } catch let error as AgentToolError {
            return ToolResponse.error(error.message)
        } catch {
            self.logger.error("Agent execution failed: \(error.localizedDescription)")
            return ToolResponse.error("Agent execution failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Execution Helpers

    private func listSessionsResponse() async throws -> ToolResponse {
        guard let agent = self.context.agent as? PeekabooAgentService else {
            throw AgentToolError("Agent service not available")
        }

        let sessions = try await agent.listSessions()
        let summary = self.renderSessionSummaries(sessions)
        let isoFormatter = ISO8601DateFormatter()
        let sessionsArray = sessions.map { session in
            Value.object([
                "id": .string(session.id),
                "createdAt": .string(isoFormatter.string(from: session.createdAt)),
                "updatedAt": .string(isoFormatter.string(from: session.lastAccessedAt)),
                "messageCount": .string(String(session.messageCount)),
            ])
        }

        let baseMeta = Value.object([
            "sessionCount": .string(String(sessions.count)),
            "sessions": .array(sessionsArray),
        ])
        let summaryMeta = ToolEventSummary(
            actionDescription: "List agent sessions",
            notes: "\(sessions.count) session\(sessions.count == 1 ? "" : "s")")

        return ToolResponse.text(
            "Available Sessions:\n\n\(summary)",
            meta: ToolEventSummary.merge(summary: summaryMeta, into: baseMeta))
    }

    private func renderSessionSummaries(_ sessions: [SessionSummary]) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        return sessions.map { session in
            [
                "ID: \(session.id)",
                "Created: \(formatter.string(from: session.createdAt))",
                "Updated: \(formatter.string(from: session.lastAccessedAt))",
                "Message Count: \(session.messageCount)",
            ].joined(separator: "\n")
        }.joined(separator: "\n---\n")
    }

    @MainActor
    private func runAgentTask(task: String, input: AgentInput) async throws -> AgentExecutionResult {
        guard let agent = self.context.agent as? PeekabooAgentService else {
            throw AgentToolError("Agent service not available")
        }

        let maxSteps = try Self.validatedMaxSteps(input.maxSteps)
        let modelOverride = try Self.modelOverride(from: input.model) { modelString in
            agent.resolveConfiguredModel(modelString)
        }

        if let sessionId = input.resumeSession {
            return try await agent.resumeSession(
                sessionId: sessionId,
                model: modelOverride,
                maxSteps: maxSteps)
        }

        if input.resume {
            let sessions = try await agent.listSessions()
            guard let latest = sessions.first else {
                throw AgentToolError("No sessions available to resume")
            }
            return try await agent.resumeSession(
                sessionId: latest.id,
                model: modelOverride,
                maxSteps: maxSteps)
        }

        if input.dryRun {
            return try await agent.executeTask(
                task,
                maxSteps: maxSteps,
                model: modelOverride,
                dryRun: true,
                eventDelegate: nil)
        }

        let sessionId = input.noCache ? nil : UUID().uuidString
        return try await agent.executeTask(
            task,
            maxSteps: maxSteps,
            sessionId: sessionId,
            model: modelOverride,
            eventDelegate: nil)
    }

    static func validatedMaxSteps(_ maxSteps: Int?) throws -> Int {
        let resolved = maxSteps ?? 20
        guard AgentStepBudget.supportedRange.contains(resolved) else {
            throw AgentToolError(
                "max_steps must be between \(AgentStepBudget.supportedRange.lowerBound) and " +
                    "\(AgentStepBudget.supportedRange.upperBound)")
        }
        return resolved
    }

    static func modelOverride(
        from modelString: String?,
        resolver: (String) -> LanguageModel?) throws -> LanguageModel?
    {
        guard let modelString else { return nil }
        let trimmed = modelString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let model = resolver(trimmed),
              model.supportsTools
        else {
            throw AgentToolError("Unsupported agent model: \(modelString)")
        }
        return model
    }

    private func formatResult(result: AgentExecutionResult, input: AgentInput) -> ToolResponse {
        let summary = self.summary(for: result)

        if input.quiet {
            return ToolResponse.text(result.content, meta: ToolEventSummary.merge(summary: summary, into: nil))
        }

        if input.verbose {
            let verboseMeta = self.verboseMetadata(for: result)
            return ToolResponse.text(
                result.content,
                meta: ToolEventSummary.merge(summary: summary, into: verboseMeta))
        }

        var output = result.content
        if let sessionId = result.sessionId {
            output += "\n🆔 Session: \(sessionId)"
        }
        if !result.metadata.modelName.isEmpty {
            output += "\n⚙️  Model: \(result.metadata.modelName)"
        }
        if result.metadata.toolCallCount > 0 {
            output += "\n🛠️  Tool Calls: \(result.metadata.toolCallCount)"
        }
        if let usage = result.usage {
            let tokensLine = "\n📊 Tokens — Input: \(usage.inputTokens), " +
                "Output: \(usage.outputTokens), Total: \(usage.totalTokens)"
            output += tokensLine
        }

        let baseMeta = result.sessionId.map { Value.object(["sessionId": .string($0)]) }
        return ToolResponse.text(output, meta: ToolEventSummary.merge(summary: summary, into: baseMeta))
    }

    private func summary(for result: AgentExecutionResult) -> ToolEventSummary {
        var details: [String] = []
        if !result.metadata.modelName.isEmpty {
            details.append("Model \(result.metadata.modelName)")
        }
        if result.metadata.toolCallCount > 0 {
            details.append("\(result.metadata.toolCallCount) tool call\(result.metadata.toolCallCount == 1 ? "" : "s")")
        }
        if let usage = result.usage {
            details.append("\(usage.totalTokens) tokens total")
        }

        return ToolEventSummary(
            actionDescription: "Agent run",
            notes: details.isEmpty ? nil : details.joined(separator: " · "))
    }

    private func verboseMetadata(for result: AgentExecutionResult) -> Value {
        var metadata: [String: Value] = [
            "toolCallCount": .int(result.metadata.toolCallCount),
            "modelName": .string(result.metadata.modelName),
        ]

        if let sessionId = result.sessionId {
            metadata["sessionId"] = .string(sessionId)
        }

        if let usage = result.usage {
            metadata["usage"] = .object([
                "inputTokens": .string(String(usage.inputTokens)),
                "outputTokens": .string(String(usage.outputTokens)),
                "totalTokens": .string(String(usage.totalTokens)),
            ])
        }

        return .object(metadata)
    }
}

// MARK: - Supporting Types

struct AgentInput: Codable {
    let task: String?
    let model: String?
    let quiet: Bool
    let verbose: Bool
    let dryRun: Bool
    let maxSteps: Int?
    let resume: Bool
    let resumeSession: String?
    let listSessions: Bool
    let noCache: Bool

    enum CodingKeys: String, CodingKey {
        case task, model, quiet, verbose, resume, noCache
        case dryRun = "dry_run"
        case maxSteps = "max_steps"
        case resumeSession
        case listSessions
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.task = try container.decodeIfPresent(String.self, forKey: .task)
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.quiet = try container.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
        self.verbose = try container.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        self.dryRun = try container.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
        self.maxSteps = try container.decodeIfPresent(Int.self, forKey: .maxSteps)
        self.resume = try container.decodeIfPresent(Bool.self, forKey: .resume) ?? false
        self.resumeSession = try container.decodeIfPresent(String.self, forKey: .resumeSession)
        self.listSessions = try container.decodeIfPresent(Bool.self, forKey: .listSessions) ?? false
        self.noCache = try container.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
    }
}

private struct AgentToolError: Error {
    let message: String
    init(_ message: String) {
        self.message = message
    }
}
