import AppKit
import os.log
import PeekabooCore
import SwiftUI

struct MenuBarStatusView: View {
    private let logger = Logger(subsystem: "boo.peekaboo.app", category: "MenuBarStatus")

    @Environment(PeekabooAgent.self) private var agent
    @Environment(SessionStore.self) private var sessionStore
    @Environment(PeekabooSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

    @State private var inputText = ""
    @State private var detailsExpanded = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            StatusBarHeaderView(
                onOpenMainWindow: self.openMainWindow,
                onOpenInspector: self.openInspector,
                onOpenSettings: self.openSettings,
                onNewSession: self.createNewSession)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            StatusBarInputView(
                inputText: self.$inputText,
                isInputFocused: self.$isInputFocused,
                isProcessing: self.agent.isProcessing,
                onSubmit: self.submitInput)
                .padding(12)

            Divider()

            StatusBarContentView(detailsExpanded: self.$detailsExpanded)
                .frame(maxHeight: 320)
                .padding(.horizontal, 8)
                .padding(.vertical, 10)

            Divider()

            ActionButtonsView(
                onOpenMainWindow: self.openMainWindow,
                onNewSession: self.createNewSession)
                .padding(12)
        }
        .frame(width: 360)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(NSColor.separatorColor).opacity(0.7), lineWidth: 0.5)
        }
        .padding(8)
        .onAppear {
            self.focusInputIfNeeded()
        }
        .onChange(of: self.agent.isProcessing) { _, newValue in
            if newValue {
                self.detailsExpanded = true
            }
            self.focusInputIfNeeded()
        }
        .onChange(of: self.sessionStore.currentSession?.id) { _, _ in
            self.focusInputIfNeeded()
        }
    }

    // MARK: - Setup and Lifecycle

    private func focusInputIfNeeded() {
        guard !self.agent.isProcessing else { return }
        DispatchQueue.main.async {
            self.isInputFocused = true
        }
    }

    // MARK: - Input Handling

    private func submitInput() {
        let text = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        self.executeTask(text)
        self.inputText = ""
    }

    private func executeTask(_ text: String) {
        // Add user message to current session (or create new if needed)
        if let session = sessionStore.currentSession {
            self.sessionStore.addMessage(
                PeekabooCore.ConversationMessage(role: .user, content: text),
                to: session)
        } else {
            // Create new session if needed
            let newSession = self.sessionStore.createSession(title: text)
            self.sessionStore.addMessage(
                PeekabooCore.ConversationMessage(role: .user, content: text),
                to: newSession)
        }

        // Execute the task
        Task {
            do {
                try await self.agent.executeTask(text)
            } catch {
                self.logger.error("Failed to execute task: \(error)")
            }
        }
    }

    private func openMainWindow() {
        guard AgentSessionUI.isAvailable(agentModeEnabled: self.settings.agentModeEnabled) else { return }

        DockIconManager.shared.temporarilyShowDock()
        NSApp.activate(ignoringOtherApps: true)
        self.openWindow(id: "main")
    }

    private func openInspector() {
        DockIconManager.shared.temporarilyShowDock()
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showInspector, object: nil)
    }

    private func openSettings() {
        SettingsOpener.openSettings()
    }

    private func createNewSession() {
        guard AgentSessionUI.isAvailable(agentModeEnabled: self.settings.agentModeEnabled) else { return }

        _ = self.sessionStore.createSession(title: "New Session")
        self.detailsExpanded = true
    }
}
