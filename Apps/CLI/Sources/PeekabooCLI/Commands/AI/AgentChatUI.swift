//
//  AgentChatUI.swift
//  PeekabooCLI
//

import Foundation
import PeekabooAgentRuntime
import TauTUI

@MainActor
final class AgentChatUI {
    var onCancelRequested: (() -> Void)?
    var onInterruptRequested: (() -> Void)?

    private let tui: TUI
    private let messages = Container()
    private let input = AgentChatInput()
    private let header: Text
    private let sessionLine: Text
    private let helpLines: [String]
    private let queueMode: QueueMode
    private let queueContainer = Container()
    private let queuePreview = Text(text: "", paddingX: 1, paddingY: 0)

    // Palette for consistent styling (ANSI colors)
    private let accentBlue = AnsiStyling.color(39)
    private let successGreen = AnsiStyling.color(82)
    private let failureRed = AnsiStyling.color(203)
    private let thinkingGray = AnsiStyling.color(246)

    private var promptContinuation: AsyncStream<String>.Continuation?
    private var loader: AgentChatLoader?
    private var assistantBuffer = ""
    private var assistantComponent: MarkdownComponent?
    private var thinkingBlocks: [MarkdownComponent] = []
    private var sessionId: String?
    private var queuedPrompts: [String] = []
    private var isRunning = false

    init(modelDescription: String, sessionId: String?, queueMode: QueueMode, helpLines: [String]) {
        self.tui = TUI(terminal: ProcessTerminal())
        self.sessionId = sessionId
        self.helpLines = helpLines
        self.queueMode = queueMode
        let queueLabel = queueMode == .all ? "all" : "one-at-a-time"
        self.header = Text(
            text: "Interactive agent chat – model: \(modelDescription) • queue: \(queueLabel)",
            paddingX: 1,
            paddingY: 0
        )
        self.sessionLine = Text(
            text: AgentChatUI.sessionDescription(for: sessionId, queueMode: queueMode),
            paddingX: 1,
            paddingY: 0
        )

        self.input.onSubmit = { [weak self] value in
            self?.handleSubmit(value)
        }
        self.input.onCancel = { [weak self] in
            self?.onCancelRequested?()
        }
        self.input.onInterrupt = { [weak self] in
            self?.onInterruptRequested?()
        }
        self.input.onQueueWhileLocked = { [weak self] in
            self?.queueCurrentInput()
        }
    }

    func start() throws {
        self.tui.addChild(self.header)
        self.tui.addChild(self.sessionLine)
        self.tui.addChild(Spacer(lines: 1))
        self.tui.addChild(self.messages)
        self.tui.addChild(Spacer(lines: 1))
        self.tui.addChild(self.queueContainer)
        self.tui.addChild(self.input)
        self.tui.setFocus(self.input)

        try self.tui.start()
        self.showHelpMenu()
        self.tui.requestRender()
    }

    func stop() {
        self.tui.stop()
    }

    func promptStream(initialPrompt: String?) -> AsyncStream<String> {
        AsyncStream { continuation in
            self.promptContinuation = continuation
            if let seed = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !seed.isEmpty {
                self.appendUserMessage(seed)
                continuation.yield(seed)
            }
        }
    }

    func finishPromptStream() {
        self.promptContinuation?.finish()
    }

    func beginRun(prompt: String) {
        self.setRunning(true)
        self.removeLoader()
        self.loader = AgentChatLoader(tui: self.tui, message: "Running…")
        if let loader {
            self.messages.addChild(loader)
        }
        self.assistantBuffer = ""
        self.assistantComponent = nil
        self.thinkingBlocks.removeAll()
        self.requestRender()
    }

    func endRun(result: AgentExecutionResult, sessionId: String?) {
        self.loader?.stop()
        self.loader = nil
        if let sessionId {
            self.sessionId = sessionId
            self.sessionLine.text = AgentChatUI.sessionDescription(for: sessionId, queueMode: self.queueMode)
        }
        let summary = self.summaryLine(for: result)
        let summaryComponent = Text(text: summary, paddingX: 1, paddingY: 0)
        self.messages.addChild(summaryComponent)
        self.setRunning(false)
        self.processNextQueuedPromptIfNeeded()
        self.requestRender()
    }

    func showHelpMenu() {
        // Render each line separately so the bullets always appear on their own lines,
        // even when terminals collapse single newlines in a single Text component.
        for line in self.helpLines {
            let helpLine = Text(text: line, paddingX: 1, paddingY: 0)
            self.messages.addChild(helpLine)
        }
        self.requestRender()
    }

    func showCancelled() {
        self.setRunning(false)
        let cancelled = Text(text: "◼︎ Cancelled", paddingX: 1, paddingY: 0)
        self.messages.addChild(cancelled)
        self.requestRender()
    }

    func showError(_ message: String) {
        self.setRunning(false)
        let errorText = Text(text: "✗ \(message)", paddingX: 1, paddingY: 0)
        self.messages.addChild(errorText)
        self.requestRender()
    }

    func updateSessionId(_ sessionId: String) {
        self.sessionId = sessionId
        self.sessionLine.text = AgentChatUI.sessionDescription(for: sessionId, queueMode: self.queueMode)
        self.requestRender()
    }

    func showToolStart(name: String, summary: String?, icon: String?, displayName: String?) {
        let label = displayName ?? name
        let detail = summary.flatMap { $0.isEmpty ? nil : $0 }
        let body = detail.map { "**\(label)** – \($0)" } ?? "**\(label)**"
        let content = ["⚒", icon, body].compactMap(\.self).joined(separator: " ")
        self.messages.addChild(self.colorLine(content, color: self.accentBlue))
        self.requestRender()
    }

    func showToolCompletion(name: String, success: Bool, summary: String?, icon: String?, displayName: String?) {
        let prefix = success ? "✓" : "✗"
        let color = success ? self.successGreen : self.failureRed
        let label = displayName ?? name
        let detail = summary.flatMap { $0.isEmpty ? nil : $0 }
        let body = detail.map { "**\(label)** – \($0)" } ?? "**\(label)**"
        let content = [prefix, icon, body].compactMap(\.self).joined(separator: " ")
        self.messages.addChild(self.colorLine(content, color: color))
        self.requestRender()
    }

    func showToolUpdate(name: String, summary: String?, icon: String?, displayName: String?) {
        let label = displayName ?? name
        let detail = summary.flatMap { $0.isEmpty ? nil : $0 }
        let body = detail.map { "**\(label)** – \($0)" } ?? "**\(label)**"
        let content = ["↻", icon, body].compactMap(\.self).joined(separator: " ")
        self.messages.addChild(self.colorLine(content, color: self.accentBlue))
        self.requestRender()
    }

    func updateThinking(_ content: String) {
        let component = MarkdownComponent(
            text: "*\(content)*",
            padding: .init(horizontal: 1, vertical: 0),
            defaultTextStyle: .init(color: self.thinkingGray)
        )
        self.thinkingBlocks.append(component)
        self.messages.addChild(component)
        self.requestRender()
    }

    func appendAssistant(_ content: String) {
        self.assistantBuffer.append(content)
        let formatted = "**Agent:** \(self.assistantBuffer)"
        if let assistantComponent {
            assistantComponent.text = formatted
        } else {
            let component = MarkdownComponent(text: formatted, padding: .init(horizontal: 1, vertical: 0))
            self.assistantComponent = component
            self.messages.addChild(component)
        }
        self.requestRender()
    }

    func finishStreaming() {
        self.requestRender()
    }

    func setRunning(_ running: Bool) {
        let wasRunning = self.isRunning
        self.isRunning = running
        self.input.isLocked = running
        if !running {
            self.removeLoader()
            if wasRunning {
                self.processNextQueuedPromptIfNeeded()
            }
        }
    }

    func markCancelling() {
        self.loader?.setMessage("Cancelling…")
        self.requestRender()
    }

    func requestRender() {
        self.tui.requestRender()
    }

    private func colorLine(_ text: String, color: @escaping AnsiStyling.Style) -> MarkdownComponent {
        MarkdownComponent(
            text: text,
            padding: .init(horizontal: 1, vertical: 0),
            defaultTextStyle: .init(color: color)
        )
    }

    private func removeLoader() {
        guard let loader else { return }
        loader.stop()
        self.messages.removeChild(loader)
        self.loader = nil
        self.requestRender()
    }

    private func handleSubmit(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if self.isRunning {
            self.enqueueQueuedPrompt(trimmed)
            self.input.clear()
            return
        }

        self.dispatchPrompt(trimmed)
    }

    private func queueCurrentInput() {
        guard self.isRunning else { return }
        let trimmed = self.input.currentText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.enqueueQueuedPrompt(trimmed)
        self.input.clear()
    }

    private func enqueueQueuedPrompt(_ prompt: String) {
        self.queuedPrompts.append(prompt)
        self.updateQueuePreview()
    }

    private func updateQueuePreview() {
        if self.queuedPrompts.isEmpty {
            self.queueContainer.clear()
            self.queuePreview.text = ""
            self.requestRender()
            return
        }

        self.queuePreview.text = self.queuePreviewLine()
        if self.queueContainer.children.isEmpty {
            self.queueContainer.addChild(self.queuePreview)
        }
        self.requestRender()
    }

    private func queuePreviewLine() -> String {
        let joined = self.queuedPrompts.joined(separator: "   ·   ")
        var summary = "Queued (\(self.queuedPrompts.count)): \(joined)"
        let limit = 96
        if summary.count > limit {
            let index = summary.index(summary.startIndex, offsetBy: max(0, limit - 1))
            summary = String(summary[..<index]) + "…"
        }
        return summary
    }

    private func processNextQueuedPromptIfNeeded() {
        guard !self.queuedPrompts.isEmpty else { return }
        let next = self.queuedPrompts.removeFirst()
        self.updateQueuePreview()
        self.dispatchPrompt(next)
    }

    func drainQueuedPrompts() -> [String] {
        let queued = self.queuedPrompts
        self.queuedPrompts.removeAll()
        self.updateQueuePreview()
        return queued
    }

    private func dispatchPrompt(_ text: String) {
        self.appendUserMessage(text)
        self.promptContinuation?.yield(text)
    }

    private func appendUserMessage(_ text: String) {
        let message = MarkdownComponent(text: "**You:** \(text)", padding: .init(horizontal: 1, vertical: 0))
        self.messages.addChild(message)
        self.requestRender()
    }

    private func summaryLine(for result: AgentExecutionResult) -> String {
        let duration = String(format: "%.1fs", result.metadata.executionTime)
        let tools = result.metadata.toolCallCount == 1 ? "1 tool" : "\(result.metadata.toolCallCount) tools"
        let sessionFragment = self.sessionId.map { String($0.prefix(8)) } ?? "new session"
        return "✓ Session \(sessionFragment) • \(duration) • \(tools)"
    }

    private static func sessionDescription(for sessionId: String?, queueMode: QueueMode) -> String {
        let base = sessionId.map { "Session: \($0)" } ?? "Session: new (will be created on first run)"
        let mode = queueMode == .all ? "queue: all" : "queue: one-at-a-time"
        return "\(base) • \(mode)"
    }
}
