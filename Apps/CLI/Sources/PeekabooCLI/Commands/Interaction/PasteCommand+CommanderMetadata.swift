import Commander

@available(macOS 14.0, *)
extension PasteCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "text",
                    help: "Text to paste; omit to paste current clipboard",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption("textOption", help: "Text to paste (alternative to positional argument)", long: "text"),
                .commandOption("filePath", help: "Path to file to paste", long: "file-path"),
                .commandOption("dataBase64", help: "Base64 data to paste", long: "data-base64"),
                .commandOption("uti", help: "UTI for base64 payload or to force type", long: "uti"),
                .commandOption(
                    "alsoText",
                    help: "Optional plain-text companion when setting binary",
                    long: "also-text"
                ),
                .commandOption(
                    "restoreDelay",
                    help: "Clipboard restore delay; bare values are milliseconds, or use ms/s suffixes",
                    long: "restore-delay"
                ),
            ],
            flags: [
                .commandFlag("allowLarge", help: "Allow payloads larger than 10 MB", long: "allow-large"),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeBackgroundDelivery: true),
            ]
        )
    }
}

@available(macOS 14.0, *)
@MainActor
extension PasteCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.text = values.positional.first
        self.textOption = values.singleOption("text") ?? values.singleOption("textOption")
        self.filePath = values.singleOption("filePath")
        self.dataBase64 = values.singleOption("dataBase64")
        self.uti = values.singleOption("uti")
        self.alsoText = values.singleOption("alsoText")
        if let delay: CLIDuration = try values.decodeOption("restoreDelay", as: CLIDuration.self) {
            self.restoreDelay = delay
        }
        self.allowLarge = values.flag("allowLarge")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions(includeBackgroundDelivery: true)
    }
}
