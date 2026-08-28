import PeekabooCore
import SwiftUI

struct ProvidersSettingsView: View {
    @Environment(PeekabooSettings.self) private var settings

    var body: some View {
        @Bindable var settings = self.settings
        Form {
            Section("API Keys") {
                ProviderCredentialRows(coordinator: settings.credentialCoordinator)
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
        .onAppear { self.settings.credentialCoordinator.reload() }
    }
}
