import Commander
import PeekabooCore

@MainActor
extension ClickCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        let definition = UIAutomationToolDefinitions.click.commandConfiguration
        return CommandDescription(
            commandName: definition.commandName,
            abstract: definition.abstract,
            discussion: definition.discussion,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension ClickCommand: AsyncRuntimeCommand {}

@MainActor
extension ClickCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.query = try values.decodeOptionalPositional(0, label: "query")
        self.snapshot = values.singleOption("snapshot")
        self.on = values.singleOption("on")
        self.id = values.singleOption("id")
        self.target = try values.makeInteractionTargetOptions()
        self.coords = values.singleOption("coords")
        self.globalCoords = values.flag("globalCoords")
        if let wait: Int = try values.decodeOption("waitFor", as: Int.self) {
            self.waitFor = wait
        }
        self.double = values.flag("double")
        self.right = values.flag("right")
        self.longPress = values.flag("longPress")
        self.foreground = values.flag("foreground")
        self.focusOptions = try values.makeFocusOptions(includeBackgroundDelivery: true)
    }
}

extension ClickCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "query",
                    help: "Element text or query to click",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
                .commandOption(
                    "on",
                    help: "Opaque element ID copied from current see or inspect-ui output",
                    long: "on"
                ),
                .commandOption(
                    "id",
                    help: "Element ID to click (alias for --on)",
                    long: "id"
                ),
                .commandOption(
                    "coords",
                    help: "Click at x,y. Target-relative when --app/--pid/--window-* is supplied; global otherwise.",
                    long: "coords"
                ),
                .commandOption(
                    "waitFor",
                    help: "Maximum milliseconds to wait for element",
                    long: "wait-for"
                ),
            ],
            flags: [
                .commandFlag(
                    "double",
                    help: "Double-click instead of single click",
                    long: "double"
                ),
                .commandFlag(
                    "right",
                    help: "Right-click (secondary click)",
                    long: "right"
                ),
                .commandFlag(
                    "longPress",
                    help: "Press and hold for 1.2 seconds at a stationary point",
                    long: "long-press"
                ),
                .commandFlag(
                    "foreground",
                    help: "Focus target and send a foreground mouse click",
                    long: "foreground"
                ),
                .commandFlag(
                    "globalCoords",
                    help: "Treat --coords as global screen coordinates even with target options",
                    long: "global-coords"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeBackgroundDelivery: true),
            ]
        )
    }
}
