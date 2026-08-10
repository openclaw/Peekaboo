import Commander

// MARK: - Conformances

@MainActor
extension MoveCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "move",
                abstract: "Move the mouse cursor to coordinates or UI elements",
                discussion: """
                    The 'move' command positions the mouse cursor at specific locations or
                    on UI elements detected by 'see'. Supports instant and smooth movement.

                    EXAMPLES:
                      peekaboo move --at 100,200 --foreground
                      peekaboo move --on "$ELEMENT_ID" --foreground
                      peekaboo move --at 500,300 --smooth --foreground

                    MOVEMENT MODES:
                      - Instant (default): Immediate cursor positioning
                      - Smooth: Natural arcs with eased velocity
                      - Linear: Deterministic straight-line travel via '--profile linear'

                    ELEMENT TARGETING:
                      When targeting elements, the cursor moves to the element's center.
                      Use element IDs from 'see' output for precise targeting.

                    FOREGROUND POLICY:
                      move always changes the shared physical cursor and requires --foreground.
                """,

                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension MoveCommand: AsyncRuntimeCommand {}

@MainActor
extension MoveCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.at = values.singleOption("at")
        self.on = values.singleOption("on")
        self.target = try values.makeInteractionTargetOptions()
        self.smooth = values.flag("smooth")
        if let duration: CLIDuration = try values.decodeOption("duration", as: CLIDuration.self) {
            self.duration = duration
        }
        if let steps: Int = try values.decodeOption("steps", as: Int.self) {
            self.steps = steps
        }
        self.snapshot = values.singleOption("snapshot")
        self.profile = values.singleOption("profile")
        self.global = values.flag("global")
        self.focusOptions = try values.makeFocusOptions()
    }
}

extension MoveCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption(
                    "at",
                    help: "x,y — target-relative when --app/--window-* given; global otherwise " +
                        "(use --global for explicit global)",
                    long: "at"
                ),
                .commandOption(
                    "on",
                    help: "Opaque element ID copied from current see output",
                    long: "on"
                ),
                .commandOption(
                    "duration",
                    help: "Movement duration; bare values are milliseconds, or use ms/s suffixes",
                    long: "duration"
                ),
                .commandOption(
                    "steps",
                    help: "Number of movement samples",
                    long: "steps"
                ),
                .commandOption(
                    "profile",
                    help: "Movement profile (linear or human)",
                    long: "profile"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID for element resolution, or 'latest'",
                    long: "snapshot"
                ),
            ],
            flags: [
                .commandFlag(
                    "smooth",
                    help: "Use natural smooth movement",
                    long: "smooth"
                ),
                .commandFlag("global", help: "Treat --at as global screen coordinates", long: "global"),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
