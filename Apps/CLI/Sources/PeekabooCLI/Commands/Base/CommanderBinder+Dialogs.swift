import Commander
import Foundation

extension CommanderCLIBinder {
    static func applyDialogRuntimeOptions(
        _ options: inout CommandRuntimeOptions,
        _ commandType: (any ParsableCommand.Type)?,
        _ values: CommanderBindableValues,
        _ servesDynamicTools: Bool
    ) throws {
        options.requiresTargetedDialogList = false
        if commandType == DialogCommand.ListSubcommand.self {
            options.requiresTargetedDialogList = try values.makeInteractionTargetOptions().hasAnyTarget
        }
        options.requiresPreparedDialogClick = commandType == DialogCommand.ClickSubcommand.self
        options.requiresPreparedDialogDismiss = commandType == DialogCommand.DismissSubcommand.self &&
            !values.flag("force")
        if servesDynamicTools {
            options.requiresTargetedDialogList = true
            options.requiresPreparedDialogClick = true
            options.requiresPreparedDialogDismiss = true
        }
    }

    static func validateDialogBeforeRuntimeResolution(
        _ commandType: (any ParsableCommand.Type)?,
        values: CommanderBindableValues
    ) throws {
        let isDialogCommand = commandType == DialogCommand.ClickSubcommand.self ||
            commandType == DialogCommand.InputSubcommand.self ||
            commandType == DialogCommand.FileSubcommand.self ||
            commandType == DialogCommand.DismissSubcommand.self ||
            commandType == DialogCommand.ListSubcommand.self
        guard isDialogCommand else { return }

        let target: InteractionTargetOptions
        do {
            target = try values.makeInteractionTargetOptions()
        } catch {
            throw PreDispatchActionError(
                message: error.localizedDescription,
                code: .VALIDATION_ERROR,
                hint: "Correct the dialog target selectors before retrying.",
                reason: .invalidRequest
            )
        }

        func refuse(_ message: String, hint: String) throws -> Never {
            throw PreDispatchActionError(
                message: message,
                code: .VALIDATION_ERROR,
                hint: hint,
                reason: .invalidRequest
            )
        }
        func requireTarget() throws {
            guard target.hasAnyTarget else {
                try refuse(
                    "Dialog mutations require an explicit app, PID, or window target.",
                    hint: "Add --app, --pid, or --window-id after listing the dialog."
                )
            }
        }
        func rejectForegroundOptionsWithoutConsent() throws {
            let usesForegroundOption = values.flag("spaceSwitch") ||
                values.flag("bringToCurrentSpace") || values.flag("noAutoFocus")
            if usesForegroundOption, !values.flag("foreground") {
                try refuse(
                    "Dialog focus options require --foreground.",
                    hint: "Remove the focus option or explicitly authorize foreground interaction."
                )
            }
        }

        if commandType == DialogCommand.ClickSubcommand.self {
            try requireTarget()
            let button = values.singleOption("button")?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard button?.isEmpty == false else {
                try refuse(
                    "Dialog click requires a nonempty button name.",
                    hint: "Run dialog list and pass one exact --button value."
                )
            }
            try rejectForegroundOptionsWithoutConsent()
        } else if commandType == DialogCommand.InputSubcommand.self {
            if !target.hasAnyTarget, !values.flag("foreground") {
                try refuse(
                    "Targetless dialog input uses keyboard interaction and requires --foreground.",
                    hint: "Add an exact target for background AXValue input or authorize --foreground."
                )
            }
            try rejectForegroundOptionsWithoutConsent()
        } else if commandType == DialogCommand.FileSubcommand.self {
            guard values.flag("foreground") else {
                try refuse(
                    "Dialog file interaction requires --foreground.",
                    hint: "Add --foreground to authorize keyboard and coordinate interaction."
                )
            }
        } else if commandType == DialogCommand.DismissSubcommand.self {
            if values.flag("force") {
                guard values.flag("foreground") else {
                    try refuse(
                        "Forced dialog dismissal sends global Escape and requires --foreground.",
                        hint: "Add --foreground or remove --force and provide an exact target."
                    )
                }
            } else {
                try requireTarget()
            }
            try rejectForegroundOptionsWithoutConsent()
        }
    }
}
