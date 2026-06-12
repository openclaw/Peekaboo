import Commander
import PeekabooBridge

extension DaemonCommand {
    @MainActor
    struct Status: OutputFormattable, RuntimeOptionsConfigurable {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "status",
                    abstract: "Show daemon status"
                )
            }
        }

        @Option(name: .long, help: "Override bridge socket path")
        var bridgeSocket: String?

        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        private var logger: Logger {
            self.resolvedRuntime.logger
        }

        var outputLogger: Logger {
            self.logger
        }

        var jsonOutput: Bool {
            self.resolvedRuntime.configuration.jsonOutput
        }

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let targets = await DaemonControlResolver.targets(explicitSocket: self.bridgeSocket)

            if let status = targets.first?.status {
                self.output(status) {
                    DaemonStatusPrinter.render(status: status)
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
