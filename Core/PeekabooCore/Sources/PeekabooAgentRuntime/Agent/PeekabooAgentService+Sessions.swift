//
//  PeekabooAgentService+Sessions.swift
//  PeekabooCore
//

import Foundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    private static let usageObservedMetadataKey = "agent_usage_observed"
    private static let usageCostCompleteMetadataKey = "agent_usage_cost_complete"

    struct SessionContext {
        let id: String
        let messages: [ModelMessage]
        let createdAt: Date
        let executionStart: Date
        let metadata: SessionMetadata
        let modelIdentity: PersistedModelIdentity
        let provider: (any ModelProvider)?
    }

    enum SessionLogBehavior {
        case always
        case verboseOnly
    }

    func prepareSession(
        task: String,
        model: LanguageModel,
        label: String,
        logBehavior: SessionLogBehavior) async throws -> SessionContext
    {
        self.currentModel = model
        let startTime = Date()
        let sessionId = UUID().uuidString
        let messages = [
            ModelMessage.system(AgentSystemPrompt.generate(for: model)),
            ModelMessage.user(task),
        ]
        let configuration = TachikomaConfiguration.resolve(.current)
        let provider = try configuration.makeProvider(for: model)
        let modelIdentity = self.persistedModelIdentity(for: model, provider: provider)

        let session = AgentSession(
            id: sessionId,
            modelName: modelIdentity.displayName,
            modelSelection: modelIdentity.selection,
            modelEndpointIdentity: modelIdentity.endpointIdentity,
            modelProviderIdentity: modelIdentity.providerIdentity,
            messages: messages,
            metadata: SessionMetadata(),
            createdAt: startTime,
            updatedAt: startTime)

        let forceLogging = logBehavior == .always
        self.logSession("\(label): Creating session with ID: \(sessionId)", force: forceLogging)
        self.logSession("\(label): Session messages count: \(messages.count)", force: forceLogging)

        do {
            try self.sessionManager.saveSession(session)
            self.logSession("\(label): Successfully saved initial session", force: forceLogging)
        } catch {
            print("ERROR (\(label)): Failed to save initial session: \(error)")
            throw error
        }

        return SessionContext(
            id: sessionId,
            messages: messages,
            createdAt: startTime,
            executionStart: startTime,
            metadata: SessionMetadata(),
            modelIdentity: modelIdentity,
            provider: provider)
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
            messages: finalMessages,
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
        modelIdentity: PersistedModelIdentity? = nil) -> SessionContext
    {
        var updatedMessages = session.messages
        if let userMessage {
            updatedMessages.append(.user(userMessage))
        }
        let provider = provider ?? (try? TachikomaConfiguration.resolve(.current).makeProvider(for: model))
        let modelIdentity = modelIdentity ?? provider.map { self.persistedModelIdentity(for: model, provider: $0) } ??
            self.persistedModelIdentity(for: model)
        return SessionContext(
            id: session.id,
            messages: updatedMessages,
            createdAt: session.createdAt,
            executionStart: Date(),
            metadata: session.metadata,
            modelIdentity: modelIdentity,
            provider: provider)
    }
}
