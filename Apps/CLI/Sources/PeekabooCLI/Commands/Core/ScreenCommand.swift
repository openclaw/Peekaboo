import Commander

/// Display inventory shortcuts.
@MainActor
struct ScreenCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "screen",
        abstract: "Inspect connected displays",
        discussion: """
        Examples:
          peekaboo screen list
          peekaboo screen list --json

        `peekaboo list screens` remains available as a compatibility spelling.
        """,
        subcommands: [ListSubcommand.self],
        defaultSubcommand: ListSubcommand.self
    )

    func run() async throws {}

    @MainActor
    struct ListSubcommand: RuntimeOptionsConfigurable {
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = ListCommand.ScreensSubcommand()
            command.runtimeOptions = self.runtimeOptions
            try await command.run(using: runtime)
        }
    }
}

@MainActor
extension ScreenCommand.ListSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list",
                abstract: "List displays with IDs, bounds, scale, and primary status"
            )
        }
    }
}

extension ScreenCommand.ListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ScreenCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}
