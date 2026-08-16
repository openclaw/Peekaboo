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
            usageExamples: [
                CommandUsageExample(
                    command: "peekaboo see --window-id 12345 --no-elements --json",
                    description: "Capture a fresh exact-window receipt and copy its snapshot ID."
                ),
                CommandUsageExample(
                    command: "peekaboo click --window-id 12345 --at 20,40 --snapshot SNAPSHOT_ID",
                    description: "Click window-relative coordinates in the background without moving the cursor."
                ),
            ],
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
        self.target = try values.makeInteractionTargetOptions()
        self.at = values.singleOption("at")
        self.global = values.flag("global")
        if let wait: CLIDuration = try values.decodeOption("waitFor", as: CLIDuration.self) {
            self.waitFor = wait
        }
        self.double = values.flag("double")
        self.right = values.flag("right")
        self.middle = values.flag("middle")
        self.triple = values.flag("triple")
        self.longPress = values.flag("longPress")
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
                    help: "Snapshot ID; element/query clicks may use latest when omitted, but background " +
                        "coordinates require an explicit fresh exact-window snapshot",
                    long: "snapshot"
                ),
                .commandOption(
                    "on",
                    help: "Opaque element ID copied from current see output",
                    long: "on"
                ),
                .commandOption(
                    "at",
                    help: "x,y — target-relative when --app/--window-* given; global otherwise " +
                        "(use --global for explicit global)",
                    long: "at"
                ),
                .commandOption(
                    "waitFor",
                    help: "Maximum wait; bare values are milliseconds, or use ms/s suffixes",
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
                    "middle",
                    help: "Middle-click with the center mouse button",
                    long: "middle"
                ),
                .commandFlag(
                    "triple",
                    help: "Triple-click instead of single click",
                    long: "triple"
                ),
                .commandFlag(
                    "longPress",
                    help: "Press and hold for 1.2 seconds at a stationary point (requires --foreground)",
                    long: "long-press"
                ),
                .commandFlag(
                    "global",
                    help: "Treat --at as global screen coordinates even with target options",
                    long: "global"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(includeBackgroundDelivery: true),
            ]
        )
    }
}
