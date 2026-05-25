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
    let environmentValueLabel: String

    var primaryEnvironmentVariable: String {
        self.environmentVariables.first ?? ""
    }

    static let openai = ProviderInfo(
        name: "openai",
        displayName: "OpenAI",
        environmentVariables: ["OPENAI_API_KEY"],
        requiresAPIKey: true,
        environmentValueLabel: "API key")

    static let anthropic = ProviderInfo(
        name: "anthropic",
        displayName: "Anthropic",
        environmentVariables: ["ANTHROPIC_API_KEY"],
        requiresAPIKey: true,
        environmentValueLabel: "API key")

    static let grok = ProviderInfo(
        name: "grok",
        displayName: "Grok",
        environmentVariables: ["X_AI_API_KEY", "XAI_API_KEY", "GROK_API_KEY"],
        requiresAPIKey: true,
        environmentValueLabel: "API key")

    static let google = ProviderInfo(
        name: "google",
        displayName: "Gemini",
        environmentVariables: ["GEMINI_API_KEY", "GOOGLE_API_KEY"],
        requiresAPIKey: true,
        environmentValueLabel: "API key")

    static let minimax = ProviderInfo(
        name: "minimax",
        displayName: "MiniMax",
        environmentVariables: ["MINIMAX_API_KEY"],
        requiresAPIKey: true,
        environmentValueLabel: "API key")

    static let minimaxChina = ProviderInfo(
        name: "minimax-cn",
        displayName: "MiniMax China",
        environmentVariables: ["MINIMAX_CN_API_KEY", "MINIMAX_API_KEY"],
        requiresAPIKey: true,
        environmentValueLabel: "API key")

    static let ollama = ProviderInfo(
        name: "ollama",
        displayName: "Ollama",
        environmentVariables: ["OLLAMA_API_KEY"],
        requiresAPIKey: false,
        environmentValueLabel: "API key")
}

/// Reusable API key field that shows environment variable status and allows override
struct APIKeyField: View {
    let provider: ProviderInfo
    @Binding var apiKey: String
    @State private var detectedEnvironmentVariable: String?
    @State private var showEnvironmentStatus: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(self.provider.displayName) API Key")
                    .font(.headline)

                if self.hasEnvironmentKey {
                    Label("Found in environment", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }

            if self.hasEnvironmentKey, self.apiKey.isEmpty {
                // Show environment variable status when no override is set
                HStack {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundColor(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            "Using \(self.provider.environmentValueLabel) from \(self.displayEnvironmentVariable)")
                            .font(.callout)
                            .foregroundColor(.secondary)

                        Text("Leave empty to continue using environment variable")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .opacity(0.7)
                    }

                    Spacer()

                    Button("Override") {
                        // Focus on the text field by setting a placeholder
                        self.showEnvironmentStatus = true
                    }
                    .buttonStyle(.link)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)

                if self.showEnvironmentStatus {
                    SecureField("Enter API key to override environment variable", text: self.$apiKey)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                // Normal text field for manual API key entry
                SecureField(self.environmentPlaceholder, text: self.$apiKey)
                    .textFieldStyle(.roundedBorder)

                if self.hasEnvironmentKey, !self.apiKey.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)

                        Text("Overriding environment variable \(self.displayEnvironmentVariable)")
                            .font(.caption)
                            .foregroundColor(.orange)

                        Spacer()

                        Button("Use Environment") {
                            self.apiKey = ""
                            self.showEnvironmentStatus = false
                        }
                        .buttonStyle(.link)
                    }
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

    private var hasEnvironmentKey: Bool {
        self.detectedEnvironmentVariable != nil
    }

    private var displayEnvironmentVariable: String {
        self.detectedEnvironmentVariable ?? self.provider.primaryEnvironmentVariable
    }

    private var environmentPlaceholder: String {
        if self.hasEnvironmentKey {
            "Override \(self.displayEnvironmentVariable) or leave empty"
        } else if self.provider.requiresAPIKey {
            "Enter your \(self.provider.displayName) API key"
        } else {
            "Optional API key for \(self.provider.displayName)"
        }
    }

    private func checkEnvironmentVariable() {
        let environment = ProcessInfo.processInfo.environment
        self.detectedEnvironmentVariable = self.provider.environmentVariables.first { key in
            environment[key]?.isEmpty == false
        }
    }
}
