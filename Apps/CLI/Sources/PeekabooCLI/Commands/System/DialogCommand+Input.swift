import Commander
import Foundation
import PeekabooCore

extension DialogCommand {
    // MARK: - Input Text in Dialog

    @MainActor
    struct InputSubcommand {
        static let commandDescription = CommandDescription(
            commandName: "input",
            abstract: "Enter text in a dialog field using DialogService"
        )

        @Option(help: "Text to enter")
        var text: String

        @Option(help: "Field label or placeholder to target")
        var field: String?

        @Option(help: "Field index (0-based) if multiple fields")
        var index: Int?

        @Flag(help: "Clear existing text first")
        var clear = false

        @Flag(help: "Focus the dialog before sending keyboard input")
        var foreground = false

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
                    throw ValidationError("dialog input sends keyboard input and requires --foreground")
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

                let resolvedWindowTitle = try await self.target.resolveWindowTitleOptional(services: self.services)
                let appHint = try await DialogCommand.resolveDialogAppHint(target: self.target, services: self.services)

                let fieldIdentifier = self.field ?? self.index.map { String($0) }
                self.resolvedRuntime.beginInteractionMutation()
                let result = try await self.services.dialogs.enterText(
                    text: self.text,
                    fieldIdentifier: fieldIdentifier,
                    clearExisting: self.clear,
                    windowTitle: resolvedWindowTitle,
                    appName: appHint
                )

                if self.jsonOutput {
                    let outputData = DialogInputResult(
                        action: "dialog_input",
                        field: result.details["field"] ?? "Text Field",
                        textLength: result.details["text_length"] ?? String(self.text.count),
                        cleared: result.details["cleared"] ?? String(self.clear)
                    )
                    outputSuccessCodable(data: outputData, logger: self.outputLogger)
                } else {
                    print("✓ Entered text in '\(result.details["field"] ?? "field")'")
                }
                let fieldDescription = result.details["field"]
                    ?? self.field
                    ?? self.index.map { "index \($0)" }
                    ?? "field"
                let textLength = result.details["text_length"] ?? String(self.text.count)
                let clearedValue = result.details["cleared"] ?? String(self.clear)
                AutomationEventLogger.log(
                    .dialog,
                    "action=input field='\(fieldDescription)' chars=\(textLength) "
                        + "cleared=\(clearedValue) app='\(appHint ?? "unknown")'"
                )

            } catch let error as Commander.ValidationError {
                handleDialogValidationError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch let error as DialogError {
                handleDialogServiceError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch {
                handleGenericError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            }
        }
    }
}

private struct DialogInputResult: Codable {
    let action: String
    let field: String
    let textLength: String
    let cleared: String
}
