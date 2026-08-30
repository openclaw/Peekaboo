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
            Credential keys (for example `OPENAI_API_KEY`) are stored directly without provider validation.

            With no credential source, an interactive terminal shows a no-echo prompt. Noninteractive
            callers should pipe one line with --credential-stdin or use an owner-only regular file with
            --credential-file. --no-input forbids prompting but still accepts an explicit pipe or file.

            Passing the credential as the second positional argument remains available for compatibility,
            but is deprecated because process listings can expose argv.
            """
        )

        @Argument(help: "Provider id or raw credential key")
        var keyOrProvider: String

        @Argument(help: "Deprecated credential value in argv; use secure input instead")
        var value: String?

        @Option(
            name: .customLong("credential-file"),
            help: "Read one line from an owner-only, ACL-free regular file (mode 0400 or 0600)"
        )
        var credentialFile: String?

        @Flag(name: .customLong("credential-stdin"), help: "Read one credential line from stdin")
        var credentialStdin = false

        @Flag(name: .customLong("no-input"), help: "Never prompt; fail if no pipe or file supplies a credential")
        var noInput = false

        @Option(name: .customLong("timeout"), help: "Validation timeout (bare values are milliseconds; default 30s)")
        var timeout: CLIDuration = .seconds(30)

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            let provider = TKProviderId.normalize(self.keyOrProvider)
            guard provider != nil || Self.isValidRawCredentialKey(self.keyOrProvider) else {
                self.output.error(
                    code: "INVALID_CREDENTIAL_KEY",
                    message: "Credential keys must be nonempty and cannot contain " +
                        "whitespace, '=', or control characters."
                )
                throw ExitCode.failure
            }

            let credential: String
            do {
                credential = try ConfigCredentialInput.resolve(
                    .init(
                        legacyValue: self.value,
                        reference: nil,
                        filePath: self.credentialFile,
                        readFromStdin: self.credentialStdin,
                        noInput: self.noInput,
                        prompt: "Credential for \(self.keyOrProvider): "
                    )
                ).value
            } catch {
                self.output.error(code: "CREDENTIAL_INPUT_ERROR", message: error.localizedDescription)
                throw ExitCode.failure
            }

            guard let provider else {
                do {
                    try self.configManager.setCredential(key: self.keyOrProvider, value: credential)
                    self.output.success(message: "[ok] Stored credential '\(self.keyOrProvider)'")
                    return
                } catch {
                    let message = ConfigCredentialOutputRedactor.redact(
                        "Failed to store credential: \(error.localizedDescription)",
                        credential: credential
                    )
                    self.output.error(code: "FILE_IO_ERROR", message: message)
                    throw ExitCode.failure
                }
            }

            let timeoutSeconds = self.timeout.seconds > 0 ? self.timeout.seconds : 30
            let result = await TKAuthManager.shared.validate(
                provider: provider,
                secret: credential,
                timeout: timeoutSeconds
            )

            do {
                try TKAuthManager.shared.setCredential(key: provider.credentialKeys.first!, value: credential)
            } catch {
                let message = ConfigCredentialOutputRedactor.redact(
                    "Failed to store credential: \(error.localizedDescription)",
                    credential: credential
                )
                self.output.error(code: "FILE_IO_ERROR", message: message)
                throw ExitCode.failure
            }

            switch result {
            case .success:
                self.output.success(message: "[ok] Stored and validated \(provider.displayName) credential")
            case let .failure(reason):
                self.output.error(
                    code: "VALIDATION_FAILED",
                    message: ConfigCredentialOutputRedactor.redact(
                        "[warn] Stored credential but validation failed: \(reason)",
                        credential: credential
                    )
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

        static func isValidRawCredentialKey(_ value: String) -> Bool {
            guard !value.isEmpty, value.utf8.count <= 128 else { return false }
            return value.allSatisfy { character in
                !character.isWhitespace && character != "=" &&
                    character.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
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
