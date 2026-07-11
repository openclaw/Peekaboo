import PeekabooCore
import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(PeekabooSettings.self) private var settings

    var body: some View {
        @Bindable var settings = self.settings
        Form {
            Section("API Keys") {
                APIKeyField(provider: .openai, apiKey: $settings.openAIAPIKey)
                APIKeyField(provider: .anthropic, apiKey: $settings.anthropicAPIKey)
                APIKeyField(provider: .grok, apiKey: $settings.grokAPIKey)
                APIKeyField(provider: .google, apiKey: $settings.googleAPIKey)
                APIKeyField(provider: .minimax, apiKey: $settings.miniMaxAPIKey)
                APIKeyField(provider: .minimaxChina, apiKey: $settings.miniMaxChinaAPIKey)
            }

            Section("Local Models") {
                TextField("Ollama base URL", text: $settings.ollamaBaseURL, prompt: Text("http://localhost:11434"))
                    .multilineTextAlignment(.trailing)
                Text("Models are detected automatically while Ollama is running locally.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // CustomProviderView renders its own "Custom Providers" header + Add button.
            Section {
                CustomProviderView()
            }
        }
        .formStyle(.grouped)
    }
}
