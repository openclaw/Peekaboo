//
//  PeekabooAgentService+SessionLifecycle.swift
//  PeekabooCore
//

import Foundation
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    public func continueSession(
        sessionId: String,
        userMessage: String,
        model: LanguageModel? = nil,
        maxSteps: Int = 20,
        dryRun: Bool = false,
        queueMode: QueueMode = .oneAtATime,
        eventDelegate: (any AgentEventDelegate)? = nil,
        verbose: Bool = false,
        enhancementOptions: AgentEnhancementOptions? = .default) async throws -> AgentExecutionResult
    {
        self.isVerbose = verbose
        TachikomaConfiguration.current.setVerbose(verbose)

        guard let existingSession = try await self.sessionManager.loadSession(id: sessionId) else {
            throw PeekabooError.sessionNotFound(sessionId)
        }

        if dryRun {
            let now = Date()
            return AgentExecutionResult(
                content: "Dry run completed. Session \(sessionId) would receive: \(userMessage)",
                messages: existingSession.messages,
                sessionId: sessionId,
                usage: nil,
                metadata: AgentMetadata(
                    executionTime: 0,
                    toolCallCount: 0,
                    modelName: existingSession.modelName,
                    startTime: now,
                    endTime: now))
        }

        let selectedModel = self.resolveModel(model)
        let sessionContext = self.makeContinuationContext(from: existingSession, userMessage: userMessage)

        if let eventDelegate {
            let unsafeDelegate = UnsafeTransfer<any AgentEventDelegate>(eventDelegate)
            let (eventStream, eventContinuation) = AsyncStream<AgentEvent>.makeStream()

            let eventTask = Task { @MainActor in
                let delegate = unsafeDelegate.wrappedValue
                delegate.agentDidEmitEvent(.started(task: userMessage))
                for await event in eventStream {
                    delegate.agentDidEmitEvent(event)
                }
            }

            let eventHandler = EventHandler { event in
                eventContinuation.yield(event)
            }

            let streamingDelegate = StreamingEventDelegate { chunk in
                await eventHandler.send(.assistantMessage(content: chunk))
            }

            do {
                let result = if selectedModel.supportsStreaming {
                    try await self.executeWithStreaming(
                        context: sessionContext,
                        model: selectedModel,
                        maxSteps: maxSteps,
                        streamingDelegate: streamingDelegate,
                        queueMode: queueMode,
                        eventHandler: eventHandler,
                        enhancementOptions: enhancementOptions)
                } else {
                    try await self.executeWithoutStreaming(
                        context: sessionContext,
                        model: selectedModel,
                        maxSteps: maxSteps,
                        eventHandler: eventHandler,
                        enhancementOptions: enhancementOptions)
                }

                await eventHandler.send(.completed(summary: result.content, usage: result.usage))
                eventContinuation.finish()
                await eventTask.value
                return result
            } catch {
                eventContinuation.finish()
                eventTask.cancel()
                throw error
            }
        } else {
            return try await self.executeWithoutStreaming(
                context: sessionContext,
                model: selectedModel,
                maxSteps: maxSteps,
                enhancementOptions: enhancementOptions)
        }
    }

    /// Resume a previous session
    public func resumeSession(
        sessionId: String,
        model: LanguageModel? = nil,
        maxSteps: Int = 20,
        eventDelegate: (any AgentEventDelegate)? = nil,
        enhancementOptions: AgentEnhancementOptions? = .default) async throws -> AgentExecutionResult
    {
        let continuationPrompt = "Continue from where we left off."
        return try await self.continueSession(
            sessionId: sessionId,
            userMessage: continuationPrompt,
            model: model,
            maxSteps: maxSteps,
            dryRun: false,
            eventDelegate: eventDelegate,
            verbose: self.isVerbose,
            enhancementOptions: enhancementOptions)
    }

    // MARK: - Session Management

    /// List available sessions
    public func listSessions() async throws -> [SessionSummary] {
        // List available sessions
        self.sessionManager.listSessions()
        // SessionSummary is already returned from listSessions()
    }

    /// Get detailed session information
    public func getSessionInfo(sessionId: String) async throws -> AgentSession? {
        // Get detailed session information
        try await self.sessionManager.loadSession(id: sessionId)
    }

    /// Delete a specific session
    public func deleteSession(id: String) async throws {
        // Delete a specific session
        try await self.sessionManager.deleteSession(id: id)
    }

    /// Clear all sessions
    public func clearAllSessions() async throws {
        // Not available in current AgentSessionManager implementation
        // Would need to iterate and delete individual sessions
        let sessions = self.sessionManager.listSessions()
        for session in sessions {
            try await self.sessionManager.deleteSession(id: session.id)
        }
    }
}
