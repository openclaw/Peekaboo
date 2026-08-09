import Commander
import PeekabooCore

// MARK: - Switch Space

@MainActor
struct SwitchSubcommand: ErrorHandlingCommand, OutputFormattable, InjectedRuntimeBackedCommand {
    @Option(name: .long, help: "Space number to switch to (1-based)")
    var to: Int
    @RuntimeStorage var runtime: CommandRuntime?

    /// Validate the requested Space index, switch to it, and report the outcome.
    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            let spaceService = SpaceCommandEnvironment.service
            let spaces = await spaceService.getAllSpaces()

            guard self.to > 0 && self.to <= spaces.count else {
                throw ValidationError("Invalid Space number. Available: 1-\(spaces.count)")
            }

            let targetSpace = spaces[self.to - 1]
            self.resolvedRuntime.beginInteractionMutation()
            try await spaceService.switchToSpace(targetSpace.id)
            AutomationEventLogger.log(
                .space,
                "switch to=\(self.to) space_id=\(targetSpace.id)"
            )

            if self.jsonOutput {
                let data = SpaceActionResult(
                    action: "switch",
                    success: true,
                    space_id: targetSpace.id,
                    space_number: self.to
                )
                outputSuccessCodable(data: data, logger: self.logger)
            } else {
                print("✓ Switched to Space \(self.to)")
            }

        } catch {
            handleError(error)
            throw ExitCode(1)
        }
    }
}

@MainActor
extension SwitchSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "switch",
                abstract: "Switch to a different Space"
            )
        }
    }
}

extension SwitchSubcommand: AsyncRuntimeCommand {}

@MainActor
extension SwitchSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.to = try values.requireOption("to", as: Int.self)
    }
}
