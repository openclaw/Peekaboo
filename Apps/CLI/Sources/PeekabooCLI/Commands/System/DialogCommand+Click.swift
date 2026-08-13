import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension DialogCommand {
    // MARK: - Click Dialog Button

    @MainActor
    struct ClickSubcommand: ConfirmedActionOutputFormattable, InjectedRuntimeBackedCommand {
        @Option(help: "Button text to click (e.g., 'OK', 'Cancel', 'Save')")
        var button: String

        @Flag(help: "Focus the target before the exact AXPress action")
        var foreground = false

        @OptionGroup var target: InteractionTargetOptions
        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            var preparedReceipt: PreparedDialogActionReceipt?
            let buttonText = self.button
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .whenRequested(self.foreground, self.focusOptions),
                resolveWindowTitle: false,
                validate: {
                    guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                        throw ValidationError("Dialog focus options require --foreground")
                    }
                },
                prepareBeforeFocus: { context in
                    let request = try DialogActionPreparationRequest(
                        target: context.target,
                        kind: .clickButton,
                        buttonText: buttonText
                    )
                    preparedReceipt = try await context.services.dialogs.prepareDialogAction(request)
                },
                operation: { context in
                    guard let receipt = preparedReceipt else {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .runtimeIncompatible,
                            message: "Dialog click lost its prepared action receipt before execution.",
                            hint: "Prepare the dialog action again before retrying."
                        )
                    }
                    let result = try await context.services.dialogs.performPreparedDialogAction(receipt)
                    _ = try result.requiredPreparedOutcome(kind: .clickButton)

                    if self.jsonOutput {
                        let outputData = DialogClickResult(
                            action: "dialog_click",
                            button: result.details["button"] ?? self.button,
                            buttonIdentifier: result.details["button_identifier"],
                            window: result.details["window"] ?? "Dialog"
                        )
                        outputSuccessCodable(
                            data: outputData,
                            outcome: result.outcome,
                            logger: self.outputLogger
                        )
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
