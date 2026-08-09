import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    /// Validate configuration syntax.
    struct ValidateCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "validate",
            abstract: "Validate configuration file syntax"
        )

        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            guard FileManager.default.fileExists(atPath: self.configPath) else {
                if self.jsonOutput {
                    let errorOutput = ErrorOutput(
                        error: true,
                        code: "FILE_IO_ERROR",
                        message: "No configuration file found",
                        details: "Path: \(self.configPath). Run 'peekaboo config init' to create one."
                    )
                    outputJSON(errorOutput, logger: self.logger)
                } else {
                    print("No configuration file found at: \(self.configPath)")
                    print("Run 'peekaboo config init' to create one.")
                }
                throw ExitCode.failure
            }

            guard let config = self.configManager.loadConfiguration() else {
                if self.jsonOutput {
                    let errorOutput = ErrorOutput(
                        error: true,
                        code: "FILE_IO_ERROR",
                        message: "Failed to parse configuration file. Check for syntax errors.",
                        details: "Path: \(self.configPath). Common issues: trailing commas, unclosed comments, "
                            + "invalid JSON syntax."
                    )
                    outputJSON(errorOutput, logger: self.logger)
                } else {
                    print("[error] Configuration is invalid.")
                    print()
                    print("Common issues:")
                    print("  • Trailing commas in JSON")
                    print("  • Unclosed comments")
                    print("  • Invalid JSON syntax")
                    print()
                    print("Run 'peekaboo config show' to view the raw file.")
                }
                throw ExitCode.failure
            }

            if self.jsonOutput {
                let data: [String: Any] = [
                    "valid": true,
                    "message": "Configuration is valid",
                    "path": self.configPath,
                    "hasAIProviders": config.aiProviders != nil,
                    "hasDefaults": config.defaults != nil,
                    "hasLogging": config.logging != nil,
                ]
                let successOutput = SuccessOutput(success: true, data: data)
                outputJSON(successOutput, logger: self.logger)
            } else {
                print("[ok] Configuration is valid.")
                print()
                print("Detected sections:")
                if config.aiProviders != nil {
                    print("  ✓ AI Providers")
                }
                if config.defaults != nil {
                    print("  ✓ Defaults")
                }
                if config.logging != nil {
                    print("  ✓ Logging")
                }
            }
        }
    }
}
