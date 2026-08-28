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

    func beginAgentSessionExecution(for sessionID: String) throws -> UUID {
        guard self.agentSessionDeletionTombstones[sessionID] == nil else {
            throw PeekabooError.sessionNotFound(sessionID)
        }
        let generation = UUID()
        self.agentSessionExecutionGenerations[sessionID, default: []].insert(generation)
        return generation
    }

    func requireCurrentAgentSessionExecution(
        sessionID: String,
        executionGeneration: UUID?) throws
    {
        guard self.agentSessionDeletionTombstones[sessionID] == nil else {
            throw PeekabooError.sessionNotFound(sessionID)
        }
        guard let executionGeneration else { return }
        guard self.agentSessionExecutionGenerations[sessionID]?.contains(executionGeneration) == true else {
            throw PeekabooError.sessionNotFound(sessionID)
        }
    }

    func isCurrentAgentSessionExecution(
        sessionID: String,
        executionGeneration: UUID?) -> Bool
    {
        guard self.agentSessionDeletionTombstones[sessionID] == nil else { return false }
        guard let executionGeneration else { return true }
        return self.agentSessionExecutionGenerations[sessionID]?.contains(executionGeneration) == true
    }

    func finishAgentSessionExecution(sessionID: String, executionGeneration: UUID?) {
        guard let executionGeneration else { return }
        self.finishAgentSessionBrowserExecution(
            sessionID: sessionID,
            executionGeneration: executionGeneration)
        if var tombstone = self.agentSessionDeletionTombstones[sessionID],
           tombstone.invalidatedExecutionGenerations.remove(executionGeneration) != nil
        {
            self.agentSessionDeletionTombstones[sessionID] = tombstone
            self.settleAgentSessionDeletionIfPossible(sessionID: sessionID)
            return
        }
        guard var generations = self.agentSessionExecutionGenerations[sessionID] else { return }
        generations.remove(executionGeneration)
        if generations.isEmpty {
            self.agentSessionExecutionGenerations.removeValue(forKey: sessionID)
        } else {
            self.agentSessionExecutionGenerations[sessionID] = generations
        }
    }

    func beginAgentSessionBrowserExecution(sessionID: String, executionGeneration: UUID?) {
        guard let executionGeneration else { return }
        self.agentSessionBrowserExecutionGenerations[sessionID, default: []].insert(executionGeneration)
    }

    @discardableResult
    func finishAgentSessionBrowserExecution(sessionID: String, executionGeneration: UUID?) -> Bool {
        guard let executionGeneration,
              var generations = self.agentSessionBrowserExecutionGenerations[sessionID]
        else { return false }
        let removed = generations.remove(executionGeneration) != nil
        if generations.isEmpty {
            self.agentSessionBrowserExecutionGenerations.removeValue(forKey: sessionID)
        } else {
            self.agentSessionBrowserExecutionGenerations[sessionID] = generations
        }
        return removed
    }

    func hasAgentSessionBrowserExecution(sessionID: String) -> Bool {
        self.agentSessionBrowserExecutionGenerations[sessionID]?.isEmpty == false
    }

    func installAgentSessionDeletionTombstones(for sessionIDs: [String]) -> [String: UUID] {
        var claims: [String: UUID] = [:]
        for sessionID in sessionIDs where claims[sessionID] == nil {
            guard self.agentSessionDeletionTombstones[sessionID] == nil else { continue }
            let deletionGeneration = UUID()
            let invalidated = self.agentSessionExecutionGenerations.removeValue(forKey: sessionID) ?? []
            self.agentSessionDeletionTombstones[sessionID] = AgentSessionDeletionTombstone(
                deletionGeneration: deletionGeneration,
                invalidatedExecutionGenerations: invalidated)
            claims[sessionID] = deletionGeneration
        }
        return claims
    }

    func rollbackAgentSessionDeletion(sessionID: String, deletionGeneration: UUID) {
        guard let tombstone = self.agentSessionDeletionTombstones[sessionID],
              tombstone.deletionGeneration == deletionGeneration,
              tombstone.phase == .deleting
        else { return }
        self.agentSessionDeletionTombstones.removeValue(forKey: sessionID)
        if !tombstone.invalidatedExecutionGenerations.isEmpty {
            self.agentSessionExecutionGenerations[sessionID, default: []]
                .formUnion(tombstone.invalidatedExecutionGenerations)
        }
    }

    func markAgentSessionStorageDeleted(sessionID: String, deletionGeneration: UUID) {
        guard var tombstone = self.agentSessionDeletionTombstones[sessionID],
              tombstone.deletionGeneration == deletionGeneration
        else { return }
        tombstone.phase = .deleted
        tombstone.browserCleanupStarted = true
        self.agentSessionDeletionTombstones[sessionID] = tombstone
    }

    func recordAgentSessionBrowserCleanup(
        sessionID: String,
        deletionGeneration: UUID,
        confirmed: Bool)
    {
        guard var tombstone = self.agentSessionDeletionTombstones[sessionID],
              tombstone.deletionGeneration == deletionGeneration,
              tombstone.browserCleanupStarted
        else { return }
        if confirmed {
            tombstone.browserCleanupPending = false
            tombstone.browserCleanupConfirmed = true
        } else {
            tombstone.browserCleanupPending = true
        }
        self.agentSessionDeletionTombstones[sessionID] = tombstone
        self.settleAgentSessionDeletionIfPossible(sessionID: sessionID)
    }

    func recordDrainedAgentSessionBrowserCleanup() {
        let sessionIDs = self.agentSessionDeletionTombstones.compactMap { sessionID, tombstone in
            tombstone.phase == .deleted && tombstone.browserCleanupPending ? sessionID : nil
        }
        for sessionID in sessionIDs {
            guard var tombstone = self.agentSessionDeletionTombstones[sessionID] else { continue }
            tombstone.browserCleanupPending = false
            tombstone.browserCleanupConfirmed = true
            self.agentSessionDeletionTombstones[sessionID] = tombstone
            self.settleAgentSessionDeletionIfPossible(sessionID: sessionID)
        }
    }

    private func settleAgentSessionDeletionIfPossible(sessionID: String) {
        guard let tombstone = self.agentSessionDeletionTombstones[sessionID],
              tombstone.phase == .deleted,
              tombstone.browserCleanupStarted,
              tombstone.browserCleanupConfirmed,
              tombstone.invalidatedExecutionGenerations.isEmpty
        else { return }
        self.agentSessionDeletionTombstones.removeValue(forKey: sessionID)
    }

    func deletePersistedAgentSession(
        id: String,
        deletionGeneration: UUID) async throws -> Bool
    {
        do {
            try await self.sessionManager.deleteSession(id: id)
        } catch {
            self.rollbackAgentSessionDeletion(
                sessionID: id,
                deletionGeneration: deletionGeneration)
            throw error
        }
        self.markAgentSessionStorageDeleted(
            sessionID: id,
            deletionGeneration: deletionGeneration)
        let cleanupConfirmed = await self.endBrowserClient(forAgentSessionID: id)
        self.recordAgentSessionBrowserCleanup(
            sessionID: id,
            deletionGeneration: deletionGeneration,
            confirmed: cleanupConfirmed)
        return cleanupConfirmed
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
        enhancementOptions: AgentEnhancementOptions? = .default,
        requestedToolExecutionPolicy: MCPToolExecutionPolicy? = nil) async throws -> AgentExecutionResult
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
            enhancementOptions: enhancementOptions,
            requestedToolExecutionPolicy: requestedToolExecutionPolicy)
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
        enhancementOptions: AgentEnhancementOptions?,
        requestedToolExecutionPolicy: MCPToolExecutionPolicy?) async throws -> AgentExecutionResult
    {
        let maxSteps = try AgentStepBudget.validate(maxSteps)
        self.isVerbose = verbose
        TachikomaConfiguration.current.setVerbose(verbose)

        let executionGeneration = try self.beginAgentSessionExecution(for: sessionId)
        defer {
            self.finishAgentSessionExecution(
                sessionID: sessionId,
                executionGeneration: executionGeneration)
        }

        guard let existingSession = try await self.sessionManager.loadSession(id: sessionId) else {
            throw PeekabooError.sessionNotFound(sessionId)
        }
        try self.requireCurrentAgentSessionExecution(
            sessionID: sessionId,
            executionGeneration: executionGeneration)
        let executionPolicy = try Self.resolveToolExecutionPolicy(
            for: existingSession,
            requested: requestedToolExecutionPolicy)
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
                    modelName: self.continuationDryRunModelDisplayName(
                        explicitModel: model,
                        session: existingSession),
                    startTime: now,
                    endTime: now))
        }

        let resolvedModel = try self.resolveContinuationModelContext(
            explicitModel: model,
            session: existingSession)
        let selectedModel = resolvedModel.model
        self.currentModel = selectedModel

        let sessionContext = self.makeContinuationContext(
            from: existingSession,
            userMessage: userMessage,
            model: selectedModel,
            provider: resolvedModel.provider,
            modelIdentity: resolvedModel.identity,
            toolExecutionPolicy: executionPolicy,
            executionGeneration: executionGeneration)

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
        enhancementOptions: AgentEnhancementOptions? = .default,
        requestedToolExecutionPolicy: MCPToolExecutionPolicy? = nil) async throws -> AgentExecutionResult
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
            enhancementOptions: enhancementOptions,
            requestedToolExecutionPolicy: requestedToolExecutionPolicy)
    }

    static func resolveToolExecutionPolicy(
        for session: AgentSession,
        requested: MCPToolExecutionPolicy?) throws -> MCPToolExecutionPolicy
    {
        let storedMaximum = session.effectiveToolExecutionPolicy
        let requestedInvocation = requested ?? .backgroundOnly
        guard requestedInvocation != .unrestricted else {
            throw PeekabooError.invalidInput("Agent sessions cannot request unrestricted tool execution authority.")
        }
        guard requestedInvocation != .foregroundAllowed || storedMaximum == .foregroundAllowed else {
            throw PeekabooError.invalidInput(
                "Session \(session.id) has immutable tool execution policy '\(storedMaximum.rawValue)' and cannot be " +
                    "broadened while resuming. Start a new session with --allow-foreground when " +
                    "foreground interaction is intentionally authorized.")
        }
        return requestedInvocation
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
                "Session \(session.id)'s original provider, model, and endpoint can no longer be verified " +
                    "safely. Pass an explicit model " +
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
                "Session \(session.id)'s original provider, model, and endpoint can no longer be verified " +
                    "safely. Pass an explicit model " +
                    "to resume this session.")
        }
        return ResolvedContinuationModel(model: persistedModel, provider: provider, identity: identity)
    }

    private func continuationDryRunModelDisplayName(
        explicitModel: LanguageModel?,
        session: AgentSession) -> String
    {
        if let explicitModel {
            return self.safeModelDisplayName(for: explicitModel)
        }

        guard let selection = session.modelSelection,
              let persistedModel = self.resolveConfiguredModel(selection)
        else {
            return "Saved session model"
        }
        return self.safeModelDisplayName(for: persistedModel)
    }

    /// Delete a specific session
    public func deleteSession(id: String) async throws {
        let claims = self.installAgentSessionDeletionTombstones(for: [id])
        guard let deletionGeneration = claims[id] else {
            throw PeekabooError.operationError(message: "Agent session \(id) is already being deleted")
        }
        guard try await self.deletePersistedAgentSession(
            id: id,
            deletionGeneration: deletionGeneration)
        else {
            throw PeekabooError.operationError(
                message: "Browser session cleanup remains pending after deleting agent session \(id)")
        }
    }

    /// Clear all sessions
    public func clearAllSessions() async throws {
        let sessions = self.sessionManager.listSessions()
        let sessionIDs = sessions.map(\.id)
        let claims = self.installAgentSessionDeletionTombstones(for: sessionIDs)
        guard claims.count == Set(sessionIDs).count else {
            for (sessionID, deletionGeneration) in claims {
                self.rollbackAgentSessionDeletion(
                    sessionID: sessionID,
                    deletionGeneration: deletionGeneration)
            }
            throw PeekabooError.operationError(message: "An agent session is already being deleted")
        }
        for (index, sessionID) in sessionIDs.enumerated() {
            guard let deletionGeneration = claims[sessionID] else { continue }
            do {
                _ = try await self.deletePersistedAgentSession(
                    id: sessionID,
                    deletionGeneration: deletionGeneration)
            } catch {
                for pendingID in sessionIDs.dropFirst(index + 1) {
                    guard let pendingGeneration = claims[pendingID] else { continue }
                    self.rollbackAgentSessionDeletion(
                        sessionID: pendingID,
                        deletionGeneration: pendingGeneration)
                }
                throw error
            }
        }
        let cleanupDebtDrained = await self.drainBrowserCleanupDebt()
        guard cleanupDebtDrained else {
            throw PeekabooError.operationError(
                message: "Browser session cleanup remains pending after clearing agent sessions")
        }
    }
}
