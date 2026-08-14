import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension DialogCommand {
    // MARK: - Dismiss Dialog

    @MainActor
    struct DismissSubcommand: ConfirmedActionOutputFormattable, InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "dismiss",
            abstract: "Dismiss a dialog using DialogService"
        )

        @Flag(help: "Force dismiss with Escape key")
        var force = false

        @Flag(help: "Focus the target before dismissal; required with --force")
        var foreground = false

        @OptionGroup var target: InteractionTargetOptions
        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            var preparationRequest: DialogActionPreparationRequest?
            var preparedReceipt: PreparedDialogActionReceipt?
            let force = self.force
            let foreground = self.foreground
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .whenRequested(self.foreground, self.focusOptions),
                resolveWindowTitle: self.force,
                validate: {
                    guard !self.force || self.foreground else {
                        throw ValidationError("dialog dismiss --force sends global Escape and requires --foreground")
                    }
                    guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                        throw ValidationError("Dialog focus options require --foreground")
                    }
                },
                prepareBeforeFocus: { context in
                    guard !force else { return }
                    let request = try DialogActionPreparationRequest(
                        target: context.target,
                        kind: .dismiss
                    )
                    preparationRequest = request
                    guard !foreground else { return }
                    preparedReceipt = try await context.services.dialogs.prepareDialogAction(request)
                },
                operation: { context in
                    let result: DialogActionResult
                    if self.force {
                        result = try await context.services.dialogs.dismissDialog(
                            force: true,
                            windowTitle: context.windowTitle,
                            appName: context.appHint
                        )
                    } else {
                        let receipt: PreparedDialogActionReceipt
                        if let preparedReceipt {
                            receipt = preparedReceipt
                        } else {
                            guard let request = preparationRequest else {
                                throw DesktopActionFailure.preDispatchRefusal(
                                    reason: .invalidRequest,
                                    message: "Dialog dismiss lost its validated preparation request.",
                                    hint: "Validate and prepare the dialog action again before retrying."
                                )
                            }
                            receipt = try await context.services.dialogs.prepareDialogAction(request)
                        }
                        result = try await context.services.dialogs.performPreparedDialogAction(receipt)
                        _ = try result.requiredPreparedOutcome(kind: .dismiss)
                    }

                    if self.jsonOutput {
                        let outputData = DialogDismissResult(
                            action: "dialog_dismiss",
                            method: result.details["method"] ?? "unknown",
                            button: result.details["button"]
                        )
                        outputSuccessCodable(
                            data: outputData,
                            effect: result.outcome == nil ? .confirmed : nil,
                            outcome: result.outcome,
                            logger: self.outputLogger
                        )
                    } else if result.details["method"] == "escape" {
                        print("✓ Dismissed dialog with Escape")
                    } else if let button = result.details["button"] {
                        print("✓ Dismissed dialog by clicking '\(button)'")
                    } else {
                        print("✓ Dismissed dialog")
                    }
                    let method = result.details["method"] ?? (self.force ? "escape" : "button")
                    let dismissedButton = result.details["button"] ?? "none"
                    AutomationEventLogger.log(
                        .dialog,
                        "action=dismiss method=\(method) button='\(dismissedButton)' "
                            + "app='\(context.appHint ?? "unknown")'"
                    )
                }
            )
        }
    }

    // MARK: - List Dialog Elements

    @MainActor
    struct ListSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "list",
            abstract: "List elements in current dialog using DialogService"
        )

        @Option(name: .customLong("timeout"), help: "Dialog-list timeout (bare values are milliseconds; default 5s)")
        var timeout: CLIDuration = .seconds(5)

        @OptionGroup var target: InteractionTargetOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let timeoutSeconds = self.timeout.seconds
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .none,
                resolveWindowTitle: false,
                beginsInteractionMutation: false,
                handlesValidationError: false,
                operation: { context in
                    let elements = try await withMainActorCommandTimeout(
                        seconds: timeoutSeconds,
                        operationName: "dialog list"
                    ) {
                        if context.target.hasTarget {
                            try await context.services.dialogs.listDialogElements(target: context.target)
                        } else {
                            try await context.services.dialogs.listDialogElements(
                                windowTitle: nil,
                                appName: nil
                            )
                        }
                    }

                    if self.jsonOutput {
                        let textFields = elements.textFields.map { field in
                            DialogListResult.TextField(
                                title: field.title ?? "",
                                value: field.value ?? "",
                                placeholder: field.placeholder ?? ""
                            )
                        }
                        let outputData = DialogListResult(
                            title: elements.dialogInfo.title,
                            role: elements.dialogInfo.role,
                            buttons: elements.buttons.map(\.title),
                            textFields: textFields,
                            textElements: elements.staticTexts
                        )
                        outputSuccessCodable(data: outputData, logger: self.outputLogger)
                    } else {
                        print("Dialog: \(elements.dialogInfo.title)")

                        if !elements.buttons.isEmpty {
                            print("\nButtons:")
                            elements.buttons.forEach { print("  • \($0.title)") }
                        }

                        if !elements.textFields.isEmpty {
                            print("\nText Fields:")
                            for field in elements.textFields {
                                let title = field.title ?? "Untitled"
                                let placeholder = field.placeholder ?? ""
                                print("  • \(title) [\(placeholder)]")
                            }
                        }

                        if !elements.staticTexts.isEmpty {
                            print("\nText:")
                            elements.staticTexts.forEach { print("  \($0)") }
                        }
                    }
                    AutomationEventLogger.log(
                        .dialog,
                        "action=list title='\(elements.dialogInfo.title)' buttons=\(elements.buttons.count) "
                            + "text_fields=\(elements.textFields.count) app='\(context.appHint ?? "unknown")'"
                    )
                }
            )
        }
    }
}

private struct DialogDismissResult: Codable {
    let action: String
    let method: String
    let button: String?
}

private struct DialogListResult: Codable {
    let title: String
    let role: String
    let buttons: [String]
    let textFields: [TextField]
    let textElements: [String]

    struct TextField: Codable {
        let title: String
        let value: String
        let placeholder: String
    }
}
