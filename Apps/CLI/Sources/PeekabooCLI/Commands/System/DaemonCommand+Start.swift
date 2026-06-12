import Commander
import Darwin
import Foundation
import PeekabooBridge
import PeekabooFoundation

extension DaemonCommand {
    @MainActor
    struct Start: OutputFormattable, RuntimeOptionsConfigurable {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "start",
                    abstract: "Start the Peekaboo daemon (on-demand)"
                )
            }
        }

        @Option(name: .long, help: "Override bridge socket path")
        var bridgeSocket: String?

        @Option(name: .long, help: "Window tracker poll interval in milliseconds (default 1000)")
        var pollIntervalMs: Int?

        @Option(name: .long, help: "Seconds to wait for daemon startup (default 3)")
        var waitSeconds: Int = 3

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
            let socketPath = self.bridgeSocket ?? PeekabooBridgeConstants.daemonSocketPath
            let client = DaemonControlClient(socketPath: socketPath)
            let lockHandle = DaemonPaths.openDaemonStartupLock()
            if let fileDescriptor = lockHandle?.fileDescriptor {
                flock(fileDescriptor, LOCK_EX)
            }
            defer {
                if let fileDescriptor = lockHandle?.fileDescriptor {
                    flock(fileDescriptor, LOCK_UN)
                }
                try? lockHandle?.close()
            }

            let targets = await DaemonControlResolver.targets(explicitSocket: self.bridgeSocket)
            if let target = targets.first(where: { !$0.isLegacyDefault }) {
                let status = target.status
                self.output(status) {
                    DaemonStatusPrinter.render(status: status)
                }
                return
            }

            let legacyTarget = targets.first {
                $0.isLegacyDefault && DaemonControlClient.isReusableDaemonStatus($0.status)
            }
            if let legacyTarget {
                guard DaemonControlClient.supportsSafeMigration(legacyTarget.status) else {
                    throw PeekabooError.operationError(
                        message: "Legacy daemon predates safe migration; run `peekaboo daemon stop`, then retry start"
                    )
                }
                guard DaemonControlClient.isIdleForMigration(legacyTarget.status) else {
                    throw PeekabooError.operationError(
                        message: "Legacy daemon has active requests; retry start after they finish"
                    )
                }
            }

            switch await DaemonLaunchPolicy.waitForDaemonSocketAvailability(
                socketPath: socketPath,
                client: client,
                timeout: TimeInterval(max(self.waitSeconds, DaemonControlClient.defaultShutdownWaitSeconds))
            ) {
            case .available:
                break
            case .reusableDaemon:
                if let status = await client.fetchReusableDaemonStatus() {
                    self.output(status) {
                        DaemonStatusPrinter.render(status: status)
                    }
                    return
                }
            case .timedOut:
                throw PeekabooError.operationError(message: "Daemon socket is still shutting down")
            }

            let arguments = DaemonLaunchPolicy.daemonArguments(
                socketPath: socketPath,
                mode: .manual,
                pollIntervalMs: self.pollIntervalMs ?? legacyTarget?.status.windowTracker?.cgPollIntervalMs,
                idleTimeoutSeconds: CommandRuntime.defaultDaemonIdleTimeoutSeconds
            )
            guard let replacement = await DaemonLaunchPolicy.launchDaemon(
                socketPath: socketPath,
                arguments: arguments,
                timeout: TimeInterval(self.waitSeconds)
            )
            else {
                throw PeekabooError.operationError(message: "Daemon did not start within \(self.waitSeconds)s")
            }

            if let legacyTarget {
                do {
                    let stopped = try await legacyTarget.client.stopAndWait(
                        waitSeconds: max(self.waitSeconds, DaemonControlClient.defaultShutdownWaitSeconds),
                        expectedPID: legacyTarget.status.pid,
                        requireIdentityMatch: true
                    )
                    if !stopped,
                       await legacyTarget.client.fetchReusableDaemonStatus() != nil {
                        throw PeekabooError.operationError(message: "Legacy daemon refused migration stop request")
                    }
                } catch {
                    if await legacyTarget.client.fetchReusableDaemonStatus() != nil {
                        let cleanedUp = await DaemonLaunchPolicy.stopReplacement(
                            client: client,
                            replacement: replacement
                        )
                        if !cleanedUp {
                            throw PeekabooError.operationError(
                                message: "Legacy migration failed and replacement cleanup timed out"
                            )
                        }
                        throw error
                    }
                }
            }

            let status = replacement.status
            self.output(status) {
                DaemonStatusPrinter.render(status: status)
            }
        }
    }
}

extension DaemonCommand.Start: AsyncRuntimeCommand {}

@MainActor
extension DaemonCommand.Start: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.bridgeSocket = values.singleOption("bridge-socket")
        self.pollIntervalMs = try values.decodeOption("pollIntervalMs", as: Int.self)
        if let waitSeconds = try values.decodeOption("waitSeconds", as: Int.self) {
            self.waitSeconds = waitSeconds
        }
    }
}
