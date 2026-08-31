import Commander
import PeekabooBridge

extension DaemonCommand {
    @MainActor
    struct Status: OutputFormattable, RuntimeOptionsConfigurable, InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "status",
                    abstract: "Show daemon status"
                )
            }
        }

        var bridgeSocket: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let targets = try await DaemonControlResolver.targets(explicitSocket: self.bridgeSocket)

            if let target = DaemonControlPlanner.preferredStatusTarget(
                targets,
                explicitSocket: self.bridgeSocket
            ) {
                let additionalSocketPaths = DaemonControlPlanner.additionalSocketPaths(
                    in: targets,
                    excluding: target
                )
                if !additionalSocketPaths.isEmpty {
                    self.logger.warn(
                        "Additional Peekaboo daemon detected at \(additionalSocketPaths.joined(separator: ", ")); " +
                            "reporting \(target.client.socketPath)"
                    )
                }
                self.output(target.status) {
                    DaemonStatusPrinter.render(status: target.status)
                }
            } else {
                let stopped = PeekabooDaemonStatus(running: false)
                self.output(stopped) {
                    DaemonStatusPrinter.render(status: stopped)
                }
            }
        }
    }
}

extension DaemonCommand.Status: AsyncRuntimeCommand {}

@MainActor
extension DaemonCommand.Status: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.bridgeSocket = values.singleOption("bridge-socket")
    }
}
