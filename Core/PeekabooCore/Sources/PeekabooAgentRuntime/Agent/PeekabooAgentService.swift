import CoreGraphics
import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import Tachikoma

// MARK: - Helper Types

/// Simple event delegate wrapper for streaming
@available(macOS 14.0, *)
@MainActor
final class StreamingEventDelegate: @unchecked Sendable, AgentEventDelegate {
    let onChunk: @MainActor @Sendable (String) async -> Void

    init(onChunk: @MainActor @escaping @Sendable (String) async -> Void) {
        self.onChunk = onChunk
    }

    func agentDidEmitEvent(_ event: AgentEvent) {
        // Extract content from different event types and schedule async work
        Task { @MainActor in
            switch event {
            case let .thinkingMessage(content):
                await self.onChunk(content)
            case let .assistantMessage(content):
                await self.onChunk(content)
            case let .completed(summary, _):
                await self.onChunk(summary)
            default:
                break
            }
        }
    }
}

// MARK: - Peekaboo Agent Service

/// Service that integrates the new agent architecture with PeekabooCore services
@available(macOS 14.0, *)
@MainActor
public final class PeekabooAgentService: AgentServiceProtocol {
    let services: any PeekabooServiceProviding
    let sessionManager: AgentSessionManager
    let defaultLanguageModel: LanguageModel
    var currentModel: LanguageModel?
    var cachedSmartCaptureService: SmartCaptureService?
    let logger = os.Logger(subsystem: "boo.peekaboo", category: "agent")
    var isVerbose: Bool = false

    /// The default model used by this agent service
    public var defaultModel: String {
        self.defaultLanguageModel.description
    }

    /// Credential-free provider-qualified reference for callers that need to resolve the default model.
    public var defaultModelSelection: String {
        switch self.defaultLanguageModel {
        case let .openai(model): "openai/\(model.modelId)"
        case let .anthropic(model): "anthropic/\(model.modelId)"
        case let .google(model): "google/\(model.userFacingModelId)"
        case let .mistral(model): "mistral/\(model.rawValue)"
        case let .groq(model): "groq/\(model.rawValue)"
        case let .grok(model): "grok/\(model.modelId)"
        case let .ollama(model): "ollama/\(model.modelId)"
        case let .lmstudio(model): "lmstudio/\(model.modelId)"
        case let .minimax(model): "minimax/\(model.modelId)"
        case let .minimaxCN(model): "minimax-cn/\(model.modelId)"
        case let .openRouter(modelID): "openrouter/\(modelID)"
        case let .together(modelID): "together/\(modelID)"
        case let .replicate(modelID): "replicate/\(modelID)"
        case let .custom(provider): provider.modelId
        case .azureOpenAI, .openaiCompatible, .anthropicCompatible:
            self.defaultLanguageModel.description
        }
    }

    public func resolveConfiguredModel(_ selection: String) -> LanguageModel? {
        PeekabooAIService(configuration: self.services.configuration).resolveConfiguredModel(selection)
    }

    /// Get the masked API key for the current model
    public var maskedApiKey: String? {
        get async {
            // Get the current model
            let model = self.currentModel ?? self.defaultLanguageModel

            // Get the configuration
            let config = TachikomaConfiguration.current

            // Determine the provider based on the model
            let apiKey: String? = switch model {
            case .ollama, .lmstudio:
                "local"
            case .openai:
                config.getAPIKey(for: .openai)
            case .anthropic:
                config.getAPIKey(for: .anthropic)
            case .google:
                config.getAPIKey(for: .google)
            case .minimax:
                config.getAPIKey(for: .minimax)
            case .minimaxCN:
                config.getAPIKey(for: .minimaxCN)
            case .mistral:
                config.getAPIKey(for: .mistral)
            case .groq:
                config.getAPIKey(for: .groq)
            case .grok:
                config.getAPIKey(for: .grok)
            case .azureOpenAI:
                config.getAPIKey(for: .azureOpenAI)
            case .openRouter:
                config.getAPIKey(for: .custom("openrouter"))
            case .together:
                config.getAPIKey(for: .custom("together"))
            case .replicate:
                config.getAPIKey(for: .custom("replicate"))
            case .openaiCompatible, .anthropicCompatible:
                nil // Custom endpoints may have keys embedded
            case let .custom(provider):
                provider.apiKey
            }

            // Mask the API key
            guard let key = apiKey, !key.isEmpty else {
                return nil
            }

            // Show first 5 and last 5 characters
            if key.count > 15 {
                let prefix = String(key.prefix(5))
                let suffix = String(key.suffix(5))
                return "\(prefix)...\(suffix)"
            } else if key.count > 8 {
                // For shorter keys, show less
                let prefix = String(key.prefix(3))
                let suffix = String(key.suffix(3))
                return "\(prefix)...\(suffix)"
            } else {
                // Very short keys, just show asterisks
                return String(repeating: "*", count: key.count)
            }
        }
    }

    public init(
        services: any PeekabooServiceProviding,
        defaultModel: LanguageModel = .anthropic(.opus48))
        throws
    {
        self.services = services
        self.sessionManager = try AgentSessionManager()
        self.defaultLanguageModel = defaultModel
    }

    // MARK: - AgentServiceProtocol Conformance

    /// Execute a task using the AI agent
    public func executeTask(
        _ task: String,
        maxSteps: Int = 20,
        dryRun: Bool = false,
        queueMode: QueueMode = .oneAtATime,
        eventDelegate: (any AgentEventDelegate)? = nil) async throws -> AgentExecutionResult
    {
        try await self.executeTask(
            task,
            maxSteps: maxSteps,
            sessionId: nil,
            model: nil,
            dryRun: dryRun,
            queueMode: queueMode,
            eventDelegate: eventDelegate,
            verbose: self.isVerbose)
    }

    /// Execute a task with audio content
    public func executeTaskWithAudio(
        audioContent: AudioContent,
        maxSteps: Int = 20,
        dryRun: Bool = false,
        queueMode: QueueMode = .oneAtATime,
        eventDelegate: (any AgentEventDelegate)? = nil) async throws -> AgentExecutionResult
    {
        if dryRun {
            let transcript = audioContent.transcript
            let durationSeconds = Int(audioContent.duration ?? 0)
            let description = transcript ?? "[Audio message - duration: \(durationSeconds)s]"
            return self.makeAudioDryRunResult(description: description)
        }

        let input = audioContent.transcript ?? "[Audio message without transcript]"

        if let eventDelegate {
            return try await self.executeAudioStreamingTask(
                input: input,
                maxSteps: maxSteps,
                queueMode: queueMode,
                eventDelegate: eventDelegate)
        }

        let sessionContext = try await self.prepareSession(
            task: input,
            model: self.defaultLanguageModel,
            label: "audio",
            logBehavior: .verboseOnly)
        return try await self.executeWithoutStreaming(
            context: sessionContext,
            model: self.defaultLanguageModel,
            maxSteps: maxSteps)
    }

    /// Clean up any cached sessions or resources
    public func cleanup() async {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let sessions = self.sessionManager.listSessions()

        for session in sessions where session.lastAccessedAt < cutoff {
            try? await self.sessionManager.deleteSession(id: session.id)
        }
    }

    // MARK: - Agent Creation

    // MARK: - Execution Methods

    /// Execute a task with the automation agent (with session support)
    public func executeTask(
        _ task: String,
        maxSteps: Int = 20,
        sessionId: String? = nil,
        model: LanguageModel? = nil,
        dryRun: Bool = false,
        queueMode: QueueMode = .oneAtATime,
        eventDelegate: (any AgentEventDelegate)? = nil,
        verbose: Bool = false,
        enhancementOptions: AgentEnhancementOptions? = .default) async throws -> AgentExecutionResult
    {
        // Store the verbose flag for this execution
        self.isVerbose = verbose
        if verbose {
            print("DEBUG: Verbose mode enabled in PeekabooAgentService")
        }

        // Set verbose mode in Tachikoma configuration
        TachikomaConfiguration.current.setVerbose(verbose)

        let selectedModel = self.resolveModel(model)

        if dryRun {
            return AgentExecutionResult(
                content: "Dry run completed. Task would be: \(task)",
                messages: [],
                sessionId: sessionId ?? UUID().uuidString,
                usage: nil,
                metadata: AgentMetadata(
                    executionTime: 0,
                    toolCallCount: 0,
                    modelName: selectedModel.description,
                    startTime: Date(),
                    endTime: Date()))
        }

        // If we have an event delegate, emit events even for non-streaming models.
        if let eventDelegate {
            // SAFETY: We ensure that the delegate is only accessed on MainActor
            // This is a legacy API pattern that predates Swift's strict concurrency
            let unsafeDelegate = UnsafeTransfer<any AgentEventDelegate>(eventDelegate)

            // Create event stream infrastructure
            let (eventStream, eventContinuation) = AsyncStream<AgentEvent>.makeStream()

            // Start processing events on MainActor
            let eventTask = Task { @MainActor in
                let delegate = unsafeDelegate.wrappedValue

                // Send start event
                delegate.agentDidEmitEvent(.started(task: task))

                for await event in eventStream {
                    delegate.agentDidEmitEvent(event)
                }
            }

            // Create the event handler
            let eventHandler = EventHandler { event in
                eventContinuation.yield(event)
            }

            // Create event delegate wrapper for streaming
            let streamingDelegate = StreamingEventDelegate { chunk in
                await eventHandler.send(.assistantMessage(content: chunk))
            }

            do {
                let sessionContext = try await self.prepareSession(
                    task: task,
                    model: selectedModel,
                    label: "streaming",
                    logBehavior: .always)

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

                // Send completion event with usage information
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
            // Non-streaming execution
            let sessionContext = try await self.prepareSession(
                task: task,
                model: selectedModel,
                label: "(non-streaming)",
                logBehavior: .verboseOnly)
            return try await self.executeWithoutStreaming(
                context: sessionContext,
                model: selectedModel,
                maxSteps: maxSteps,
                enhancementOptions: enhancementOptions)
        }
    }

    /// Execute a task with streaming output
    public func executeTaskStreaming(
        _ task: String,
        sessionId: String? = nil,
        model: LanguageModel? = nil,
        streamHandler: @Sendable @escaping (String) async -> Void) async throws -> AgentExecutionResult
    {
        // Execute a task with streaming output
        let selectedModel = self.resolveModel(model)
        if !selectedModel.supportsStreaming {
            let sessionContext = try await self.prepareSession(
                task: task,
                model: selectedModel,
                label: "(non-streaming)",
                logBehavior: .verboseOnly)
            let result = try await self.executeWithoutStreaming(
                context: sessionContext,
                model: selectedModel,
                maxSteps: 20)
            await streamHandler(result.content)
            return result
        }

        // For streaming without event handler, create a dummy delegate that discards chunks
        let dummyDelegate = StreamingEventDelegate { _ in /* discard */ }
        let sessionContext = try await self.prepareSession(
            task: task,
            model: selectedModel,
            label: "streaming-api",
            logBehavior: .always)
        return try await self.executeWithStreaming(
            context: sessionContext,
            model: selectedModel,
            maxSteps: 20,
            streamingDelegate: dummyDelegate,
            queueMode: .oneAtATime,
            eventHandler: nil)
    }

    func resolveModel(_ requestedModel: LanguageModel?) -> LanguageModel {
        requestedModel ?? self.defaultLanguageModel
    }

    // MARK: - Tool Creation
}
