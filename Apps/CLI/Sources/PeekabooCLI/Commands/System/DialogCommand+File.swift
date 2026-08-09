import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension DialogCommand {
    // MARK: - Handle File Dialog

    @MainActor
    struct FileSubcommand {
        static let commandDescription = CommandDescription(
            commandName: "file",
            abstract: "Handle file save/open dialogs using DialogService"
        )

        @Option(help: "Full file path to navigate to")
        var path: String?

        @Option(help: "File name to enter (for save dialogs)")
        var name: String?

        @Option(help: "Button to click after entering path/name. Omit (or pass 'default') to click the OKButton.")
        var select: String?

        @Flag(name: .long, help: "Ensure file dialogs are expanded (Show Details) before setting --path")
        var ensureExpanded = false

        @Flag(help: "Focus the file dialog before keyboard or coordinate interaction")
        var foreground = false

        @Option(help: "Maximum time to spend handling the file dialog")
        var timeoutSeconds: TimeInterval = 20

        @OptionGroup var target: InteractionTargetOptions
        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage private var runtime: CommandRuntime?

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        private var services: any PeekabooServiceProviding {
            self.resolvedRuntime.services
        }

        private var logger: Logger {
            self.resolvedRuntime.logger
        }

        var outputLogger: Logger {
            self.logger
        }

        var jsonOutput: Bool {
            self.resolvedRuntime.configuration.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.target.validate()
                guard self.foreground else {
                    throw ValidationError("dialog file uses keyboard/coordinate interaction and requires --foreground")
                }
                if self.focusOptions.autoFocus {
                    self.resolvedRuntime.beginInteractionMutation()
                }
                try await ensureFocused(
                    snapshotId: nil,
                    target: self.target,
                    options: self.focusOptions,
                    services: self.services
                )

                let appHint = try await DialogCommand.resolveDialogAppHint(target: self.target, services: self.services)
                let dialogs = self.services.dialogs
                let path = self.path
                let name = self.name
                let select = self.select
                let ensureExpanded = self.ensureExpanded

                self.resolvedRuntime.beginInteractionMutation()
                let result = try await withMainActorCommandTimeout(
                    seconds: self.timeoutSeconds,
                    operationName: "dialog file",
                    desktopMutationWatermarkStore: DesktopMutationWatermarkStore()
                ) {
                    try await dialogs.handleFileDialog(
                        path: path,
                        filename: name,
                        actionButton: select,
                        ensureExpanded: ensureExpanded,
                        appName: appHint
                    )
                }

                if self.jsonOutput {
                    outputSuccessCodable(data: self.makeOutput(from: result), logger: self.outputLogger)
                } else {
                    print("✓ Handled file dialog")
                    if let path = result.details["path"] {
                        print("  Path: \(path)")
                    }
                    if let name = result.details["filename"] {
                        print("  Name: \(name)")
                    }
                    print("  Action: \(result.details["button_clicked"] ?? self.select ?? "default")")
                    if let savedPath = result.details["saved_path"], result.details["saved_path_exists"] == "true" {
                        print("  Saved: \(savedPath)")
                    }
                }
                let resolvedPath = result.details["path"] ?? self.path ?? "unknown"
                let resolvedName = result.details["filename"] ?? self.name ?? "unknown"
                let buttonClicked = result.details["button_clicked"] ?? self.select ?? "default"
                let savedPath = result.details["saved_path"] ?? "unknown"
                let savedPathVerified = result.details["saved_path_exists"] ?? "unknown"
                AutomationEventLogger.log(
                    .dialog,
                    "action=file path='\(resolvedPath)' name='\(resolvedName)' "
                        + "button='\(buttonClicked)' saved_path='\(savedPath)' "
                        + "saved_path_verified=\(savedPathVerified) app='\(appHint ?? "unknown")'"
                )

            } catch let error as Commander.ValidationError {
                handleDialogValidationError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch let error as DialogError {
                handleDialogServiceError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch let error as PeekabooError {
                let code: ErrorCode = switch error {
                case .timeout:
                    .TIMEOUT
                case .invalidInput:
                    .INVALID_INPUT
                default:
                    .UNKNOWN_ERROR
                }
                if self.jsonOutput {
                    outputError(message: error.localizedDescription, code: code, logger: self.outputLogger)
                } else {
                    fputs("❌ \(error.localizedDescription)\n", stderr)
                }
                throw ExitCode(1)
            } catch {
                handleGenericError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            }
        }

        private func makeOutput(from result: DialogActionResult) -> FileDialogResult {
            let savedPathVerified =
                result.details["saved_path_verified"] == "true" || result.details["saved_path_exists"] == "true"

            return FileDialogResult(
                action: "file_dialog",
                dialogIdentifier: result.details["dialog_identifier"],
                foundVia: result.details["found_via"],
                path: result.details["path"],
                pathNavigationMethod: result.details["path_navigation_method"],
                name: result.details["filename"],
                buttonClicked: result.details["button_clicked"] ?? self.select ?? "default",
                buttonIdentifier: result.details["button_identifier"],
                savedPath: result.details["saved_path"],
                savedPathVerified: savedPathVerified,
                savedPathFoundVia: result.details["saved_path_found_via"],
                savedPathMatchesExpected: result.details["saved_path_matches_expected"].map { $0 == "true" },
                savedPathExpected: result.details["saved_path_expected"],
                savedPathMatchesExpectedDirectory: result.details["saved_path_matches_expected_directory"]
                    .map { $0 == "true" },
                savedPathExpectedDirectory: result.details["saved_path_expected_directory"],
                savedPathDirectory: result.details["saved_path_directory"],
                overwriteConfirmed: result.details["overwrite_confirmed"].map { $0 == "true" },
                ensureExpanded: result.details["ensure_expanded"].map { $0 == "true" }
            )
        }
    }
}

private struct FileDialogResult: Codable {
    let action: String
    let dialogIdentifier: String?
    let foundVia: String?
    let path: String?
    let pathNavigationMethod: String?
    let name: String?
    let buttonClicked: String
    let buttonIdentifier: String?
    let savedPath: String?
    let savedPathVerified: Bool
    let savedPathFoundVia: String?
    let savedPathMatchesExpected: Bool?
    let savedPathExpected: String?
    let savedPathMatchesExpectedDirectory: Bool?
    let savedPathExpectedDirectory: String?
    let savedPathDirectory: String?
    let overwriteConfirmed: Bool?
    let ensureExpanded: Bool?

    enum CodingKeys: String, CodingKey {
        case action
        case dialogIdentifier = "dialog_identifier"
        case foundVia = "found_via"
        case path
        case pathNavigationMethod = "path_navigation_method"
        case name
        case buttonClicked
        case buttonIdentifier = "button_identifier"
        case savedPath
        case savedPathVerified
        case savedPathFoundVia = "saved_path_found_via"
        case savedPathMatchesExpected = "saved_path_matches_expected"
        case savedPathExpected = "saved_path_expected"
        case savedPathMatchesExpectedDirectory = "saved_path_matches_expected_directory"
        case savedPathExpectedDirectory = "saved_path_expected_directory"
        case savedPathDirectory = "saved_path_directory"
        case overwriteConfirmed = "overwrite_confirmed"
        case ensureExpanded = "ensure_expanded"
    }
}
