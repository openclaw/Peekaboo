//
//  APIKeyField.swift
//  Peekaboo
//

import SwiftUI

/// Provider information for API key fields
struct ProviderInfo {
    let name: String
    let displayName: String
    let environmentVariables: [String]
    let requiresAPIKey: Bool

    static let openai = ProviderInfo(
        name: "openai",
        displayName: "OpenAI",
        environmentVariables: ["OPENAI_API_KEY"],
        requiresAPIKey: true)

    static let anthropic = ProviderInfo(
        name: "anthropic",
        displayName: "Anthropic",
        environmentVariables: ["ANTHROPIC_API_KEY"],
        requiresAPIKey: true)

    static let grok = ProviderInfo(
        name: "grok",
        displayName: "Grok",
        environmentVariables: ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"],
        requiresAPIKey: true)

    static let google = ProviderInfo(
        name: "google",
        displayName: "Gemini",
        environmentVariables: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        requiresAPIKey: true)

    static let minimax = ProviderInfo(
        name: "minimax",
        displayName: "MiniMax",
        environmentVariables: ["MINIMAX_API_KEY"],
        requiresAPIKey: true)

    static let minimaxChina = ProviderInfo(
        name: "minimax-cn",
        displayName: "MiniMax China",
        environmentVariables: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY"],
        requiresAPIKey: false)

    static let ollama = ProviderInfo(
        name: "ollama",
        displayName: "Ollama",
        environmentVariables: ["OLLAMA_API_KEY"],
        requiresAPIKey: false)
}

/// One form row per provider: name on the left, secure field on the right,
/// with a compact footnote describing environment-variable state.
/// Typing a key overrides the environment; clearing it falls back.
struct APIKeyField: View {
    let provider: ProviderInfo
    @Binding var apiKey: String
    @State private var detectedEnvironmentVariable: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField(self.provider.displayName, text: self.$apiKey, prompt: Text(self.placeholder))
                .multilineTextAlignment(.trailing)

            if let variable = self.detectedEnvironmentVariable {
                if self.apiKey.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Using \(variable) from the environment")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Overriding \(variable)")
                            .foregroundStyle(.secondary)
                        Button("Use Environment") {
                            self.apiKey = ""
                        }
                        .buttonStyle(.link)
                    }
                    .font(.caption)
                }
            }
        }
        .onAppear {
            self.checkEnvironmentVariable()
        }
        .onChange(of: self.apiKey) { _, _ in
            self.checkEnvironmentVariable()
        }
    }

    private var placeholder: String {
        if self.detectedEnvironmentVariable != nil {
            "Override environment key"
        } else if self.provider.requiresAPIKey {
            "Required"
        } else {
            "Optional"
        }
    }

    private func checkEnvironmentVariable() {
        let environment = ProcessInfo.processInfo.environment
        self.detectedEnvironmentVariable = self.provider.environmentVariables.first { key in
            environment[key]?.isEmpty == false
        }
    }
}
