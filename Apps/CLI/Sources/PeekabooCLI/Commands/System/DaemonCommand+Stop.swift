import Commander
import Foundation
import PeekabooBridge
import PeekabooFoundation

extension DaemonCommand {
    @MainActor
    struct Stop: OutputFormattable, RuntimeOptionsConfigurable, InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "stop",
                    abstract: "Stop the Peekaboo daemon"
                )
            }
        }

        var bridgeSocket: String?

        @Option(name: .customLong("wait"), help: "Daemon shutdown wait (bare values are milliseconds; default 12s)")
        var wait: CLIDuration = .seconds(TimeInterval(DaemonControlClient.defaultShutdownWaitSeconds))

        var waitSeconds: Int {
            Int(self.wait.seconds.rounded(.up))
        }

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let targets = try await DaemonControlResolver.targets(explicitSocket: self.bridgeSocket)

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
        if let wait = try values.decodeOption("wait", as: CLIDuration.self) {
            self.wait = wait
        }
    }
}
