import Commander

extension VerifyCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("windowBounds", help: "Expected x,y,width,height[,tolerance]", long: "window-bounds"),
                .commandOption("on", help: "Element ID or role:label query", long: "on"),
                .commandOption("valueEquals", help: "Expected element value", long: "value-equals"),
                .commandOption(
                    "timeout",
                    help: "Polling timeout; bare values are milliseconds, or use ms/s suffixes",
                    long: "timeout"
                ),
                .commandOption("stableSamples", help: "Required stable samples (default: 2)", long: "stable-samples"),
                .commandOption("screenshot", help: "Save the final exact-window screenshot", long: "screenshot"),
            ],
            flags: [
                .commandFlag("windowExists", help: "Require the target window to exist", long: "window-exists"),
                .commandFlag("exists", help: "Require the selected element to exist", long: "exists"),
                .commandFlag("enabled", help: "Require the selected element to be enabled", long: "enabled"),
                .commandFlag("selected", help: "Require the selected element to be selected", long: "selected"),
            ],
            optionGroups: [InteractionTargetOptions.commanderSignature()]
        )
    }
}

extension VerifyCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.target = try values.makeInteractionTargetOptions()
        self.windowExists = values.flag("windowExists")
        self.windowBounds = values.singleOption("windowBounds")
        self.on = values.singleOption("on")
        self.exists = values.flag("exists")
        self.valueEquals = values.singleOption("valueEquals")
        self.enabled = values.flag("enabled")
        self.selected = values.flag("selected")
        self.timeout = try values.decodeOption("timeout", as: CLIDuration.self) ?? .seconds(5)
        self.stableSamples = try values.decodeOption("stableSamples", as: Int.self) ?? 2
        self.screenshot = values.singleOption("screenshot")
    }
}
