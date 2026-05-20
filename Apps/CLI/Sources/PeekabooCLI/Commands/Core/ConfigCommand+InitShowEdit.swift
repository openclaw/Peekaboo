import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
@MainActor
extension ConfigCommand {
    /// Create a default configuration file.
    struct InitCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "init",
            abstract: "Create a default configuration file"
        )

        @Flag(name: .long, help: "Force overwrite existing configuration")
        var force = false
        @Option(name: .customLong("timeout"), help: "Validation timeout in seconds (default 30)")
        var timeoutSeconds: Double = 30
        @RuntimeStorage var runtime: CommandRuntime?

        private var io: ConfigCommandOutput {
            self.output
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            let path = self.configPath
            try self.ensureWritableConfig(at: path)
            try self.createConfiguration(at: path)
            if !self.jsonOutput {
                let reporter = ProviderStatusReporter(timeoutSeconds: self.timeoutSeconds)
                await reporter.printSummary()
            }
        }

        private func ensureWritableConfig(at path: String) throws {
            guard FileManager.default.fileExists(atPath: path), !self.force else { return }
            self.io.error(
                code: "FILE_IO_ERROR",
                message: "Configuration file already exists. Use --force to overwrite.",
                details: "Path: \(path)",
                textLines: [
                    "Configuration file already exists at: \(path)",
                    "Use --force to overwrite."
                ]
            )
            throw ExitCode.failure
        }

        private func createConfiguration(at path: String) throws {
            do {
                try self.configManager.createDefaultConfiguration()
                self.io.success(
                    message: "Configuration file created successfully",
                    data: ["path": path],
                    textLines: TKConfigMessages.initGuidance.map { $0.replacingOccurrences(of: "{path}", with: path) }
                )
            } catch {
                self.io.error(
                    code: "FILE_IO_ERROR",
                    message: error.localizedDescription,
                    details: "Path: \(path)",
                    textLines: ["[error] Failed to create configuration file: \(error)"]
                )
                throw ExitCode.failure
            }
        }
    }

    /// Display the current configuration.
    struct ShowCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "show",
            abstract: "Display current configuration"
        )

        @Flag(name: .long, help: "Show effective configuration (merged with environment)")
        var effective = false
        @Option(name: .customLong("timeout"), help: "Validation timeout in seconds (default 30)")
        var timeoutSeconds: Double = 30
        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            if !self.effective {
                try self.showRawConfiguration()
                return
            }

            try self.showEffectiveConfiguration()
            if !self.jsonOutput {
                let reporter = ProviderStatusReporter(timeoutSeconds: self.timeoutSeconds)
                await reporter.printSummary()
            }
        }

        private func showRawConfiguration() throws {
            guard FileManager.default.fileExists(atPath: self.configPath) else {
                if self.jsonOutput {
                    outputError(
                        message: "No configuration file found",
                        code: .FILE_IO_ERROR,
                        details: "Path: \(self.configPath). Run 'peekaboo config init' to create one.",
                        logger: self.logger
                    )
                } else {
                    print("No configuration file found at: \(self.configPath)")
                    print("Run 'peekaboo config init' to create one.")
                }
                throw ExitCode.failure
            }

            do {
                let contents = try String(contentsOfFile: self.configPath, encoding: .utf8)
                if self.jsonOutput {
                    guard let config = self.configManager.loadConfiguration() else {
                        outputError(
                            message: "Failed to parse configuration file",
                            code: .FILE_IO_ERROR,
                            logger: self.logger
                        )
                        throw ExitCode.failure
                    }

                    outputSuccessCodable(data: config, logger: self.logger)
                } else {
                    print(contents)
                }
            } catch {
                if error is ExitCode {
                    throw error
                }

                if self.jsonOutput {
                    outputError(
                        message: error.localizedDescription,
                        code: .FILE_IO_ERROR,
                        logger: self.logger
                    )
                } else {
                    print("Failed to read configuration file: \(error)")
                }
                throw ExitCode.failure
            }
        }

        private func showEffectiveConfiguration() throws {
            _ = self.configManager.loadConfiguration()

            let effectiveConfig: [String: Any] = [
                "aiProviders": [
                    "providers": self.configManager.getAIProviders(),
                    "openaiApiKey": self.configManager.getOpenAIAPIKey() != nil ? "***SET***" : "NOT SET",
                    "ollamaBaseUrl": self.configManager.getOllamaBaseURL(),
                ],
                "defaults": [
                    "savePath": self.configManager.getDefaultSavePath(),
                ],
                "logging": [
                    "level": self.configManager.getLogLevel(),
                    "path": self.configManager.getLogPath(),
                ],
                "configFile": FileManager.default.fileExists(atPath: self.configPath) ? self.configPath : "NOT FOUND",
                "credentialsFile": FileManager.default.fileExists(atPath: self.credentialsPath) ? self
                    .credentialsPath : "NOT FOUND",
            ]

            if self.jsonOutput {
                let successOutput = SuccessOutput(
                    success: true,
                    data: effectiveConfig,
                    debugLogs: self.logger.getDebugLogs()
                )
                outputJSON(successOutput, logger: self.logger)
            } else {
                print("Effective Configuration (after merging all sources):")
                print(String(repeating: "=", count: 50))
                print()
                print("AI Providers:")
                print("  Providers: \(self.configManager.getAIProviders())")
                print("  OpenAI API Key: \(self.configManager.getOpenAIAPIKey() != nil ? "***SET***" : "NOT SET")")
                print("  Ollama Base URL: \(self.configManager.getOllamaBaseURL())")
                print()
                print("Defaults:")
                print("  Save Path: \(self.configManager.getDefaultSavePath())")
                print()
                print("Logging:")
                print("  Level: \(self.configManager.getLogLevel())")
                print("  Path: \(self.configManager.getLogPath())")
                print()
                print("Files:")
                let configFilePath = FileManager.default.fileExists(atPath: self.configPath)
                    ? self.configPath
                    : "NOT FOUND"
                let credentialsFilePath = FileManager.default.fileExists(atPath: self.credentialsPath)
                    ? self.credentialsPath
                    : "NOT FOUND"

                print("  Config File: \(configFilePath)")
                print("  Credentials: \(credentialsFilePath)")
            }
        }
    }

    /// Display configured provider credential status.
    struct StatusCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "status",
            abstract: "Display provider credential status"
        )

        @Option(name: .customLong("timeout"), help: "Validation timeout in seconds (default 30)")
        var timeoutSeconds: Double = 30
        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)
            let reporter = ProviderStatusReporter(timeoutSeconds: self.timeoutSeconds)
            if self.jsonOutput {
                let summary = await reporter.summary()
                let response = ProviderStatusResponse(
                    success: true,
                    data: summary,
                    debugLogs: self.logger.getDebugLogs()
                )
                outputJSON(response, logger: self.logger)
            } else {
                await reporter.printSummary()
            }
        }
    }

    /// Open configuration in an editor.
    struct EditCommand: ConfigRuntimeCommand {
        static let commandDescription = CommandDescription(
            commandName: "edit",
            abstract: "Open configuration file in your default editor"
        )

        @Option(name: .long, help: "Editor to use (defaults to $EDITOR or nano)")
        var editor: String?
        @Flag(name: .customLong("print-path"), help: "Print the configuration path and exit without opening an editor")
        var printPath: Bool = false
        @RuntimeStorage var runtime: CommandRuntime?

        mutating func run(using runtime: CommandRuntime) async throws {
            self.prepare(using: runtime)

            if self.printPath {
                print(self.configPath)
                return
            }

            // Create config if it doesn't exist
            if !FileManager.default.fileExists(atPath: self.configPath) {
                if self.jsonOutput {
                    let data: [String: Any] = [
                        "message": "Creating default configuration file",
                        "path": self.configPath,
                    ]
                    let successOutput = SuccessOutput(success: true, data: data)
                    outputJSON(successOutput, logger: self.logger)
                } else {
                    print("No configuration file found. Creating default configuration...")
                }

                try self.configManager.createDefaultConfiguration()
            }

            let editorCommand = self.editor ?? self.defaultEditor()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editorCommand, self.configPath]

            do {
                try process.run()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else {
                    if self.jsonOutput {
                        let errorOutput = ErrorOutput(
                            error: true,
                            code: "EDITOR_FAILED",
                            message: "Editor exited with status \(process.terminationStatus)",
                            details: editorCommand
                        )
                        outputJSON(errorOutput, logger: self.logger)
                    } else {
                        print("[error] Editor exited with status \(process.terminationStatus)")
                    }
                    throw ExitCode.failure
                }

                if self.jsonOutput {
                    let data: [String: Any] = [
                        "message": "Configuration edited successfully",
                        "editor": editorCommand,
                        "path": self.configPath,
                    ]
                    let successOutput = SuccessOutput(success: true, data: data)
                    outputJSON(successOutput, logger: self.logger)
                } else {
                    print("[ok] Configuration saved.")

                    // Validate the edited configuration
                    if self.configManager.loadConfiguration() != nil {
                        print("[ok] Configuration is valid.")
                    } else {
                        print("[warn] Configuration may be invalid. Please check your changes.")
                    }
                }
            } catch {
                if self.jsonOutput {
                    let errorOutput = ErrorOutput(
                        error: true,
                        code: "FILE_IO_ERROR",
                        message: error.localizedDescription,
                        details: nil
                    )
                    outputJSON(errorOutput, logger: self.logger)
                } else {
                    print("Failed to open editor: \(error)")
                }
                throw ExitCode.failure
            }
        }
    }
}

private struct ProviderStatusResponse: Encodable {
    let success: Bool
    let data: ProviderStatusSummary
    let debugLogs: [String]

    enum CodingKeys: String, CodingKey {
        case success, data
        case debugLogs = "debug_logs"
    }
}
