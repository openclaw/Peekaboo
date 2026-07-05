import PeekabooCore
import SwiftUI

// MARK: - Session Detail View

struct SessionChatView: View {
    @Environment(PeekabooAgent.self) private var agent
    @Environment(SessionStore.self) private var sessionStore

    let session: ConversationSession
    @State private var inputText = ""
    @State private var isProcessing = false
    @State private var hasConnectionError = false

    private var isCurrentSession: Bool {
        self.session.id == self.agent.currentSession?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            SessionChatHeader(
                session: self.session,
                isActive: self.isCurrentSession && self.agent.isProcessing)

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(self.session.messages) { message in
                            DetailedMessageRow(message: message)
                                .id(message.id)
                                .transition(.asymmetric(
                                    insertion: .push(from: .bottom).combined(with: .opacity),
                                    removal: .opacity))
                                .animation(
                                    .spring(response: 0.3, dampingFraction: 0.8),
                                    value: self.session.messages.count)
                        }

                        // Show progress indicator for active session
                        if self.isCurrentSession, self.agent.isProcessing {
                            ProgressIndicatorView(agent: self.agent)
                                .id("progress")
                                .padding(.top, 8)
                                .transition(.asymmetric(
                                    insertion: .push(from: .bottom).combined(with: .opacity),
                                    removal: .opacity))
                                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: self.agent.isProcessing)
                        }
                    }
                    .padding()
                }
                .onChange(of: self.session.messages.count) { _, _ in
                    // Auto-scroll to bottom on new messages
                    if let lastMessage = session.messages.last {
                        withAnimation {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Input area (only for current session)
            if self.isCurrentSession {
                Divider()

                // Connection error banner
                if self.hasConnectionError {
                    ConnectionErrorBanner(
                        hasConnectionError: self.$hasConnectionError,
                        agent: self.agent,
                        isProcessing: self.$isProcessing)
                    Divider()
                }

                self.textInputArea
            }
        }
    }

    // MARK: - Input Areas

    private var textInputArea: some View {
        HStack(spacing: 8) {
            TextField(self.placeholderText, text: self.$inputText)
                .textFieldStyle(.plain)
                .font(.body)
                .onSubmit {
                    self.submitInput()
                }

            if self.agent.isProcessing, self.isCurrentSession {
                // Show stop button during execution
                Button(action: {
                    self.agent.cancelCurrentTask()
                }, label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                })
                .buttonStyle(.plain)
                .help("Cancel current task")
            }

            Button(action: self.submitInput, label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(self.inputText.isEmpty ? .secondary : .accentColor)
            })
            .buttonStyle(.plain)
            .disabled(self.inputText.isEmpty)
        }
        .padding(12)
    }

    private var placeholderText: String {
        if self.agent.isProcessing, self.isCurrentSession {
            "Ask a follow-up question..."
        } else {
            "Ask Peekaboo..."
        }
    }

    // MARK: - Input Handling

    private func submitInput() {
        let trimmedInput = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else { return }

        // Clear input immediately
        self.inputText = ""

        if self.agent.isProcessing, self.isCurrentSession {
            // During execution, just add as a follow-up message
            self.sessionStore.addMessage(
                ConversationMessage(role: .user, content: trimmedInput),
                to: self.session)

            // Start a new execution with the follow-up
            Task {
                do {
                    try await self.agent.executeTask(trimmedInput)
                } catch {
                    print("Failed to execute follow-up: \(error)")
                }
            }
        } else {
            // Normal execution
            Task {
                self.isProcessing = true
                defer { isProcessing = false }

                do {
                    try await self.agent.executeTask(trimmedInput)
                } catch {
                    // Check if it's a connection error
                    let errorMessage = error.localizedDescription
                    if errorMessage.contains("network") || errorMessage.contains("connection") {
                        self.hasConnectionError = true
                    }
                    // Error is already added to session by agent
                    print("Task error: \(errorMessage)")
                }
            }
        }
    }
}

// MARK: - Session Detail Header

struct SessionChatHeader: View {
    let session: ConversationSession
    let isActive: Bool

    @Environment(PeekabooAgent.self) private var agent
    @State private var showDebugInfo = false

    var body: some View {
        VStack(spacing: 0) {
            // Main header content
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(self.session.title)
                            .font(.headline)

                        if self.isActive {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.green)
                                .symbolEffect(.pulse, options: .repeating)
                        }
                    }

                    HStack(spacing: 4) {
                        if !self.session.modelName.isEmpty {
                            Text(formatModelName(self.session.modelName))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        if self.isActive, self.agent.isProcessing {
                            Text("•")
                                .foregroundColor(.secondary)

                            // Show current tool or thinking status
                            if let currentTool = agent.currentTool {
                                Text("\(PeekabooAgent.iconForTool(currentTool)) \(currentTool)")
                                    .font(.caption)
                                    .foregroundColor(.blue)

                                if let args = agent.currentToolArgs, !args.isEmpty {
                                    Text(args)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            } else if self.agent.isThinking {
                                AnimatedThinkingIndicator()
                            } else if !self.agent.currentTask.isEmpty {
                                Text(self.agent.currentTask)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                Spacer()

                // Debug toggle
                Button(action: { self.showDebugInfo.toggle() }, label: {
                    Label("Debug", systemImage: self.showDebugInfo ? "info.circle.fill" : "info.circle")
                        .foregroundColor(.secondary)
                })
                .buttonStyle(.plain)

                if self.isActive, self.agent.isProcessing {
                    Button(action: {
                        self.agent.cancelCurrentTask()
                    }, label: {
                        Label("Cancel", systemImage: "stop.circle")
                            .foregroundColor(.red)
                    })
                    .buttonStyle(.plain)
                }

                Text(self.session.startTime, format: .dateTime)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(self.showDebugInfo ? Color.clear : Color(NSColor.windowBackgroundColor))

            if self.showDebugInfo {
                Divider()
                    .padding(.horizontal)

                SessionDebugInfo(session: self.session, isActive: self.isActive)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .background(
            self.showDebugInfo ?
                // Extended white background with subtle material effect
                ZStack {
                    Color(NSColor.windowBackgroundColor)
                    VisualEffectView(material: .headerView, blendingMode: .withinWindow)
                        .opacity(0.5)
                } : nil)
    }
}

// MARK: - Connection Error Banner

struct ConnectionErrorBanner: View {
    @Binding var hasConnectionError: Bool
    let agent: PeekabooAgent
    @Binding var isProcessing: Bool

    var body: some View {
        HStack {
            Image(systemName: "wifi.slash")
                .foregroundColor(.red)

            Text("Connection lost. Messages will be queued.")
                .font(.caption)
                .foregroundColor(.red)

            Spacer()

            Button("Retry") {
                // Clear error state and retry connection
                self.hasConnectionError = false

                // Retry the last failed task if available
                if let lastTask = agent.lastTask {
                    Task {
                        self.isProcessing = true
                        defer { isProcessing = false }

                        // Re-execute the last task
                        do {
                            try await self.agent.executeTask(lastTask)
                            self.hasConnectionError = false
                        } catch {
                            // Error persists
                            self.hasConnectionError = true
                        }
                    }
                }
            }
            .buttonStyle(.link)
            .foregroundColor(.red)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.1))
    }
}

// MARK: - Empty Session View

struct EmptySessionView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            AnimatedGhostView(size: 108)
                .padding(.bottom, 28)

            Text("No Session Selected")
                .font(.title2.weight(.semibold))

            Text("Choose a session from the sidebar, or start a new conversation with Peekaboo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 8)

            self.newSessionButton
                .padding(.top, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Soft accent glow behind the ghost gives the glass something to refract.
            RadialGradient(
                colors: [Color.accentColor.opacity(self.colorScheme == .dark ? 0.16 : 0.10), .clear],
                center: UnitPoint(x: 0.5, y: 0.35),
                startRadius: 20,
                endRadius: 340)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var newSessionButton: some View {
        let button = Button {
            _ = self.sessionStore.createSession(title: "New Session")
        } label: {
            Label("New Session", systemImage: "plus")
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
        }
        .controlSize(.large)

        if #available(macOS 26.0, *) {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }
}
