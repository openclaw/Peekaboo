import Commander
import Darwin
import Foundation
import PeekabooAgentRuntime
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import TauTUI

@available(macOS 14.0, *)
extension AgentCommand {
    var isNewTaskDryRunRequest: Bool {
        self.dryRun && !self.chat && !self.resume && self.resumeSession == nil && !self.listSessions
    }

    var newTaskDryRunInstruction: String? {
        self.isNewTaskDryRunRequest ? self.normalizedTaskInput : nil
    }

    func validateDryRunRequest() throws {
        guard self.isNewTaskDryRunRequest else { return }
        guard self.normalizedTaskInput != nil else {
            throw PeekabooError.invalidInput("Task argument is required for --dry-run.")
        }
        guard !self.audio, self.audioFile == nil else {
            throw PeekabooError.invalidInput(
                "--dry-run accepts a text task only; audio input would require transcription."
            )
        }
    }

    func displayDryRunPreview(instruction: String) {
        if self.jsonOutput {
            let response = self.makeDryRunJSONResponse(instruction: instruction)
            if let jsonData = try? JSONSerialization.data(
                withJSONObject: response,
                options: [.prettyPrinted, .sortedKeys]
            ) {
                print(String(data: jsonData, encoding: .utf8) ?? "{}")
            }
            return
        }

        for line in self.dryRunHumanLines(instruction: instruction) {
            print(line)
        }
    }

    func dryRunHumanLines(instruction: String) -> [String] {
        let policy = self.newSessionToolExecutionPolicy
        return [
            "Dry run preview",
            "Instruction: \(instruction)",
            "Requested foreground UI: \(self.allowForeground ? "yes" : "no")",
            "Effective UI authority: \(policy.rawValue)",
            "Model execution: skipped",
            "Tool calls: 0",
            "Session saved: no",
        ]
    }

    func makeDryRunJSONResponse(instruction: String) -> [String: Any] {
        let now = Date(timeIntervalSince1970: 0)
        let result = AgentExecutionResult(
            content: "Dry run preview. No model or tools were invoked.",
            messages: [],
            sessionId: nil,
            usage: nil,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 0,
                modelName: "not_invoked",
                startTime: now,
                endTime: now
            )
        )
        var response = self.makeAgentJSONResponse(result)
        guard var payload = response["result"] as? [String: Any] else { return response }
        payload["dryRun"] = true
        payload["instruction"] = instruction
        payload["modelExecution"] = "skipped"
        let policy = self.newSessionToolExecutionPolicy
        payload["uiAuthority"] = [
            "requestedForeground": self.allowForeground,
            "effectivePolicy": policy.rawValue,
            "backgroundOnly": policy == .backgroundOnly,
        ]
        response["result"] = payload
        return response
    }

    func requireAgentCredentials(
        selectedModel: LanguageModel
    ) throws {
        #if DEBUG
        if ProcessInfo.processInfo.environment["PEEKABOO_AGENT_EXECUTION_TEST_PROVIDER"] == "permissions-v1" {
            return
        }
        #endif
        if self.isLocalModel(selectedModel) {
            return
        }

        if self.hasCredentials(for: selectedModel) {
            return
        }

        let providerName = self.providerDisplayName(for: selectedModel)
        let envVar = self.providerEnvironmentVariable(for: selectedModel)
        try self.failAgentCommand(
            message: "Missing API key for \(providerName). Set \(envVar) and retry.",
            code: .MISSING_API_KEY
        )
    }

    /// Render the agent execution result using either JSON output or a rich CLI transcript.
    @MainActor
    func displayResult(_ result: AgentExecutionResult, delegate: AgentOutputDelegate? = nil) {
        if self.jsonOutput {
            let response = self.makeAgentJSONResponse(result)
            if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted) {
                print(String(data: jsonData, encoding: .utf8) ?? "{}")
            }
        } else if self.outputMode == .quiet {
            print(result.content)
        }

        delegate?.showFinalSummaryIfNeeded(result)
    }

    func makeAgentJSONResponse(_ result: AgentExecutionResult) -> [String: Any] {
        let trace = result.executionTrace()
        var legacyToolCalls: [[String: Any]] = []
        var traceIndex = 0
        for message in result.messages {
            for content in message.content {
                guard case let .toolCall(toolCall) = content else { continue }
                let arguments: String
                if trace.entries.indices.contains(traceIndex) {
                    let entry = trace.entries[traceIndex]
                    arguments = entry.id == toolCall.id && entry.name == toolCall.name
                        ? Self.safeLegacyArguments(entry.arguments)
                        : Self.fullyRedactedLegacyArguments
                } else {
                    arguments = Self.fullyRedactedLegacyArguments
                }
                legacyToolCalls.append([
                    "id": toolCall.id,
                    "name": toolCall.name,
                    "arguments": arguments,
                ])
                traceIndex += 1
            }
        }
        let usage: Any = result.usage.map { usage in
            [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "totalTokens": usage.totalTokens,
            ]
        } ?? NSNull()
        let resultPayload: [String: Any] = [
            "content": result.content,
            "sessionId": result.sessionId.map { $0 as Any } ?? NSNull(),
            "toolCalls": legacyToolCalls,
            "executionTrace": self.executionTraceJSONObject(trace),
            "metadata": [
                "executionTime": result.metadata.executionTime,
                "toolCallCount": result.metadata.toolCallCount,
                "modelName": result.metadata.modelName,
            ],
            "usage": usage,
        ]
        return ["success": true, "result": resultPayload]
    }

    private static let fullyRedactedLegacyArguments = #"{"redacted":true}"#

    private static func safeLegacyArguments(_ arguments: [String: AnyAgentToolValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arguments),
              let text = String(data: data, encoding: .utf8)
        else {
            return Self.fullyRedactedLegacyArguments
        }
        return text
    }

    private func executionTraceJSONObject(_ trace: AgentExecutionTrace) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(trace),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [
                "entries": [],
                "totalCallCount": trace.totalCallCount,
                "truncated": true,
            ]
        }
        return object
    }

    func makeDisplayDelegate(for task: String) -> AgentOutputDelegate? {
        guard !self.jsonOutput, !self.quiet else { return nil }
        return AgentOutputDelegate(outputMode: self.outputMode, jsonOutput: self.jsonOutput, task: task)
    }

    func makeStreamingDelegate(using displayDelegate: AgentOutputDelegate?) -> (any AgentEventDelegate)? {
        if let displayDelegate {
            return displayDelegate
        }

        if self.jsonOutput || self.quiet {
            return SilentAgentEventDelegate()
        }

        return nil
    }

    final class SilentAgentEventDelegate: AgentEventDelegate {
        func agentDidEmitEvent(_ event: AgentEvent) {}
    }

    func printAgentExecutionError(_ message: String) {
        self.emitAgentError(message: message, code: .AGENT_ERROR)
    }

    func printAgentValidationError(_ message: String) {
        self.emitAgentError(message: message, code: .VALIDATION_ERROR)
    }

    func emitAgentError(message: String, code: ErrorCode, hint: String? = nil) {
        if self.jsonOutput {
            let logger = Logger.shared
            logger.setJsonOutputMode(true)
            outputError(message: message, code: code, hint: hint, logger: logger)
        } else if code == .VALIDATION_ERROR {
            fputs("Error: \(message)\n", stderr)
            if let hint, !hint.isEmpty {
                fputs("\(hint)\n", stderr)
            }
        } else {
            print("\(TerminalColor.red)Error: \(message)\(TerminalColor.reset)")
            if let hint, !hint.isEmpty {
                print(hint)
            }
        }
    }

    func failAgentCommand(message: String, code: ErrorCode, hint: String? = nil) throws -> Never {
        self.emitAgentError(message: message, code: code, hint: hint)
        throw ExitCode.failure
    }

    func executeAgentTask(
        _ agentService: PeekabooAgentService,
        task: String,
        requestedModel: LanguageModel?,
        maxSteps: Int,
        queueMode: QueueMode,
        preserveStepLimitError: Bool = false,
        wrapReportedFailure: Bool = false
    ) async throws -> AgentExecutionResult {
        let outputDelegate = self.makeDisplayDelegate(for: task)
        let streamingDelegate = self.makeStreamingDelegate(using: outputDelegate)
        do {
            let result = try await agentService.executeTask(
                task,
                maxSteps: maxSteps,
                sessionId: nil,
                model: requestedModel,
                dryRun: self.dryRun,
                queueMode: queueMode,
                eventDelegate: streamingDelegate,
                verbose: self.verbose,
                persistSession: !self.noCache,
                toolExecutionPolicy: self.newSessionToolExecutionPolicy
            )
            self.displayResult(result, delegate: outputDelegate)
            Self.logAgentAutomationResult(result, task: task, dryRun: self.dryRun)
            return result
        } catch let error as PeekabooAgentService.AgentStepLimitExceededError where preserveStepLimitError {
            if outputDelegate?.hasReceivedError != true {
                self.printAgentExecutionError("Agent execution failed: \(error.localizedDescription)")
            }
            throw error
        } catch let error as CancellationError {
            throw error
        } catch {
            if outputDelegate?.hasReceivedError == true {
                if wrapReportedFailure {
                    throw ReportedChatTurnError(underlyingError: error)
                }
            } else {
                self.printAgentExecutionError("Agent execution failed: \(error.localizedDescription)")
            }
            throw ExitCode.failure
        }
    }

    static func logAgentAutomationResult(_ result: AgentExecutionResult, task: String, dryRun: Bool) {
        let model = Self.agentAutomationModelFamily(result.metadata.modelName)
        let sessionId = result.sessionId
            .flatMap(UUID.init(uuidString:))
            .map(\.uuidString) ?? (result.sessionId == nil ? "none" : "invalid")
        let duration = String(format: "%.2f", result.metadata.executionTime)
        let finalTokens = result.usage?.totalTokens ?? 0
        AutomationEventLogger.log(
            .agent,
            "result status=completed task_chars=\(task.count) model=\(model) duration=\(duration)s "
                + "tools=\(result.metadata.toolCallCount) dry_run=\(dryRun) "
                + "session=\(sessionId) tokens=\(finalTokens)"
        )
    }

    private static func agentAutomationModelFamily(_ modelName: String) -> String {
        guard let family = modelName.split(separator: "/", maxSplits: 1).first?.lowercased() else {
            return "other"
        }
        return switch family {
        case "anthropic", "anthropic-compatible", "google", "groq", "grok", "kimi", "lmstudio",
             "minimax", "minimax-cn", "mistral", "ollama", "openai", "openai-compatible",
             "openrouter", "replicate", "together":
            family
        case "azureopenai": "azure-openai"
        default: "other"
        }
    }

    var normalizedTaskInput: String? {
        guard let task else { return nil }
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasTaskInput: Bool {
        self.normalizedTaskInput != nil || self.audio || self.audioFile != nil
    }

    var resolvedMaxSteps: Int {
        self.maxSteps ?? 100
    }

    func validatedMaxStepCount() throws -> Int {
        try AgentStepBudget.validate(self.resolvedMaxSteps)
    }

    func resolvedQueueMode() throws -> QueueMode {
        guard let raw = self.queueMode?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .oneAtATime
        }

        switch raw.lowercased() {
        case "one", "one-at-a-time", "single", "sequential", "1":
            return .oneAtATime
        case "all", "batch", "together":
            return .all
        default:
            throw PeekabooError.invalidInput("Invalid queue mode '\(raw)'. Use one-at-a-time or all.")
        }
    }
}
