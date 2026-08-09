import Commander
import Foundation
import PeekabooCore

extension DialogCommand {
    // MARK: - Click Dialog Button

    @MainActor
    struct ClickSubcommand {
        @Option(help: "Button text to click (e.g., 'OK', 'Cancel', 'Save')")
        var button: String

        @Flag(help: "Focus the target and allow foreground click fallback")
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
                guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                    throw ValidationError("Dialog focus options require --foreground")
                }
                if self.foreground {
                    if self.focusOptions.autoFocus {
                        self.resolvedRuntime.beginInteractionMutation()
                    }
                    try await ensureFocused(
                        snapshotId: nil,
                        target: self.target,
                        options: self.focusOptions,
                        services: self.services
                    )
                }

                let resolvedWindowTitle = try await self.target.resolveWindowTitleOptional(services: self.services)
                let appHint = try await DialogCommand.resolveDialogAppHint(target: self.target, services: self.services)

                self.resolvedRuntime.beginInteractionMutation()
                let result = try await self.services.dialogs.clickButton(
                    buttonText: self.button,
                    windowTitle: resolvedWindowTitle,
                    appName: appHint,
                    allowGlobalFallback: self.foreground
                )

                if self.jsonOutput {
                    let outputData = DialogClickResult(
                        action: "dialog_click",
                        button: result.details["button"] ?? self.button,
                        buttonIdentifier: result.details["button_identifier"],
                        window: result.details["window"] ?? "Dialog"
                    )
                    outputSuccessCodable(data: outputData, logger: self.outputLogger)
                } else {
                    print("✓ Clicked '\(result.details["button"] ?? self.button)' button")
                }
                AutomationEventLogger.log(
                    .dialog,
                    "action=click button='\(result.details["button"] ?? self.button)' "
                        + "window='\(result.details["window"] ?? resolvedWindowTitle ?? "unknown")' "
                        + "app='\(appHint ?? "unknown")'"
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

private struct DialogClickResult: Codable {
    let action: String
    let button: String
    let buttonIdentifier: String?
    let window: String

    enum CodingKeys: String, CodingKey {
        case action
        case button
        case buttonIdentifier = "button_identifier"
        case window
    }
}
