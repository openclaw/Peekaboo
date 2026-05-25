import AppKit
import Observation
import PeekabooCore
import SwiftUI

struct SettingsWindow: View {
    let updater: any UpdaterProviding

    @Environment(PeekabooSettings.self) private var settings
    @Environment(Permissions.self) private var permissions
    @State private var selectedTab: PeekabooSettingsTab = .general
    @State private var monitoringPermissions = false

    init(updater: any UpdaterProviding = DisabledUpdaterController()) {
        self.updater = updater
    }

    var body: some View {
        TabView(selection: self.$selectedTab) {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(PeekabooSettingsTab.general)

            if self.settings.agentModeEnabled {
                AISettingsView()
                    .tabItem {
                        Label("AI", systemImage: "brain")
                    }
                    .tag(PeekabooSettingsTab.ai)
            }

            VisualizerSettingsTabView()
                .tabItem {
                    Label("Visualizer", systemImage: "sparkles")
                }
                .tag(PeekabooSettingsTab.visualizer)

            ShortcutSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }
                .tag(PeekabooSettingsTab.shortcuts)

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .tag(PeekabooSettingsTab.permissions)

            AboutSettingsView(updater: self.updater)
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(PeekabooSettingsTab.about)
        }
        .frame(width: 600, height: 720)
        .onReceive(NotificationCenter.default.publisher(for: .peekabooSelectSettingsTab)) { note in
            if let tab = note.object as? PeekabooSettingsTab {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    self.selectedTab = self.sanitizedTabSelection(tab)
                }
            }
        }
        .onAppear {
            if let pending = SettingsTabRouter.consumePending() {
                self.selectedTab = self.sanitizedTabSelection(pending)
            }
            if !self.settings.agentModeEnabled, self.selectedTab == .ai {
                self.selectedTab = .general
            }
            self.updatePermissionMonitoring(for: self.selectedTab)
        }
        .onChange(of: self.selectedTab) { _, newValue in
            self.updatePermissionMonitoring(for: newValue)
        }
        .onChange(of: self.settings.agentModeEnabled) { _, enabled in
            if !enabled, self.selectedTab == .ai {
                self.selectedTab = .general
            }
        }
        .onDisappear {
            self.stopPermissionMonitoring()
        }
    }

    private func sanitizedTabSelection(_ tab: PeekabooSettingsTab) -> PeekabooSettingsTab {
        if tab == .ai, !self.settings.agentModeEnabled {
            return .general
        }
        return tab
    }

    private func updatePermissionMonitoring(for tab: PeekabooSettingsTab) {
        let shouldMonitor = tab == .permissions
        if shouldMonitor, !self.monitoringPermissions {
            self.monitoringPermissions = true
            self.permissions.registerMonitoring()
        } else if !shouldMonitor, self.monitoringPermissions {
            self.monitoringPermissions = false
            self.permissions.unregisterMonitoring()
        }
    }

    private func stopPermissionMonitoring() {
        guard self.monitoringPermissions else { return }
        self.monitoringPermissions = false
        self.permissions.unregisterMonitoring()
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @Environment(PeekabooSettings.self) private var settings

    var body: some View {
        Form {
            Section {
                SettingsIntroRow()
            }

            Section("App") {
                SettingsToggleRow(
                    title: "Launch at login",
                    subtitle: "Start Peekaboo automatically when you sign in.",
                    systemImage: "power",
                    isOn: self.binding(\.launchAtLogin))
                SettingsToggleRow(
                    title: "Show in Dock",
                    subtitle: "Keep a Dock icon and normal app switching behavior.",
                    systemImage: "dock.rectangle",
                    isOn: self.binding(\.showInDock))
                SettingsToggleRow(
                    title: "Keep window on top",
                    subtitle: "Pin the main session window above other apps.",
                    systemImage: "macwindow.on.rectangle",
                    isOn: self.binding(\.alwaysOnTop))
            }

            Section("Interaction") {
                SettingsToggleRow(
                    title: "Agent mode",
                    subtitle: "Enable chat sessions and automation from the app.",
                    systemImage: "sparkles",
                    isOn: self.binding(\.agentModeEnabled))
                SettingsToggleRow(
                    title: "Haptic feedback",
                    subtitle: "Use subtle feedback for supported controls.",
                    systemImage: "waveform.path",
                    isOn: self.binding(\.hapticFeedbackEnabled))
                SettingsToggleRow(
                    title: "Sound effects",
                    subtitle: "Play quiet confirmations for app actions.",
                    systemImage: "speaker.wave.2",
                    isOn: self.binding(\.soundEffectsEnabled))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func binding(_ keyPath: ReferenceWritableKeyPath<PeekabooSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0 })
    }
}

private struct SettingsIntroRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image("MenuIcon")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12)))

            VStack(alignment: .leading, spacing: 4) {
                Text("Peekaboo")
                    .font(.headline)
                Text("Tune the menu bar app, automation session window, and feedback behavior.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: self.systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(self.title)
                Text(self.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle(self.title, isOn: self.$isOn)
                .labelsHidden()
        }
        .padding(.vertical, 3)
    }
}

// MARK: - AI Settings

struct AISettingsView: View {
    @Environment(PeekabooSettings.self) private var settings
    @State private var detectedOllamaModelOptions: [(id: String, name: String)] = []
    @State private var hasAttemptedOllamaDetection = false

    private var allModels: [(provider: String, models: [(id: String, name: String)])] {
        var models: [(provider: String, models: [(id: String, name: String)])] = [
            ("openai", [
                ("gpt-5.5", "GPT-5.5"),
                ("gpt-5.4", "GPT-5.4"),
                ("gpt-5.4-mini", "GPT-5.4 mini"),
                ("gpt-5.4-nano", "GPT-5.4 nano"),
                ("gpt-5", "GPT-5"),
                ("gpt-5-mini", "GPT-5 mini"),
            ]),
            ("anthropic", [
                ("claude-opus-4-7", "Claude Opus 4.7"),
                ("claude-sonnet-4-5-20250929", "Claude Sonnet 4.5"),
                ("claude-haiku-4.5", "Claude Haiku 4.5"),
            ]),
            ("grok", [
                ("grok-4.3", "Grok 4.3"),
            ]),
            ("google", [
                ("gemini-3.1-pro-preview", "Gemini 3.1 Pro Preview"),
                ("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite"),
                ("gemini-3-flash", "Gemini 3 Flash"),
            ]),
            ("minimax", [
                ("MiniMax-M2.7", "MiniMax M2.7"),
                ("MiniMax-M2.7-highspeed", "MiniMax M2.7 Highspeed"),
            ]),
            ("minimax-cn", [
                ("MiniMax-M2.7", "MiniMax China M2.7"),
                ("MiniMax-M2.7-highspeed", "MiniMax China M2.7 Highspeed"),
            ]),
            ("ollama", self.ollamaModelOptions),
            ("lmstudio", [
                ("openai/gpt-oss-120b", "GPT-OSS 120B"),
                ("openai/gpt-oss-20b", "GPT-OSS 20B"),
            ]),
        ]

        // Add custom providers
        for (id, provider) in self.settings.customProviders.sorted(by: { $0.key < $1.key }) {
            let providerModels = provider.models?.map { (id: $0.key, name: $0.value.name) } ?? [
                (id: "custom-model", name: "Default Model"),
            ]
            models.append((id, providerModels))
        }

        return models
    }

    private var modelDescriptions: [String: String] {
        [
            // OpenAI models
            "gpt-5.5": "Flagship GPT-5.5 model with 400K context and upgraded tool " +
                "usage + reasoning.",
            "gpt-5.4": "GPT-5.4 model with 400K context and upgraded tool " +
                "usage + reasoning.",
            "gpt-5.4-mini": "Cost-optimized GPT-5.4 Mini with identical tools + 400K context " +
                "at a friendlier price.",
            "gpt-5.4-nano": "Ultra-low latency GPT-5.4 Nano tuned for snappy agent runs and " +
                "tool calling.",
            "gpt-5": "Flagship GPT-5 model with 400K context and best-in-class " +
                "coding + automation skills.",
            "gpt-5-mini": "Cost-optimized GPT-5 Mini with the same tools + 400K context " +
                "at a friendlier price.",
            // Anthropic models
            "claude-opus-4-7": "Claude Opus 4.7 with 1M context for long-running " +
                "automation and computer-use tasks.",
            "claude-sonnet-4-5-20250929": "Claude Sonnet 4.5 with new tools + computer use, " +
                "tuned for long-running automation tasks.",
            "claude-haiku-4.5": "Claude Haiku 4.5 for ultra-low latency assistant tasks with " +
                "the updated reasoning stack.",
            "grok-4.3": "xAI's latest Grok model for reasoning-heavy automation tasks.",
            "gemini-3.1-pro-preview": "Google Gemini 3.1 Pro Preview for multimodal agent runs.",
            "gemini-3.1-flash-lite": "Google Gemini 3.1 Flash Lite for low-latency agent runs.",
            "gemini-3-flash": "Google Gemini Flash tuned for fast, lower-latency multimodal agent runs.",
            "MiniMax-M2.7": "MiniMax M2.7 using the Anthropic-compatible API.",
            "MiniMax-M2.7-highspeed": "MiniMax M2.7 Highspeed using the Anthropic-compatible API.",
            "minimax-cn/MiniMax-M2.7": "MiniMax China M2.7 using the Anthropic-compatible API.",
            "minimax-cn/MiniMax-M2.7-highspeed": "MiniMax China M2.7 Highspeed using the " +
                "Anthropic-compatible API.",
            "openai/gpt-oss-120b": "Local GPT-OSS 120B through LM Studio.",
            "openai/gpt-oss-20b": "Local GPT-OSS 20B through LM Studio.",
            // Ollama models
            "llava:latest": "Open-source multimodal model that runs locally. Good for " +
                "privacy-conscious users and offline usage.",
            "llama3.2-vision:latest": "Meta's latest vision-capable model with strong " +
                "performance on visual understanding tasks.",
        ]
    }

    private func provider(for modelId: String) -> String? {
        for (provider, models) in self.allModels
            where models.contains(where: { $0.id == modelId })
        {
            return provider
        }
        return nil
    }

    private func modelTag(provider: String, modelId: String) -> String {
        "\(provider)/\(modelId)"
    }

    private func providerAndModel(from tag: String) -> (provider: String, model: String)? {
        let parts = tag.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (provider: parts[0], model: parts[1])
    }

    private func selectedModelTag() -> String {
        self.modelTag(provider: self.settings.selectedProvider, modelId: self.settings.selectedModel)
    }

    private func modelDescription(provider: String, modelId: String) -> String? {
        self.modelDescriptions[self.modelTag(provider: provider, modelId: modelId)] ?? self.modelDescriptions[modelId]
    }

    var body: some View {
        Form {
            // Model Selection
            Section("Model Selection") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Model")
                            .frame(width: 80, alignment: .trailing)

                        Picker("", selection: Binding(
                            get: { self.selectedModelTag() },
                            set: { newTag in
                                if let selection = self.providerAndModel(from: newTag) {
                                    self.settings.selectedModel = selection.model
                                    self.settings.selectedProvider = selection.provider
                                } else {
                                    self.settings.selectedModel = newTag
                                    // Update provider based on model selection
                                    if let provider = self.provider(for: newTag) {
                                        self.settings.selectedProvider = provider
                                    }
                                }
                            })) {
                                ForEach(self.allModels, id: \.provider) { provider, models in
                                    Section(header: Text(provider.capitalized)) {
                                        ForEach(models, id: \.id) { model in
                                            Text(model.name).tag(self.modelTag(provider: provider, modelId: model.id))
                                        }
                                    }
                                }
                            }
                            .pickerStyle(.menu)
                                .frame(width: 200)
                    }

                    // Model description
                    if let description = modelDescription(
                        provider: settings.selectedProvider,
                        modelId: settings.selectedModel)
                    {
                        HStack {
                            Spacer()
                                .frame(width: 88)

                            Text(description)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 300, alignment: .leading)
                        }
                    }
                }
            }

            // Provider-specific configuration
            Section("OpenAI Configuration") {
                APIKeyField(
                    provider: .openai,
                    apiKey: Binding(
                        get: { self.settings.openAIAPIKey },
                        set: { self.settings.openAIAPIKey = $0 }))
            }

            Section("Anthropic Configuration") {
                APIKeyField(
                    provider: .anthropic,
                    apiKey: Binding(
                        get: { self.settings.anthropicAPIKey },
                        set: { self.settings.anthropicAPIKey = $0 }))
            }

            Section("Grok Configuration") {
                APIKeyField(
                    provider: .grok,
                    apiKey: Binding(
                        get: { self.settings.grokAPIKey },
                        set: { self.settings.grokAPIKey = $0 }))
            }

            Section("Gemini Configuration") {
                APIKeyField(
                    provider: .google,
                    apiKey: Binding(
                        get: { self.settings.googleAPIKey },
                        set: { self.settings.googleAPIKey = $0 }))
            }

            Section("MiniMax Configuration") {
                APIKeyField(
                    provider: .minimax,
                    apiKey: Binding(
                        get: { self.settings.miniMaxAPIKey },
                        set: { self.settings.miniMaxAPIKey = $0 }))
            }

            Section("MiniMax China Configuration") {
                APIKeyField(
                    provider: .minimaxChina,
                    apiKey: Binding(
                        get: { self.settings.miniMaxChinaAPIKey },
                        set: { self.settings.miniMaxChinaAPIKey = $0 }))
            }

            Section("Ollama Configuration") {
                // Base URL
                HStack {
                    Text("Base URL")
                        .frame(width: 80, alignment: .trailing)

                    TextField("http://localhost:11434", text: Binding(
                        get: { self.settings.ollamaBaseURL },
                        set: { self.settings.ollamaBaseURL = $0 }))
                        .textFieldStyle(.roundedBorder)
                }

                // Connection status
                HStack {
                    Spacer()
                    Text("Ensure Ollama is running locally")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            Section("Parameters") {
                // Temperature
                HStack {
                    Text("Temperature")
                        .frame(width: 80, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { self.settings.temperature },
                            set: { self.settings.temperature = $0 }),
                        in: 0...1,
                        step: 0.1)

                    Text(String(format: "%.1f", self.settings.temperature))
                        .monospacedDigit()
                        .frame(width: 30)
                }

                // Max tokens
                HStack {
                    Text("Max Tokens")
                        .frame(width: 80, alignment: .trailing)

                    TextField(
                        "",
                        value: Binding(
                            get: { self.settings.maxTokens },
                            set: { self.settings.maxTokens = $0 }),
                        format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)

                    Text("(1 - 128,000)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Vision Model Override
            Section("Vision Model Override") {
                Toggle(isOn: Binding(
                    get: { self.settings.useCustomVisionModel },
                    set: { self.settings.useCustomVisionModel = $0 }))
                {
                    Text("Use custom model for vision tasks")
                }

                if self.settings.useCustomVisionModel {
                    HStack {
                        Text("Vision Model")
                            .frame(width: 80, alignment: .trailing)

                        Picker("", selection: Binding(
                            get: { self.settings.customVisionModel },
                            set: { self.settings.customVisionModel = $0 }))
                        {
                            ForEach(self.allModels, id: \.provider) { provider, models in
                                Section(header: Text(provider.capitalized)) {
                                    ForEach(models, id: \.id) { model in
                                        Text(model.name).tag(model.id)
                                    }
                                }
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)
                    }

                    Text(
                        "When enabled, this model will be used for all vision-related tasks " +
                            "like screenshots and image analysis, regardless of the primary " +
                            "model selection.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.leading, 88)
                }
            }

            // Custom Providers
            Section("Custom Providers") {
                CustomProviderView()
            }

            // API usage info
        }
        .formStyle(.grouped)
        .padding()
        .task(id: self.settings.ollamaBaseURL) {
            await self.refreshOllamaModels()
        }
    }

    private var ollamaModelOptions: [(id: String, name: String)] {
        if !self.detectedOllamaModelOptions.isEmpty {
            return self.detectedOllamaModelOptions
        }
        return Self.defaultOllamaModels
    }

    private static let defaultOllamaModels: [(id: String, name: String)] = [
        ("llava:latest", "LLaVA"),
        ("llama3.2-vision:latest", "Llama 3.2 Vision"),
    ]

    @MainActor
    private func refreshOllamaModels() async {
        if self.hasAttemptedOllamaDetection {
            return
        }
        self.hasAttemptedOllamaDetection = true

        guard let url = URL(string: "\(self.settings.ollamaBaseURL)/api/tags") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return
            }

            let decoded = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
            let models = decoded.models.map { model in
                (id: model.name, name: model.displayName)
            }

            if !models.isEmpty {
                self.detectedOllamaModelOptions = models
            }
        } catch {
            // Silently ignore detection failures; defaults remain.
        }
    }
}

private struct OllamaTagsResponse: Decodable {
    struct OllamaModel: Decodable {
        struct Details: Decodable {
            let parameter_size: String?
        }

        let name: String
        let details: Details?

        var displayName: String {
            if let parameterSize = self.details?.parameter_size {
                return "\(self.name) (\(parameterSize))"
            }
            return self.name
        }
    }

    let models: [OllamaModel]
}

// MARK: - Visualizer Settings Tab Wrapper

struct VisualizerSettingsTabView: View {
    @Environment(PeekabooSettings.self) private var settings
    @Environment(VisualizerCoordinator.self) private var visualizerCoordinator

    var body: some View {
        VisualizerSettingsView(settings: self.settings)
            .environment(self.visualizerCoordinator)
    }
}

// MARK: - Shortcuts Settings (Wrapper)

// ShortcutsSettingsView is now in its own file
