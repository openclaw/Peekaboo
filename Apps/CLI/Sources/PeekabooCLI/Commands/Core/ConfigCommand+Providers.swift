import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

enum ConfigCommandTimeouts {
    static let network: Duration = .seconds(10)
}

enum TimeoutError: Error {
    case timedOut
}

@Sendable
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async -> T
) async -> Result<T, TimeoutError> {
    await withTaskGroup(of: Result<T, TimeoutError>.self) { group in
        group.addTask {
            await .success(operation())
        }
        group.addTask {
            try? await Task.sleep(for: duration)
            return .failure(.timedOut)
        }
        let result = await group.next()!
        group.cancelAll()
        return result
    }
}

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    /// Add a custom AI provider.
    struct AddProviderCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "add-provider",
            abstract: "Add a custom AI provider",
            discussion: """
            Add a custom AI provider to your Peekaboo configuration.

            This allows you to connect to OpenAI-compatible or Anthropic-compatible
            endpoints beyond the built-in providers.

            Examples:

            # Add OpenRouter
            peekaboo config add-provider openrouter \\
              --type openai \\
              --name "OpenRouter" \\
              --base-url "https://openrouter.ai/api/v1" \\
              --api-key "${OPENROUTER_API_KEY}" \\
              --description "Access to 300+ models via OpenRouter"

            # Add local Ollama with authentication
            peekaboo config add-provider local-ollama \\
              --type openai \\
              --name "Local Ollama" \\
              --base-url "http://localhost:11434/v1" \\
              --api-key "dummy-key"

            # Add Groq
            peekaboo config add-provider groq \\
              --type openai \\
              --name "Groq" \\
              --base-url "https://api.groq.com/openai/v1" \\
              --api-key "${GROQ_API_KEY}"
            """
        )

        @Argument(help: "Unique identifier for the provider (letters, numbers, hyphens only)")
        var providerId: String

        @Option(name: .long, help: "Provider type (openai or anthropic)")
        var type: String

        @Option(name: .long, help: "Human-readable name for the provider")
        var name: String

        @Option(name: .long, help: "Base URL for the API endpoint")
        var baseUrl: String

        @Option(name: .long, help: "API key or credential reference (e.g., ${API_KEY})")
        var apiKey: String

        @Option(name: .long, help: "Optional description of the provider")
        var description: String?

        @Option(name: .long, help: "Additional HTTP headers (key:value,key:value)")
        var headers: String?

        @Flag(name: .long, help: "Overwrite existing provider with same ID")
        var force: Bool = false

        @Flag(name: .long, help: "Show the change without writing to disk")
        var dryRun: Bool = false

        @RuntimeStorage var runtime: CommandRuntime?

        enum HeaderParseError: LocalizedError {
            case invalidPair(String)
            case emptyKey(String)

            var errorDescription: String? {
                switch self {
                case let .invalidPair(pair):
                    "Invalid header entry '\(pair)'. Use key:value pairs separated by commas."
                case let .emptyKey(pair):
                    "Header key is empty in entry '\(pair)'."
                }
            }
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            guard Self.isValidProviderId(self.providerId) else {
                self.emitError(
                    code: "INVALID_ID",
                    message: "Provider ID must contain only letters, numbers, hyphens, and underscores"
                )
                throw ExitCode.failure
            }

            guard let providerType = Configuration.CustomProvider.ProviderType(rawValue: self.type) else {
                self.emitError(
                    code: "INVALID_TYPE",
                    message: "Invalid provider type '\(self.type)'. Must be 'openai' or 'anthropic'."
                )
                throw ExitCode.failure
            }

            guard !self.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.emitError(
                    code: "INVALID_NAME",
                    message: "Provider name must not be empty"
                )
                throw ExitCode.failure
            }

            guard let validatedBaseURL = Self.validatedURL(self.baseUrl) else {
                self.emitError(
                    code: "INVALID_URL",
                    message: "Base URL must include scheme and host (e.g., https://api.example.com)"
                )
                throw ExitCode.failure
            }

            guard !self.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.emitError(
                    code: "INVALID_API_KEY",
                    message: "API key must not be empty"
                )
                throw ExitCode.failure
            }

            let manager = self.configManager
            if manager.getCustomProvider(id: self.providerId) != nil, !self.force {
                self.emitError(
                    code: "PROVIDER_EXISTS",
                    message: "Provider '\(self.providerId)' already exists. Use --force to overwrite."
                )
                throw ExitCode.failure
            }

            let headerDict: [String: String]?
            do {
                headerDict = try Self.parseHeaders(self.headers)
            } catch {
                self.emitError(code: "INVALID_HEADERS", message: error.localizedDescription)
                throw ExitCode.failure
            }

            let options = Configuration.ProviderOptions(
                baseURL: validatedBaseURL,
                apiKey: self.apiKey,
                headers: headerDict
            )

            let provider = Configuration.CustomProvider(
                name: self.name,
                description: self.description,
                type: providerType,
                options: options,
                models: nil,
                enabled: true
            )

            if self.dryRun {
                self.emitDryRunSummary(provider: provider, providerId: self.providerId)
                return
            }

            do {
                try manager.addCustomProvider(provider, id: self.providerId)

                if self.jsonOutput {
                    let successOutput = SuccessOutput(
                        success: true,
                        data: [
                            "providerId": providerId,
                            "name": name,
                            "type": type,
                            "baseUrl": baseUrl
                        ]
                    )
                    outputJSON(successOutput, logger: self.logger)
                } else {
                    print("[ok] Added custom provider '\(self.providerId)' (\(self.name))")
                    print("   Type: \(self.type)")
                    print("   Base URL: \(self.baseUrl)")
                    if let description {
                        print("   Description: \(description)")
                    }
                    print("\nTip: Test the connection with: peekaboo config test-provider \(self.providerId)")
                }
            } catch {
                self.emitError(
                    code: "ADD_FAILED",
                    message: "Failed to add provider: \(error.localizedDescription)"
                )
                throw ExitCode.failure
            }
        }

        static func isValidProviderId(_ id: String) -> Bool {
            let pattern = "^[a-zA-Z0-9-_]+$"
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(location: 0, length: id.utf16.count)
            return regex.firstMatch(in: id, options: [], range: range) != nil
        }

        static func parseHeaders(_ rawHeaders: String?) throws -> [String: String]? {
            guard let rawHeaders, !rawHeaders.isEmpty else { return nil }

            var headerDict: [String: String] = [:]
            for pair in rawHeaders.split(separator: ",") {
                let entry = String(pair)
                let components = entry.split(separator: ":", maxSplits: 1)
                guard components.count == 2 else {
                    throw HeaderParseError.invalidPair(entry)
                }

                let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)

                guard !key.isEmpty else {
                    throw HeaderParseError.emptyKey(entry)
                }
                headerDict[key] = value
            }
            return headerDict
        }

        static func validatedURL(_ value: String) -> String? {
            guard let components = URLComponents(string: value),
                  let scheme = components.scheme,
                  !scheme.isEmpty,
                  components.host != nil
            else { return nil }
            return components.string
        }

        private func emitError(code: String, message: String) {
            if self.jsonOutput {
                let errorOutput = ErrorOutput(error: true, code: code, message: message, details: nil)
                outputJSON(errorOutput, logger: self.logger)
            } else {
                print("[error] \(message)")
            }
        }

        private func emitDryRunSummary(provider: Configuration.CustomProvider, providerId: String) {
            let summary = [
                "providerId": providerId,
                "type": provider.type.rawValue,
                "baseUrl": provider.options.baseURL,
                "apiKey": provider.options.apiKey
            ]

            if self.jsonOutput {
                let output = SuccessOutput(success: true, data: [
                    "message": "Dry run - no changes written",
                    "provider": summary
                ])
                outputJSON(output, logger: self.logger)
            } else {
                print("[dry-run] Would add provider '\(providerId)' (\(provider.name))")
                print("   Type: \(provider.type.rawValue)")
                print("   Base URL: \(provider.options.baseURL)")
                if let description = provider.description {
                    print("   Description: \(description)")
                }
            }
        }
    }
}
