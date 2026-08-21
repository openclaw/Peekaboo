import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

enum ConfigCommandTimeouts {
    static let network: Duration = .seconds(10)
}

enum TimeoutError: Error {
    case timedOut
    case cancelled
}

@Sendable
func withTimeout<T: Sendable>(
    _ duration: Duration,
    operation: @escaping @Sendable () async -> T
) async -> Result<T, TimeoutError> {
    do {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        let value = try await withCommandTimeout(
            seconds: seconds,
            operationName: "provider operation",
            operation: operation
        )
        return .success(value)
    } catch is CancellationError {
        return .failure(.cancelled)
    } catch {
        return .failure(.timedOut)
    }
}

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    /// Add a custom AI provider.
    struct AddProviderCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "add",
            abstract: "Add a custom AI provider",
            discussion: """
            Add a custom AI provider to your Peekaboo configuration.

            This allows you to connect to OpenAI-compatible or Anthropic-compatible
            endpoints beyond the built-in providers.

            Examples:

            # Store a secret outside argv, then add OpenRouter by reference
            printenv OPENROUTER_API_KEY | peekaboo config credential set OPENROUTER_API_KEY \\
              --credential-stdin --no-input
            peekaboo config provider add openrouter \\
              --type openai \\
              --name "OpenRouter" \\
              --base-url "https://openrouter.ai/api/v1" \\
              --credential-ref '${OPENROUTER_API_KEY}' \\
              --description "Access to 300+ models via OpenRouter"

            # Pipe a credential directly; it is never placed in argv or output
            printf '%s\\n' 'dummy-key' | peekaboo config provider add local-ollama \\
              --type openai \\
              --name "Local Ollama" \\
              --base-url "http://localhost:11434/v1" \\
              --credential-stdin --no-input

            With no credential source, an interactive terminal shows a no-echo prompt. --api-key remains
            available for compatibility, but is deprecated because process listings can expose argv.
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

        @Option(name: .customLong("credential-ref"), help: "Non-secret credential reference in ${NAME} form")
        var credentialReference: String?

        @Option(
            name: .customLong("credential-file"),
            help: "Read one line from an owner-only, ACL-free regular file (mode 0400 or 0600)"
        )
        var credentialFile: String?

        @Flag(name: .customLong("credential-stdin"), help: "Read one credential line from stdin")
        var credentialStdin = false

        @Flag(name: .customLong("no-input"), help: "Never prompt; fail if no source supplies a credential")
        var noInput = false

        @Option(
            name: .customLong("api-key"),
            help: "Deprecated API key or reference in argv; use --credential-ref or secure input"
        )
        var apiKey: String?

        @Option(name: .long, help: "Optional description of the provider")
        var description: String?

        @Option(name: .long, help: "Non-secret additional HTTP headers (key:value,key:value)")
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

            let credential: ConfigCredentialInput.Resolution
            do {
                credential = try ConfigCredentialInput.resolve(
                    .init(
                        legacyValue: self.apiKey,
                        reference: self.credentialReference,
                        filePath: self.credentialFile,
                        readFromStdin: self.credentialStdin,
                        noInput: self.noInput,
                        prompt: "Credential for custom provider \(self.providerId): "
                    )
                )
            } catch {
                self.emitError(code: "CREDENTIAL_INPUT_ERROR", message: error.localizedDescription)
                throw ExitCode.failure
            }

            let options = Configuration.ProviderOptions(
                baseURL: validatedBaseURL,
                apiKey: credential.value,
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
                self.emitDryRunSummary(
                    provider: provider,
                    providerId: self.providerId,
                    credentialSource: credential.source
                )
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
                    print("\nTip: Test the connection with: peekaboo config provider test \(self.providerId)")
                }
            } catch {
                self.emitError(
                    code: "ADD_FAILED",
                    message: ConfigCredentialOutputRedactor.redact(
                        "Failed to add provider: \(error.localizedDescription)",
                        credential: credential.value
                    )
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

        private func emitDryRunSummary(
            provider: Configuration.CustomProvider,
            providerId: String,
            credentialSource: ConfigCredentialInput.Resolution.Source
        ) {
            let summary = [
                "providerId": providerId,
                "type": provider.type.rawValue,
                "baseUrl": provider.options.baseURL,
                "credentialSource": credentialSource.rawValue,
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
