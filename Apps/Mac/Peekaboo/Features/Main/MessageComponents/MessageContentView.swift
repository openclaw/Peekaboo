import Combine
import PeekabooCore
import SwiftUI

// MARK: - Message Content View

struct MessageContentView: View {
    let message: ConversationMessage
    let isThinkingMessage: Bool
    let isErrorMessage: Bool
    let isWarningMessage: Bool
    let isToolMessage: Bool
    let extractToolName: (String) -> String

    var body: some View {
        if self.isThinkingMessage {
            // Show the actual thinking content, removing the planning token prefix
            Text(self.message.content.replacingOccurrences(
                of: "\(AgentDisplayTokens.Status.planning) ",
                with: ""))
                .font(.system(.body))
                .foregroundColor(.purple)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.isErrorMessage {
            Text(self.message.content)
                .foregroundColor(.red)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.isWarningMessage {
            Text(self.message.content)
                .foregroundColor(.orange)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.isToolMessage {
            ToolMessageContent(message: self.message, extractToolName: self.extractToolName)
        } else if self.message.role == .assistant {
            AssistantMessageContent(message: self.message)
        } else {
            Text(self.message.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Tool Message Content

struct ToolMessageContent: View {
    let message: ConversationMessage
    let extractToolName: (String) -> String

    var body: some View {
        // Show tool execution details without inline icon (icon is in avatar position)
        if let toolCall = message.toolCalls.first {
            let isRunning = toolCall.result == "Running..."
            let content = self.message.content
                .replacingOccurrences(of: AgentDisplayTokens.Status.running + " ", with: "")
                .replacingOccurrences(of: AgentDisplayTokens.Status.success + " ", with: "")
                .replacingOccurrences(of: AgentDisplayTokens.Status.failure + " ", with: "")

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(content)
                        .font(.system(.body, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    if !isRunning, toolCall.result != "Running..." {
                        // Show result summary if available
                        let toolName = self.extractToolName(self.message.content)
                        if let resultSummary = ToolFormatter.toolResultSummary(
                            toolName: toolName,
                            result: toolCall.result)
                        {
                            Text(resultSummary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                if isRunning {
                    TimeIntervalText(startTime: self.message.timestamp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .textSelection(.enabled)
        } else {
            Text(self.message.content
                .replacingOccurrences(of: AgentDisplayTokens.Status.running + " ", with: "")
                .replacingOccurrences(of: AgentDisplayTokens.Status.success + " ", with: "")
                .replacingOccurrences(of: AgentDisplayTokens.Status.failure + " ", with: ""))
                .font(.system(.body, design: .rounded))
                .fontWeight(.medium)
                .foregroundColor(.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Assistant Message Content

struct AssistantMessageContent: View {
    let message: ConversationMessage

    var body: some View {
        // Render assistant messages as Markdown
        if let attributedString = try? AttributedString(
            markdown: message.content,
            options: AttributedString.MarkdownParsingOptions(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace))
        {
            Text(attributedString)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(self.message.content)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Displays elapsed time since a start time, updating every second.
struct TimeIntervalText: View {
    let startTime: Date
    @State private var currentTime = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(ToolFormatter.formatDuration(self.currentTime.timeIntervalSince(self.startTime)))
            .onReceive(self.timer) { _ in
                self.currentTime = Date()
            }
    }
}
