import Commander
import Foundation
import PeekabooCore

extension DialogCommand {
    // MARK: - Dismiss Dialog

    @MainActor
    struct DismissSubcommand: InjectedRuntimeBackedCommand {
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
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .whenRequested(self.foreground, self.focusOptions),
                validate: {
                    guard !self.force || self.foreground else {
                        throw ValidationError("dialog dismiss --force sends global Escape and requires --foreground")
                    }
                    guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                        throw ValidationError("Dialog focus options require --foreground")
                    }
                },
                operation: { context in
                    let result = try await context.services.dialogs.dismissDialog(
                        force: self.force,
                        windowTitle: context.windowTitle,
                        appName: context.appHint
                    )

                    if self.jsonOutput {
                        let outputData = DialogDismissResult(
                            action: "dialog_dismiss",
                            method: result.details["method"] ?? "unknown",
                            button: result.details["button"]
                        )
                        outputSuccessCodable(data: outputData, logger: self.outputLogger)
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
                beginsInteractionMutation: false,
                handlesValidationError: false,
                operation: { context in
                    let elements = try await withMainActorCommandTimeout(
                        seconds: timeoutSeconds,
                        operationName: "dialog list"
                    ) {
                        try await context.services.dialogs.listDialogElements(
                            windowTitle: context.windowTitle,
                            appName: context.appHint
                        )
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
