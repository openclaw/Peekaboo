import Commander
import Foundation
import PeekabooAgentRuntime
import PeekabooCore
import PeekabooFoundation
import Tachikoma
import TauTUI

@available(macOS 14.0, *)
extension AgentCommand {
    func ensureAgentHasCredentials(
        selectedModel: LanguageModel
    ) -> Bool {
        if self.isLocalModel(selectedModel) {
            return true
        }

        if self.hasCredentials(for: selectedModel) {
            return true
        }

        let providerName = self.providerDisplayName(for: selectedModel)
        let envVar = self.providerEnvironmentVariable(for: selectedModel)
        self.printAgentExecutionError(
            "Missing API key for \(providerName). Set \(envVar) and retry."
        )
        return false
    }

    /// Render the agent execution result using either JSON output or a rich CLI transcript.
    @MainActor
    func displayResult(_ result: AgentExecutionResult, delegate: AgentOutputDelegate? = nil) {
        if self.jsonOutput {
            let response = [
                "success": true,
                "result": [
                    "content": result.content,
                    "sessionId": result.sessionId as Any,
                    "toolCalls": result.messages.flatMap { message in
                        message.content.compactMap { content in
                            if case let .toolCall(toolCall) = content {
                                return [
                                    "id": toolCall.id,
                                    "name": toolCall.name,
                                    "arguments": String(describing: toolCall.arguments)
                                ]
                            }
                            return nil
                        }
                    },
                    "metadata": [
                        "executionTime": result.metadata.executionTime,
                        "toolCallCount": result.metadata.toolCallCount,
                        "modelName": result.metadata.modelName
                    ],
                    "usage": result.usage.map { usage in
                        [
                            "inputTokens": usage.inputTokens,
                            "outputTokens": usage.outputTokens,
                            "totalTokens": usage.totalTokens
                        ]
                    } as Any
                ]
            ] as [String: Any]
            if let jsonData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted) {
                print(String(data: jsonData, encoding: .utf8) ?? "{}")
            }
        } else if self.outputMode == .quiet {
            print(result.content)
        }

        delegate?.showFinalSummaryIfNeeded(result)
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
        if self.jsonOutput {
            let error: [String: Any] = ["success": false, "error": message]
            if let jsonData = try? JSONSerialization.data(withJSONObject: error, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                print(jsonString)
            } else {
                print("{\"success\":false,\"error\":\"\(message)\"}")
            }
        } else {
            print("\(TerminalColor.red)Error: \(message)\(TerminalColor.reset)")
        }
    }

    func executeAgentTask(
        _ agentService: PeekabooAgentService,
        task: String,
        requestedModel: LanguageModel?,
        maxSteps: Int,
        queueMode: QueueMode,
        preserveStepLimitError: Bool = false
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
                verbose: self.verbose
            )
            self.displayResult(result, delegate: outputDelegate)
            let duration = String(format: "%.2f", result.metadata.executionTime)
            let sessionId = result.sessionId ?? "none"
            let finalTokens = result.usage?.totalTokens ?? 0
            let status = result.metadata.context["status"] ?? "completed"
            AutomationEventLogger.log(
                .agent,
                "result status=\(status) task='\(task)' model=\(result.metadata.modelName) duration=\(duration)s "
                    + "tools=\(result.metadata.toolCallCount) dry_run=\(self.dryRun) "
                    + "session=\(sessionId) tokens=\(finalTokens)"
            )
            return result
        } catch let error as PeekabooAgentService.AgentStepLimitExceededError where preserveStepLimitError {
            if outputDelegate?.hasReceivedError != true {
                self.printAgentExecutionError("Agent execution failed: \(error.localizedDescription)")
            }
            throw error
        } catch {
            if outputDelegate?.hasReceivedError != true {
                self.printAgentExecutionError("Agent execution failed: \(error.localizedDescription)")
            }
            throw ExitCode.failure
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
