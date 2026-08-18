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
        - Background application control (already-running launch readiness checks, quit, inspect)
        - Window management (move, resize, close)
        - Background text delivery and native Accessibility actions

        MCP-started Agent sessions are always background-only. They refuse focus/activation, shared-pointer/global
        input, foreground capture, persistent clipboard writes, targetless dialog input, dialog file actions, shared
        system UI mutations, Space switch/follow, browser setup/fronting, and Shell-tool access before dispatch.
        \(AgentBackgroundCapabilityContract.receiptPinnedPress)
        \(AgentBackgroundCapabilityContract.snapshotPinnedType)
        \(AgentBackgroundCapabilityContract.exactDialogMutations)
        \(AgentBackgroundCapabilityContract.rawPressObservation)
        Space listing and unfollowed window placement remain available. This UI authority boundary
        is not a process sandbox; trusted prompts can operate terminal or scripting apps through their UI. Only the
        human-facing CLI can explicitly authorize foreground UI for a session. Direct text paste is available only
        with a generation-pinned app/PID/window target and a canonical background result; targetless, foreground,
        current-clipboard, and binary paste remain refused.

        Example tasks:
        - "Inspect the current page in an already-running Safari window"
        - "Take a screenshot of the current window and save it to Desktop"
        - "Find the login button and click it, then type my credentials"
        - "In an already-running TextEdit document, write 'Hello World'"

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
                    OpenAI model to use (e.g., gpt-5.6, gpt-5-mini).
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
                    description: "Validate and echo the task without calling a model or tools",
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
                    description: "Run without saving a resumable session; " +
                        "incompatible with resume/list options",
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
        self.logger.info(
            "AgentTool executing with task: \(input.task ?? "none"), listSessions: \(input.listSessions)")

        do {
            try Self.validateSessionOptions(
                noCache: input.noCache,
                resume: input.resume,
                resumeSession: input.resumeSession,
                listSessions: input.listSessions)
            _ = try Self.validatedMaxSteps(input.maxSteps)
            guard input.listSessions || input.task != nil else {
                throw AgentToolError("Missing required parameter: task")
            }
        } catch let error as AgentToolError {
            return ToolResponse.error(error.message)
        }
        if let rejection = self.context.executionPolicy.nestedAgentAuthorityRejection() {
            return rejection
        }

        if input.listSessions {
            return try await self.listSessionsResponse()
        }

        guard let task = input.task else { preconditionFailure("Agent task validation must run before dispatch") }

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
                "status": .string(session.status.rawValue),
                "task": .string(session.summary ?? ""),
                "toolExecutionPolicy": .string(session.toolExecutionPolicy.rawValue),
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
                "Task: \(session.summary ?? "Unknown task")",
                "Status: \(session.status.rawValue)",
                "Message Count: \(session.messageCount)",
                "Tool Policy: \(session.toolExecutionPolicy.rawValue)",
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
                maxSteps: maxSteps,
                requestedToolExecutionPolicy: .backgroundOnly)
        }

        if input.resume {
            let sessions = try await agent.listSessions()
            guard let latest = sessions.first else {
                throw AgentToolError("No sessions available to resume")
            }
            return try await agent.resumeSession(
                sessionId: latest.id,
                model: modelOverride,
                maxSteps: maxSteps,
                requestedToolExecutionPolicy: .backgroundOnly)
        }

        return try await agent.executeTask(
            task,
            maxSteps: maxSteps,
            model: modelOverride,
            dryRun: input.dryRun,
            eventDelegate: nil,
            persistSession: !input.noCache,
            toolExecutionPolicy: .backgroundOnly)
    }

    static func validateSessionOptions(
        noCache: Bool,
        resume: Bool,
        resumeSession: String?,
        listSessions: Bool) throws
    {
        guard !noCache || !resume && resumeSession == nil && !listSessions else {
            throw AgentToolError("noCache cannot be combined with resume, resumeSession, or listSessions")
        }
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
            return ToolResponse.text(
                result.content,
                meta: ToolEventSummary.merge(summary: summary, into: Self.executionTraceMetadata(for: result)))
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

        var baseMetadata = Self.executionTraceMetadataObject(for: result)
        if let sessionId = result.sessionId {
            baseMetadata["sessionId"] = .string(sessionId)
        }
        let baseMeta = Value.object(baseMetadata)
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
        var metadata = Self.executionTraceMetadataObject(for: result)
        metadata.merge([
            "toolCallCount": .int(result.metadata.toolCallCount),
            "modelName": .string(result.metadata.modelName),
        ], uniquingKeysWith: { _, new in new })

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

    static func executionTraceMetadata(for result: AgentExecutionResult) -> Value {
        .object(self.executionTraceMetadataObject(for: result))
    }

    private static func executionTraceMetadataObject(for result: AgentExecutionResult) -> [String: Value] {
        let trace = result.executionTrace()
        return [
            "executionTrace": (try? Value(trace)) ?? .object([
                "entries": .array([]),
                "totalCallCount": .int(trace.totalCallCount),
                "truncated": .bool(true),
            ]),
        ]
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

extension MCPAgentTool: MCPToolArgumentSemanticValidating {
    func validateArgumentSemantics(_ arguments: ToolArguments) throws {
        let input = try arguments.decode(AgentInput.self)
        try Self.validateSessionOptions(
            noCache: input.noCache,
            resume: input.resume,
            resumeSession: input.resumeSession,
            listSessions: input.listSessions)
        _ = try Self.validatedMaxSteps(input.maxSteps)
        guard input.listSessions || input.task != nil else {
            throw AgentToolError("Missing required parameter: task")
        }
    }
}

private struct AgentToolError: LocalizedError {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        self.message
    }
}
