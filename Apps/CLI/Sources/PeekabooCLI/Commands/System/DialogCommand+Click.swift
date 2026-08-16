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
            var preparationRequest: DialogActionPreparationRequest?
            var preparedReceipt: PreparedDialogActionReceipt?
            let buttonText = self.button
            let foreground = self.foreground
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .whenRequested(self.foreground, self.focusOptions),
                resolveWindowTitle: false,
                resolveAppHint: false,
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
                    preparationRequest = request
                    guard !foreground else { return }
                    preparedReceipt = try await context.services.dialogs.prepareDialogAction(request)
                },
                operation: { context in
                    let receipt: PreparedDialogActionReceipt
                    if let preparedReceipt {
                        receipt = preparedReceipt
                    } else {
                        guard let request = preparationRequest else {
                            throw DesktopActionFailure.preDispatchRefusal(
                                reason: .invalidRequest,
                                message: "Dialog click lost its validated preparation request.",
                                hint: "Validate and prepare the dialog action again before retrying."
                            )
                        }
                        receipt = try await context.services.dialogs.prepareDialogAction(request)
                    }
                    let result = try await context.services.dialogs.performPreparedDialogAction(receipt)
                    let outcome: DesktopActionOutcome
                    do {
                        outcome = try result.requiredPreparedOutcome(kind: .clickButton)
                    } catch let failure as DesktopActionFailure {
                        throw failure.attributed(to: DialogCommand.targetReceipt(receipt.target))
                    }
                    let resultTarget: DesktopTargetIdentity
                    do {
                        guard let exactTarget = try DialogCommand.exactResultTargetIdentity(
                            from: result,
                            matching: context.target,
                            expectedTarget: receipt.target
                        )
                        else {
                            throw DesktopTargetIdentityError.incompleteExactWindow
                        }
                        resultTarget = exactTarget
                    } catch {
                        try context.actionSequence.recordExactTargetLeaf(
                            outcome: outcome,
                            targetIdentity: nil,
                            operation: "Dialog click"
                        )
                        throw error
                    }
                    try context.actionSequence.record(
                        outcome: outcome,
                        targetIdentity: resultTarget,
                        operation: "Dialog click"
                    )
                    let compositeResult = context.actionSequence.result(payload: ())

                    if self.jsonOutput {
                        let outputData = DialogClickResult(
                            action: "dialog_click",
                            button: result.details["button"] ?? self.button,
                            buttonIdentifier: result.details["button_identifier"],
                            window: result.details["window"] ?? "Dialog"
                        )
                        outputSuccessCodable(
                            data: outputData,
                            outcome: compositeResult.outcome,
                            targetIdentity: compositeResult.targetIdentity,
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
