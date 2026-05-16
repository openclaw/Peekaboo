import PeekabooCore
import SwiftUI

/// Modern redesigned Add Custom Provider UI with card-based layout and better UX
struct AddCustomProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PeekabooSettings.self) private var settings

    @State private var currentStep: AddProviderStep = .selectType
    @State private var selectedTemplate: ProviderTemplate?

    // Form data
    @State private var providerId = ""
    @State private var name = ""
    @State private var description = ""
    @State private var type: Configuration.CustomProvider.ProviderType = .openai
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var headers = ""
    @State private var testResult: TestResult?
    @State private var isTestingConnection = false

    // UI state
    @State private var showingError = false
    @State private var errorMessage = ""
    @State private var isAdvancedMode = false

    enum AddProviderStep: CaseIterable {
        case selectType
        case configure
        case test

        var title: String {
            switch self {
            case .selectType: "Choose Provider Type"
            case .configure: "Configure Provider"
            case .test: "Test & Add"
            }
        }

        var subtitle: String {
            switch self {
            case .selectType: "Select from popular providers or create a custom one"
            case .configure: "Enter your provider details and API credentials"
            case .test: "Verify connection and add to your providers"
            }
        }
    }

    enum TestResult {
        case success(String)
        case failure(String)

        var isSuccess: Bool {
            if case .success = self { return true }
            return false
        }

        var message: String {
            switch self {
            case let .success(msg): msg
            case let .failure(msg): msg
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header with progress indicator
                self.headerView

                Divider()

                // Main content
                GeometryReader { _ in
                    ZStack {
                        ForEach(AddProviderStep.allCases, id: \.self) { step in
                            self.stepContent(for: step)
                                .opacity(self.currentStep == step ? 1 : 0)
                                .animation(.easeInOut, value: self.currentStep)
                        }
                    }
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        self.dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    self.navigationButton
                }
            }
        }
        .frame(width: 700, height: 600)
        .alert("Error", isPresented: self.$showingError) {
            Button("OK") {}
        } message: {
            Text(self.errorMessage)
        }
    }

    private var headerView: some View {
        VStack(spacing: 16) {
            // Progress indicator
            HStack(spacing: 12) {
                ForEach(Array(AddProviderStep.allCases.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 8) {
                        // Step circle
                        Circle()
                            .fill(self.stepColor(for: step))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Group {
                                    if step == self.currentStep {
                                        Text("\(index + 1)")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                    } else if AddProviderStep.allCases.firstIndex(of: step)! < AddProviderStep
                                        .allCases.firstIndex(of: self.currentStep)!
                                    {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundColor(.white)
                                    } else {
                                        Text("\(index + 1)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                })

                        // Connector line
                        if index < AddProviderStep.allCases.count - 1 {
                            Rectangle()
                                .fill(self.connectorColor(for: step))
                                .frame(width: 40, height: 2)
                        }
                    }
                }
            }
            .padding(.horizontal)

            // Step title and subtitle
            VStack(spacing: 4) {
                Text(self.currentStep.title)
                    .font(.title2.bold())

                Text(self.currentStep.subtitle)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 20)
        .background(.ultraThinMaterial)
    }

    private func stepColor(for step: AddProviderStep) -> Color {
        let currentIndex = AddProviderStep.allCases.firstIndex(of: self.currentStep) ?? 0
        let stepIndex = AddProviderStep.allCases.firstIndex(of: step) ?? 0

        if stepIndex <= currentIndex {
            return .accentColor
        } else {
            return Color(.controlBackgroundColor)
        }
    }

    private func connectorColor(for step: AddProviderStep) -> Color {
        let currentIndex = AddProviderStep.allCases.firstIndex(of: self.currentStep) ?? 0
        let stepIndex = AddProviderStep.allCases.firstIndex(of: step) ?? 0

        if stepIndex < currentIndex {
            return .accentColor
        } else {
            return Color(.separatorColor)
        }
    }

    private func stepContent(for step: AddProviderStep) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                switch step {
                case .selectType:
                    self.providerSelectionView
                case .configure:
                    self.configurationView
                case .test:
                    self.testView
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
        }
    }

    private var providerSelectionView: some View {
        ProviderSelectionStepView(
            selectedTemplate: self.$selectedTemplate,
            applyTemplate: self.applyTemplate)
    }

    private var configurationView: some View {
        ProviderConfigurationStepView(
            selectedTemplate: self.selectedTemplate,
            providerId: self.$providerId,
            name: self.$name,
            description: self.$description,
            type: self.$type,
            baseURL: self.$baseURL,
            apiKey: self.$apiKey,
            headers: self.$headers,
            isAdvancedMode: self.$isAdvancedMode)
    }

    private var testView: some View {
        ProviderTestStepView(
            selectedTemplate: self.selectedTemplate,
            name: self.name,
            baseURL: self.baseURL,
            type: self.type,
            testResult: self.testResult,
            isTestingConnection: self.isTestingConnection,
            testAction: self.testConnection)
    }

    private var navigationButton: some View {
        Button(self.navigationButtonTitle) {
            self.navigationAction()
        }
        .disabled(!self.canNavigate)
    }

    private var navigationButtonTitle: String {
        switch self.currentStep {
        case .selectType:
            self.selectedTemplate != nil ? "Next" : "Select Provider"
        case .configure:
            "Next"
        case .test:
            self.testResult?.isSuccess == true ? "Add Provider" : "Test First"
        }
    }

    private var canNavigate: Bool {
        switch self.currentStep {
        case .selectType:
            self.selectedTemplate != nil
        case .configure:
            self.isConfigurationValid
        case .test:
            self.testResult?.isSuccess == true
        }
    }

    private var isConfigurationValid: Bool {
        !self.providerId.isEmpty && !self.name.isEmpty && !self.baseURL.isEmpty && !self.apiKey.isEmpty
    }

    private func navigationAction() {
        switch self.currentStep {
        case .selectType:
            withAnimation {
                self.currentStep = .configure
            }
        case .configure:
            withAnimation {
                self.currentStep = .test
            }
        case .test:
            if self.testResult?.isSuccess == true {
                self.addProvider()
            }
        }
    }

    private func applyTemplate(_ template: ProviderTemplate) {
        self.name = template.name
        self.description = template.description
        self.type = template.type
        self.baseURL = template.baseURL
        self.providerId = template.suggestedId
    }

    func testConnection() {
        self.isTestingConnection = true
        self.testResult = nil

        Task {
            await MainActor.run {
                // Simulate test - in real implementation, this would call the actual API
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    self.isTestingConnection = false
                    // Simulate success for demo
                    self.testResult = .success("Connection successful! Provider is ready to use.")
                }
            }
        }
    }

    private func addProvider() {
        // Parse headers
        var headerDict: [String: String]?
        if !self.headers.isEmpty {
            headerDict = [:]
            let pairs = self.headers.split(separator: ",")
            for pair in pairs {
                let components = pair.split(separator: ":", maxSplits: 1)
                if components.count == 2 {
                    let key = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let value = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    headerDict?[key] = value
                }
            }
        }

        let options = Configuration.ProviderOptions(
            baseURL: self.baseURL,
            apiKey: self.apiKey,
            headers: headerDict)

        let provider = Configuration.CustomProvider(
            name: self.name,
            description: self.description.isEmpty ? nil : self.description,
            type: self.type,
            options: options,
            models: nil,
            enabled: true)

        do {
            try self.settings.addCustomProvider(provider, id: self.providerId)
            self.dismiss()
        } catch {
            self.errorMessage = error.localizedDescription
            self.showingError = true
        }
    }
}

// MARK: - Supporting Views

private struct ProviderSelectionStepView: View {
    @Binding var selectedTemplate: ProviderTemplate?
    let applyTemplate: (ProviderTemplate) -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Popular Providers")
                    .font(.headline)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 2), spacing: 16) {
                    ForEach(ProviderTemplate.popular, id: \.id) { template in
                        ProviderTemplateCard(
                            template: template,
                            isSelected: self.selectedTemplate?.id == template.id)
                        {
                            self.selectedTemplate = template
                            self.applyTemplate(template)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 16) {
                Text("Custom Provider")
                    .font(.headline)

                ProviderTemplateCard(
                    template: ProviderTemplate.custom,
                    isSelected: self.selectedTemplate?.id == ProviderTemplate.custom.id)
                {
                    let template = ProviderTemplate.custom
                    self.selectedTemplate = template
                    self.applyTemplate(template)
                }
            }
        }
    }
}

private struct ProviderConfigurationStepView: View {
    let selectedTemplate: ProviderTemplate?
    @Binding var providerId: String
    @Binding var name: String
    @Binding var description: String
    @Binding var type: Configuration.CustomProvider.ProviderType
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var headers: String
    @Binding var isAdvancedMode: Bool

    var body: some View {
        VStack(spacing: 24) {
            if let template = self.selectedTemplate {
                ProviderPreviewCard(template: template, name: self.name.isEmpty ? template.name : self.name)
            }

            VStack(spacing: 20) {
                SectionCard(title: "Basic Information", icon: "info.circle") {
                    VStack(spacing: 16) {
                        FormField(title: "Provider ID", binding: self.$providerId, placeholder: "my-custom-provider") {
                            Text("Unique identifier for this provider")
                                .foregroundColor(.secondary)
                        }

                        FormField(title: "Display Name", binding: self.$name, placeholder: "My Custom Provider") {
                            Text("Friendly name shown in the UI")
                                .foregroundColor(.secondary)
                        }

                        FormField(
                            title: "Description",
                            binding: self.$description,
                            placeholder: "Optional description")
                        {
                            Text("Brief description of this provider")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                SectionCard(title: "Connection", icon: "network") {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Provider Type")
                                .font(.headline)

                            Picker("Type", selection: self.$type) {
                                ForEach(
                                    Configuration.CustomProvider.ProviderType.allCases,
                                    id: \.self)
                                { providerType in
                                    Label(providerType.displayName, systemImage: providerType.icon)
                                        .tag(providerType)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        FormField(
                            title: "Base URL",
                            binding: self.$baseURL,
                            placeholder: "https://api.provider.com/v1")
                        {
                            Text("API endpoint URL for this provider")
                                .foregroundColor(.secondary)
                        }

                        SecureFormField(
                            title: "API Key",
                            binding: self.$apiKey,
                            placeholder: "sk-... or ${API_KEY}")
                        {
                            Text("Your API key or environment variable reference (use ${VAR})")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                DisclosureGroup("Advanced Settings", isExpanded: self.$isAdvancedMode) {
                    VStack(spacing: 16) {
                        FormField(
                            title: "Custom Headers",
                            binding: self.$headers,
                            placeholder: "Authorization:Bearer token,X-Custom:value")
                        {
                            Text("Additional headers in key:value,key:value format")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 16)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color(.controlBackgroundColor))
                .cornerRadius(12)
            }
        }
    }
}

private struct ProviderTestStepView: View {
    let selectedTemplate: ProviderTemplate?
    let name: String
    let baseURL: String
    let type: Configuration.CustomProvider.ProviderType
    let testResult: AddCustomProviderView.TestResult?
    let isTestingConnection: Bool
    let testAction: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            if let template = self.selectedTemplate {
                ProviderSummaryCard(
                    template: template,
                    name: self.name,
                    baseURL: self.baseURL,
                    type: self.type)
            }

            VStack(spacing: 20) {
                Text("Test Connection")
                    .font(.title2.bold())

                if let result = self.testResult {
                    TestResultCard(result: result)
                } else if self.isTestingConnection {
                    TestingCard()
                } else {
                    Button(action: self.testAction) {
                        Label("Test Connection", systemImage: "bolt.fill")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(.blue)
                            .cornerRadius(12)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
    }
}

struct ProviderTemplateCard: View {
    let template: ProviderTemplate
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: self.onTap) {
            VStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(self.template.color.opacity(0.1))
                        .frame(width: 50, height: 50)

                    Image(systemName: self.template.icon)
                        .font(.title2)
                        .foregroundColor(self.template.color)
                }

                // Content
                VStack(spacing: 4) {
                    Text(self.template.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)

                    Text(self.template.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(self.isSelected ? Color.accentColor.opacity(0.1) : Color(.controlBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(self.isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

struct ProviderPreviewCard: View {
    let template: ProviderTemplate
    let name: String

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(self.template.color.opacity(0.1))
                    .frame(width: 40, height: 40)

                Image(systemName: self.template.icon)
                    .font(.title3)
                    .foregroundColor(self.template.color)
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(self.name)
                    .font(.headline)

                Text(self.template.type.displayName)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(self.template.color.opacity(0.2))
                    .cornerRadius(4)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section header
            HStack {
                Image(systemName: self.icon)
                    .foregroundColor(.accentColor)
                Text(self.title)
                    .font(.headline)
            }

            self.content
        }
        .padding(20)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct FormField<Help: View>: View {
    let title: String
    @Binding var binding: String
    let placeholder: String
    @ViewBuilder let help: Help

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.title)
                .font(.headline)

            TextField(self.placeholder, text: self.$binding)
                .textFieldStyle(.roundedBorder)

            self.help
        }
    }
}

struct SecureFormField<Help: View>: View {
    let title: String
    @Binding var binding: String
    let placeholder: String
    @ViewBuilder let help: Help

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(self.title)
                .font(.headline)

            SecureField(self.placeholder, text: self.$binding)
                .textFieldStyle(.roundedBorder)

            self.help
        }
    }
}

struct ProviderSummaryCard: View {
    let template: ProviderTemplate
    let name: String
    let baseURL: String
    let type: Configuration.CustomProvider.ProviderType

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(self.template.color.opacity(0.1))
                        .frame(width: 50, height: 50)

                    Image(systemName: self.template.icon)
                        .font(.title2)
                        .foregroundColor(self.template.color)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(self.name)
                        .font(.title2.bold())

                    Text(self.type.displayName)
                        .font(.callout)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(self.template.color.opacity(0.2))
                        .cornerRadius(4)
                }

                Spacer()
            }

            // Details
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "link")
                        .foregroundColor(.secondary)
                        .frame(width: 20)
                    Text(self.baseURL)
                        .font(.callout)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Image(systemName: "checkmark.shield")
                        .foregroundColor(.green)
                        .frame(width: 20)
                    Text("API key configured")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .background(Color(.controlBackgroundColor))
        .cornerRadius(12)
    }
}

struct TestResultCard: View {
    let result: AddCustomProviderView.TestResult

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: self.result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.title2)
                .foregroundColor(self.result.isSuccess ? .green : .red)

            VStack(alignment: .leading, spacing: 4) {
                Text(self.result.isSuccess ? "Connection Successful" : "Connection Failed")
                    .font(.headline)
                    .foregroundColor(self.result.isSuccess ? .green : .red)

                Text(self.result.message)
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(self.result.isSuccess ? Color.green.opacity(0.1) : Color.red.opacity(0.1))
        .cornerRadius(12)
    }
}

struct TestingCard: View {
    var body: some View {
        HStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)

            VStack(alignment: .leading, spacing: 4) {
                Text("Testing Connection")
                    .font(.headline)

                Text("Verifying your provider configuration...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }
}

// MARK: - Provider Templates

struct ProviderTemplate: Identifiable {
    let id = UUID()
    let name: String
    let description: String
    let type: Configuration.CustomProvider.ProviderType
    let baseURL: String
    let suggestedId: String
    let icon: String
    let color: Color

    @MainActor
    static let popular: [ProviderTemplate] = [
        ProviderTemplate(
            name: "OpenRouter",
            description: "Access 300+ models from one API",
            type: .openai,
            baseURL: "https://openrouter.ai/api/v1",
            suggestedId: "openrouter",
            icon: "arrow.triangle.2.circlepath",
            color: .purple),
        ProviderTemplate(
            name: "Groq",
            description: "Ultra-fast inference for Llama models",
            type: .openai,
            baseURL: "https://api.groq.com/openai/v1",
            suggestedId: "groq",
            icon: "bolt.fill",
            color: .orange),
        ProviderTemplate(
            name: "Together AI",
            description: "Open-source model hosting",
            type: .openai,
            baseURL: "https://api.together.xyz/v1",
            suggestedId: "together",
            icon: "person.2.fill",
            color: .blue),
        ProviderTemplate(
            name: "Perplexity",
            description: "Search-powered AI models",
            type: .openai,
            baseURL: "https://api.perplexity.ai",
            suggestedId: "perplexity",
            icon: "magnifyingglass.circle.fill",
            color: .teal),
    ]

    @MainActor
    static let custom = ProviderTemplate(
        name: "Custom Provider",
        description: "Configure your own API endpoint",
        type: .openai,
        baseURL: "",
        suggestedId: "custom",
        icon: "gearshape.fill",
        color: .gray)
}

// MARK: - Extensions

extension Configuration.CustomProvider.ProviderType {
    var icon: String {
        switch self {
        case .openai: "brain.head.profile"
        case .anthropic: "person.crop.rectangle.stack"
        }
    }
}
