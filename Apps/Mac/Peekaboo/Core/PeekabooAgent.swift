import Foundation
import PeekabooCore
import SwiftUI
import Tachikoma

/// Tool execution record for tracking agent actions
struct ToolExecution: Identifiable {
    let toolName: String
    let arguments: String?
    let timestamp: Date
    var status: ToolExecutionStatus
    var result: String?
    var duration: TimeInterval?

    var id: String {
        "tool-\(self.toolName)-\(self.timestamp.timeIntervalSince1970)"
    }
}

/// Tool execution status
enum ToolExecutionStatus {
    case running
    case completed
    case failed
    case cancelled
}

/// Simplified agent interface for the Peekaboo Mac app.
///
/// This class provides a clean interface to the PeekabooCore agent service,
/// handling task execution and real-time event updates.
@Observable
@MainActor
final class PeekabooAgent {
    // MARK: - Properties

    private let services: PeekabooServices
    private let sessionStore: SessionStore
    private let settings: PeekabooSettings

    /// Track current processing state
    @ObservationIgnored
    private var processingTask: Task<Void, any Error>?

    /// Current session ID for continuity
    private(set) var currentSessionId: String?

    /// Whether the agent is currently processing
    private(set) var isProcessing = false

    /// Last error message if any
    private(set) var lastError: String?

    /// Current task description being processed
    private(set) var currentTask: String = ""

    /// Current tool being executed
    private(set) var currentTool: String?

    /// Current tool arguments for display
    private(set) var currentToolArgs: String?

    /// Whether agent is thinking (not executing tools)
    private(set) var isThinking = false

    /// Current thinking content
    private(set) var currentThinkingContent: String?

    /// Tool execution history for current task
    private(set) var toolExecutionHistory: [ToolExecution] = []

    /// Task execution start time
    @ObservationIgnored
    private var taskStartTime: Date?

    /// Token usage from last execution
    @ObservationIgnored
    private var lastTokenUsage: Usage?

    /// Get current token usage
    var tokenUsage: Usage? {
        self.lastTokenUsage
    }

    /// Current session
    var currentSession: ConversationSession? {
        self.sessionStore.currentSession
    }

    /// Store the last failed task for retry functionality
    @ObservationIgnored
    private var lastFailedTask: String?

    /// Get the last failed task (for retry button)
    var lastTask: String? {
        self.lastFailedTask
    }

    // MARK: - Initialization

    init(
        settings: PeekabooSettings,
        sessionStore: SessionStore,
        services: PeekabooServices = PeekabooServices())
    {
        self.services = services
        self.settings = settings
        self.sessionStore = sessionStore
    }

    // MARK: - Public Methods

    /// Get the underlying agent service for advanced use cases
    func getAgentService() async throws -> PeekabooAgentService? {
        guard let agentService = self.services.agent else {
            throw AgentError.serviceUnavailable
        }
        return agentService as? PeekabooAgentService
    }

    /// Execute a task with the agent
    func executeTask(_ task: String) async throws {
        guard self.services.agent != nil else {
            throw AgentError.serviceUnavailable
        }

        // Call the common implementation with text content
        try await self.executeTaskWithContent(.text(task))
    }

    /// Common implementation for executing tasks with different content types
    private func executeTaskWithContent(_ content: ModelMessage.ContentPart) async throws {
        guard let agentService = services.agent else {
            throw AgentError.serviceUnavailable
        }

        // Create a cancellable task
        let task = Task<Void, any Error> {
            try await self.executeTaskInternal(content: content, agentService: agentService)
        }

        // Assign the task and wait for it to complete
        self.processingTask = task
        try await task.value
    }

    /// Internal task execution helper
    @MainActor
    private func executeTaskInternal(
        content: ModelMessage.ContentPart,
        agentService: any AgentServiceProtocol) async throws
    {
        let taskDescription = self.taskDescription(for: content)
        self.prepareForTask(description: taskDescription)
        defer { self.cleanupAfterTask() }

        do {
            try Task.checkCancellation()
            let agent = try self.peekabooAgent(from: agentService)
            let session = self.ensureSession()
            self.logUserMessage(content, in: session)
            let delegate = self.makeEventDelegate()
            let result = try await self.runAgentTask(
                content: content,
                description: taskDescription,
                agent: agent,
                eventDelegate: delegate)
            try Task.checkCancellation()
            await self.persistResult(result, for: session, taskDescription: taskDescription)
        } catch {
            try self.handleTaskError(error, taskDescription: taskDescription)
            throw error
        }
    }

    /// Resume a previous session
    func resumeSession(_ sessionId: String, withTask task: String) async throws {
        self.currentSessionId = sessionId
        try await self.executeTask(task)
    }

    /// List available sessions
    func listSessions() async throws -> [ConversationSessionSummary] {
        // Return summaries from the session store
        self.sessionStore.sessions.map { ConversationSessionSummary(from: $0) }
    }

    /// Clear current session
    func clearSession() {
        self.currentSessionId = nil
        self.lastError = nil
    }

    /// Check if agent is available
    var isAvailable: Bool {
        self.services.agent != nil
    }

    /// Cancel the current task
    func cancelCurrentTask() {
        self.processingTask?.cancel()
        // Don't add a message here - it will be added when the cancellation is actually handled
    }
}

// MARK: - Private Methods

@MainActor
extension PeekabooAgent {
    @MainActor
    private func taskDescription(for content: ModelMessage.ContentPart) -> String {
        switch content {
        case let .text(text):
            text
        case .image:
            "[Image message]"
        case let .toolCall(toolCall):
            "[Tool call: \(toolCall.name)]"
        case let .toolResult(toolResult):
            "[Tool result: \(toolResult.toolCallId)]"
        case .reasoning:
            "[Reasoning]"
        }
    }

    @MainActor
    private func prepareForTask(description: String) {
        self.isProcessing = true
        self.currentTask = description
        self.lastError = nil
        self.lastFailedTask = nil
        self.isThinking = true
        self.currentTool = nil
        self.currentToolArgs = nil
        self.toolExecutionHistory = []
        self.taskStartTime = Date()
        self.lastTokenUsage = nil
    }

    @MainActor
    private func cleanupAfterTask() {
        self.isProcessing = false
        self.currentTask = ""
        self.processingTask = nil
    }

    @MainActor
    private func peekabooAgent(from service: any AgentServiceProtocol) throws -> PeekabooAgentService {
        guard let agent = service as? PeekabooAgentService else {
            throw AgentError.invalidConfiguration("Agent service not properly initialized")
        }
        return agent
    }

    @MainActor
    private func ensureSession() -> PeekabooCore.ConversationSession {
        if let current = self.sessionStore.currentSession {
            self.currentSessionId = current.id
            return current
        }

        let session = self.sessionStore.createSession(title: "", modelName: self.settings.selectedModel)
        self.currentSessionId = session.id
        return session
    }

    @MainActor
    private func logUserMessage(_ content: ModelMessage.ContentPart, in session: PeekabooCore.ConversationSession) {
        let messageContent: String = self.taskDescription(for: content)
        let userMessage = PeekabooCore.ConversationMessage(role: .user, content: messageContent)
        self.sessionStore.addMessage(userMessage, to: session)

        if session.title == "New Session" || session.title.isEmpty {
            self.sessionStore.generateTitleForSession(session)
        }
    }

    @MainActor
    private func makeEventDelegate() -> AgentEventDelegateWrapper {
        AgentEventDelegateWrapper { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handleAgentEvent(event)
            }
        }
    }

    @MainActor
    private func runAgentTask(
        content: ModelMessage.ContentPart,
        description: String,
        agent: PeekabooAgentService,
        eventDelegate: AgentEventDelegateWrapper) async throws -> AgentExecutionResult
    {
        switch content {
        case let .text(text):
            try await agent.executeTask(
                text,
                sessionId: self.currentSessionId,
                model: nil,
                eventDelegate: eventDelegate)
        case .image, .toolCall, .toolResult, .reasoning:
            try await agent.executeTask(
                description,
                sessionId: self.currentSessionId,
                model: nil,
                eventDelegate: eventDelegate)
        }
    }

    @MainActor
    private func persistResult(
        _ result: AgentExecutionResult,
        for session: PeekabooCore.ConversationSession,
        taskDescription: String) async
    {
        self.currentSessionId = result.sessionId
        self.updateModelNameIfNeeded(for: session)
        self.appendAssistantMessageIfNeeded(result: result, session: session)
        self.appendSummaryIfNeeded(to: session)

        if !result.content.isEmpty {
            self.sessionStore.updateSummary(result.content, for: session)
        }
    }

    @MainActor
    private func updateModelNameIfNeeded(for session: PeekabooCore.ConversationSession) {
        guard session.modelName.isEmpty,
              let index = self.sessionStore.sessions.firstIndex(where: { $0.id == session.id }) else { return }
        self.sessionStore.sessions[index].modelName = self.settings.selectedModel
        Task { @MainActor in
            self.sessionStore.saveSessions()
        }
    }

    @MainActor
    private func appendAssistantMessageIfNeeded(
        result: AgentExecutionResult,
        session: PeekabooCore.ConversationSession)
    {
        let hasAssistantMessage = self.sessionStore.sessions
            .first(where: { $0.id == session.id })?
            .messages
            .contains(where: { $0.role == .assistant && $0.content == result.content }) ?? false

        guard !hasAssistantMessage else { return }

        let assistantMessage = ConversationMessage(
            role: .assistant,
            content: result.content,
            toolCalls: [])
        self.sessionStore.addMessage(assistantMessage, to: session)
    }

    @MainActor
    private func appendSummaryIfNeeded(to session: PeekabooCore.ConversationSession) {
        guard let startTime = self.taskStartTime else { return }

        let totalDuration = Date().timeIntervalSince(startTime)
        let durationText = formatDuration(totalDuration)
        let toolCount = self.toolExecutionHistory.count
        var summaryContent = "Task completed in \(durationText)"
        if toolCount > 0 {
            summaryContent += " with \(toolCount) tool call\(toolCount == 1 ? "" : "s")"
        }

        if let usage = self.lastTokenUsage {
            summaryContent += " • \(AgentDisplayTokens.Status.info) \(usage.totalTokens) tokens"
            if usage.inputTokens > 0, usage.outputTokens > 0 {
                summaryContent += " (\(usage.inputTokens) in, \(usage.outputTokens) out)"
            }
        }

        let summaryMessage = PeekabooCore.ConversationMessage(
            role: .system,
            content: summaryContent)
        self.sessionStore.addMessage(summaryMessage, to: session)
    }

    @MainActor
    private func handleTaskError(_ error: any Error, taskDescription: String) throws {
        if error is CancellationError {
            self.lastError = "Task was cancelled"
            if let session = self.sessionStore.currentSession {
                let cancelMessage = PeekabooCore.ConversationMessage(
                    role: .system,
                    content: "\(AgentDisplayTokens.Status.warning) Task was cancelled by user")
                self.sessionStore.addMessage(cancelMessage, to: session)
            }
            return
        }

        self.lastError = error.localizedDescription
        self.lastFailedTask = taskDescription
        if let session = self.sessionStore.currentSession {
            let errorMessage = PeekabooCore.ConversationMessage(
                role: .system,
                content: "\(AgentDisplayTokens.Status.failure) Error: \(error.localizedDescription)")
            self.sessionStore.addMessage(errorMessage, to: session)
        }
    }

    private func handleAgentEvent(_ event: PeekabooCore.AgentEvent) {
        switch event {
        case let .error(message):
            self.handleAgentErrorEvent(message)
        case let .assistantMessage(delta):
            self.handleAssistantDelta(delta)
        case let .thinkingMessage(content):
            self.handleThinkingMessage(content)
        case let .toolCallStarted(name, arguments):
            self.handleToolCallStarted(name: name, arguments: arguments)
        case let .toolCallCompleted(name, result):
            self.handleToolCallCompleted(name: name, result: result)
        case let .completed(_, usage):
            self.lastTokenUsage = usage
        default:
            break
        }
    }

    private func handleAgentErrorEvent(_ message: String) {
        self.lastError = message

        if let currentTool,
           let index = toolExecutionHistory.lastIndex(where: { $0.toolName == currentTool && $0.status == .running })
        {
            self.toolExecutionHistory[index].status = .failed
            self.toolExecutionHistory[index].result = message
        }
    }

    private func handleAssistantDelta(_ delta: String) {
        self.isThinking = false
        self.currentTool = nil
        self.currentToolArgs = nil

        guard let currentSession = sessionStore.currentSession,
              let sessionIndex = sessionStore.sessions.firstIndex(where: { $0.id == currentSession.id }) else { return }

        if let lastMessage = sessionStore.sessions[sessionIndex].messages.last,
           lastMessage.role == .assistant,
           lastMessage.timestamp.timeIntervalSinceNow > -5.0
        {
            let accumulatedContent = lastMessage.content + delta
            let updatedMessage = ConversationMessage(
                id: lastMessage.id,
                role: .assistant,
                content: accumulatedContent,
                timestamp: lastMessage.timestamp,
                toolCalls: lastMessage.toolCalls)
            self.sessionStore.sessions[sessionIndex]
                .messages[self.sessionStore.sessions[sessionIndex].messages.count - 1] = updatedMessage
        } else if !delta.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
            let assistantMessage = PeekabooCore.ConversationMessage(
                role: .assistant,
                content: delta)
            self.sessionStore.addMessage(assistantMessage, to: currentSession)
        }
    }

    private func handleThinkingMessage(_ content: String) {
        guard !content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty else { return }
        self.isThinking = true
        self.currentThinkingContent = content
        self.currentTool = nil
        self.currentToolArgs = nil

        if let currentSession = sessionStore.currentSession {
            let thinkingMessage = PeekabooCore.ConversationMessage(
                role: .system,
                content: "\(AgentDisplayTokens.Status.planning) \(content)")
            self.sessionStore.addMessage(thinkingMessage, to: currentSession)
        }
    }

    private func handleToolCallStarted(name: String, arguments: String) {
        self.isThinking = false
        self.currentThinkingContent = nil
        self.currentTool = name
        self.currentToolArgs = arguments

        let formattedMessage = ToolFormatterBridge.shared.formatToolCall(
            name: name,
            arguments: arguments)

        self.currentToolArgs = ToolFormatterBridge.shared.formatArguments(
            name: name,
            arguments: arguments)

        if let currentSession = sessionStore.currentSession {
            let toolMessage = ConversationMessage(
                role: .system,
                content: formattedMessage,
                toolCalls: [ConversationToolCall(name: name, arguments: arguments, result: "Running...")])
            self.sessionStore.addMessage(toolMessage, to: currentSession)
        }

        let execution = ToolExecution(
            toolName: name,
            arguments: currentToolArgs ?? arguments,
            timestamp: Date(),
            status: .running)
        self.toolExecutionHistory.append(execution)
    }

    private func handleToolCallCompleted(name: String, result: String) {
        self.updateSessionToolMessage(name: name, result: result)
        self.completeToolExecution(name: name, result: result)
        self.currentTool = nil
        self.currentToolArgs = nil
        self.isThinking = true
    }

    private func updateSessionToolMessage(name: String, result: String) {
        guard let currentSession = sessionStore.currentSession,
              let sessionIndex = sessionStore.sessions.firstIndex(where: { $0.id == currentSession.id }) else { return }

        guard let toolMessageIndex = sessionStore.sessions[sessionIndex].messages.lastIndex(where: { message in
            message.role == .system &&
                message.toolCalls.contains { $0.name == name && $0.result == "Running..." }
        }) else {
            return
        }

        if let toolCallIndex = sessionStore.sessions[sessionIndex].messages[toolMessageIndex].toolCalls
            .firstIndex(where: { $0.name == name })
        {
            self.sessionStore.sessions[sessionIndex].messages[toolMessageIndex].toolCalls[toolCallIndex]
                .result = result
            Task { @MainActor in
                self.sessionStore.saveSessions()
            }
        }
    }

    private func completeToolExecution(name: String, result: String) {
        guard let index = toolExecutionHistory.lastIndex(where: { $0.toolName == name && $0.status == .running }) else {
            return
        }

        let startTime = self.toolExecutionHistory[index].timestamp
        let duration = Date().timeIntervalSince(startTime)
        self.toolExecutionHistory[index].status = .completed
        self.toolExecutionHistory[index].result = result
        self.toolExecutionHistory[index].duration = duration

        guard let currentSession = sessionStore.currentSession,
              let sessionIndex = sessionStore.sessions.firstIndex(where: { $0.id == currentSession.id }),
              let toolMessageIndex = sessionStore.sessions[sessionIndex].messages.lastIndex(where: { message in
                  message.role == .system &&
                      message.content.contains("\(AgentDisplayTokens.Status.running) \(name):")
              })
        else {
            return
        }

        let originalMessage = self.sessionStore.sessions[sessionIndex].messages[toolMessageIndex]
        let durationText = String(format: "%.2fs", duration)
        let statusText = "\(AgentDisplayTokens.Status.time) \(durationText)"
        let updatedContent = originalMessage.content + " " + statusText

        let updatedMessage = ConversationMessage(
            role: originalMessage.role,
            content: updatedContent,
            toolCalls: originalMessage.toolCalls)

        self.sessionStore.sessions[sessionIndex].messages[toolMessageIndex] = updatedMessage
    }
}

// MARK: - Tool Display Helpers

extension PeekabooAgent {
    /// Get icon for tool name (delegates to formatter bridge)
    static func iconForTool(_ toolName: String) -> String {
        ToolFormatterBridge.shared.toolIcon(for: toolName)
    }

    // compactToolSummary method removed - now using ToolFormatterBridge
}

// MARK: - Agent Errors

public enum AgentError: LocalizedError, Equatable {
    case serviceUnavailable
    case invalidConfiguration(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .serviceUnavailable:
            "Agent service is not available. Please check your OpenAI API key."
        case let .invalidConfiguration(message):
            "Invalid configuration: \(message)"
        case let .executionFailed(message):
            "Execution failed: \(message)"
        }
    }
}

// MARK: - Agent Event Delegate Wrapper

private final class AgentEventDelegateWrapper: PeekabooCore.AgentEventDelegate {
    private let handler: (PeekabooCore.AgentEvent) -> Void

    init(handler: @escaping (PeekabooCore.AgentEvent) -> Void) {
        self.handler = handler
    }

    func agentDidEmitEvent(_ event: PeekabooCore.AgentEvent) {
        self.handler(event)
    }
}
