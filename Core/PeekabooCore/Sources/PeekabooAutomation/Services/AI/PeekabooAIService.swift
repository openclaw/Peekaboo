import CoreGraphics
import Foundation
import ImageIO
import Tachikoma

public struct InferredAnthropicModelCapabilities: Sendable {
    public let contextLength: Int
    public let maxOutputTokens: Int
    public let supportsStreaming: Bool
}

public enum AnthropicModelCapabilityInference {
    public static func capabilities(for modelId: String) -> InferredAnthropicModelCapabilities? {
        guard let model = self.anthropicModel(for: modelId) else { return nil }
        return InferredAnthropicModelCapabilities(
            contextLength: model.contextLength,
            maxOutputTokens: model.maxOutputTokens,
            supportsStreaming: model.supportsStreaming)
    }

    public static func hasStreamingRefusalRisk(modelId: String) -> Bool {
        if let capabilities = self.capabilities(for: modelId) {
            return !capabilities.supportsStreaming
        }
        return LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: modelId)
    }

    private static func anthropicModel(for modelId: String) -> LanguageModel.Anthropic? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsedModel = ProviderParser.parse(trimmed)?.model
        let candidates = [trimmed, parsedModel].compactMap(\.self)
        for candidate in candidates {
            guard case let .anthropic(model) = LanguageModel.parse(from: "anthropic/\(candidate)") else {
                continue
            }
            if case .custom = model {
                continue
            }
            return model
        }
        return nil
    }
}

private final class PeekabooCustomProviderModel: ModelProvider, @unchecked Sendable {
    enum Kind {
        case openai
        case anthropic
    }

    let providerID: String
    let resolvedModelID: String
    let kind: Kind
    let modelId: String
    let baseURL: String?
    let apiKey: String?
    let additionalHeaders: [String: String]
    let capabilities: ModelCapabilities

    init(
        providerID: String,
        resolvedModelID: String,
        kind: Kind,
        baseURL: String,
        apiKey: String?,
        additionalHeaders: [String: String],
        supportsVision: Bool,
        supportsTools: Bool,
        maxOutputTokens: Int?)
    {
        self.providerID = providerID
        self.resolvedModelID = resolvedModelID
        self.kind = kind
        self.modelId = "\(providerID)/\(resolvedModelID)"
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.additionalHeaders = additionalHeaders
        let inferredAnthropicCapabilities = kind == .anthropic
            ? AnthropicModelCapabilityInference.capabilities(for: resolvedModelID)
            : nil
        let inferredMaxOutputTokens = inferredAnthropicCapabilities?.maxOutputTokens ?? 4096
        let hasStreamingRefusalRisk = inferredAnthropicCapabilities.map { !$0.supportsStreaming } ??
            LanguageModel.Anthropic.hasStreamingRefusalRisk(modelId: resolvedModelID)
        self.capabilities = ModelCapabilities(
            supportsVision: supportsVision,
            supportsTools: supportsTools,
            supportsStreaming: !hasStreamingRefusalRisk,
            contextLength: inferredAnthropicCapabilities?.contextLength ?? 128_000,
            maxOutputTokens: maxOutputTokens ?? inferredMaxOutputTokens)
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        switch self.kind {
        case .openai:
            try await self.openAICompatibleProvider().generateText(request: request)
        case .anthropic:
            try await self.anthropicCompatibleProvider().generateText(request: request)
        }
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        switch self.kind {
        case .openai:
            try await self.openAICompatibleProvider().streamText(request: request)
        case .anthropic:
            try await self.anthropicCompatibleProvider().streamText(request: request)
        }
    }

    private func compatibleConfiguration() -> TachikomaConfiguration {
        let configuration = TachikomaConfiguration(loadFromEnvironment: true)
        guard let apiKey, !apiKey.isEmpty else { return configuration }

        switch self.kind {
        case .openai:
            configuration.setAPIKey(apiKey, for: "openai_compatible")
        case .anthropic:
            configuration.setAPIKey(apiKey, for: "anthropic_compatible")
        }
        return configuration
    }

    private func openAICompatibleProvider() throws -> OpenAICompatibleProvider {
        guard let apiKey, !apiKey.isEmpty else {
            throw TachikomaError.authenticationFailed(
                "API key reference for custom provider '\(self.providerID)' could not be resolved")
        }

        return try OpenAICompatibleProvider(
            modelId: self.resolvedModelID,
            baseURL: self.baseURL ?? "",
            configuration: self.compatibleConfiguration(),
            additionalHeaders: self.additionalHeaders)
    }

    private func anthropicCompatibleProvider() throws -> AnthropicCompatibleProvider {
        guard let apiKey, !apiKey.isEmpty else {
            throw TachikomaError.authenticationFailed(
                "API key reference for custom provider '\(self.providerID)' could not be resolved")
        }

        return try AnthropicCompatibleProvider(
            modelId: self.resolvedModelID,
            baseURL: self.baseURL ?? "",
            configuration: self.compatibleConfiguration(),
            additionalHeaders: self.additionalHeaders,
            reasoningProvider: "custom-anthropic",
            reasoningModelId: self.modelId,
            reasoningBaseURL: self.baseURL)
    }
}

/// AI service for handling model interactions and AI-powered features
@MainActor
public final class PeekabooAIService {
    private let configuration: ConfigurationManager
    private let resolvedModels: [LanguageModel]
    private let defaultModel: LanguageModel
    private let defaultVisionModel: LanguageModel?

    /// Exposed for tests (internal)
    var resolvedDefaultModel: LanguageModel {
        self.defaultModel
    }

    /// Exposed for tests (internal)
    var resolvedDefaultVisionModel: LanguageModel? {
        self.defaultVisionModel
    }

    public init(configuration: ConfigurationManager = .shared) {
        self.configuration = configuration
        ConfigurationManager.configureTachikomaProfileDirectory()
        _ = configuration.loadConfiguration()
        configuration.applyAIProviderKeys()
        self.resolvedModels = Self.resolveAvailableModels(configuration: configuration)
        self.defaultModel = self.resolvedModels.first ?? .openai(.gpt55)
        self.defaultVisionModel = self.resolvedModels.first { $0.supportsVision }
    }

    public struct AnalysisResult: Sendable {
        public let provider: String
        public let model: String
        public let text: String
    }

    /// Analyze an image with a question using AI
    public func analyzeImage(imageData: Data, question: String, model: LanguageModel? = nil) async throws -> String {
        let result = try await self.analyzeImageDetailed(imageData: imageData, question: question, model: model)
        return result.text
    }

    /// Analyze an image with a question returning structured metadata
    public func analyzeImageDetailed(
        imageData: Data,
        question: String,
        model: LanguageModel? = nil) async throws -> AnalysisResult
    {
        let selectedModel = try self.resolveVisionModel(model)

        // Create a message with the image using Tachikoma's API
        let base64String = imageData.base64EncodedString()
        let imageContent = ModelMessage.ContentPart.ImageContent(data: base64String, mimeType: "image/png")
        let messages = [ModelMessage.user(text: question, images: [imageContent])]

        let response = try await Tachikoma.generateText(
            model: selectedModel,
            messages: messages,
            configuration: self.tachikomaConfiguration(for: selectedModel))

        let (provider, modelName) = Self.providerAndModelName(for: selectedModel)

        let normalizedText = Self.normalizeCoordinateTextIfNeeded(
            response.text,
            model: modelName,
            imageSize: Self.imageSize(from: imageData))

        return AnalysisResult(provider: provider, model: modelName, text: normalizedText)
    }

    /// Analyze an image file with a question
    public func analyzeImageFile(
        at path: String,
        question: String,
        model: LanguageModel? = nil) async throws -> String
    {
        // Load image data
        let url = Self.imageFileURL(for: path)
        let imageData = try Data(contentsOf: url)

        return try await self.analyzeImage(imageData: imageData, question: question, model: model)
    }

    /// Analyze an image file returning structured metadata
    public func analyzeImageFileDetailed(
        at path: String,
        question: String,
        model: LanguageModel? = nil) async throws -> AnalysisResult
    {
        // Analyze an image file returning structured metadata
        let url = Self.imageFileURL(for: path)
        let imageData = try Data(contentsOf: url)
        return try await self.analyzeImageDetailed(imageData: imageData, question: question, model: model)
    }

    static func imageFileURL(for path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Generate text from a prompt
    public func generateText(prompt: String, model: LanguageModel? = nil) async throws -> String {
        // Generate text from a prompt
        let selectedModel = model ?? self.defaultModel

        let messages = [
            ModelMessage.user(prompt),
        ]

        let response = try await Tachikoma.generateText(
            model: selectedModel,
            messages: messages,
            configuration: self.tachikomaConfiguration(for: selectedModel))

        return response.text
    }

    /// List available models
    public func availableModels() -> [LanguageModel] {
        self.resolvedModels
    }

    /// Resolve a user/config provider reference, including custom providers registered in Peekaboo config.
    public func resolveConfiguredModel(_ modelString: String) -> LanguageModel? {
        Self.parseProviderEntry(modelString, configuration: self.configuration)
    }

    /// Return true when an enabled custom provider owns this provider identifier.
    public func hasEnabledCustomProvider(matching providerID: String) -> Bool {
        guard let customProviderID = Self.customProviderID(
            matching: providerID,
            configuration: self.configuration)
        else {
            return false
        }
        return self.configuration.getCustomProvider(id: customProviderID)?.enabled == true
    }

    /// Return true when a model can be used with the current credentials or local runtime.
    public func isModelAvailable(_ model: LanguageModel) -> Bool {
        Self.hasCredentialsOrLocalRuntime(for: model, configuration: self.configuration)
    }

    private func resolveVisionModel(_ model: LanguageModel?) throws -> LanguageModel {
        if let model {
            guard model.supportsVision else {
                throw TachikomaError.unsupportedOperation("Model \(model.description) does not support vision")
            }
            return model
        }

        guard let defaultVisionModel else {
            throw TachikomaError.unsupportedOperation("No configured vision-capable AI model is available")
        }
        return defaultVisionModel
    }

    private static func parseProviderEntry(_ entry: String, configuration: ConfigurationManager) -> LanguageModel? {
        let components = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if components.count == 2,
           let customProviderID = self.customProviderID(matching: components[0], configuration: configuration),
           configuration.getCustomProvider(id: customProviderID)?.enabled == true
        {
            return self.customProviderModel(
                providerID: customProviderID,
                modelString: components[1],
                configuration: configuration).map { .custom(provider: $0) }
        }

        if let parsed = AIProviderParser.parse(entry) {
            let provider = parsed.provider.lowercased()
            let modelString = parsed.model

            let loose = LanguageModel.parse(from: modelString)

            if self.isHostedProviderIdentifier(provider) {
                return self.parseHostedProviderEntry(provider: provider, modelString: modelString, loose: loose)
            }
            if self.isLocalProviderIdentifier(provider) {
                return self.parseLocalProviderEntry(provider: provider, modelString: modelString)
            }
            return nil
        }

        // Back-compat: allow loose model strings without "provider/model"
        return LanguageModel.parse(from: entry)
    }

    private static func isHostedProviderIdentifier(_ provider: String) -> Bool {
        switch provider {
        case "openai", "anthropic", "google", "gemini", "minimax", "minimax-cn", "minimax_cn", "minimaxi",
             "kimi", "moonshot",
             "openrouter", "mistral", "groq", "grok", "xai":
            true
        default:
            false
        }
    }

    private static func isLocalProviderIdentifier(_ provider: String) -> Bool {
        switch provider {
        case "ollama", "lmstudio", "lm-studio":
            true
        default:
            false
        }
    }

    private static func parseHostedProviderEntry(
        provider: String,
        modelString: String,
        loose: LanguageModel?) -> LanguageModel?
    {
        switch provider {
        case "openai":
            if case .openai = loose { return loose }
            return .openai(.custom(modelString))
        case "anthropic":
            if case .anthropic = loose { return loose }
            return .anthropic(.custom(modelString))
        case "google", "gemini":
            if case .google = loose { return loose }
            return nil
        case "minimax":
            if case .minimax = loose { return loose }
            return nil
        case "minimax-cn", "minimax_cn", "minimaxi":
            if case .minimaxCN = loose { return loose }
            let parsed = LanguageModel.parse(from: "minimax-cn/\(modelString)")
            if case .minimaxCN = parsed { return parsed }
            return nil
        case "kimi", "moonshot":
            if case .kimi = loose { return loose }
            return nil
        case "openrouter":
            return .openRouter(modelId: modelString)
        case "mistral":
            if case .mistral = loose { return loose }
            return nil
        case "groq":
            if case .groq = loose { return loose }
            return nil
        case "grok", "xai":
            guard !self.isUnsupportedGrokModel(modelString) else { return nil }
            if case .grok = loose { return loose }
            return .grok(.custom(modelString))
        default:
            return nil
        }
    }

    private static func isUnsupportedGrokModel(_ modelString: String) -> Bool {
        let normalized = modelString.lowercased()
        let compact = normalized
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
        return normalized.contains("grok-4.20-multi-agent") ||
            normalized.contains("grok-4-20-multi-agent") ||
            compact.contains("grok420multiagent")
    }

    private static func parseLocalProviderEntry(provider: String, modelString: String) -> LanguageModel? {
        switch provider {
        case "ollama":
            // For Ollama, prefer preserving the exact model id string.
            // Heuristics for custom model capabilities live in Tachikoma (LanguageModel.Ollama).
            .ollama(.custom(modelString))
        case "lmstudio", "lm-studio":
            .lmstudio(.custom(modelString))
        default:
            nil
        }
    }

    private static func resolveAvailableModels(configuration: ConfigurationManager) -> [LanguageModel] {
        let providers = configuration.getAIProviders()
        let parsed = providers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { self.parseProviderEntry($0, configuration: configuration) }

        if self.hasExplicitProviderList(configuration: configuration) {
            return parsed
        }

        if !parsed.isEmpty {
            let available = parsed.filter { self.hasCredentialsOrLocalRuntime(for: $0, configuration: configuration) }
            if !available.isEmpty {
                return self.appendingGeneratedVisionFallbacks(from: parsed, to: available)
            }
            if parsed.contains(where: { model in
                if case .custom = model {
                    return true
                }
                return false
            }) {
                return parsed
            }
        }

        // Fallback: prefer Anthropic if any auth (API key or OAuth) is present
        if configuration.hasAnthropicAuth() {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: [.anthropic(.opus48)])
        }
        if let key = configuration.getGeminiAPIKey(), !key.isEmpty {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: [.google(.gemini35Flash)])
        }
        if let key = configuration.getGrokAPIKey(), !key.isEmpty {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: [.grok(.grok43)])
        }
        if let key = configuration.getMiniMaxChinaAPIKey(fallbackToSharedKey: false), !key.isEmpty {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: [.minimaxCN(.m27)])
        }
        if let key = configuration.getMiniMaxAPIKey(), !key.isEmpty {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: [.minimax(.m27)])
        }
        if let key = configuration.getKimiAPIKey(), !key.isEmpty {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: [.kimi(.k26)])
        }
        if let key = configuration.getOpenRouterAPIKey(), !key.isEmpty {
            return self.appendingGeneratedVisionFallbacks(
                from: parsed,
                to: [.openRouter(modelId: "openai/gpt-oss-120b")])
        }
        let customModels = self.customProviderModels(configuration: configuration)
        if !customModels.isEmpty {
            return self.appendingGeneratedVisionFallbacks(from: parsed, to: customModels)
        }
        return [.openai(.gpt55), .anthropic(.opus48)]
    }

    private static func appendingGeneratedVisionFallbacks(
        from parsed: [LanguageModel],
        to models: [LanguageModel]) -> [LanguageModel]
    {
        var result = models
        for model in parsed where self.isLocalVisionFallback(model) && !result.contains(model) {
            result.append(model)
        }
        return result
    }

    private static func isLocalVisionFallback(_ model: LanguageModel) -> Bool {
        switch model {
        case .ollama, .lmstudio:
            model.supportsVision
        default:
            false
        }
    }

    private static func hasExplicitProviderList(configuration: ConfigurationManager) -> Bool {
        if ProcessInfo.processInfo.environment["PEEKABOO_AI_PROVIDERS"]?.isEmpty == false {
            return true
        }
        guard let providers = configuration.configuration?.aiProviders?.providers,
              !providers.isEmpty
        else {
            return false
        }
        return !self.isGeneratedProviderList(
            providers,
            configuredDefault: configuration.configuration?.agent?.defaultModel)
    }

    private static func isGeneratedProviderList(_ providers: String, configuredDefault: String?) -> Bool {
        let entries = providers
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        if entries == ["openai/gpt-5.5", "anthropic/claude-opus-4-7"] ||
            entries == ["openai/gpt-5.5", "anthropic/claude-opus-4-8"]
        {
            return true
        }

        let entriesWithoutVisionFallback = entries.filter { entry in
            entry != "ollama/llava" && entry != "ollama/llava:latest"
        }

        guard entriesWithoutVisionFallback.count == 1,
              entriesWithoutVisionFallback.count < entries.count,
              let entry = entriesWithoutVisionFallback.first,
              let configuredDefault = configuredDefault?.lowercased(),
              let model = entry.split(separator: "/", maxSplits: 1).last.map(String.init)
        else {
            return false
        }
        return model == configuredDefault || entry == configuredDefault
    }

    private static func hasCredentialsOrLocalRuntime(
        for model: LanguageModel,
        configuration: ConfigurationManager) -> Bool
    {
        switch model {
        case .openai:
            configuration.hasOpenAIAuth()
        case .anthropic:
            configuration.hasAnthropicAuth()
        case .google:
            configuration.getGeminiAPIKey()?.isEmpty == false
        case .minimax:
            configuration.getMiniMaxAPIKey()?.isEmpty == false
        case .minimaxCN:
            configuration.getMiniMaxChinaAPIKey()?.isEmpty == false
        case .kimi:
            configuration.getKimiAPIKey()?.isEmpty == false
        case .grok:
            configuration.getGrokAPIKey()?.isEmpty == false
        case .openRouter:
            configuration.getOpenRouterAPIKey()?.isEmpty == false
        case .ollama, .lmstudio:
            model.supportsTools
        case let .custom(provider):
            provider.apiKey?.isEmpty == false
        default:
            false
        }
    }

    private static func providerAndModelName(for model: LanguageModel) -> (provider: String, model: String) {
        switch model {
        case let .openai(m): ("openai", m.modelId)
        case let .anthropic(m): ("anthropic", m.modelId)
        case let .google(m): ("google", m.rawValue)
        case let .mistral(m): ("mistral", m.rawValue)
        case let .groq(m): ("groq", m.rawValue)
        case let .grok(m): ("grok", m.modelId)
        case let .ollama(m): ("ollama", m.modelId)
        case let .lmstudio(m): ("lmstudio", m.modelId)
        case let .minimax(m): ("minimax", m.modelId)
        case let .minimaxCN(m): ("minimax-cn", m.modelId)
        case let .kimi(m): ("kimi", m.modelId)
        case let .azureOpenAI(deployment, _, _, _): ("azure-openai", deployment)
        case let .openRouter(modelId): ("openrouter", modelId)
        case let .together(modelId): ("together", modelId)
        case let .replicate(modelId): ("replicate", modelId)
        case let .openaiCompatible(modelId, _): ("openai-compatible", modelId)
        case let .anthropicCompatible(modelId, _): ("anthropic-compatible", modelId)
        case let .custom(provider):
            if let peekabooProvider = provider as? PeekabooCustomProviderModel {
                (peekabooProvider.providerID, peekabooProvider.resolvedModelID)
            } else {
                ("custom", provider.modelId)
            }
        }
    }

    func tachikomaConfiguration(for model: LanguageModel) -> TachikomaConfiguration {
        guard case let .custom(provider) = model,
              let peekabooProvider = provider as? PeekabooCustomProviderModel
        else {
            return .current
        }

        let configuration = TachikomaConfiguration(loadFromEnvironment: true)
        configuration.setProviderFactoryOverride { selectedModel, baseConfiguration in
            if case let .custom(selectedProvider) = selectedModel,
               selectedProvider.modelId == peekabooProvider.modelId
            {
                return peekabooProvider
            }
            return try ProviderFactory.createProvider(for: selectedModel, configuration: baseConfiguration)
        }
        guard let apiKey = peekabooProvider.apiKey, !apiKey.isEmpty else {
            return configuration
        }

        switch peekabooProvider.kind {
        case .openai:
            configuration.setAPIKey(apiKey, for: "openai_compatible")
        case .anthropic:
            configuration.setAPIKey(apiKey, for: "anthropic_compatible")
        }
        return configuration
    }

    private static func customProviderModel(
        providerID: String,
        modelString: String,
        configuration: ConfigurationManager) -> PeekabooCustomProviderModel?
    {
        guard let provider = configuration.getCustomProvider(id: providerID),
              provider.enabled
        else {
            return nil
        }

        let models = provider.models ?? [:]
        guard models.isEmpty || models[modelString] != nil else {
            return nil
        }
        let model = models[modelString]
        let kind: PeekabooCustomProviderModel.Kind = switch provider.type {
        case .openai: .openai
        case .anthropic: .anthropic
        }

        return PeekabooCustomProviderModel(
            providerID: providerID,
            resolvedModelID: modelString,
            kind: kind,
            baseURL: provider.options.baseURL,
            apiKey: configuration.resolveCredentialReference(provider.options.apiKey),
            additionalHeaders: provider.options.headers ?? [:],
            supportsVision: model?.supportsVision ?? true,
            supportsTools: model?.supportsTools ?? true,
            maxOutputTokens: model?.maxTokens)
    }

    private static func customProviderID(matching providerID: String, configuration: ConfigurationManager) -> String? {
        if configuration.getCustomProvider(id: providerID) != nil {
            return providerID
        }

        let matches = configuration.listCustomProviders().keys.filter {
            $0.caseInsensitiveCompare(providerID) == .orderedSame
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func customProviderModels(configuration: ConfigurationManager) -> [LanguageModel] {
        configuration.listCustomProviders()
            .keys
            .sorted()
            .flatMap { providerID -> [LanguageModel] in
                guard let provider = configuration.getCustomProvider(id: providerID),
                      provider.enabled,
                      configuration.resolveCredentialReference(provider.options.apiKey)?.isEmpty == false,
                      let modelIDs = provider.models?.keys.sorted(),
                      !modelIDs.isEmpty
                else {
                    return []
                }

                return modelIDs.compactMap { modelID in
                    self.customProviderModel(
                        providerID: providerID,
                        modelString: modelID,
                        configuration: configuration).map { .custom(provider: $0) }
                }
            }
    }

    nonisolated static func normalizeCoordinateTextIfNeeded(
        _ text: String,
        model: String,
        imageSize: CGSize?) -> String
    {
        guard self.modelUsesNormalizedThousandCoordinates(model),
              let imageSize,
              imageSize.width > 0,
              imageSize.height > 0
        else {
            return text
        }

        let nsText = text as NSString
        let numberPattern = #"(-?\d+(?:\.\d+)?)"#
        let pattern = #"\[\s*"# +
            numberPattern +
            #"\s*,\s*"# +
            numberPattern +
            #"\s*,\s*"# +
            numberPattern +
            #"\s*,\s*"# +
            numberPattern +
            #"\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }

        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        var result = text
        for match in matches {
            let values = (1...4).compactMap { index -> Double? in
                Double(nsText.substring(with: match.range(at: index)))
            }
            guard values.count == 4,
                  values.allSatisfy({ (0.0...1000.0).contains($0) }),
                  values[2] > values[0],
                  values[3] > values[1]
            else {
                continue
            }

            let converted = [
                Int((values[0] * Double(imageSize.width) / 1000.0).rounded()),
                Int((values[1] * Double(imageSize.height) / 1000.0).rounded()),
                Int((values[2] * Double(imageSize.width) / 1000.0).rounded()),
                Int((values[3] * Double(imageSize.height) / 1000.0).rounded()),
            ]
            let original = nsText.substring(with: match.range)
            let replacement = "[\(converted[0]), \(converted[1]), \(converted[2]), \(converted[3])] " +
                "(converted from GLM normalized \(original))"

            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }

        return result
    }

    private nonisolated static func modelUsesNormalizedThousandCoordinates(_ model: String) -> Bool {
        model.lowercased().contains("glm")
    }

    private nonisolated static func imageSize(from imageData: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat
        else {
            return nil
        }

        return CGSize(width: width, height: height)
    }
}
