//
//  PeekabooAgentService+Sessions.swift
//  PeekabooCore
//

import Foundation
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    private static let usageObservedMetadataKey = "agent_usage_observed"
    private static let usageCostCompleteMetadataKey = "agent_usage_cost_complete"

    struct SessionContext {
        let id: String
        let isPersistent: Bool
        let messages: [ModelMessage]
        let createdAt: Date
        let executionStart: Date
        let metadata: SessionMetadata
        let modelIdentity: PersistedModelIdentity
        let storedToolExecutionPolicy: MCPToolExecutionPolicy
        let toolExecutionPolicy: MCPToolExecutionPolicy
        let provider: (any ModelProvider)?
        let executionGeneration: UUID?
    }

    enum SessionLogBehavior {
        case always
        case verboseOnly
    }

    func prepareSession(
        task: String,
        model: LanguageModel,
        label: String,
        logBehavior: SessionLogBehavior,
        persistSession: Bool = true,
        toolExecutionPolicy: MCPToolExecutionPolicy = .backgroundOnly) async throws -> SessionContext
    {
        guard toolExecutionPolicy != .unrestricted else {
            throw PeekabooError.invalidInput(
                "Unrestricted MCP authority cannot be assigned to an Agent session. " +
                    "Use foreground_allowed for explicit foreground UI without shell authority.")
        }
        self.currentModel = model
        let startTime = Date()
        let sessionId = UUID().uuidString
        let messages = [
            ModelMessage.system(AgentSystemPrompt.generate(
                for: model,
                executionPolicy: toolExecutionPolicy)),
            ModelMessage.user(task),
        ]
        let configuration = TachikomaConfiguration.resolve(.current)
        #if DEBUG
        let provider: any ModelProvider = if ProcessInfo.processInfo.environment[
            "PEEKABOO_AGENT_EXECUTION_TEST_PROVIDER",
        ] == "permissions-v1" {
            AgentProcessLimitProbeProvider()
        } else {
            try configuration.makeProvider(for: model)
        }
        #else
        let provider = try configuration.makeProvider(for: model)
        #endif
        let modelIdentity = self.persistedModelIdentity(for: model, provider: provider)

        let session = AgentSession(
            id: sessionId,
            modelName: modelIdentity.displayName,
            modelSelection: modelIdentity.selection,
            modelEndpointIdentity: modelIdentity.endpointIdentity,
            modelProviderIdentity: modelIdentity.providerIdentity,
            toolExecutionPolicy: toolExecutionPolicy,
            messages: messages,
            metadata: SessionMetadata(),
            createdAt: startTime,
            updatedAt: startTime)

        let forceLogging = logBehavior == .always
        self.logSession("\(label): Creating session with ID: \(sessionId)", force: forceLogging)
        self.logSession("\(label): Session messages count: \(messages.count)", force: forceLogging)

        if persistSession {
            do {
                try self.sessionManager.saveSession(session)
                self.logSession("\(label): Successfully saved initial session", force: forceLogging)
            } catch {
                print("ERROR (\(label)): Failed to save initial session: \(error)")
                throw error
            }
        }

        let executionGeneration = persistSession
            ? try self.beginAgentSessionExecution(for: sessionId)
            : nil
        return SessionContext(
            id: sessionId,
            isPersistent: persistSession,
            messages: messages,
            createdAt: startTime,
            executionStart: startTime,
            metadata: SessionMetadata(),
            modelIdentity: modelIdentity,
            storedToolExecutionPolicy: toolExecutionPolicy,
            toolExecutionPolicy: toolExecutionPolicy,
            provider: provider,
            executionGeneration: executionGeneration)
    }

    // swiftlint:disable:next function_parameter_count
    func saveExecutionSession(
        context: SessionContext,
        model: LanguageModel,
        finalMessages: [ModelMessage],
        endTime: Date,
        toolCallCount: Int,
        usage: Usage?,
        status: String) throws
    {
        guard context.isPersistent else { return }
        try self.requireCurrentAgentSessionExecution(
            sessionID: context.id,
            executionGeneration: context.executionGeneration)
        let executionTime = endTime.timeIntervalSince(context.executionStart)
        let totalTokens = context.metadata.totalTokens + (usage?.totalTokens ?? 0)
        let hadPreviousUsage = context.metadata.customData[Self.usageObservedMetadataKey]
            .flatMap(Bool.init) ?? (context.metadata.totalTokens > 0 || context.metadata.totalCost != nil)
        let previousCostWasComplete = context.metadata.customData[Self.usageCostCompleteMetadataKey]
            .flatMap(Bool.init) ?? (context.metadata.totalCost != nil)
        let hasAdditionalUsage = usage != nil
        let additionalCostIsComplete = usage?.cost != nil
        let hasAccumulatedUsage = hadPreviousUsage || hasAdditionalUsage
        let accumulatedCostIsComplete = (!hadPreviousUsage || previousCostWasComplete) &&
            (!hasAdditionalUsage || additionalCostIsComplete)
        let accumulatedCost: Double? = if hasAccumulatedUsage, accumulatedCostIsComplete {
            (context.metadata.totalCost ?? 0) + (usage?.cost?.total ?? 0)
        } else {
            nil
        }

        let customData = context.metadata.customData.merging([
            "status": status,
            Self.usageObservedMetadataKey: String(hasAccumulatedUsage),
            Self.usageCostCompleteMetadataKey: String(accumulatedCostIsComplete),
        ]) { _, new in new }

        let updatedMetadata = SessionMetadata(
            totalTokens: totalTokens,
            totalCost: accumulatedCost,
            toolCallCount: context.metadata.toolCallCount + toolCallCount,
            totalExecutionTime: context.metadata.totalExecutionTime + executionTime,
            customData: customData)
        let modelIdentity = context.modelIdentity
        let updatedSession = AgentSession(
            id: context.id,
            modelName: modelIdentity.displayName,
            modelSelection: modelIdentity.selection,
            modelEndpointIdentity: modelIdentity.endpointIdentity,
            modelProviderIdentity: modelIdentity.providerIdentity,
            toolExecutionPolicy: context.storedToolExecutionPolicy,
            messages: finalMessages.removingConsumedAgentToolImageContext(),
            metadata: updatedMetadata,
            createdAt: context.createdAt,
            updatedAt: endTime)
        try self.sessionManager.saveSession(updatedSession)
    }

    func preserveExecutionCheckpoint(
        context: SessionContext,
        model: LanguageModel,
        checkpoint: StreamingLoopOutcome,
        status: String)
    {
        guard context.isPersistent else { return }
        do {
            try self.saveExecutionSession(
                context: context,
                model: model,
                finalMessages: checkpoint.messages,
                endTime: Date(),
                toolCallCount: checkpoint.toolCallCount,
                usage: checkpoint.usage,
                status: status)
        } catch {
            let message = "Failed to preserve \(status) agent session \(context.id): \(error.localizedDescription)"
            self.logger.error("\(message, privacy: .public)")
        }
    }

    func makeExecutionMetadata(
        model: LanguageModel,
        executionTime: TimeInterval,
        toolCallCount: Int,
        startTime: Date,
        endTime: Date) -> AgentMetadata
    {
        AgentMetadata(
            executionTime: executionTime,
            toolCallCount: toolCallCount,
            modelName: self.safeModelDisplayName(for: model),
            startTime: startTime,
            endTime: endTime)
    }

    func logModelUsage(_ model: LanguageModel, prefix: String) {
        guard self.isVerbose else { return }
        let displayName = self.safeModelDisplayName(for: model)
        self.logger.debug("\(prefix)Using model: \(displayName, privacy: .public)")
    }

    private func logSession(_ message: String, force: Bool) {
        if force || self.isVerbose {
            self.logger.debug("\(message, privacy: .public)")
        }
    }

    func makeContinuationContext(
        from session: AgentSession,
        userMessage: String?,
        model: LanguageModel,
        provider: (any ModelProvider)? = nil,
        modelIdentity: PersistedModelIdentity? = nil,
        toolExecutionPolicy: MCPToolExecutionPolicy = .backgroundOnly,
        executionGeneration: UUID? = nil) -> SessionContext
    {
        var updatedMessages = session.messages
        let authorityPrompt = AgentSystemPrompt.generate(
            for: model,
            executionPolicy: toolExecutionPolicy)
        if let systemIndex = updatedMessages.firstIndex(where: { $0.role == .system }) {
            let existing = updatedMessages[systemIndex]
            updatedMessages[systemIndex] = ModelMessage(
                id: existing.id,
                role: .system,
                content: [.text(authorityPrompt)],
                timestamp: existing.timestamp,
                channel: existing.channel,
                metadata: existing.metadata)
        } else {
            updatedMessages.insert(.system(authorityPrompt), at: 0)
        }
        if let userMessage {
            updatedMessages.append(.user(userMessage))
        }
        let provider = provider ?? (try? TachikomaConfiguration.resolve(.current).makeProvider(for: model))
        let modelIdentity = modelIdentity ?? provider.map { self.persistedModelIdentity(for: model, provider: $0) } ??
            self.persistedModelIdentity(for: model)
        return SessionContext(
            id: session.id,
            isPersistent: true,
            messages: updatedMessages,
            createdAt: session.createdAt,
            executionStart: Date(),
            metadata: session.metadata,
            modelIdentity: modelIdentity,
            storedToolExecutionPolicy: session.effectiveToolExecutionPolicy,
            toolExecutionPolicy: toolExecutionPolicy,
            provider: provider,
            executionGeneration: executionGeneration)
    }
}
