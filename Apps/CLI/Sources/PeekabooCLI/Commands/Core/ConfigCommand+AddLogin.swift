import Commander
import Foundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    struct CredentialSetCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "set",
            abstract: "Validate and store a provider credential, or set a raw credential key",
            discussion: """
            Known provider names (for example `openai`) are validated before the command succeeds.
            Credential keys (for example `OPENAI_API_KEY`) are stored directly without validation.
            """
        )

        @Argument(help: "Provider id or raw credential key")
        var keyOrProvider: String

        @Argument(help: "Credential value")
        var value: String

        @Option(name: .customLong("timeout"), help: "Validation timeout (bare values are milliseconds; default 30s)")
        var timeout: CLIDuration = .seconds(30)

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            guard let provider = TKProviderId.normalize(self.keyOrProvider) else {
                do {
                    try self.configManager.setCredential(key: self.keyOrProvider, value: self.value)
                    self.output.success(message: "[ok] Stored credential '\(self.keyOrProvider)'")
                    return
                } catch {
                    self.output.error(code: "FILE_IO_ERROR", message: "Failed to store credential: \(error)")
                    throw ExitCode.failure
                }
            }

            let timeoutSeconds = self.timeout.seconds > 0 ? self.timeout.seconds : 30
            let result = await TKAuthManager.shared.validate(
                provider: provider,
                secret: self.value,
                timeout: timeoutSeconds
            )

            do {
                try TKAuthManager.shared.setCredential(key: provider.credentialKeys.first!, value: self.value)
            } catch {
                self.output.error(code: "FILE_IO_ERROR", message: "Failed to store credential: \(error)")
                throw ExitCode.failure
            }

            switch result {
            case .success:
                self.output.success(message: "[ok] Stored and validated \(provider.displayName) credential")
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

        @Option(
            name: .customLong("timeout"),
            help: "Token exchange timeout (bare values are milliseconds; default 30s)"
        )
        var timeout: CLIDuration = .seconds(30)

        @Flag(name: .customLong("no-browser"), help: "Do not auto-open the browser")
        var noBrowser: Bool = false

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            guard let pid = TKProviderId.normalize(self.provider), pid.supportsOAuth else {
                self.output.error(code: "INVALID_PROVIDER", message: "OAuth supported: openai, anthropic")
                throw ExitCode.failure
            }
            let timeoutSeconds = self.timeout.seconds > 0 ? self.timeout.seconds : 30
            let result = await TKAuthManager.shared.oauthLogin(
                provider: pid,
                timeout: timeoutSeconds,
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
