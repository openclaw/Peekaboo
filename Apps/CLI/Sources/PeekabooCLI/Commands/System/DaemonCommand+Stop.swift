import Commander
import Foundation
import PeekabooBridge
import PeekabooFoundation

extension DaemonCommand {
    @MainActor
    struct Stop: OutputFormattable, RuntimeOptionsConfigurable {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "stop",
                    abstract: "Stop the Peekaboo daemon"
                )
            }
        }

        @Option(name: .long, help: "Override bridge socket path")
        var bridgeSocket: String?

        @Option(name: .long, help: "Seconds to wait for daemon shutdown (default 12)")
        var waitSeconds: Int = DaemonControlClient.defaultShutdownWaitSeconds

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

            guard !targets.isEmpty else {
                let stopped = PeekabooDaemonStatus(running: false)
                self.output(stopped) {
                    DaemonStatusPrinter.render(status: stopped)
                }
                return
            }

            if targets.contains(where: { $0.status.mode == nil }) {
                throw PeekabooError.operationError(message: "Connected host does not support daemon stop")
            }

            for target in targets {
                guard try await target.client.stopAndWait(
                    waitSeconds: self.waitSeconds,
                    expectedPID: target.status.pid,
                    requireIdentityMatch: DaemonControlClient.supportsSafeMigration(target.status)
                )
                else {
                    throw PeekabooError.operationError(message: "Daemon refused stop request")
                }
            }

            let stopped = PeekabooDaemonStatus(running: false)
            self.output(stopped) {
                DaemonStatusPrinter.render(status: stopped)
            }
        }
    }
}

extension DaemonCommand.Stop: AsyncRuntimeCommand {}

@MainActor
extension DaemonCommand.Stop: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.bridgeSocket = values.singleOption("bridge-socket")
        if let waitSeconds = try values.decodeOption("waitSeconds", as: Int.self) {
            self.waitSeconds = waitSeconds
        }
    }
}
