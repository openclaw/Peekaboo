import Foundation

extension ConfigurationManager {
    public func addCustomProvider(_ provider: Configuration.CustomProvider, id: String) throws {
        try self.validate(provider: provider, id: id)

        var config = self.loadConfiguration() ?? Configuration()
        if config.customProviders == nil {
            config.customProviders = [:]
        }
        config.customProviders?[id] = provider
        try self.saveConfiguration(config)
        self.configuration = config
    }

    public func removeCustomProvider(id: String) throws {
        var config = self.loadConfiguration() ?? Configuration()
        config.customProviders?.removeValue(forKey: id)
        if config.customProviders?.isEmpty == true {
            config.customProviders = nil
        }
        try self.saveConfiguration(config)
        self.configuration = config
    }

    public func getCustomProvider(id: String) -> Configuration.CustomProvider? {
        self.loadConfiguration()?.customProviders?[id]
    }

    public func listCustomProviders() -> [String: Configuration.CustomProvider] {
        self.loadConfiguration()?.customProviders ?? [:]
    }

    public func testCustomProvider(id: String) async -> (success: Bool, error: String?) {
        guard let provider = getCustomProvider(id: id) else {
            return (false, "Provider '\(id)' not found")
        }

        guard let apiKey = self.resolveCredentialReference(provider.options.apiKey) else {
            return (false, "API key not found or invalid: \(provider.options.apiKey)")
        }

        do {
            switch provider.type {
            case .openai:
                return try await self.testOpenAICompatibleProvider(provider: provider, apiKey: apiKey)
            case .anthropic:
                return try await self.testAnthropicCompatibleProvider(provider: provider, apiKey: apiKey)
            }
        } catch {
            return (false, "Connection test failed: \(error.localizedDescription)")
        }
    }

    public func discoverModelsForCustomProvider(id: String) async -> (models: [String], error: String?) {
        guard let provider = getCustomProvider(id: id) else {
            return ([], "Provider '\(id)' not found")
        }

        guard let apiKey = self.resolveCredentialReference(provider.options.apiKey) else {
            return ([], "API key not found: \(provider.options.apiKey)")
        }

        do {
            switch provider.type {
            case .openai:
                return try await self.discoverOpenAICompatibleModels(provider: provider, apiKey: apiKey)
            case .anthropic:
                let configuredModels = provider.models?.keys.map { String($0) } ?? []
                return (configuredModels, nil)
            }
        } catch {
            return ([], "Model discovery failed: \(error.localizedDescription)")
        }
    }

    public func resolveCredentialReference(_ reference: String) -> String? {
        guard let varName = Self.credentialReferenceName(reference) else {
            return reference
        }

        if let envValue = self.environmentValue(for: varName) {
            return envValue
        }
        if let credValue = self.credentialValue(for: varName) {
            return credValue
        }
        return nil
    }

    static func credentialReferenceName(_ reference: String) -> String? {
        if reference.hasPrefix("{env:"), reference.hasSuffix("}") {
            return String(reference.dropFirst(5).dropLast(1))
        }

        if reference.hasPrefix("${"), reference.hasSuffix("}") {
            return String(reference.dropFirst(2).dropLast(1))
        }

        return nil
    }

    private func validate(provider: Configuration.CustomProvider, id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationValidationError.invalidIdentifier("Provider id must not be empty")
        }

        guard !provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationValidationError.invalidName("Provider name must not be empty")
        }

        guard let components = URLComponents(string: provider.options.baseURL),
              let scheme = components.scheme, !scheme.isEmpty,
              components.host != nil
        else {
            throw ConfigurationValidationError.invalidURL("Base URL must include scheme and host")
        }

        guard !provider.options.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationValidationError.invalidAPIKey("API key must not be empty")
        }

        if let headers = provider.options.headers {
            for (key, value) in headers {
                guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationValidationError.invalidHeaders("Header keys must not be empty")
                }
                guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationValidationError.invalidHeaders("Header values must not be empty")
                }
            }
        }

        if let models = provider.models {
            for (name, _) in models {
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConfigurationValidationError.invalidModels("Model names must not be empty")
                }
            }
        }
    }

    private func testOpenAICompatibleProvider(
        provider: Configuration.CustomProvider,
        apiKey: String) async throws -> (success: Bool, error: String?)
    {
        let url = URL(string: "\(provider.options.baseURL)/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        provider.options.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (false, "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            return (false, errorMessage)
        }

        return (true, nil)
    }

    private func testAnthropicCompatibleProvider(
        provider: Configuration.CustomProvider,
        apiKey: String) async throws -> (success: Bool, error: String?)
    {
        let url = URL(string: "\(provider.options.baseURL)/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        provider.options.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let testPayload: [String: Any] = [
            "model": "claude-opus-4-7",
            "max_tokens": 10,
            "messages": [["role": "user", "content": "Hi"]],
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: testPayload)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (false, "Invalid response")
        }

        if httpResponse.statusCode < 500 {
            return (true, nil)
        }

        let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
        return (false, errorMessage)
    }

    private func discoverOpenAICompatibleModels(
        provider: Configuration.CustomProvider,
        apiKey: String) async throws -> (models: [String], error: String?)
    {
        let url = URL(string: "\(provider.options.baseURL)/models")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        provider.options.headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return ([], "Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            let errorMessage = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            return ([], errorMessage)
        }

        struct ModelsResponse: Codable {
            let data: [ModelInfo]

            struct ModelInfo: Codable { let id: String }
        }

        do {
            let response = try JSONDecoder().decode(ModelsResponse.self, from: data)
            return (response.data.map(\.id), nil)
        } catch {
            return ([], "Failed to parse models response: \(error.localizedDescription)")
        }
    }
}

enum ConfigurationValidationError: LocalizedError {
    case invalidIdentifier(String)
    case invalidName(String)
    case invalidURL(String)
    case invalidAPIKey(String)
    case invalidHeaders(String)
    case invalidModels(String)

    var errorDescription: String? {
        switch self {
        case let .invalidIdentifier(msg),
             let .invalidName(msg),
             let .invalidURL(msg),
             let .invalidAPIKey(msg),
             let .invalidHeaders(msg),
             let .invalidModels(msg):
            msg
        }
    }
}
