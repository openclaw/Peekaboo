//
//  AgentCommand+Chat.swift
//  PeekabooCLI
//

import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import TauTUI

@available(macOS 14.0, *)
extension AgentCommand {
    struct ReportedChatTurnError: Error {
        let underlyingError: any Error
    }

    private func ensureChatModePreconditions() -> Bool {
        let flags = AgentChatPreconditions.Flags(
            jsonOutput: self.jsonOutput,
            quiet: self.quiet,
            dryRun: self.dryRun,
            noCache: self.noCache,
            audio: self.audio,
            audioFileProvided: self.audioFile != nil
        )
        if let violation = AgentChatPreconditions.firstViolation(for: flags) {
            self.printAgentExecutionError(violation)
            return false
        }
        return true
    }

    func printNonInteractiveChatHelp() {
        if self.jsonOutput {
            self
                .printAgentExecutionError(
                    AgentMessages.Chat.nonInteractiveHelp
                )
            return
        }

        let hint = [
            "Interactive chat requires a TTY.",
            "To force it from scripts: peekaboo agent --chat < prompts.txt",
            "Provide a task arg or use --chat when piping input.",
            "",
        ]
        hint.forEach { print($0) }
        self.printChatHelpMenu()
    }

    @MainActor
    func runChatLoop(
        _ agentService: PeekabooAgentService,
        requestedModel: LanguageModel?,
        initialPrompt: String?,
        capabilities: TerminalCapabilities,
        queueMode: QueueMode
    ) async throws {
        guard self.ensureChatModePreconditions() else {
            throw ExitCode.failure
        }

        if self.shouldUseTauTUIChat(capabilities: capabilities) {
            do {
                try await self.runTauTUIChatLoop(
                    agentService,
                    requestedModel: requestedModel,
                    initialPrompt: initialPrompt,
                    capabilities: capabilities,
                    queueMode: queueMode
                )
                return
            } catch is ExitCode {
                throw ExitCode.failure
            } catch {
                self.printAgentExecutionError(
                    "Failed to launch TauTUI chat: \(error.localizedDescription). Falling back to basic chat."
                )
            }
        }

        try await self.runLineChatLoop(
            agentService,
            requestedModel: requestedModel,
            initialPrompt: initialPrompt,
            capabilities: capabilities,
            queueMode: queueMode
        )
    }

    @MainActor
    private func runLineChatLoop(
        _ agentService: PeekabooAgentService,
        requestedModel: LanguageModel?,
        initialPrompt: String?,
        capabilities: TerminalCapabilities,
        queueMode: QueueMode
    ) async throws {
        let failTasklessResumeTurn = self.shouldFailTasklessResumeTurn(capabilities: capabilities)
        var turnContext = ChatTurnContext(
            sessionId: nil,
            requestedModel: requestedModel,
            queueMode: queueMode,
            queuedWhileRunning: []
        )
        do {
            turnContext.sessionId = try await self.initialChatSessionId(agentService)
        } catch {
            self.printAgentExecutionError(error.localizedDescription)
            throw ExitCode.failure
        }

        let modelDescription = await self.describeChatModel(
            requestedModel,
            sessionId: turnContext.sessionId,
            agentService: agentService
        )
        self.printChatWelcome(
            sessionId: turnContext.sessionId,
            modelDescription: modelDescription,
            queueMode: queueMode
        )
        self.printChatHelpIntro()

        if let seed = initialPrompt {
            do {
                try await self.performChatTurn(seed, agentService: agentService, context: &turnContext)
            } catch is ReportedChatTurnError {
                // The streaming delegate already rendered the provider failure.
            }
        }

        while true {
            guard let line = self.readChatLine(prompt: "> ", capabilities: capabilities) else {
                if capabilities.isInputInteractive {
                    print()
                }
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed == "/help" {
                self.printChatHelpMenu()
                continue
            }

            // If queueMode=all, batch any queued prompts gathered while a run was active
            let batchedPrompt = trimmed

            do {
                try await self.performChatTurn(
                    batchedPrompt,
                    agentService: agentService,
                    context: &turnContext,
                    propagateTurnFailure: failTasklessResumeTurn
                )
            } catch is ReportedChatTurnError {
                if failTasklessResumeTurn {
                    throw ExitCode.failure
                }
            } catch is CancellationError {
                if failTasklessResumeTurn {
                    self.printAgentExecutionError("Agent turn was cancelled")
                    throw ExitCode.failure
                }
            } catch {
                self.printAgentExecutionError(error.localizedDescription)
                if failTasklessResumeTurn {
                    throw ExitCode.failure
                }
            }
        }
    }

    @MainActor
    private func runTauTUIChatLoop(
        _ agentService: PeekabooAgentService,
        requestedModel: LanguageModel?,
        initialPrompt: String?,
        capabilities: TerminalCapabilities,
        queueMode: QueueMode
    ) async throws {
        var activeSessionId: String?
        do {
            activeSessionId = try await self.initialChatSessionId(agentService)
        } catch {
            self.printAgentExecutionError(error.localizedDescription)
            throw ExitCode.failure
        }

        let modelDescription = await self.describeChatModel(
            requestedModel,
            sessionId: activeSessionId,
            agentService: agentService
        )
        let chatUI = AgentChatUI(
            modelDescription: modelDescription,
            sessionId: activeSessionId,
            queueMode: queueMode,
            helpLines: self.chatHelpLines
        )

        try chatUI.start()
        defer { chatUI.stop() }

        var currentRun: Task<AgentExecutionResult, any Error>?
        chatUI.onCancelRequested = { [weak chatUI] in
            guard let run = currentRun else { return }
            if !run.isCancelled {
                run.cancel()
                chatUI?.markCancelling()
            }
        }

        chatUI.onInterruptRequested = { [weak chatUI] in
            if let run = currentRun, !run.isCancelled {
                run.cancel()
                chatUI?.markCancelling()
            } else {
                chatUI?.finishPromptStream()
            }
        }

        let promptStream = chatUI.promptStream(initialPrompt: initialPrompt)
        for await prompt in promptStream {
            let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            if trimmed == "/help" {
                chatUI.showHelpMenu()
                continue
            }

            // For queueMode=all, batch any queued prompts into this turn
            let batchedPrompt: String
            if queueMode == .all {
                let extras = chatUI.drainQueuedPrompts()
                batchedPrompt = ([trimmed] + extras).joined(separator: "\n\n")
            } else {
                batchedPrompt = trimmed
            }

            chatUI.beginRun(prompt: trimmed)
            let tuiDelegate = AgentChatEventDelegate(ui: chatUI)

            let sessionForRun = activeSessionId
            let tuiContext = AgentRunContext(
                sessionId: sessionForRun,
                requestedModel: requestedModel,
                queueMode: queueMode,
                delegate: tuiDelegate
            )
            currentRun = Task { @MainActor in
                try await self.runAgentTurnForTUI(
                    batchedPrompt,
                    agentService: agentService,
                    context: tuiContext
                )
            }

            do {
                guard let run = currentRun else { continue }
                let result = try await run.value
                if let sessionId = result.sessionId {
                    activeSessionId = sessionId
                }
                chatUI.endRun(result: result, sessionId: activeSessionId)
            } catch is CancellationError {
                chatUI.showCancelled()
            } catch {
                if let sessionId = self.stepLimitSessionId(from: error) {
                    activeSessionId = sessionId
                    chatUI.updateSessionId(sessionId)
                }
                if !tuiDelegate.hasReceivedError {
                    chatUI.showError(error.localizedDescription)
                }
            }

            currentRun = nil
            chatUI.setRunning(false)
        }
    }

    struct AgentRunContext {
        var sessionId: String?
        var requestedModel: LanguageModel?
        var queueMode: QueueMode
        var delegate: any AgentEventDelegate
    }

    @MainActor
    private func runAgentTurnForTUI(
        _ input: String,
        agentService: PeekabooAgentService,
        context: AgentRunContext
    ) async throws -> AgentExecutionResult {
        let sessionId = context.sessionId
        let requestedModel = context.requestedModel
        let queueMode = context.queueMode
        let delegate = context.delegate
        if let existingSessionId = sessionId {
            return try await agentService.continueSession(
                sessionId: existingSessionId,
                userMessage: input,
                model: requestedModel,
                maxSteps: self.resolvedMaxSteps,
                dryRun: self.dryRun,
                queueMode: queueMode,
                eventDelegate: delegate,
                verbose: self.verbose
            )
        }

        return try await agentService.executeTask(
            input,
            maxSteps: self.resolvedMaxSteps,
            sessionId: nil,
            model: requestedModel,
            dryRun: self.dryRun,
            queueMode: queueMode,
            eventDelegate: delegate,
            verbose: self.verbose
        )
    }

    private func initialChatSessionId(
        _ agentService: PeekabooAgentService
    ) async throws -> String? {
        if let sessionId = self.resumeSession {
            guard try await agentService.getSessionInfo(sessionId: sessionId) != nil else {
                throw PeekabooError.sessionNotFound(sessionId)
            }
            return sessionId
        }

        if self.resume {
            let sessions = try await agentService.listSessions()
            guard let mostRecent = sessions.first else {
                throw PeekabooError.commandFailed("No sessions available to resume.")
            }
            return mostRecent.id
        }

        return nil
    }

    private func readChatLine(prompt: String, capabilities: TerminalCapabilities) -> String? {
        if capabilities.isInputInteractive {
            fputs(prompt, stdout)
            fflush(stdout)
        }
        return readLine()
    }

    struct ChatTurnContext {
        var sessionId: String?
        var requestedModel: LanguageModel?
        var queueMode: QueueMode
        var queuedWhileRunning: [String]
    }

    private func performChatTurn(
        _ input: String,
        agentService: PeekabooAgentService,
        context: inout ChatTurnContext,
        propagateTurnFailure: Bool = false
    ) async throws {
        let startingSessionId = context.sessionId
        let queueMode = context.queueMode
        let requestedModel = context.requestedModel
        var batchedInput = input
        if queueMode == .all {
            let extras = context.queuedWhileRunning
            context.queuedWhileRunning.removeAll()
            batchedInput = ([input] + extras).joined(separator: "\n\n")
        }

        let runTask = Task { () throws -> AgentExecutionResult in
            if let existingSessionId = startingSessionId {
                let outputDelegate = self.makeDisplayDelegate(for: batchedInput)
                let streamingDelegate = self.makeStreamingDelegate(using: outputDelegate)
                do {
                    let result = try await agentService.continueSession(
                        sessionId: existingSessionId,
                        userMessage: batchedInput,
                        model: requestedModel,
                        maxSteps: self.resolvedMaxSteps,
                        dryRun: self.dryRun,
                        queueMode: queueMode,
                        eventDelegate: streamingDelegate,
                        verbose: self.verbose
                    )
                    self.displayResult(result, delegate: outputDelegate)
                    return result
                } catch {
                    if outputDelegate?.hasReceivedError == true {
                        throw ReportedChatTurnError(underlyingError: error)
                    }
                    throw error
                }
            } else {
                return try await self.executeAgentTask(
                    agentService,
                    task: batchedInput,
                    requestedModel: requestedModel,
                    maxSteps: self.resolvedMaxSteps,
                    queueMode: queueMode,
                    preserveStepLimitError: true,
                    wrapReportedFailure: true
                )
            }
        }

        let cancelMonitor = EscapeKeyMonitor { [runTask] in
            if !runTask.isCancelled {
                runTask.cancel()
                await MainActor.run {
                    print("\n\(TerminalColor.yellow)Esc pressed – cancelling current run...\(TerminalColor.reset)")
                }
            }
        }
        cancelMonitor.start()

        let result: AgentExecutionResult
        do {
            defer { cancelMonitor.stop() }
            result = try await runTask.value
        } catch let error as CancellationError {
            cancelMonitor.stop()
            if propagateTurnFailure {
                throw error
            }
            return
        } catch {
            cancelMonitor.stop()
            let underlyingError = (error as? ReportedChatTurnError)?.underlyingError ?? error
            if let sessionId = self.stepLimitSessionId(from: underlyingError) {
                context.sessionId = sessionId
                if propagateTurnFailure {
                    throw error
                }
                return
            }
            throw error
        }

        if let updatedSessionId = result.sessionId {
            context.sessionId = updatedSessionId
        }

        self.printChatTurnSummary(result)
    }

    func stepLimitSessionId(from error: any Error) -> String? {
        (error as? PeekabooAgentService.AgentStepLimitExceededError)?.sessionId
    }

    func shouldFailTasklessResumeTurn(capabilities: TerminalCapabilities) -> Bool {
        guard !self.chat,
              !self.hasTaskInput,
              self.resume || self.resumeSession != nil
        else {
            return false
        }

        return !capabilities.isInputInteractive || capabilities.isCI
    }

    func shouldUseTauTUIChat(capabilities: TerminalCapabilities) -> Bool {
        capabilities.isInputInteractive &&
            capabilities.isInteractive &&
            !capabilities.isPiped &&
            (!capabilities.isCI || self.chat)
    }

    private func printChatTurnSummary(_ result: AgentExecutionResult) {
        guard !self.quiet else { return }
        let duration = String(format: "%.1fs", result.metadata.executionTime)
        let sessionFragment = result.sessionId.map { String($0.prefix(8)) } ?? "–"
        let line = [
            TerminalColor.dim,
            "↺ Session ",
            sessionFragment,
            ": ",
            duration,
            " • ⚒ ",
            String(result.metadata.toolCallCount),
            TerminalColor.reset,
        ].joined()
        print(line)
    }

    func describeChatModel(
        _ requestedModel: LanguageModel?,
        sessionId: String?,
        agentService: PeekabooAgentService
    ) async -> String {
        if let requestedModel {
            return agentService.safeModelDisplayName(for: requestedModel)
        }

        guard let sessionId else {
            return agentService.defaultModelDisplayName
        }

        guard let session = try? await agentService.getSessionInfo(sessionId: sessionId),
              let selection = session.modelSelection,
              let model = agentService.resolveConfiguredModel(selection)
        else {
            return "saved session model"
        }
        return agentService.safeModelDisplayName(for: model)
    }
}
