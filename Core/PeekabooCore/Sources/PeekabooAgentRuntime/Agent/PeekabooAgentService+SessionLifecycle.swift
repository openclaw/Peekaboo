//
//  PeekabooAgentService+SessionLifecycle.swift
//  PeekabooCore
//

import Foundation
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    struct ResolvedContinuationModel {
        let model: LanguageModel
        let provider: any ModelProvider
        let identity: PersistedModelIdentity
    }

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
        try await self.continueSessionInternal(
            sessionId: sessionId,
            userMessage: userMessage,
            model: model,
            maxSteps: maxSteps,
            dryRun: dryRun,
            queueMode: queueMode,
            eventDelegate: eventDelegate,
            verbose: verbose,
            enhancementOptions: enhancementOptions)
    }

    // swiftlint:disable:next function_parameter_count
    private func continueSessionInternal(
        sessionId: String,
        userMessage: String?,
        model: LanguageModel?,
        maxSteps: Int,
        dryRun: Bool,
        queueMode: QueueMode,
        eventDelegate: (any AgentEventDelegate)?,
        verbose: Bool,
        enhancementOptions: AgentEnhancementOptions?) async throws -> AgentExecutionResult
    {
        let maxSteps = try AgentStepBudget.validate(maxSteps)
        self.isVerbose = verbose
        TachikomaConfiguration.current.setVerbose(verbose)

        guard let existingSession = try await self.sessionManager.loadSession(id: sessionId) else {
            throw PeekabooError.sessionNotFound(sessionId)
        }
        let resolvedModel = try self.resolveContinuationModelContext(
            explicitModel: model,
            session: existingSession)
        let selectedModel = resolvedModel.model
        let taskDescription = userMessage ?? "Resume session \(sessionId)"

        if dryRun {
            let now = Date()
            return AgentExecutionResult(
                content: userMessage.map { "Dry run completed. Session \(sessionId) would receive: \($0)" } ??
                    "Dry run completed. Session \(sessionId) would resume from its saved turn boundary.",
                messages: existingSession.messages,
                sessionId: sessionId,
                usage: nil,
                metadata: AgentMetadata(
                    executionTime: 0,
                    toolCallCount: 0,
                    modelName: self.safeModelDisplayName(for: selectedModel),
                    startTime: now,
                    endTime: now))
        }

        let sessionContext = self.makeContinuationContext(
            from: existingSession,
            userMessage: userMessage,
            model: selectedModel,
            provider: resolvedModel.provider,
            modelIdentity: resolvedModel.identity)

        if let eventDelegate {
            let unsafeDelegate = UnsafeTransfer<any AgentEventDelegate>(eventDelegate)
            let (eventStream, eventContinuation) = AsyncStream<AgentEvent>.makeStream()

            let eventTask = Task { @MainActor in
                let delegate = unsafeDelegate.wrappedValue
                delegate.agentDidEmitEvent(.started(task: taskDescription))
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
            } catch let error as CancellationError {
                eventContinuation.finish()
                await eventTask.value
                throw error
            } catch {
                await eventHandler.send(.error(message: error.localizedDescription))
                eventContinuation.finish()
                await eventTask.value
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
        try await self.continueSessionInternal(
            sessionId: sessionId,
            userMessage: nil,
            model: model,
            maxSteps: maxSteps,
            dryRun: false,
            queueMode: .oneAtATime,
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

    func resolveContinuationModel(
        explicitModel: LanguageModel?,
        session: AgentSession) throws -> LanguageModel
    {
        try self.resolveContinuationModelContext(
            explicitModel: explicitModel,
            session: session).model
    }

    func resolveContinuationModelContext(
        explicitModel: LanguageModel?,
        session: AgentSession) throws -> ResolvedContinuationModel
    {
        if let explicitModel {
            let provider = try TachikomaConfiguration.resolve(.current).makeProvider(for: explicitModel)
            return ResolvedContinuationModel(
                model: explicitModel,
                provider: provider,
                identity: self.persistedModelIdentity(for: explicitModel, provider: provider))
        }

        guard let selection = session.modelSelection,
              let endpointIdentity = session.modelEndpointIdentity,
              let providerIdentity = session.modelProviderIdentity,
              let persistedModel = self.resolveConfiguredModel(selection),
              persistedModel.supportsTools
        else {
            throw PeekabooError.invalidInput(
                "Session \(session.id) was created with model '\(session.modelName)', but its original " +
                    "provider, model, and endpoint can no longer be verified safely. Pass an explicit model " +
                    "to resume this session.")
        }
        let provider = try TachikomaConfiguration.resolve(.current).makeProvider(for: persistedModel)
        let identity = self.persistedModelIdentity(for: persistedModel, provider: provider)
        guard identity.displayName == session.modelName,
              identity.selection == selection,
              identity.endpointIdentity == endpointIdentity,
              identity.providerIdentity == providerIdentity
        else {
            throw PeekabooError.invalidInput(
                "Session \(session.id) was created with model '\(session.modelName)', but its original " +
                    "provider, model, and endpoint can no longer be verified safely. Pass an explicit model " +
                    "to resume this session.")
        }
        return ResolvedContinuationModel(model: persistedModel, provider: provider, identity: identity)
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
