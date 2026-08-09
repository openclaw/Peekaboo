import Commander

@MainActor
struct CaptureWatchAlias: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "watch", abstract: "Alias for capture live", version: "1.0.0")
        }
    }

    private var live = CaptureLiveCommand()

    mutating func run(using runtime: CommandRuntime) async throws {
        try await self.live.run(using: runtime)
    }
}

extension CaptureWatchAlias: AsyncRuntimeCommand {}

@MainActor
extension CaptureWatchAlias: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        try self.live.applyCommanderValues(values)
    }
}
