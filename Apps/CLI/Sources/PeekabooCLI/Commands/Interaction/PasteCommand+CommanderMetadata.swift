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
                .commandOption("imagePath", help: "Path to image to paste (alias of file-path)", long: "image-path"),
                .commandOption("dataBase64", help: "Base64 data to paste", long: "data-base64"),
                .commandOption("uti", help: "UTI for base64 payload or to force type", long: "uti"),
                .commandOption(
                    "alsoText",
                    help: "Optional plain-text companion when setting binary",
                    long: "also-text"
                ),
                .commandOption(
                    "restoreDelayMs",
                    help: "Delay before restoring previous clipboard (ms)",
                    long: "restore-delay-ms"
                ),
            ],
            flags: [
                .commandFlag("allowLarge", help: "Allow payloads larger than 10 MB", long: "allow-large"),
                .commandFlag(
                    "foreground",
                    help: "Focus target and send foreground/global Cmd+V",
                    long: "foreground"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
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
        self.imagePath = values.singleOption("imagePath")
        self.dataBase64 = values.singleOption("dataBase64")
        self.uti = values.singleOption("uti")
        self.alsoText = values.singleOption("alsoText")
        if let delay: Int = try values.decodeOption("restoreDelayMs", as: Int.self) {
            self.restoreDelayMs = delay
        }
        self.allowLarge = values.flag("allowLarge")
        self.foreground = values.flag("foreground")

        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}
