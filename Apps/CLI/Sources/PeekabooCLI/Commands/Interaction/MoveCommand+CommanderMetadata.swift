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
                      peekaboo move 100,200                 # Move to coordinates
                      peekaboo move --to "Submit Button"    # Move to element by text
                      peekaboo move --on "$ELEMENT_ID"      # ID copied from current output
                      peekaboo move 500,300 --smooth        # Natural smooth movement
                      peekaboo move --center                # Move to screen center

                    MOVEMENT MODES:
                      - Instant (default): Immediate cursor positioning
                      - Smooth: Natural arcs with eased velocity
                      - Linear: Deterministic straight-line travel via '--profile linear'

                    ELEMENT TARGETING:
                      When targeting elements, the cursor moves to the element's center.
                      Use element IDs from 'see' output for precise targeting.
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
        self.coordinates = try values.decodeOptionalPositional(0, label: "coordinates")
        self.coords = values.singleOption("coords")
        self.to = values.singleOption("to")
        self.on = values.singleOption("on")
        self.id = values.singleOption("id")
        self.target = try values.makeInteractionTargetOptions()
        self.center = values.flag("center")
        self.smooth = values.flag("smooth")
        if let duration: Int = try values.decodeOption("duration", as: Int.self) {
            self.duration = duration
        }
        if let steps: Int = try values.decodeOption("steps", as: Int.self) {
            self.steps = steps
        }
        self.snapshot = values.singleOption("snapshot")
        self.profile = values.singleOption("profile")
        self.focusOptions = try values.makeFocusOptions()
    }
}

extension MoveCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "coordinates",
                    help: "Coordinates as x,y",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption(
                    "coords",
                    help: "Coordinates as x,y (alias for positional argument)",
                    long: "coords"
                ),
                .commandOption(
                    "to",
                    help: "Move to element by text/label",
                    long: "to"
                ),
                .commandOption(
                    "on",
                    help: "Opaque element ID copied from current see or inspect-ui output",
                    long: "on"
                ),
                .commandOption(
                    "id",
                    help: "Element ID to move to (alias for --on)",
                    long: "id"
                ),
                .commandOption(
                    "duration",
                    help: "Movement duration in milliseconds",
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
                    "center",
                    help: "Move to screen center",
                    long: "center"
                ),
                .commandFlag(
                    "smooth",
                    help: "Use natural smooth movement",
                    long: "smooth"
                ),
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
            ]
        )
    }
}
