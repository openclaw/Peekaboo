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
            let dialogTarget = try self.target.dialogTargetSelector()
            var preparationRequest: DialogActionPreparationRequest?
            var preparedReceipt: PreparedDialogActionReceipt?
            let force = self.force
            let foreground = self.foreground
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: self.force
                    ? .required(self.focusOptions)
                    : .whenRequested(self.foreground, self.focusOptions),
                resolveWindowTitle: self.force && !dialogTarget.hasTarget,
                resolveAppHint: self.force && !dialogTarget.hasTarget,
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
                    let outcome: DesktopActionOutcome
                    var targetIdentity: DesktopTargetIdentity?
                    if self.force {
                        if context.target.hasTarget {
                            result = try await context.services.dialogs.forceDismissDialog(
                                DialogForcedDismissExecutionRequest(
                                    target: context.target,
                                    focus: DialogForegroundFocusPolicy(
                                        autoFocus: self.focusOptions.autoFocus,
                                        timeout: self.focusOptions.focusTimeout ?? 5,
                                        retryCount: self.focusOptions.focusRetryCount ?? 3,
                                        switchSpace: self.focusOptions.spaceSwitch,
                                        bringToCurrentSpace: self.focusOptions.bringToCurrentSpace
                                    )
                                )
                            )
                        } else {
                            result = try await context.services.dialogs.dismissDialog(
                                force: true,
                                windowTitle: context.windowTitle,
                                appName: context.appHint
                            )
                        }
                        outcome = result.foregroundOutcomeOrUnverified(
                            route: context.services.dialogs.foregroundOutcomeRoute
                        )
                        if context.target.hasTarget {
                            do {
                                guard let exactTarget = try DialogCommand.exactResultTargetIdentity(
                                    from: result,
                                    matching: context.target
                                )
                                else {
                                    throw DesktopTargetIdentityError.incompleteExactWindow
                                }
                                targetIdentity = exactTarget
                            } catch {
                                try context.actionSequence.recordExactTargetLeaf(
                                    outcome: outcome,
                                    targetIdentity: nil,
                                    operation: "Dialog dismissal"
                                )
                                throw error
                            }
                        }
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
                        do {
                            outcome = try result.requiredPreparedOutcome(kind: .dismiss)
                        } catch let failure as DesktopActionFailure {
                            throw failure.attributed(to: receipt.target.actionTargetReceipt)
                        }
                        do {
                            guard let exactTarget = try DialogCommand.exactResultTargetIdentity(
                                from: result,
                                matching: context.target,
                                expectedTarget: receipt.target
                            )
                            else {
                                throw DesktopTargetIdentityError.incompleteExactWindow
                            }
                            targetIdentity = exactTarget
                        } catch {
                            try context.actionSequence.recordExactTargetLeaf(
                                outcome: outcome,
                                targetIdentity: nil,
                                operation: "Dialog dismissal"
                            )
                            throw error
                        }
                    }
                    try context.actionSequence.record(
                        outcome: outcome,
                        targetIdentity: targetIdentity,
                        operation: "Dialog dismissal"
                    )
                    let compositeResult = context.actionSequence.result(payload: ())

                    self.outputDismissResult(
                        result,
                        compositeResult: compositeResult,
                        outcome: outcome,
                        appHint: context.appHint
                    )
                }
            )
        }

        private func outputDismissResult(
            _ result: DialogActionResult,
            compositeResult: UIAutomationActionResult<Void>,
            outcome: DesktopActionOutcome,
            appHint: String?
        ) {
            if self.jsonOutput {
                let outputData = DialogDismissResult(
                    action: "dialog_dismiss",
                    method: result.details["method"] ?? "unknown",
                    button: result.details["button"],
                    pid: result.details["pid"].flatMap(Int32.init),
                    process_start_identity: result.details["process_start_identity"].flatMap(UInt64.init),
                    process_start_identity_decimal: result.details["process_start_identity_decimal"],
                    window_id: result.details["window_id"].flatMap(Int.init)
                )
                outputSuccessCodable(
                    data: outputData,
                    outcome: compositeResult.outcome,
                    targetIdentity: compositeResult.targetIdentity,
                    logger: self.outputLogger
                )
            } else {
                print(ActionOutcomeHumanRenderer.statusLine(
                    for: compositeResult.outcome ?? outcome,
                    operation: "Dialog dismissal"
                ))
            }
            let method = result.details["method"] ?? (self.force ? "escape" : "button")
            let dismissedButton = result.details["button"] ?? "none"
            AutomationEventLogger.log(
                .dialog,
                "action=dismiss method=\(method) button='\(dismissedButton)' "
                    + "app='\(appHint ?? "unknown")'"
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
                resolveAppHint: false,
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
                    let targetIdentity = try DialogCommand.exactListTargetIdentity(
                        from: elements,
                        matching: context.target
                    )

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
                        outputSuccessCodable(
                            data: outputData,
                            targetIdentity: targetIdentity,
                            logger: self.outputLogger
                        )
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
    let pid: Int32?
    let process_start_identity: UInt64?
    let process_start_identity_decimal: String?
    let window_id: Int?
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
