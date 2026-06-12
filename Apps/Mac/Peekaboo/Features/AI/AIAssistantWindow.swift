import SwiftUI
import Tachikoma

private enum AIAssistantPrompts {
    static let general = "You are a helpful assistant specialized in macOS automation and development using Peekaboo."
    static let automation = """
    You are an expert in macOS automation. Help users create powerful automation workflows using \
    Peekaboo's tools. Be specific about which commands to use and provide working examples.
    """
    static let swift = """
    You are a Swift development expert. Help with Swift programming, SwiftUI, macOS app development, \
    and integration with Peekaboo's APIs. Provide clean, modern Swift code examples.
    """
    static let debugging = """
    You are a debugging specialist. Help users troubleshoot issues with Peekaboo automation scripts, \
    analyze error messages, and suggest solutions. Always ask for specific error details and logs.
    """
    static let compactDefault = "You are a helpful assistant."
}

// MARK: - AI Assistant Window

@available(macOS 14.0, *)
public struct AIAssistantWindow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedModel: Model = .openai(.gpt55)
    @State private var systemPrompt: String = AIAssistantPrompts.general
    @State private var showSettings = false

    public init() {}

    public var body: some View {
        NavigationSplitView {
            // Sidebar with settings
            VStack(alignment: .leading, spacing: 16) {
                // Model selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("AI Model")
                        .font(.headline)

                    Picker("Model", selection: self.$selectedModel) {
                        Text("GPT-5.5").tag(Model.openai(.gpt55))
                        Text("Claude Opus 4.8").tag(Model.anthropic(.opus48))
                    }
                    .pickerStyle(.menu)
                }

                Divider()

                // System prompt
                VStack(alignment: .leading, spacing: 8) {
                    Text("System Prompt")
                        .font(.headline)

                    TextEditor(text: self.$systemPrompt)
                        .frame(minHeight: 100)
                        .padding(4)
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(6)
                }

                Divider()

                // Quick templates
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Templates")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        Button("👻 General Assistant") {
                            self.systemPrompt = AIAssistantPrompts.general
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)

                        Button("⚡ Automation Expert") {
                            self.systemPrompt = AIAssistantPrompts.automation
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)

                        Button("🧑‍[sh] Swift Developer") {
                            self.systemPrompt = AIAssistantPrompts.swift
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)

                        Button("🔍 Debugging Helper") {
                            self.systemPrompt = AIAssistantPrompts.debugging
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                }

                Spacer()
            }
            .padding()
            .frame(minWidth: 250, maxWidth: 300)
        } detail: {
            // Main chat area
            PeekabooChatView(
                model: self.selectedModel,
                system: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
                settings: .default,
                tools: nil)
                .id(self.selectedModel.description)
        }
        .navigationTitle("AI Assistant")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Close") {
                    self.dismiss()
                }
            }
        }
    }
}

// MARK: - Compact AI Assistant

/// A more compact version suitable for smaller windows or panels
@available(macOS 14.0, *)
public struct CompactAIAssistant: View {
    @State private var model: Model = .openai(.gpt55)
    let systemPrompt: String

    public init(systemPrompt: String? = nil) {
        self.systemPrompt = systemPrompt ?? AIAssistantPrompts.compactDefault
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header with model selector
            HStack {
                Text("AI Assistant")
                    .font(.headline)

                Spacer()

                Picker("Model", selection: self.$model) {
                    Text("GPT-5.5").tag(Model.openai(.gpt55))
                    Text("Claude Opus 4.8").tag(Model.anthropic(.opus48))
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.gray.opacity(0.1))

            // Chat interface
            PeekabooChatView(
                model: self.model,
                system: self.systemPrompt.isEmpty ? nil : self.systemPrompt,
                settings: .default,
                tools: nil)
                .id(self.model.description)
        }
    }
}

#Preview("AI Assistant Window") {
    AIAssistantWindow()
        .frame(width: 800, height: 600)
}

#Preview("Compact AI Assistant") {
    CompactAIAssistant(systemPrompt: "You are a helpful macOS automation assistant.")
        .frame(width: 400, height: 500)
}
