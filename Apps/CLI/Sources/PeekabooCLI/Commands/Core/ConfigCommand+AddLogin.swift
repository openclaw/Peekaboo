import Commander
import Foundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    struct AddCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "add",
            abstract: "Add and validate a provider credential (API key)"
        )

        @Argument(help: "Provider id (openai|anthropic|grok|xai|gemini|openrouter)")
        var provider: String

        @Argument(help: "Secret value (API key)")
        var secret: String

        @Option(name: .customLong("timeout"), help: "Validation timeout in seconds (default 30)")
        var timeoutSeconds: Double = 30

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            guard let pid = TKProviderId.normalize(self.provider) else {
                self.output.error(
                    code: "INVALID_PROVIDER",
                    message: "Supported: openai, anthropic, grok, xai, gemini, openrouter"
                )
                throw ExitCode.failure
            }

            let timeout = self.timeoutSeconds > 0 ? self.timeoutSeconds : 30
            let result = await TKAuthManager.shared.validate(provider: pid, secret: self.secret, timeout: timeout)

            do {
                try TKAuthManager.shared.setCredential(key: pid.credentialKeys.first!, value: self.secret)
            } catch {
                self.output.error(code: "FILE_IO_ERROR", message: "Failed to store credential: \(error)")
                throw ExitCode.failure
            }

            switch result {
            case .success:
                self.output.success(message: "[ok] Stored and validated \(pid.displayName) credential")
            case let .failure(reason):
                self.output.error(
                    code: "VALIDATION_FAILED",
                    message: "[warn] Stored credential but validation failed: \(reason)"
                )
                throw ExitCode.failure
            case let .timeout(seconds):
                self.output.error(
                    code: "VALIDATION_TIMEOUT",
                    message: "[warn] Stored credential but validation timed out after \(Int(seconds))s"
                )
                throw ExitCode.failure
            }
        }
    }

    struct LoginCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "login",
            abstract: "OAuth login for supported providers (openai, anthropic)"
        )

        @Argument(help: "Provider id (openai|anthropic)")
        var provider: String

        @Option(name: .customLong("timeout"), help: "Timeout in seconds for token exchange (default 30)")
        var timeoutSeconds: Double = 30

        @Flag(name: .customLong("no-browser"), help: "Do not auto-open the browser")
        var noBrowser: Bool = false

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            guard let pid = TKProviderId.normalize(self.provider), pid.supportsOAuth else {
                self.output.error(code: "INVALID_PROVIDER", message: "OAuth supported: openai, anthropic")
                throw ExitCode.failure
            }
            let timeout = self.timeoutSeconds > 0 ? self.timeoutSeconds : 30
            let result = await TKAuthManager.shared.oauthLogin(
                provider: pid,
                timeout: timeout,
                noBrowser: self.noBrowser
            )
            switch result {
            case .success:
                self.output.success(message: "[ok] OAuth tokens stored for \(pid.displayName.lowercased())")
            case let .failure(reason):
                let message: String = switch reason {
                case .unsupported: "OAuth not supported for provider"
                case let .general(text): text
                }
                self.output.error(code: "OAUTH_ERROR", message: message)
                throw ExitCode.failure
            }
        }
    }
}
