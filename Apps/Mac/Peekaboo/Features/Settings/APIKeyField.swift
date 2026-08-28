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
        environmentVariables: ["MINIMAX_CN_API_KEY"],
        requiresAPIKey: false)

    static let ollama = ProviderInfo(
        name: "ollama",
        displayName: "Ollama",
        environmentVariables: ["OLLAMA_API_KEY"],
        requiresAPIKey: false)
}

/// The same production rows are used by Settings and the isolated native credential fixture.
struct ProviderCredentialRows: View {
    let coordinator: ProviderCredentialCoordinator
    var environment: [String: String] = ProcessInfo.processInfo.environment

    var body: some View {
        ForEach(PeekabooCredential.allCases, id: \.self) { credential in
            APIKeyField(credential: credential, coordinator: self.coordinator, environment: self.environment)
        }
        HStack {
            Button("Reload keys") { self.coordinator.reload() }
            if !self.coordinator.recoverable.isEmpty || self.coordinator.recoveryFailed {
                Button("Import saved app keys") { self.coordinator.importSavedAppKeys() }
            }
        }
        if self.coordinator.reloadFailed {
            Text("Could not read the credential file. Last confirmed keys and unsaved edits are unchanged.")
                .font(.caption).foregroundStyle(.orange)
        }
        if self.coordinator.recoveryFailed {
            Text("Import failed. Saved app preferences were kept. You can retry Import saved app keys.")
                .font(.caption).foregroundStyle(.orange)
        }
        if self.coordinator.recoveryDurabilityWarning {
            Text(
                "Imported, but disk durability could not be confirmed. Reload to check; do not repeat import.")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

struct APIKeyField: View {
    let credential: PeekabooCredential
    let coordinator: ProviderCredentialCoordinator
    let environment: [String: String]

    private var provider: ProviderInfo {
        switch self.credential {
        case .openAI: .openai
        case .anthropic: .anthropic
        case .grok: .grok
        case .google: .google
        case .miniMax: .minimax
        case .miniMaxChina: .minimaxChina
        }
    }

    var body: some View {
        let state = self.coordinator.state(for: self.credential)
        VStack(alignment: .leading, spacing: 4) {
            SecureField(
                self.provider.displayName,
                text: Binding(
                    get: { self.coordinator.state(for: self.credential).draft },
                    set: { self.coordinator.edit($0, for: self.credential) }),
                prompt: Text(self.provider.requiresAPIKey ? "Required" : "Optional"))
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier(self.credential.rawValue)
            if let failure = state.failure {
                Text(failure == .clear
                    ? "Clear failed — saved credential was not removed."
                    : "Not saved — last confirmed credential is unchanged.")
                    .foregroundStyle(.orange)
                Button("Retry") { self.coordinator.retry(self.credential) }
                    .accessibilityIdentifier("retry.\(self.credential.rawValue)")
            } else {
                if self.coordinator.reloadFailed {
                    Text("Credential file unavailable; reload to check.")
                        .foregroundStyle(.orange)
                } else if state.durabilityWarning {
                    Text("Saved, but disk durability could not be confirmed. Reload to check.")
                        .foregroundStyle(.orange)
                } else {
                    Text(state.confirmed.isEmpty ? "No saved key" : "Saved in credential file")
                        .foregroundStyle(.secondary)
                }
                if let variable = self.provider.environmentVariables
                    .first(where: { self.environment[$0]?.isEmpty == false })
                {
                    Text("Using \(variable) from the environment")
                        .foregroundStyle(.secondary)
                } else if self.credential == .miniMaxChina, self.environment["MINIMAX_API_KEY"]?.isEmpty == false {
                    Text("International MiniMax environment key is available as a fallback.")
                        .foregroundStyle(.secondary)
                } else if self.credential == .miniMaxChina, state.confirmed.isEmpty {
                    Text("Falls back to the international MiniMax key when available.")
                        .foregroundStyle(.secondary)
                }
            }
            if !state.confirmed.isEmpty {
                Button("Clear saved key") { self.coordinator.edit("", for: self.credential) }
                    .disabled(state.failure != nil)
                    .accessibilityIdentifier("clear.\(self.credential.rawValue)")
            }
        }
        .font(.caption)
        .buttonStyle(.link)
    }
}
