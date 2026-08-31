import Commander
import Foundation
import PeekabooBridge
import PeekabooFoundation

extension DaemonCommand {
    @MainActor
    struct Start: OutputFormattable, RuntimeOptionsConfigurable, InjectedRuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "start",
                    abstract: "Start the Peekaboo daemon (on-demand)"
                )
            }
        }

        var bridgeSocket: String?

        @Option(name: .customLong("poll-interval"), help: "Window tracker poll interval (bare values are milliseconds)")
        var pollInterval: CLIDuration?

        @Option(name: .customLong("wait"), help: "Daemon startup wait (bare values are milliseconds; default 3s)")
        var wait: CLIDuration = .seconds(3)

        var pollIntervalMs: Int? {
            self.pollInterval?.roundedMilliseconds
        }

        var waitSeconds: Int {
            Int(self.wait.seconds.rounded(.up))
        }

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            try await DaemonStartupGate.withExclusiveStartup(
                lockURL: DaemonPaths.daemonStartupLockURL(socketPath: self.bridgeSocket)
            ) { _ in
                try await self.runWithStartupLockHeld()
            }
        }

        private func runWithStartupLockHeld() async throws {
            let defaultSocketPath = PeekabooBridgeConstants.daemonSocketPath
            let buildScopedSocketPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
                daemonSocketPath: defaultSocketPath,
                runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
            )

            let targets = try await DaemonControlResolver.targets(explicitSocket: self.bridgeSocket)
            let action = DaemonControlPlanner.startAction(
                targets: targets,
                explicitSocket: self.bridgeSocket,
                defaultSocketPath: defaultSocketPath,
                buildScopedSocketPath: buildScopedSocketPath
            )
            guard let destination = try await self.resolveDestination(action: action, targets: targets) else { return }
            let socketPath = destination.socketPath
            let promotionTarget = destination.promotionTarget

            let client = DaemonControlClient(socketPath: socketPath)

            let migratesLegacyTarget = DaemonControlPlanner.shouldMigrateLegacyTarget(
                explicitSocket: self.bridgeSocket,
                destinationSocketPath: socketPath,
                defaultSocketPath: defaultSocketPath,
                targets: targets
            )
            let legacyTarget = migratesLegacyTarget
                ? targets.first {
                    $0.isLegacyDefault && DaemonControlClient.isReusableDaemonStatus($0.status)
                }
                : nil
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

            switch try await DaemonLaunchPolicy.waitForDaemonSocketAvailability(
                socketPath: socketPath,
                client: client,
                timeout: TimeInterval(max(self.waitSeconds, DaemonControlClient.defaultShutdownWaitSeconds))
            ) {
            case .available:
                break
            case .reusableDaemon:
                if let status = try await client.fetchReusableDaemonStatus() {
                    guard status.mode == .manual else {
                        throw PeekabooError.operationError(
                            message: "Daemon at \(socketPath) remained in auto mode; retry start when it is idle"
                        )
                    }
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
                pollIntervalMs: self.pollIntervalMs ?? promotionTarget?.status.windowTracker?.cgPollIntervalMs
                    ?? legacyTarget?.status.windowTracker?.cgPollIntervalMs,
                idleTimeoutSeconds: CommandRuntime.defaultDaemonIdleTimeoutSeconds
            )
            let replacement: DaemonLaunchPolicy.LaunchResult
            do {
                replacement = try await DaemonLaunchPolicy.launchDaemon(
                    socketPath: socketPath,
                    arguments: arguments,
                    timeout: TimeInterval(self.waitSeconds)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw PeekabooError.operationError(message: error.localizedDescription)
            }

            if let legacyTarget {
                do {
                    let stopped = try await legacyTarget.client.stopAndWait(
                        waitSeconds: max(self.waitSeconds, DaemonControlClient.defaultShutdownWaitSeconds),
                        expectedPID: legacyTarget.status.pid,
                        requireIdentityMatch: true
                    )
                    if !stopped {
                        throw PeekabooError.operationError(message: "Legacy daemon refused migration stop request")
                    }
                } catch is CancellationError {
                    _ = await DaemonLaunchPolicy.stopReplacementAfterCancellation(
                        client: client,
                        replacement: replacement
                    )
                    throw CancellationError()
                } catch {
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

            let status = replacement.status
            self.output(status) {
                DaemonStatusPrinter.render(status: status)
            }
        }
    }
}

extension DaemonCommand.Start: AsyncRuntimeCommand {}

private struct DaemonStartDestination {
    let socketPath: String
    let promotionTarget: DaemonControlTarget?
}

@MainActor
extension DaemonCommand.Start {
    fileprivate func resolveDestination(
        action: DaemonStartAction,
        targets: [DaemonControlTarget]
    ) async throws -> DaemonStartDestination? {
        switch action {
        case let .useExisting(socketPath):
            guard let target = targets.first(where: { $0.client.socketPath == socketPath }) else {
                throw PeekabooError.operationError(message: "Selected daemon disappeared; retry start")
            }
            self.output(target.status) {
                DaemonStatusPrinter.render(status: target.status)
            }
            return nil
        case let .launchManual(socketPath):
            return DaemonStartDestination(socketPath: socketPath, promotionTarget: nil)
        case let .promoteAutoToManual(socketPath, pid):
            guard let target = targets.first(where: { $0.client.socketPath == socketPath }) else {
                throw PeekabooError.operationError(message: "Selected daemon disappeared; retry start")
            }
            do {
                guard try await target.client.stopAndWait(
                    waitSeconds: max(self.waitSeconds, DaemonControlClient.defaultShutdownWaitSeconds),
                    expectedPID: pid,
                    requireIdentityMatch: true
                )
                else {
                    throw PeekabooError.operationError(
                        message: "Daemon at \(socketPath) refused a safe stop; retry when it is idle"
                    )
                }
            } catch let error as PeekabooError {
                throw error
            } catch {
                throw PeekabooError.operationError(
                    message: "Could not safely promote daemon at \(socketPath): \(error.localizedDescription)"
                )
            }
            return DaemonStartDestination(socketPath: socketPath, promotionTarget: target)
        case let .rejectBusy(socketPath):
            throw PeekabooError.operationError(
                message: "Daemon at \(socketPath) has active requests; retry start after they finish"
            )
        case let .rejectUnsafe(socketPath):
            throw PeekabooError.operationError(
                message: "Daemon at \(socketPath) cannot be safely promoted; " +
                    "stop it explicitly with `peekaboo daemon stop --bridge-socket \(socketPath)`, then retry"
            )
        case let .rejectIncompatible(socketPath):
            throw PeekabooError.operationError(
                message: "Daemon at \(socketPath) is incompatible with this build; " +
                    "stop it with `peekaboo daemon stop --bridge-socket \(socketPath)`, then retry"
            )
        }
    }
}

@MainActor
extension DaemonCommand.Start: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.bridgeSocket = values.singleOption("bridge-socket")
        self.pollInterval = try values.decodeOption("pollInterval", as: CLIDuration.self)
        if let wait = try values.decodeOption("wait", as: CLIDuration.self) {
            self.wait = wait
        }
    }
}
