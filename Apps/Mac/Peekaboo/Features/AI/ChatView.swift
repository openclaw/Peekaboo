import SwiftUI
import Tachikoma

// MARK: - Chat View Components

@available(macOS 14.0, *)
public struct PeekabooChatView: View {
    @AI private var ai
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    public init(
        model: Model = .default,
        system: String? = nil,
        settings: GenerationSettings = .default,
        tools: [AgentTool]? = nil)
    {
        self._ai = AI(
            model: model,
            system: system,
            settings: settings,
            tools: tools)
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Chat messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(self.ai.conversationMessages, id: \.id) { message in
                            MessageBubble(message: message)
                                .id(message.id)
                        }

                        if self.ai.isGenerating, !self.ai.streamingText.isEmpty {
                            MessageBubble(
                                message: .assistant(self.ai.streamingText),
                                isStreaming: true)
                                .id("streaming")
                        }
                    }
                    .padding()
                }
                .onChange(of: self.ai.messages.count) { _, _ in
                    // Auto-scroll to bottom when new messages arrive
                    withAnimation(.easeOut(duration: 0.3)) {
                        if let lastMessage = self.ai.conversationMessages.last {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: self.ai.streamingText) { _, _ in
                    // Auto-scroll during streaming
                    if !self.ai.streamingText.isEmpty {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("streaming", anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Input area
            VStack(alignment: .trailing, spacing: 8) {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Type your message...", text: self.$inputText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(8)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(8)
                        .focused(self.$isInputFocused)
                        .onSubmit {
                            if !self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                self.sendMessage()
                            }
                        }

                    VStack(spacing: 4) {
                        Button(action: self.sendMessage) {
                            Image(systemName: "paperplane.fill")
                                .foregroundColor(.white)
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(self.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || self.ai
                            .isGenerating)

                        if self.ai.isGenerating {
                            Button("Cancel") {
                                self.ai.cancelGeneration()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                // Quick actions
                HStack {
                    Button("Clear") {
                        self.ai.clear()
                        self.inputText = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(self.ai.messages.isEmpty)

                    Spacer()

                    if self.ai.isGenerating {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
        }
        .onAppear {
            self.isInputFocused = true
        }
        .alert("Error", isPresented: .constant(self.ai.error != nil)) {
            Button("OK") {
                self.ai.error = nil
            }
        } message: {
            Text(self.ai.error?.localizedDescription ?? "Unknown error")
        }
    }

    private func sendMessage() {
        let message = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }

        self.inputText = ""

        Task {
            await self.ai.send(message)
        }
    }
}

@available(macOS 14.0, *)
public struct MessageBubble: View {
    let message: ModelMessage
    let isStreaming: Bool

    public init(message: ModelMessage, isStreaming: Bool = false) {
        self.message = message
        self.isStreaming = isStreaming
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if self.message.role == .user {
                Spacer(minLength: 60)
            }

            VStack(alignment: self.message.role == .user ? .trailing : .leading, spacing: 4) {
                // Message content
                Text(self.contentText)
                    .padding(12)
                    .background(self.bubbleColor)
                    .foregroundColor(self.textColor)
                    .cornerRadius(16)
                    .frame(maxWidth: .infinity, alignment: self.message.role == .user ? .trailing : .leading)

                // Streaming indicator
                if self.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("AI is typing...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Timestamp
                Text(self.formattedTimestamp)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: self.message.role == .user ? .trailing : .leading)
            }

            if self.message.role == .assistant {
                Spacer(minLength: 60)
            }
        }
    }

    private var contentText: String {
        // Extract text from content parts
        self.message.content
            .compactMap { part in
                if case let .text(text) = part {
                    return text
                }
                return nil
            }
            .joined(separator: "\n")
    }

    private var bubbleColor: Color {
        switch self.message.role {
        case .user:
            .accentColor
        case .assistant:
            Color.gray.opacity(0.2)
        case .system:
            Color.yellow.opacity(0.2)
        case .tool:
            Color.purple.opacity(0.2)
        }
    }

    private var textColor: Color {
        switch self.message.role {
        case .user:
            .white
        case .assistant, .system, .tool:
            .primary
        }
    }

    private var formattedTimestamp: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self.message.timestamp)
    }
}

#Preview {
    PeekabooChatView(
        model: LanguageModel.anthropic(.opus48),
        system: "You are a helpful assistant specialized in macOS automation and development.")
        .frame(width: 400, height: 600)
}
