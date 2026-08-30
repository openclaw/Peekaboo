import Foundation
import PeekabooCore
import Tachikoma

/// Service for generating intelligent session titles using AI
@MainActor
final class SessionTitleGenerator {
    private struct ModelSelection: Sendable {
        let providers: [String]
        let hasOpenAI: Bool
        let hasAnthropic: Bool
        let hasProviderSelection: Bool
        let configuredDefault: String?
    }

    private let configuration = ConfigurationManager.shared

    /// Generate a concise title for a task
    /// - Parameter task: The user's task description
    /// - Returns: A 2-4 word title summarizing the task
    func generateTitle(for task: String) async -> String {
        let providerTokens = self.configuration
            .getAIProviders()
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let hasOpenAI = self.configuration.hasOpenAIAuth()
        let hasAnthropic = self.configuration.hasAnthropicAuth()
        let hasProviderSelection = self.configuration.hasConfiguredAIProviderList() ||
            self.configuration.hasExplicitAIProviderList()
        let configuredDefault = self.configuration.getAgentModel()
        let selection = ModelSelection(
            providers: providerTokens,
            hasOpenAI: hasOpenAI,
            hasAnthropic: hasAnthropic,
            hasProviderSelection: hasProviderSelection,
            configuredDefault: configuredDefault)

        return await withTaskGroup(of: String.self) { group in
            group.addTask { await Self.timeoutTitle() }

            group.addTask {
                await self.generateTitleCandidate(
                    for: task,
                    selection: selection)
            }

            for await result in group {
                group.cancelAll()
                return result
            }

            return Self.fallbackTitle
        }
    }

    /// Generate a title from the first user message in a session
    func generateTitleFromFirstMessage(_ message: String) async -> String {
        // Truncate very long messages
        let truncated = String(message.prefix(200))
        return await self.generateTitle(for: truncated)
    }

    private static let fallbackTitle = "New Session"

    private static func timeoutTitle() async -> String {
        do {
            try await Task.sleep(nanoseconds: 8_000_000_000)
        } catch {
            return self.fallbackTitle
        }
        return self.fallbackTitle
    }

    private func generateTitleCandidate(
        for task: String,
        selection: ModelSelection) async -> String
    {
        do {
            let model = Self.selectModel(
                providers: selection.providers,
                hasOpenAI: selection.hasOpenAI,
                hasAnthropic: selection.hasAnthropic,
                hasProviderSelection: selection.hasProviderSelection,
                configuredDefault: selection.configuredDefault)
            let prompt = self.buildPrompt(for: task)

            let result = try await generateText(
                model: model,
                messages: [.user(prompt)],
                settings: self.generationSettings(for: model))

            return self.validatedTitle(result.text)
        } catch {
            return Self.fallbackTitle
        }
    }

    static func selectModel(
        providers: [String],
        hasOpenAI: Bool,
        hasAnthropic: Bool,
        hasProviderSelection: Bool = true,
        configuredDefault: String? = nil) -> LanguageModel
    {
        if let configuredDefault,
           let configuredModel = LanguageModel.parse(from: configuredDefault)
        {
            switch configuredModel {
            case .anthropic where hasAnthropic:
                return configuredModel
            case .openai where hasOpenAI:
                return configuredModel
            default:
                break
            }
        }

        if hasProviderSelection,
           hasAnthropic,
           let configuredAnthropic = self.configuredModel(for: "anthropic", in: providers)
        {
            return configuredAnthropic
        }
        if hasProviderSelection,
           providers.contains(where: { $0 == "anthropic" || $0.hasPrefix("anthropic/") }),
           hasAnthropic
        {
            return .anthropic(.opus5)
        }
        if hasProviderSelection,
           hasOpenAI,
           let configuredOpenAI = self.configuredModel(for: "openai", in: providers)
        {
            return configuredOpenAI
        }
        if hasProviderSelection,
           providers.contains(where: { $0 == "openai" || $0.hasPrefix("openai/") }),
           hasOpenAI
        {
            return .openai(.gpt56Sol)
        }
        if hasProviderSelection, providers.contains(where: { $0 == "ollama" || $0.hasPrefix("ollama/") }) {
            return .ollama(.llama33)
        }
        if hasAnthropic {
            return .anthropic(.opus48)
        }
        if hasOpenAI {
            return .openai(.gpt56Sol)
        }
        return .anthropic(.opus48)
    }

    private static func configuredModel(for provider: String, in selections: [String]) -> LanguageModel? {
        for selection in selections {
            let components = selection.split(separator: "/", maxSplits: 1).map(String.init)
            guard components.count == 2,
                  components[0].caseInsensitiveCompare(provider) == .orderedSame,
                  let model = LanguageModel.parse(from: components[1])
            else {
                continue
            }

            switch (provider, model) {
            case ("anthropic", .anthropic), ("openai", .openai):
                return model
            default:
                continue
            }
        }
        return nil
    }

    private func generationSettings(for model: LanguageModel) -> GenerationSettings {
        switch model {
        case .anthropic(.fable5):
            GenerationSettings(maxTokens: 256, reasoningEffort: .low)
        default:
            GenerationSettings(maxTokens: 20, temperature: 0.3)
        }
    }

    private func buildPrompt(for task: String) -> String {
        """
        Generate a 2-4 word title for this task. Be concise and descriptive.
        Only respond with the title, nothing else.

        Task: \(task)
        """
    }

    private func validatedTitle(_ rawTitle: String) -> String {
        let cleaned = rawTitle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

        let wordCount = cleaned.split(separator: " ").count
        if wordCount >= 2, wordCount <= 6 {
            return cleaned
        }
        return Self.fallbackTitle
    }
}
