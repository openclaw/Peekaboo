import Commander
import Foundation
import PeekabooCore

extension DialogCommand {
    // MARK: - Click Dialog Button

    @MainActor
    struct ClickSubcommand: InjectedRuntimeBackedCommand {
        @Option(help: "Button text to click (e.g., 'OK', 'Cancel', 'Save')")
        var button: String

        @Flag(help: "Focus the target and allow foreground click fallback")
        var foreground = false

        @OptionGroup var target: InteractionTargetOptions
        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .whenRequested(self.foreground, self.focusOptions),
                validate: {
                    guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                        throw ValidationError("Dialog focus options require --foreground")
                    }
                },
                operation: { context in
                    let result = try await context.services.dialogs.clickButton(
                        buttonText: self.button,
                        windowTitle: context.windowTitle,
                        appName: context.appHint,
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
                            + "window='\(result.details["window"] ?? context.windowTitle ?? "unknown")' "
                            + "app='\(context.appHint ?? "unknown")'"
                    )
                }
            )
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
