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
            try await DialogCommand.execute(
                runtime: runtime,
                target: self.target,
                focus: .required(self.focusOptions),
                validate: {
                    guard self.foreground else {
                        throw ValidationError("dialog input sends keyboard input and requires --foreground")
                    }
                },
                operation: { context in
                    let fieldIdentifier = self.field ?? self.index.map { String($0) }
                    let result = try await context.services.dialogs.enterText(
                        text: self.text,
                        fieldIdentifier: fieldIdentifier,
                        clearExisting: self.clear,
                        windowTitle: context.windowTitle,
                        appName: context.appHint
                    )

                    if self.jsonOutput {
                        let outputData = DialogInputResult(
                            action: "dialog_input",
                            field: result.details["field"] ?? "Text Field",
                            textLength: result.details["text_length"] ?? String(self.text.count),
                            cleared: result.details["cleared"] ?? String(self.clear)
                        )
                        outputSuccessCodable(data: outputData, effect: .confirmed, logger: self.outputLogger)
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
                            + "cleared=\(clearedValue) app='\(context.appHint ?? "unknown")'"
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
}
