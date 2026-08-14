import Commander
import Foundation
import PeekabooCore

extension DialogCommand {
    // MARK: - Input Text in Dialog

    @MainActor
    struct InputSubcommand: ConfirmedActionOutputFormattable, InjectedRuntimeBackedCommand {
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
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let dialogTarget = try self.target.dialogTargetSelector()
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                // DialogService must prepare the exact parent/dialog tuple before focus so an
                // attached sheet can be verified without widening generic window focus.
                focus: dialogTarget.hasTarget ? .none : .required(self.focusOptions),
                resolveWindowTitle: false,
                resolveAppHint: false,
                validate: {
                    guard self.foreground else {
                        throw ValidationError("dialog input sends keyboard input and requires --foreground")
                    }
                },
                operation: { context in
                    let fieldIdentifier = self.field ?? self.index.map { String($0) }
                    let result: DialogActionResult
                    if context.target.hasTarget {
                        let request = try DialogInputExecutionRequest(
                            target: context.target,
                            text: self.text,
                            fieldIdentifier: fieldIdentifier,
                            clearExisting: self.clear,
                            focus: DialogForegroundFocusPolicy(
                                autoFocus: self.focusOptions.autoFocus,
                                timeout: self.focusOptions.focusTimeout ?? 5,
                                retryCount: self.focusOptions.focusRetryCount ?? 3,
                                switchSpace: self.focusOptions.spaceSwitch,
                                bringToCurrentSpace: self.focusOptions.bringToCurrentSpace
                            )
                        )
                        result = try await context.services.dialogs.enterText(request)
                    } else {
                        result = try await context.services.dialogs.enterText(DialogLegacyInputExecutionRequest(
                            text: self.text,
                            fieldIdentifier: fieldIdentifier,
                            clearExisting: self.clear,
                            windowTitle: nil,
                            appName: nil,
                            focus: DialogForegroundFocusPolicy(
                                autoFocus: self.focusOptions.autoFocus,
                                timeout: self.focusOptions.focusTimeout ?? 5,
                                retryCount: self.focusOptions.focusRetryCount ?? 3,
                                switchSpace: self.focusOptions.spaceSwitch,
                                bringToCurrentSpace: self.focusOptions.bringToCurrentSpace
                            )
                        ))
                    }
                    let outcome = result.foregroundOutcomeOrUnverified(
                        route: context.services.dialogs.foregroundOutcomeRoute
                    )
                    let targetReceipt = result.targetReceipt

                    if self.jsonOutput {
                        let outputData = DialogInputResult(
                            action: "dialog_input",
                            field: result.details["field"] ?? "Text Field",
                            textLength: result.details["text_length"] ?? String(self.text.count),
                            cleared: result.details["cleared"] ?? String(self.clear),
                            valueVerified: result.details["value_verified"].flatMap { Swift.Bool($0) },
                            dialogIdentifier: result.details["dialog_identifier"],
                            dialogRole: result.details["dialog_role"],
                            pid: targetReceipt?.processIdentifier
                                ?? result.details["pid"].flatMap(Int32.init),
                            processStartIdentity: targetReceipt?.processStartIdentity
                                ?? result.details["process_start_identity"].flatMap(UInt64.init),
                            processStartIdentityDecimal: targetReceipt.map {
                                String($0.processStartIdentity)
                            } ?? result.details["process_start_identity_decimal"],
                            windowID: targetReceipt?.windowID
                                ?? result.details["window_id"].flatMap(Int.init)
                        )
                        outputSuccessCodable(
                            data: outputData,
                            outcome: outcome,
                            logger: self.outputLogger
                        )
                    } else {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Dialog input"))
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
                            + "cleared=\(clearedValue) "
                            + "pid='\(targetReceipt?.processIdentifier.description ?? "unknown")'"
                    )
                }
            )
        }
    }
}

private struct DialogInputResult: Codable {
    let action: String
    let field: String
    let textLength: String
    let cleared: String
    let valueVerified: Bool?
    let dialogIdentifier: String?
    let dialogRole: String?
    let pid: Int32?
    let processStartIdentity: UInt64?
    let processStartIdentityDecimal: String?
    let windowID: Int?

    enum CodingKeys: String, CodingKey {
        case action
        case field
        case textLength
        case cleared
        case valueVerified = "value_verified"
        case dialogIdentifier = "dialog_identifier"
        case dialogRole = "dialog_role"
        case pid
        case processStartIdentity = "process_start_identity"
        case processStartIdentityDecimal = "process_start_identity_decimal"
        case windowID = "window_id"
    }
}
