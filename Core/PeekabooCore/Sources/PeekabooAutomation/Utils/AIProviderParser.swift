import Foundation
import Tachikoma

/// Utility for parsing AI provider configurations from string format
/// Migrated from legacy system to work with current Tachikoma architecture
public enum AIProviderParser {
    /// Represents a parsed provider configuration
    public struct ProviderConfig: Equatable {
        public let provider: String
        public let model: String

        public init(provider: String, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    /// Parse a single provider string in format "provider/model"
    public static func parse(_ input: String) -> ProviderConfig? {
        // Parse a single provider string in format "provider/model"
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else { return nil }

        let provider = String(components[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let model = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !provider.isEmpty, !model.isEmpty else { return nil }
        guard !self.isUnsupportedLegacyModel(provider: provider, model: model) else { return nil }

        return ProviderConfig(provider: provider, model: model)
    }

    private static func isUnsupportedLegacyModel(provider: String, model: String) -> Bool {
        let provider = provider.lowercased()
        let normalized = model.lowercased()
        let compact = normalized.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ".", with: "")

        if provider == "openai",
           normalized.hasPrefix("gpt-4") || compact.hasPrefix("gpt4") ||
           normalized.hasPrefix("gpt-3") || compact.hasPrefix("gpt3") ||
           normalized.hasPrefix("o3") || normalized.hasPrefix("o4")
        {
            return true
        }

        if provider == "anthropic", normalized.hasPrefix("claude-3") || compact.hasPrefix("claude3") {
            return true
        }

        return false
    }

    /// Parse a comma-separated list of provider strings
    public static func parseList(_ input: String) -> [ProviderConfig] {
        // Parse a comma-separated list of provider strings
        let providers = input.split(separator: ",")
        return providers.compactMap { self.parse(String($0)) }
    }

    /// Parse and return the first valid provider from a list
    public static func parseFirst(_ input: String) -> ProviderConfig? {
        // Parse and return the first valid provider from a list
        let list = self.parseList(input)
        return list.first
    }

    /// Extract just the provider name from a provider/model string
    public static func extractProvider(from input: String) -> String? {
        // Extract just the provider name from a provider/model string
        self.parse(input)?.provider
    }

    /// Extract just the model name from a provider/model string
    public static func extractModel(from input: String) -> String? {
        // Extract just the model name from a provider/model string
        self.parse(input)?.model
    }

    /// Determine the default model based on available providers and configuration
    public static func determineDefaultModel(
        from providerList: String,
        hasOpenAI: Bool = false,
        hasAnthropic: Bool = false,
        hasGemini: Bool = false,
        hasMiniMax: Bool = false,
        hasMiniMaxChina: Bool = false,
        hasOllama: Bool = false,
        configuredDefault: String? = nil) -> String
    {
        // If there's a configured default, use it
        if let configuredDefault, !configuredDefault.isEmpty {
            return configuredDefault
        }

        // Parse the provider list and find the first available one
        let configs = self.parseList(providerList)
        for config in configs {
            switch config.provider.lowercased() {
            case "openai":
                if hasOpenAI { return "gpt-5.5" }
            case "anthropic":
                if hasAnthropic { return "claude-opus-4-7" }
            case "google", "gemini":
                if hasGemini { return "gemini-3-flash" }
            case "minimax":
                if hasMiniMax { return config.model }
            case "minimax-cn", "minimax_cn", "minimaxi":
                if hasMiniMaxChina { return "minimax-cn/\(config.model)" }
            case "ollama":
                if hasOllama { return config.model }
            default:
                break
            }
        }

        // Fall back to hardcoded defaults based on what's available
        if hasAnthropic {
            return "claude-opus-4-7"
        } else if hasOpenAI {
            return "gpt-5.5"
        } else if hasGemini {
            return "gemini-3-flash"
        } else if hasMiniMaxChina {
            return "minimax-cn/MiniMax-M2.7"
        } else if hasMiniMax {
            return "MiniMax-M2.7"
        } else {
            return "gpt-5.5"
        }
    }
}
