import Commander
import Darwin
import Foundation
import Logging
import os
import PeekabooAgentRuntime
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import TauTUI

/// Simple debug logging check
private var isDebugLoggingEnabled: Bool {
    // Check if verbose mode is enabled via log level
    if let logLevel = ProcessInfo.processInfo.environment["PEEKABOO_LOG_LEVEL"]?.lowercased() {
        return logLevel == "debug" || logLevel == "trace"
    }
    // Check if agent is in verbose mode
    if ProcessInfo.processInfo.arguments.contains("-v") ||
        ProcessInfo.processInfo.arguments.contains("--verbose") {
        return true
    }
    return false
}

private func aiDebugPrint(_ message: String, verbose: Bool, jsonOutput: Bool) {
    guard verbose || isDebugLoggingEnabled, !jsonOutput else { return }
    fputs("\(message)\n", stderr)
}

/// Output modes for agent execution with progressive enhancement
enum OutputMode {
    case minimal // CI/pipes - no colors, simple text
    case compact // Basic colors and icons (legacy default)
    case enhanced // Rich formatting with progress indicators
    case quiet // Only final result
    case verbose // Full JSON debug information
}

/// AI Agent command that uses new Chat Completions API architecture
@available(macOS 14.0, *)
struct AgentCommand: RuntimeBackedCommand {
    private static let loggingBootstrapState = OSAllocatedUnfairLock(initialState: false)

    static let commandDescription = CommandDescription(
        commandName: "agent",
        abstract: "Execute complex automation tasks using the Peekaboo agent",
        discussion: """
        Launches the autonomous Peekaboo operator so it can interpret a natural-language goal,
        choose tools (see, click, type, etc.), and report progress back to you. Supports resuming
        previous sessions, dry-run task previews, audio input, and JSON/quiet output modes for CI.
        """,
        usageExamples: [
            CommandUsageExample(
                command: "peekaboo agent \"Prepare the TestFlight build for review\"",
                description: "Start a brand-new session with a natural-language brief."
            ),
            CommandUsageExample(
                command: "peekaboo agent resume",
                description: "Resume the most recent session without retyping the task."
            ),
            CommandUsageExample(
                command: "peekaboo agent resume SESSION_ID --max-steps 12",
                description: "Resume a known session while capping the step budget."
            ),
        ]
    )

    @Argument(help: "Natural language description of the task to perform (optional when using --resume)")
    var task: String?

    @Flag(name: .customLong("debug-terminal"), help: "Show detailed terminal detection info")
    var debugTerminal = false

    @Flag(names: [.short("q"), .long], help: "Quiet mode - only show final result")
    var quiet = false

    @Flag(name: .long, help: "Validate and echo the task without calling a model or tools")
    var dryRun = false

    @Option(name: .long, help: "Maximum model turns before failing (1-100, default 100)")
    var maxSteps: Int?

    @Option(name: .long, help: "Queue mode for queued prompts: one-at-a-time (default) or all")
    var queueMode: String?

    @Option(
        name: .long,
        help: """
        AI model to use (for example: gpt-5.6, claude-opus-5, claude-fable-5, claude-sonnet-5, \
        gemini-3.5-flash, grok-4.3, minimax-m2.7, minimax-cn/m2.7, \
        ollama/<model>, lmstudio/<model>, or <custom-provider>/<model>)
        """
    )
    var model: String?
    var resume = false

    var resumeSession: String?

    var listSessions = false

    @Flag(name: .long, help: "Run without saving a resumable session")
    var noCache = false

    @Flag(
        name: .customLong("allow-foreground"),
        help: "Authorize foreground/global UI for this run (new sessions persist it as an immutable maximum)"
    )
    var allowForeground = false

    @Flag(name: .long, help: "Enable audio input mode (record from microphone)")
    var audio = false

    @Option(name: .long, help: "Audio input file path (instead of microphone)")
    var audioFile: String?

    @Flag(name: .long, help: "Force simple output mode (no colors or rich formatting)")
    var simple = false

    @Flag(name: .long, help: "Disable colors in output")
    var noColor = false

    var chat = false

    /// Computed property for output mode with smart detection and progressive enhancement
    var outputMode: OutputMode {
        // Explicit user overrides first
        if self.quiet {
            return .quiet
        }
        if self.verbose || self.debugTerminal {
            return .verbose
        }
        if self.simple {
            return .minimal
        }
        if self.noColor {
            return .minimal
        }

        // Check for environment-based forced modes
        if let forcedMode = TerminalDetector.shouldForceOutputMode() {
            return forcedMode
        }

        // Smart detection based on terminal capabilities
        let capabilities = TerminalDetector.detectCapabilities()
        return capabilities.recommendedOutputMode
    }

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions: CommandRuntimeOptions = {
        var options = CommandRuntimeOptions()
        // Remote GUI bridge mode is optional and can fail to expose auth state.
        // Keep agent execution local by default unless an explicit runtime option overrides it.
        options.preferRemote = false
        return options
    }()

    var verbose: Bool {
        self.runtime?.configuration.verbose ?? self.runtimeOptions.verbose
    }

    var newSessionToolExecutionPolicy: MCPToolExecutionPolicy {
        self.allowForeground ? .foregroundAllowed : .backgroundOnly
    }

    var requestedResumeToolExecutionPolicy: MCPToolExecutionPolicy {
        self.allowForeground ? .foregroundAllowed : .backgroundOnly
    }
}

@available(macOS 14.0, *)
extension AgentCommand {
    @MainActor
    mutating func run() async throws {
        let runtime = try await CommandRuntime.makeDefaultAsync(options: self.runtimeOptions)
        try await self.run(using: runtime)
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime

        do {
            try await self.runInternal(runtime: runtime)
        } catch let error as DecodingError {
            aiDebugPrint(
                "DEBUG: Caught DecodingError in run(): \(error)",
                verbose: self.verbose,
                jsonOutput: self.jsonOutput
            )
            throw error
        } catch let error as NSError {
            aiDebugPrint(
                "DEBUG: Caught NSError in run(): \(error)",
                verbose: self.verbose,
                jsonOutput: self.jsonOutput
            )
            aiDebugPrint("DEBUG: Domain: \(error.domain)", verbose: self.verbose, jsonOutput: self.jsonOutput)
            aiDebugPrint("DEBUG: Code: \(error.code)", verbose: self.verbose, jsonOutput: self.jsonOutput)
            aiDebugPrint("DEBUG: UserInfo: \(error.userInfo)", verbose: self.verbose, jsonOutput: self.jsonOutput)
            throw error
        } catch {
            aiDebugPrint(
                "DEBUG: Caught unknown error in run(): \(error)",
                verbose: self.verbose,
                jsonOutput: self.jsonOutput
            )
            throw error
        }
    }

    @MainActor
    mutating func runInternal(runtime: CommandRuntime) async throws {
        let maxSteps = try self.validateAgentRunPreflight()

        if let instruction = self.newTaskDryRunInstruction {
            self.displayDryRunPreview(instruction: instruction)
            return
        }

        let services = runtime.services

        let requestedModel: LanguageModel?
        do {
            requestedModel = try self.validatedModelSelection(configuration: services.configuration)
        } catch {
            try self.failAgentCommand(message: error.localizedDescription, code: .VALIDATION_ERROR)
        }

        let configuredAIService = PeekabooAIService(configuration: services.configuration)
        let existingAgent = services.agent as? PeekabooAgentService
        let mutationCoordinator = runtime.toolSnapshotMutationCoordinator
        existingAgent?.configureSnapshotMutationCoordinator(mutationCoordinator)
        let existingAgentModel = existingAgent.flatMap {
            configuredAIService.resolveConfiguredModel($0.defaultModelSelection) ??
                LanguageModel.parse(from: $0.defaultModelSelection)
        }
        let selectedModel = requestedModel ??
            self.implicitToolModel(
                from: configuredAIService,
                configuration: services.configuration,
                existingAgentModel: existingAgentModel
            )
        let usesPersistedSessionModel = self.shouldUsePersistedSessionModel(requestedModel: requestedModel)
        if self.listSessions {
            let listingModel = selectedModel ?? existingAgentModel ?? .anthropic(.opus5)
            let agentService: any AgentServiceProtocol = if let existing = existingAgent {
                existing
            } else {
                try PeekabooAgentService(
                    services: services,
                    defaultModel: listingModel,
                    snapshotMutationCoordinator: mutationCoordinator
                )
            }
            try await self.showSessions(agentService)
            return
        }

        if selectedModel == nil, !usesPersistedSessionModel {
            if let capabilityError = self.unavailableImplicitCustomModelToolCapabilityError(
                from: configuredAIService,
                configuration: services.configuration
            ) {
                try self.failAgentCommand(
                    message: capabilityError.localizedDescription,
                    code: .VALIDATION_ERROR
                )
            }
            try self.failAgentUnavailable()
        }

        let serviceDefaultModel = selectedModel ?? existingAgentModel ?? .anthropic(.opus5)
        if !usesPersistedSessionModel,
           !self.hasCredentials(for: serviceDefaultModel),
           !self.isLocalModel(serviceDefaultModel) {
            if requestedModel != nil {
                let providerName = self.providerDisplayName(for: serviceDefaultModel)
                let envVar = self.providerEnvironmentVariable(for: serviceDefaultModel)
                try self.failAgentCommand(
                    message: "Missing API key for \(providerName). Set \(envVar) and retry.",
                    code: .MISSING_API_KEY
                )
            } else {
                try self.failAgentUnavailable()
            }
        }

        let agentService: any AgentServiceProtocol = if let existing = existingAgent {
            existing
        } else {
            try PeekabooAgentService(
                services: services,
                defaultModel: serviceDefaultModel,
                snapshotMutationCoordinator: mutationCoordinator
            )
        }

        let terminalCapabilities = TerminalDetector.detectCapabilities()
        if self.debugTerminal {
            self.printTerminalDetectionDebug(terminalCapabilities, actualMode: self.outputMode)
        }

        let shouldSuppressMCPLogs = !self.verbose && !self.debugTerminal
        self.configureLogging(suppressingMCPLogs: shouldSuppressMCPLogs)

        guard let peekabooAgent = agentService as? PeekabooAgentService else {
            throw PeekabooError.commandFailed("Agent service not properly initialized")
        }
        peekabooAgent.configureCapturePreflightRefusal(runtime.toolCapturePreflightRefusal)

        if !usesPersistedSessionModel {
            try self.requireAgentCredentials(selectedModel: serviceDefaultModel)
        }

        try await self.requireRequestedSession(peekabooAgent)

        let chatPolicy = AgentChatLaunchPolicy()
        let chatContext = AgentChatLaunchContext(
            chatFlag: self.chat,
            hasTaskInput: self.hasTaskInput,
            listSessions: self.listSessions,
            normalizedTaskInput: self.normalizedTaskInput,
            capabilities: terminalCapabilities,
            hasSessionResumption: self.resume || self.resumeSession != nil
        )

        let queueMode: QueueMode
        do {
            queueMode = try self.resolvedQueueMode()
        } catch {
            try self.failAgentCommand(message: error.localizedDescription, code: .VALIDATION_ERROR)
        }

        switch chatPolicy.strategy(for: chatContext) {
        case .helpOnly:
            if self.jsonOutput {
                try self.failAgentCommand(
                    message: "Task argument is required",
                    code: .VALIDATION_ERROR,
                    hint: AgentMessages.Chat.nonInteractiveHelp
                )
            }
            self.printNonInteractiveChatHelp()
            return
        case let .interactive(initialPrompt):
            try await self.runChatLoop(
                peekabooAgent,
                requestedModel: requestedModel,
                initialPrompt: initialPrompt,
                capabilities: terminalCapabilities,
                queueMode: queueMode
            )
            return
        case .none:
            break
        }

        if try await self.handleSessionResumption(
            peekabooAgent,
            requestedModel: requestedModel,
            maxSteps: maxSteps,
            queueMode: queueMode
        ) {
            return
        }

        let executionTask = try await self.buildExecutionTask()

        _ = try await self.executeAgentTask(
            peekabooAgent,
            task: executionTask,
            requestedModel: requestedModel,
            maxSteps: maxSteps,
            queueMode: queueMode
        )
    }

    private func isAgentDisabled() -> Bool {
        let value = ProcessInfo.processInfo.environment["PEEKABOO_DISABLE_AGENT"]?.lowercased()
        return value == "1" || value == "true"
    }

    private func validateAgentRunPreflight() throws -> Int {
        if self.isAgentDisabled() {
            try self.failAgentCommand(
                message: "Agent service not available because PEEKABOO_DISABLE_AGENT is set.",
                code: .AGENT_ERROR
            )
        }

        do {
            try self.validateSessionOptions()
            try self.validateDryRunRequest()
            return try self.validatedMaxStepCount()
        } catch {
            try self.failAgentCommand(message: error.localizedDescription, code: .VALIDATION_ERROR)
        }
    }

    private func configureLogging(suppressingMCPLogs: Bool) {
        Self.loggingBootstrapState.withLock { isBootstrapped in
            // Embedders and in-process tests can invoke the CLI repeatedly; swift-log traps on a second bootstrap.
            guard !isBootstrapped else { return }

            if suppressingMCPLogs {
                LoggingSystem.bootstrap { label in
                    var handler = StreamLogHandler.standardOutput(label: label)
                    if label.hasPrefix("tachikoma.mcp") {
                        handler.logLevel = .critical // hide MCP init chatter unless --verbose
                    } else {
                        handler.logLevel = .info
                    }
                    return handler
                }
            } else {
                LoggingSystem.bootstrap(StreamLogHandler.standardOutput)
            }
            isBootstrapped = true
        }
    }

    func failAgentUnavailable() throws -> Never {
        let message = "Agent service not available. Please set OPENAI_API_KEY, ANTHROPIC_API_KEY, " +
            "GEMINI_API_KEY, X_AI_API_KEY, MINIMAX_API_KEY, MINIMAX_CN_API_KEY, OPENROUTER_API_KEY, " +
            "or configure ollama/<model>, lmstudio/<model>, or a custom provider."
        try self.failAgentCommand(message: message, code: .MISSING_API_KEY)
    }
}
