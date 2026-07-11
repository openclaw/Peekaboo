//
//  AgentOutputDelegate.swift
//  Peekaboo
//

import Foundation
import PeekabooCore
import Spinner
import Tachikoma

/// Handles agent output formatting and display for different output modes
@available(macOS 14.0, *)
final class AgentOutputDelegate: PeekabooCore.AgentEventDelegate {
    // MARK: - Properties

    let outputMode: OutputMode
    private let jsonOutput: Bool
    private let task: String?

    // Tool tracking
    private var currentTool: String?
    var toolStartTimes: [String: Date] = [:]
    var lastToolArguments: [String: [String: Any]] = [:]
    private var toolCallCount = 0
    private var totalTokens = 0

    // Animation and UI
    private var spinner: Spinner?
    private var hasReceivedContent = false
    private var isThinking = false
    private var hasShownFinalSummary = false
    private(set) var hasReceivedError = false
    private let startTime = Date()

    // MARK: - Initialization

    init(outputMode: OutputMode, jsonOutput: Bool, task: String?) {
        self.outputMode = outputMode
        self.jsonOutput = jsonOutput
        self.task = task
    }
}

@available(macOS 14.0, *)
extension AgentOutputDelegate {
    // MARK: - AgentEventDelegate

    func agentDidEmitEvent(_ event: PeekabooCore.AgentEvent) {
        guard !self.jsonOutput else { return }

        switch event {
        case let .started(task):
            self.handleStarted(task)

        case let .toolCallStarted(name, arguments):
            self.handleToolCallStarted(name: name, arguments: arguments)

        case let .toolCallUpdated(name, arguments):
            self.handleToolCallUpdated(name: name, arguments: arguments)

        case let .toolCallCompleted(name, result):
            self.handleToolCallCompleted(name: name, result: result)

        case let .assistantMessage(content):
            self.handleAssistantMessage(content)

        case let .thinkingMessage(content):
            self.handleThinkingMessage(content)

        case .verificationCompleted, .desktopContextRefreshed:
            break

        case let .error(message):
            self.hasReceivedError = true
            self.handleError(message)

        case let .completed(summary, usage):
            self.handleCompleted(summary: summary, usage: usage)

        case .queueDrained:
            break
        }
    }

    // MARK: - Event Handlers

    private func handleStarted(_ task: String) {
        guard self.outputMode != .quiet else { return }

        if self.outputMode == .verbose {
            print("\n🚀 Starting agent task: \(task)")
        } else if self.outputMode == .enhanced || self.outputMode == .compact {
            // Start spinner animation (fallback color)
            self.spinner = Spinner(.dots, "Thinking...", color: .default)
            self.spinner?.start()
        } else if self.outputMode == .minimal {
            print("Starting: \(task)")
        }
    }

    private func handleToolCallStarted(name: String, arguments: String) {
        self.currentTool = name
        self.toolStartTimes[name] = Date()
        self.toolCallCount += 1

        let args = parseArguments(arguments)
        self.lastToolArguments[name] = args
        let (formatter, toolType) = self.toolFormatter(for: name)

        var displayName = toolType?.displayName ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        if name == "app", let action = args["action"] as? String {
            let appName = (args["name"] as? String) ?? (args["bundleId"] as? String) ?? ""
            displayName = "App \(action.capitalized)\(appName.isEmpty ? "" : ": \(appName)")"
        }

        let titleSummary = formatter.formatForTitle(arguments: args)
        updateTerminalTitle("\(displayName): \(titleSummary) - \(self.task?.prefix(30) ?? "")")

        guard self.outputMode != .quiet else { return }

        self.spinner?.stop()
        self.spinner = nil
        self.isThinking = false

        guard !self.shouldSkipCommunicationOutput(for: toolType) else { return }

        if self.hasReceivedContent {
            print()
            self.hasReceivedContent = false
        }

        self.printToolCallStart(
            displayName: displayName,
            args: args,
            rawArguments: arguments,
            formatter: formatter
        )
    }

    private func handleToolCallUpdated(name: String, arguments: String) {
        guard self.outputMode != .quiet else { return }
        guard !self.shouldSkipCommunicationOutput(for: ToolType(rawValue: name)) else { return }

        let args = parseArguments(arguments)
        if let previous = self.lastToolArguments[name], self.dictionariesEqual(previous, args) {
            return // no change; avoid spamming the log
        }
        let diffSummary = self.diffSummary(for: name, newArgs: args)
        let (formatter, _ /* toolType */ ) = self.toolFormatter(for: name)

        switch self.outputMode {
        case .minimal:
            if let diffSummary {
                print(" ↻ \(diffSummary)", terminator: "")
            } else {
                print(" ↻", terminator: "")
            }
        case .verbose:
            let clean = self.cleanToolPrefix(formatter.formatStarting(arguments: args))
            if let diffSummary {
                print("↻ Updated args: \(diffSummary) (\(clean))")
            } else {
                print("↻ Updated args: \(clean)")
            }
        default:
            let clean = self.cleanToolPrefix(formatter.formatStarting(arguments: args))
            if let diffSummary {
                print(" \(TerminalColor.blue)↻\(TerminalColor.reset) \(diffSummary)", terminator: "")
            } else {
                print(" \(TerminalColor.blue)↻\(TerminalColor.reset) \(clean)", terminator: "")
            }
        }

        self.lastToolArguments[name] = args

        fflush(stdout)
    }

    private func handleToolCallCompleted(name: String, result: String) {
        let durationString = self.durationString(for: name)

        guard self.outputMode != .quiet else { return }
        guard let json = parseResult(result) else {
            self.printInvalidResult(rawResult: result, durationString: durationString)
            return
        }

        let (formatter, toolType) = self.toolFormatter(for: name)
        let summary = ToolEventSummary.from(resultJSON: json)
        let success = ToolResultExtractor.isSuccess(json)

        if success,
           let toolType,
           [ToolType.taskCompleted, .needMoreInformation, .needInfo].contains(toolType) {
            self.handleCommunicationToolComplete(name: name, toolType: toolType)
            return
        }

        if success {
            let resultSummary = self.resultSummary(
                for: name,
                json: json,
                formatter: formatter,
                summary: summary
            )
            self.handleSuccess(
                resultSummary: resultSummary,
                durationString: durationString,
                result: result,
                json: json
            )
        } else {
            let errorMessage = (json["error"] as? String) ?? "Failed"
            self.handleFailure(message: errorMessage, durationString: durationString, json: json, tool: name)
        }

        fflush(stdout)
    }

    private func handleAssistantMessage(_ content: String) {
        self.hasReceivedContent = true

        if self.outputMode == .verbose {
            print("\n\(AgentDisplayTokens.Status.dialog) \(content)")
        } else if self.outputMode != .quiet {
            // Stop animations when content arrives
            if self.spinner != nil {
                self.spinner?.stop()
                self.spinner = nil
                print()
            }

            if self.isThinking {
                self.isThinking = false
                print()
            }

            print(content, terminator: "")
            fflush(stdout)
        }
    }

    private func handleThinkingMessage(_ content: String) {
        self.hasReceivedContent = true
        if self.outputMode == .verbose {
            print("\n\(AgentDisplayTokens.Status.planning) Thinking: \(content)")
            return
        }

        if self.spinner != nil {
            self.spinner?.stop()
            self.spinner = nil
            print()
        }

        if !self.isThinking {
            self.isThinking = true
            print("\n\(TerminalColor.gray)", terminator: "")
        }

        // Render thinking in italic gray so it stands apart from streamed assistant text.
        print("\(TerminalColor.gray)\(TerminalColor.italic)\(content)\(TerminalColor.reset)")
        fflush(stdout)
    }

    private func handleError(_ message: String) {
        self.spinner?.stop()
        self.spinner = nil

        if self.outputMode == .minimal {
            print("\nError: \(message)")
        } else if self.outputMode != .quiet {
            print("\n\(TerminalColor.red)\(AgentDisplayTokens.Status.failure) Error: \(message)\(TerminalColor.reset)")
        }
    }

    private func handleCompleted(summary: String, usage: Tachikoma.Usage?) {
        self.spinner?.stop()
        self.spinner = nil

        // Update token count if available
        if let usage {
            self.totalTokens = usage.inputTokens + usage.outputTokens
        }

        guard !self.hasShownFinalSummary && self.outputMode != .quiet else { return }

        let totalElapsed = Date().timeIntervalSince(self.startTime)
        let tokenInfo = self.totalTokens > 0 ? ", \(self.totalTokens) tokens" : ""
        let toolsText = self.toolCallCount == 1 ? "⚒ 1 tool" : "⚒ \(self.toolCallCount) tools"

        if !summary.isEmpty && self.outputMode == .verbose {
            print("\n\(TerminalColor.gray)Summary: \(summary)\(TerminalColor.reset)")
        }

        print(self.completionSummaryLine(
            totalElapsed: totalElapsed,
            toolsText: toolsText,
            tokenInfo: tokenInfo
        ))
        self.hasShownFinalSummary = true
    }

    // MARK: - Public Methods

    func updateTokenCount(_ count: Int) {
        self.totalTokens = count
    }

    func showFinalSummaryIfNeeded(_ result: AgentExecutionResult) {
        guard !self.hasShownFinalSummary && self.outputMode != .quiet else { return }

        let totalElapsed = Date().timeIntervalSince(self.startTime)
        let tokenInfo = self.totalTokens > 0 ? ", \(self.totalTokens) tokens" : ""
        let toolsText = self.toolCallCount == 1 ? "⚒ 1 tool" : "⚒ \(self.toolCallCount) tools"

        if !result.content.isEmpty && self.outputMode == .verbose {
            print("\n\(TerminalColor.gray)Summary: \(result.content)\(TerminalColor.reset)")
        }

        print(self.completionSummaryLine(
            totalElapsed: totalElapsed,
            toolsText: toolsText,
            tokenInfo: tokenInfo
        ))
        self.hasShownFinalSummary = true
    }
}
