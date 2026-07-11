import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    /// List configured custom AI providers.
    struct ListProvidersCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "list-providers",
            abstract: "List configured custom AI providers",
            discussion: """
            Display all custom AI providers configured in Peekaboo.

            This shows providers you've added with 'peekaboo config add-provider',
            not the built-in providers (openai, anthropic, ollama).
            """
        )

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            let customProviders = self.configManager.listCustomProviders()

            if self.jsonOutput {
                let data: [String: Any] = [
                    "providers": customProviders.mapValues { provider in
                        [
                            "name": provider.name,
                            "description": provider.description ?? "",
                            "type": provider.type.rawValue,
                            "baseUrl": provider.options.baseURL,
                            "enabled": provider.enabled,
                            "modelCount": provider.models?.count ?? 0
                        ]
                    }
                ]
                let output = SuccessOutput(success: true, data: data)
                outputJSON(output, logger: self.logger)
                return
            }

            guard !customProviders.isEmpty else {
                print("No custom providers configured.")
                print("Add one with: peekaboo config add-provider <id> --type <type>")
                print("  --name <name> --base-url <url> --api-key <key>")
                return
            }

            print("Custom AI Providers:")
            print()

            for (id, provider) in customProviders.sorted(by: { $0.key < $1.key }) {
                let status = provider.enabled ? "[ok]" : "[disabled]"
                print("  \(status) \(id) (\(provider.name))")
                print("     Type: \(provider.type.rawValue)")
                print("     URL: \(provider.options.baseURL)")
                if let description = provider.description {
                    print("     Description: \(description)")
                }
                if let models = provider.models {
                    print("     Models: \(models.count) configured")
                }
                print()
            }

            print("Tip: Test a provider with: peekaboo config test-provider <id>")
            print("Tip: Remove a provider with: peekaboo config remove-provider <id>")
        }
    }

    /// Test a custom AI provider connection.
    struct TestProviderCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "test-provider",
            abstract: "Test connection to a custom AI provider",
            discussion: """
            Test the connection to a custom AI provider by making a simple API call.

            This verifies that:
            • The base URL is accessible
            • The API key is valid
            • The endpoint responds correctly

            For OpenAI-compatible providers, this calls the /models endpoint.
            For Anthropic-compatible providers, this makes a simple message request.
            """
        )

        @Argument(help: "Provider ID to test")
        var providerId: String

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            let manager = self.configManager
            let providerId = self.providerId
            let result: Result<(Bool, String?), TimeoutError> = await withTimeout(
                ConfigCommandTimeouts.network
            ) {
                await manager.testCustomProvider(id: providerId)
            }

            let success: Bool
            let error: String?

            switch result {
            case .failure:
                success = false
                error = "Connection test timed out"
            case let .success(value):
                success = value.0
                error = value.1
            }

            if self.jsonOutput {
                if success {
                    let successOutput = SuccessOutput(
                        success: true,
                        data: [
                            "providerId": providerId,
                            "connectionStatus": "successful"
                        ]
                    )
                    outputJSON(successOutput, logger: self.logger)
                } else {
                    let errorOutput = ErrorOutput(
                        error: true,
                        code: "CONNECTION_FAILED",
                        message: error ?? "Connection test failed",
                        details: nil
                    )
                    outputJSON(errorOutput, logger: self.logger)
                }
            } else {
                if success {
                    print("[ok] Connection to '\(self.providerId)' successful!")
                } else {
                    print("[error] Connection to '\(self.providerId)' failed: \(error ?? "Unknown error")")
                }
            }

            if !success {
                throw ExitCode.failure
            }
        }
    }

    /// Remove a custom AI provider.
    struct RemoveProviderCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "remove-provider",
            abstract: "Remove a custom AI provider",
            discussion: """
            Remove a custom AI provider from your Peekaboo configuration.

            This only removes providers you've added with 'peekaboo config add-provider'.
            Built-in providers (openai, anthropic, ollama) cannot be removed.
            """
        )

        @Argument(help: "Provider ID to remove")
        var providerId: String

        @Flag(name: .long, help: "Skip confirmation prompt")
        var force: Bool = false

        @Flag(name: .long, help: "Show planned removal without writing to disk")
        var dryRun: Bool = false

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            guard let provider = self.configManager.getCustomProvider(id: self.providerId) else {
                self.emitNotFoundError()
                throw ExitCode.failure
            }

            if !self.force && !self.jsonOutput {
                print(
                    "Are you sure you want to remove provider '\(self.providerId)' (\(provider.name))? [y/N]: ",
                    terminator: ""
                )
                let response = readLine()?.lowercased()
                if response != "y" && response != "yes" {
                    print("Cancelled.")
                    return
                }
            }

            if self.dryRun {
                self.emitDryRun(provider: provider)
                return
            }

            do {
                try self.configManager.removeCustomProvider(id: self.providerId)

                if self.jsonOutput {
                    let successOutput = SuccessOutput(
                        success: true,
                        data: [
                            "providerId": providerId,
                            "action": "removed"
                        ]
                    )
                    outputJSON(successOutput, logger: self.logger)
                } else {
                    print("[ok] Removed custom provider '\(self.providerId)'")
                }
            } catch {
                self.emitError(
                    code: "REMOVE_FAILED",
                    message: "Failed to remove provider: \(error.localizedDescription)"
                )
                throw ExitCode.failure
            }
        }

        private func emitNotFoundError() {
            if self.jsonOutput {
                let errorOutput = ErrorOutput(
                    error: true,
                    code: "PROVIDER_NOT_FOUND",
                    message: "Provider '\(providerId)' not found",
                    details: nil
                )
                outputJSON(errorOutput, logger: self.logger)
            } else {
                print("[error] Provider '\(self.providerId)' not found")
            }
        }

        private func emitError(code: String, message: String) {
            if self.jsonOutput {
                let errorOutput = ErrorOutput(error: true, code: code, message: message, details: nil)
                outputJSON(errorOutput, logger: self.logger)
            } else {
                print("[error] \(message)")
            }
        }

        private func emitDryRun(provider: Configuration.CustomProvider) {
            if self.jsonOutput {
                let output = SuccessOutput(success: true, data: [
                    "message": "Dry run - no changes written",
                    "providerId": self.providerId,
                    "action": "remove"
                ])
                outputJSON(output, logger: self.logger)
            } else {
                print("[dry-run] Would remove provider '\(self.providerId)' (\(provider.name))")
            }
        }
    }

    /// Discover or list models for a custom AI provider.
    struct ModelsProviderCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "models-provider",
            abstract: "List available models from a custom AI provider",
            discussion: """
            Discover and list available models from a custom AI provider.

            For OpenAI-compatible providers, this queries the /models endpoint.
            For Anthropic-compatible providers, this shows configured models
            since Anthropic doesn't have a public models endpoint.
            """
        )

        @Argument(help: "Provider ID to query")
        var providerId: String

        @Flag(name: .long, help: "Discover models from API (for OpenAI-compatible providers)")
        var discover: Bool = false

        @Flag(name: .long, help: "Persist discovered (or configured) models back into configuration")
        var save: Bool = false

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            guard let provider = self.configManager.getCustomProvider(id: providerId) else {
                self.emitNotFoundError()
                throw ExitCode.failure
            }

            let models: [String]
            let apiError: String?

            if self.discover && provider.type == .openai {
                let manager = self.configManager
                let providerId = self.providerId
                let modelResult: Result<(models: [String], error: String?), TimeoutError> = await withTimeout(
                    ConfigCommandTimeouts.network
                ) {
                    await manager.discoverModelsForCustomProvider(id: providerId)
                }
                switch modelResult {
                case .failure:
                    models = []
                    apiError = "Model discovery timed out"
                case let .success(tuple):
                    models = tuple.models
                    apiError = tuple.error
                }
            } else {
                models = provider.models?.keys.map { String($0) } ?? []
                apiError = nil
            }

            let saved = self.save && apiError == nil
            if saved {
                try self.saveModels(models, for: self.providerId, existing: provider)
            }

            if self.jsonOutput {
                let data: [String: Any] = [
                    "providerId": providerId,
                    "models": models,
                    "source": discover && provider.type == .openai ? "api" : "configuration",
                    "error": apiError as Any,
                    "saved": saved
                ]
                let output = SuccessOutput(success: apiError == nil, data: data)
                outputJSON(output, logger: self.logger)
                if apiError != nil {
                    throw ExitCode.failure
                }
                return
            }

            if let error = apiError {
                print("[error] Failed to discover models: \(error)")
                if !models.isEmpty {
                    print("Showing configured models instead:")
                }
            }

            if models.isEmpty {
                if provider.type == .openai && !self.discover {
                    print("No configured models. Try --discover to query the API.")
                } else {
                    print("No models available.")
                }
            } else {
                print("Models for provider '\(self.providerId)' (\(provider.name)):")
                print()
                for model in models.sorted() {
                    print("  • \(model)")
                }
                print()
                print("Found \(models.count) model(s)")

                if provider.type == .openai && !self.discover {
                    print("Tip: Use --discover to query the API for all available models")
                }
            }

            if saved {
                print("[ok] Saved \(models.count) model(s) to configuration")
            }
            if apiError != nil {
                throw ExitCode.failure
            }
        }

        private func emitNotFoundError() {
            if self.jsonOutput {
                let errorOutput = ErrorOutput(
                    error: true,
                    code: "PROVIDER_NOT_FOUND",
                    message: "Provider '\(providerId)' not found",
                    details: nil
                )
                outputJSON(errorOutput, logger: self.logger)
            } else {
                print("[error] Provider '\(self.providerId)' not found")
            }
        }

        private func saveModels(
            _ models: [String],
            for providerId: String,
            existing provider: Configuration.CustomProvider
        ) throws {
            let modelDefinitions = Dictionary(
                uniqueKeysWithValues: models.map { modelID in
                    (modelID, provider.models?[modelID] ?? Configuration.ModelDefinition(name: modelID))
                }
            )
            let updated = Configuration.CustomProvider(
                name: provider.name,
                description: provider.description,
                type: provider.type,
                options: provider.options,
                models: modelDefinitions,
                enabled: provider.enabled
            )
            try self.configManager.addCustomProvider(updated, id: providerId)
        }
    }
}
