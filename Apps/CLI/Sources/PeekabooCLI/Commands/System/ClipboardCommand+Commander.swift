import Commander

@available(macOS 14.0, *)
@MainActor
extension ClipboardCommand: ParsableCommand {}

@available(macOS 14.0, *)
extension ClipboardCommand: AsyncRuntimeCommand {}

@available(macOS 14.0, *)
@MainActor
extension ClipboardCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.action = try values.decodeOptionalPositional(0, label: "action", as: String.self)
        self.actionOption = try values.decodeOption("actionOption", as: String.self)
        if self.actionOption == nil {
            self.actionOption = try values.decodeOption("action", as: String.self)
        }
        self.text = try values.decodeOption("text", as: String.self)
        self.filePath = try values.decodeOption("filePath", as: String.self)
        if self.filePath == nil {
            self.filePath = try values.decodeOption("file-path", as: String.self)
        }
        self.dataBase64 = try values.decodeOption("dataBase64", as: String.self)
        if self.dataBase64 == nil {
            self.dataBase64 = try values.decodeOption("data-base64", as: String.self)
        }
        self.uti = try values.decodeOption("uti", as: String.self)
        self.prefer = try values.decodeOption("prefer", as: String.self)
        self.output = try values.decodeOption("output", as: String.self)
        self.slot = try values.decodeOption("slot", as: String.self)
        self.alsoText = try values.decodeOption("alsoText", as: String.self)
        if self.alsoText == nil {
            self.alsoText = try values.decodeOption("also-text", as: String.self)
        }
        self.allowLarge = values.flag("allowLarge") || values.flag("allow-large")
        self.verify = values.flag("verify")
    }
}
