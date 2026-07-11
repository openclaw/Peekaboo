import AppKit
import KeyboardShortcuts
import Observation
import PeekabooCore
import SwiftUI

struct SettingsWindow: View {
    let updater: any UpdaterProviding

    @Environment(Permissions.self) private var permissions
    @State private var selectedTab: PeekabooSettingsTab = .general
    @State private var monitoringPermissions = false

    init(updater: any UpdaterProviding = DisabledUpdaterController()) {
        self.updater = updater
    }

    var body: some View {
        TabView(selection: self.$selectedTab) {
            GeneralSettingsView(updater: self.updater)
                .tabItem {
                    Label("General", systemImage: "gear")
                }
                .tag(PeekabooSettingsTab.general)

            AgentSettingsView()
                .tabItem {
                    Label("Agent", systemImage: "brain")
                }
                .tag(PeekabooSettingsTab.agent)

            ProvidersSettingsView()
                .tabItem {
                    Label("Providers", systemImage: "key.horizontal")
                }
                .tag(PeekabooSettingsTab.providers)

            VisualizerSettingsTabView()
                .tabItem {
                    Label("Visualizer", systemImage: "sparkles")
                }
                .tag(PeekabooSettingsTab.visualizer)

            PermissionsSettingsView()
                .tabItem {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .tag(PeekabooSettingsTab.permissions)

            AboutSettingsView()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(PeekabooSettingsTab.about)
        }
        .frame(width: 600, height: 720)
        .onReceive(NotificationCenter.default.publisher(for: .peekabooSelectSettingsTab)) { note in
            if let tab = note.object as? PeekabooSettingsTab {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    self.selectedTab = tab
                }
            }
        }
        .onAppear {
            if let pending = SettingsTabRouter.consumePending() {
                self.selectedTab = pending
            }
            self.updatePermissionMonitoring(for: self.selectedTab)
        }
        .onChange(of: self.selectedTab) { _, newValue in
            self.updatePermissionMonitoring(for: newValue)
        }
        .onDisappear {
            self.stopPermissionMonitoring()
        }
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
    let updater: any UpdaterProviding

    @Environment(PeekabooSettings.self) private var settings
    @AppStorage("autoUpdateEnabled") private var autoUpdateEnabled: Bool = true
    @State private var didLoadUpdaterState = false

    var body: some View {
        @Bindable var settings = self.settings
        Form {
            Section {
                SettingsIntroRow()
            }

            Section("Startup & Window") {
                SettingsToggleRow(
                    title: "Launch at login",
                    subtitle: "Start Peekaboo automatically when you sign in.",
                    systemImage: "power",
                    isOn: $settings.launchAtLogin)
                DockVisibilityPickerRow(showInDock: $settings.showInDock)
                SettingsToggleRow(
                    title: "Keep main window on top",
                    subtitle: "Pin the main session window above other apps.",
                    systemImage: "macwindow.on.rectangle",
                    isOn: $settings.alwaysOnTop)
            }

            Section("Feedback") {
                SettingsToggleRow(
                    title: "Haptic feedback",
                    subtitle: "Use subtle feedback for supported controls.",
                    systemImage: "waveform.path",
                    isOn: $settings.hapticFeedbackEnabled)
                SettingsToggleRow(
                    title: "Interface sounds",
                    subtitle: "Play quiet confirmations for app actions.",
                    systemImage: "speaker.wave.2",
                    isOn: $settings.soundEffectsEnabled)
            }

            Section("Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle popover", name: .togglePopover)
                KeyboardShortcuts.Recorder("Show main window", name: .showMainWindow)
                KeyboardShortcuts.Recorder("Show Inspector", name: .showInspector)

                Text("Shortcuts must include at least one modifier key (⌘, ⌥, ⌃, or ⇧) and take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Updates") {
                if self.updater.isAvailable {
                    SettingsToggleRow(
                        title: "Check for updates automatically",
                        subtitle: "Look for new Peekaboo versions in the background.",
                        systemImage: "arrow.triangle.2.circlepath",
                        isOn: self.$autoUpdateEnabled)
                    Button("Check for Updates…") { self.updater.checkForUpdates(nil) }
                } else {
                    Text("Updates unavailable in this build.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard !self.didLoadUpdaterState else { return }
            self.updater.automaticallyChecksForUpdates = self.autoUpdateEnabled
            self.didLoadUpdaterState = true
        }
        .onChange(of: self.autoUpdateEnabled) { _, newValue in
            self.updater.automaticallyChecksForUpdates = newValue
        }
    }
}

private struct DockVisibilityPickerRow: View {
    @Binding var showInDock: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "dock.rectangle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Show Peekaboo in")
                Text("Peekaboo always lives in the menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("Show Peekaboo in", selection: self.$showInDock) {
                Text("Menu bar only").tag(false)
                Text("Menu bar and Dock").tag(true)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.vertical, 3)
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

struct SettingsToggleRow: View {
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

// MARK: - Agent Settings

struct AgentSettingsView: View {
    @Environment(PeekabooSettings.self) private var settings
    @State private var detectedOllamaModelOptions: [(id: String, name: String)] = []
    @State private var hasAttemptedOllamaDetection = false

    static let builtinProviderCatalog: [(provider: String, models: [(id: String, name: String)])] = [
        ("openai", [
            ("gpt-5.6-sol", "GPT-5.6 Sol"),
            ("gpt-5.6-terra", "GPT-5.6 Terra"),
            ("gpt-5.6-luna", "GPT-5.6 Luna"),
            ("gpt-5.5", "GPT-5.5"),
            ("gpt-5.4", "GPT-5.4"),
            ("gpt-5.4-mini", "GPT-5.4 mini"),
            ("gpt-5.4-nano", "GPT-5.4 nano"),
            ("gpt-5", "GPT-5"),
            ("gpt-5-mini", "GPT-5 mini"),
        ]),
        ("anthropic", [
            ("claude-fable-5", "Claude Fable 5"),
            ("claude-sonnet-5", "Claude Sonnet 5"),
            ("claude-opus-4-8", "Claude Opus 4.8"),
            ("claude-opus-4-7", "Claude Opus 4.7"),
            ("claude-sonnet-4-6", "Claude Sonnet 4.6"),
            ("claude-sonnet-4-5-20250929", "Claude Sonnet 4.5"),
            ("claude-haiku-4.5", "Claude Haiku 4.5"),
        ]),
        ("grok", [
            ("grok-4.3", "Grok 4.3"),
            ("grok-4", "Grok 4"),
        ]),
        ("google", [
            ("gemini-3.5-flash", "Gemini 3.5 Flash"),
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
        ("ollama", AgentSettingsView.defaultOllamaModels),
        ("lmstudio", [
            ("openai/gpt-oss-120b", "GPT-OSS 120B"),
            ("openai/gpt-oss-20b", "GPT-OSS 20B"),
        ]),
    ]

    /// Pretty name for a model id from the builtin catalog, regardless of how the
    /// provider is currently classified (builtin vs custom-provider passthrough).
    static func builtinName(forModelId id: String) -> String? {
        for group in self.builtinProviderCatalog {
            if let model = group.models.first(where: { $0.id == id }) {
                return model.name
            }
        }
        return nil
    }

    private var allModels: [(provider: String, models: [(id: String, name: String)])] {
        var models = Self.builtinProviderCatalog
        if let ollamaIndex = models.firstIndex(where: { $0.provider == "ollama" }) {
            models[ollamaIndex] = ("ollama", self.ollamaModelOptions)
        }

        let enabledCustomProviders = self.settings.customProviders.filter(\.value.enabled)
        let customProviderIDs = Set(enabledCustomProviders.keys.map { $0.lowercased() })
        models.removeAll { customProviderIDs.contains($0.provider.lowercased()) }

        // Add custom providers
        for (id, provider) in enabledCustomProviders.sorted(by: { $0.key < $1.key }) {
            var providerModels = provider.models?.map { (id: $0.key, name: $0.value.name) } ?? []
            if providerModels.isEmpty,
               self.settings.selectedProvider.caseInsensitiveCompare(id) == .orderedSame,
               !self.settings.selectedModel.isEmpty
            {
                let fallbackName = Self.builtinName(forModelId: self.settings.selectedModel)
                providerModels = [(id: self.settings.selectedModel, name: fallbackName ?? self.settings.selectedModel)]
            }
            if !providerModels.isEmpty {
                models.append((id, providerModels))
            }
        }

        let resolved = Self.appendingSelectedOpenRouterModel(
            to: models,
            selectedProvider: self.settings.selectedProvider,
            selectedModel: self.settings.selectedModel,
            customProviderIDs: customProviderIDs)
        return Self.appendingCurrentSelectionIfMissing(
            to: resolved,
            selectedProvider: self.settings.selectedProvider,
            selectedModel: self.settings.selectedModel)
    }

    /// The configured provider/model pair can come from `~/.peekaboo/config.json` and
    /// may not be in the hardcoded catalog; append it so the picker never renders blank.
    static func appendingCurrentSelectionIfMissing(
        to models: [(provider: String, models: [(id: String, name: String)])],
        selectedProvider: String,
        selectedModel: String) -> [(provider: String, models: [(id: String, name: String)])]
    {
        guard !selectedProvider.isEmpty, !selectedModel.isEmpty,
              !models.contains(where: { group in
                  group.provider == selectedProvider && group.models.contains(where: { $0.id == selectedModel })
              })
        else {
            return models
        }

        var models = models
        let name = Self.builtinName(forModelId: selectedModel) ?? selectedModel
        models.append((selectedProvider, [(id: selectedModel, name: name)]))
        return models
    }

    static func appendingSelectedOpenRouterModel(
        to models: [(provider: String, models: [(id: String, name: String)])],
        selectedProvider: String,
        selectedModel: String,
        customProviderIDs: Set<String>) -> [(provider: String, models: [(id: String, name: String)])]
    {
        guard selectedProvider.caseInsensitiveCompare("openrouter") == .orderedSame,
              !selectedModel.isEmpty,
              !customProviderIDs.contains("openrouter"),
              !models.contains(where: { group in
                  group.provider == selectedProvider && group.models.contains(where: { $0.id == selectedModel })
              })
        else {
            return models
        }

        var models = models
        let name = Self.builtinName(forModelId: selectedModel) ?? selectedModel
        models.append((selectedProvider, [(id: selectedModel, name: name)]))
        return models
    }

    private var modelDescriptions: [String: String] {
        [
            // OpenAI models
            "gpt-5.6-sol": "GPT-5.6 Sol with 372K context and up to 128K output.",
            "gpt-5.6-terra": "GPT-5.6 Terra with 372K context and up to 128K output.",
            "gpt-5.6-luna": "GPT-5.6 Luna with 372K context and up to 128K output.",
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
            "claude-fable-5": "Claude Fable 5 with 1M context for demanding " +
                "reasoning and long-horizon agent tasks.",
            "claude-sonnet-5": "Claude Sonnet 5 with 1M context for fast, capable agent tasks.",
            "claude-opus-4-8": "Claude Opus 4.8 with 1M context for long-running " +
                "automation and computer-use tasks.",
            "claude-sonnet-4-6": "Claude Sonnet 4.6 with new tools + computer use, " +
                "tuned for long-running automation tasks.",
            "claude-haiku-4.5": "Claude Haiku 4.5 for ultra-low latency assistant tasks with " +
                "the updated reasoning stack.",
            "grok-4.3": "xAI's latest Grok model for reasoning-heavy automation tasks.",
            "gemini-3.5-flash": "Google Gemini 3.5 Flash for fast multimodal agent runs.",
            "gemini-3.1-pro-preview": "Google Gemini 3.1 Pro Preview for multimodal agent runs.",
            "gemini-3.1-flash-lite": "Google Gemini 3.1 Flash Lite for low-latency agent runs.",
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

    private var modelSelectionBinding: Binding<String> {
        Binding(
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
            })
    }

    private var selectedModelDisplayName: String {
        for (provider, models) in self.allModels where provider == self.settings.selectedProvider {
            if let model = models.first(where: { $0.id == self.settings.selectedModel }) {
                return model.name
            }
        }
        return self.modelDisplayName(forId: self.settings.selectedModel)
    }

    private func modelDisplayName(forId id: String) -> String {
        for (_, models) in self.allModels {
            if let model = models.first(where: { $0.id == id }) {
                return model.name
            }
        }
        return Self.builtinName(forModelId: id) ?? id
    }

    var body: some View {
        @Bindable var settings = self.settings
        Form {
            Section {
                SettingsToggleRow(
                    title: "Enable agent",
                    subtitle: "Allow chat sessions and automation from the app.",
                    systemImage: "sparkles",
                    isOn: $settings.agentModeEnabled)
            }

            Section("Model") {
                LabeledContent("Model") {
                    // Menu of plain buttons: a Menu wrapping a Picker is promoted to a
                    // pop-up button on macOS, which drops the custom label and renders
                    // the raw selection tag.
                    Menu {
                        ForEach(self.allModels, id: \.provider) { provider, models in
                            Section(provider.capitalized) {
                                ForEach(models, id: \.id) { model in
                                    let tag = self.modelTag(provider: provider, modelId: model.id)
                                    Button {
                                        self.modelSelectionBinding.wrappedValue = tag
                                    } label: {
                                        if tag == self.selectedModelTag() {
                                            Label(model.name, systemImage: "checkmark")
                                        } else {
                                            Text(model.name)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(self.selectedModelDisplayName)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                }

                if let description = modelDescription(
                    provider: settings.selectedProvider,
                    modelId: settings.selectedModel)
                {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Text("Temperature")
                    Spacer()
                    Slider(value: $settings.temperature, in: 0...1, step: 0.1)
                        .frame(width: 170)
                    Text(String(format: "%.1f", self.settings.temperature))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }

                TextField(
                    "Max tokens",
                    value: $settings.maxTokens,
                    format: .number.grouping(.never),
                    prompt: Text("16384"))
                    .multilineTextAlignment(.trailing)
            }
            .opacity(self.settings.agentModeEnabled ? 1 : 0.5)
            .disabled(!self.settings.agentModeEnabled)

            Section("Vision") {
                LabeledContent("Vision model") {
                    Menu {
                        Button {
                            self.settings.useCustomVisionModel = false
                        } label: {
                            if !self.settings.useCustomVisionModel {
                                Label("Same as agent model", systemImage: "checkmark")
                            } else {
                                Text("Same as agent model")
                            }
                        }

                        Divider()

                        ForEach(self.allModels, id: \.provider) { provider, models in
                            Section(provider.capitalized) {
                                ForEach(models, id: \.id) { model in
                                    Button {
                                        self.settings.useCustomVisionModel = true
                                        self.settings.customVisionModel = model.id
                                    } label: {
                                        if self.settings.useCustomVisionModel,
                                           model.id == self.settings.customVisionModel
                                        {
                                            Label(model.name, systemImage: "checkmark")
                                        } else {
                                            Text(model.name)
                                        }
                                    }
                                }
                            }
                        }
                    } label: {
                        if self.settings.useCustomVisionModel {
                            Text(self.modelDisplayName(forId: self.settings.customVisionModel))
                        } else {
                            Text("Same as agent model")
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.bordered)
                    .fixedSize()
                }

                if self.settings.useCustomVisionModel {
                    Text("Used for screenshots and image analysis, regardless of the primary model selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .opacity(self.settings.agentModeEnabled ? 1 : 0.5)
            .disabled(!self.settings.agentModeEnabled)
        }
        .formStyle(.grouped)
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
