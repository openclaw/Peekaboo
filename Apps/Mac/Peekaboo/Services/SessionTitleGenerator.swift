import Foundation
import PeekabooCore
import Tachikoma

/// Service for generating intelligent session titles using AI
@MainActor
final class SessionTitleGenerator {
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

        return await withTaskGroup(of: String.self) { group in
            group.addTask { await Self.timeoutTitle() }

            group.addTask {
                await self.generateTitleCandidate(
                    for: task,
                    providers: providerTokens,
                    hasOpenAI: hasOpenAI,
                    hasAnthropic: hasAnthropic)
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
        providers: [String],
        hasOpenAI: Bool,
        hasAnthropic: Bool) async -> String
    {
        do {
            let model = Self.selectModel(
                providers: providers,
                hasOpenAI: hasOpenAI,
                hasAnthropic: hasAnthropic)
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
        hasAnthropic: Bool) -> LanguageModel
    {
        if hasAnthropic,
           let configuredAnthropic = self.configuredModel(for: "anthropic", in: providers)
        {
            return configuredAnthropic
        }
        if providers.contains(where: { $0 == "anthropic" || $0.hasPrefix("anthropic/") }), hasAnthropic {
            return .anthropic(.opus5)
        }
        if hasOpenAI,
           let configuredOpenAI = self.configuredModel(for: "openai", in: providers)
        {
            return configuredOpenAI
        }
        if providers.contains(where: { $0 == "openai" || $0.hasPrefix("openai/") }), hasOpenAI {
            return .openai(.gpt56Sol)
        }
        if providers.contains(where: { $0 == "ollama" || $0.hasPrefix("ollama/") }) {
            return .ollama(.llama33)
        }
        return .anthropic(.opus5)
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
