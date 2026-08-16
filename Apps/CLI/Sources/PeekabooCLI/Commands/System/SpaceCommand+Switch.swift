import Commander
import PeekabooCore
import PeekabooFoundation

// MARK: - Switch Space

@MainActor
struct SwitchSubcommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
InjectedRuntimeBackedCommand {
    @Option(name: .long, help: "Space number to switch to (1-based)")
    var to: Int

    @Flag(name: .long, help: "Required explicit consent to switch the visible Space")
    var foreground = false
    @RuntimeStorage var runtime: CommandRuntime?

    /// Validate the requested Space index, switch to it, and report the outcome.
    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            guard self.foreground else {
                throw PreDispatchActionError(
                    message: "Space switching changes the visible desktop and requires explicit --foreground consent.",
                    code: .VALIDATION_ERROR,
                    hint: "Use --foreground only when switching away from the user's current Space is intentional.",
                    reason: .foregroundConsentRequired
                )
            }
            try SpaceCommandHostOwnership.requireLocalMutation(
                services: self.services,
                operation: "switch Spaces"
            )
            let spaceService = SpaceCommandEnvironment.service
            let spaces = await spaceService.getAllSpaces()

            guard self.to > 0, self.to <= spaces.count else {
                throw ValidationError("Invalid Space number. Available: 1-\(spaces.count)")
            }

            let targetSpace = spaces[self.to - 1]
            self.resolvedRuntime.beginInteractionMutation()
            let actionResult = try await spaceService.switchToSpaceResult(targetSpace.id)
            try validateSuccessfulActionOutcome(
                actionResult.outcome,
                targetIdentity: nil,
                operation: "Space switch"
            )
            guard let outcome = actionResult.outcome else {
                preconditionFailure("Successful Space switch validation requires a canonical outcome")
            }
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
                outputSuccessCodable(data: data, outcome: outcome, logger: self.logger)
            } else {
                print(ActionOutcomeHumanRenderer.statusLine(
                    for: outcome,
                    operation: "Space switch"
                ))
                print(spaceSwitchCompletionMessage(outcome: outcome, spaceNumber: self.to))
            }

        } catch {
            handleError(error)
            throw ExitCode(1)
        }
    }
}

func spaceSwitchCompletionMessage(outcome: DesktopActionOutcome, spaceNumber: Int) -> String {
    switch outcome.state {
    case .confirmedNoChange:
        "Already on Space \(spaceNumber)"
    case .confirmedChange:
        "✓ Switched to Space \(spaceNumber)"
    case .dispatchedUnverified:
        "Space switch dispatched to Space \(spaceNumber), but completion was not verified"
    case .refused, .partial, .suspectedNoop, .indeterminate:
        "Space switch to Space \(spaceNumber) did not complete"
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
        self.foreground = values.flag("foreground")
    }
}
