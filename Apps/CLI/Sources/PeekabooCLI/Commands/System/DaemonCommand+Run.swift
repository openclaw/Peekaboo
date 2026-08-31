import Commander
import Foundation
import PeekabooBridge
import PeekabooCore

extension DaemonCommand {
    @MainActor
    struct Run: AsyncRuntimeCommand, CommanderBindableCommand, RuntimeOptionsConfigurable {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "run",
                    abstract: "Run the daemon (internal)"
                )
            }
        }

        @Option(name: .long, help: "Daemon mode (manual, auto)")
        var mode: String = "manual"

        var bridgeSocket: String?

        @Option(name: .customLong("poll-interval"), help: "Window tracker poll interval (bare values are milliseconds)")
        var pollInterval: CLIDuration?

        @Option(
            name: .customLong("idle-timeout"),
            help: "Idle timeout before auto daemon shutdown (bare values are milliseconds)"
        )
        var idleTimeout: CLIDuration?

        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let pollInterval = self.pollInterval?.seconds ?? 1
            let config = try Self.configuration(
                mode: self.mode,
                bridgeSocket: self.bridgeSocket,
                pollInterval: pollInterval,
                idleTimeoutSeconds: self.idleTimeout?.seconds
            )

            let daemon = PeekabooDaemon(configuration: config)
            let historicalCleanupTask: Task<Void, Never>? = if Self.shouldScheduleHistoricalCleanup(config) {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    guard let targets = try? await DaemonControlResolver.validatedHistoricalTargets(
                        daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
                        currentBuildScopedSocketPath: config.bridgeSocketPath
                    ) else { return }
                    guard !Task.isCancelled else { return }
                    await DaemonControlResolver.stopIdleHistoricalAutoDaemons(
                        targets,
                        daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
                        currentBuildScopedSocketPath: config.bridgeSocketPath
                    )
                }
            } else {
                nil
            }
            let terminationSignalSource = ProcessTerminationSignalSource { [weak daemon] _ in
                Task { @MainActor in
                    _ = await daemon?.requestStop()
                }
            }
            defer {
                historicalCleanupTask?.cancel()
                terminationSignalSource.cancel()
            }
            try await daemon.runUntilStopChecked()
        }

        static func shouldScheduleHistoricalCleanup(_ configuration: PeekabooDaemon.Configuration) -> Bool {
            let socketURL = URL(fileURLWithPath: configuration.bridgeSocketPath).standardizedFileURL
            let defaultSocketURL = URL(
                fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath
            ).standardizedFileURL
            return configuration.mode == .auto &&
                socketURL.deletingLastPathComponent() == defaultSocketURL.deletingLastPathComponent() &&
                DaemonControlResolver.isBuildScopedSocketName(socketURL.lastPathComponent)
        }

        static func configuration(
            mode: String,
            bridgeSocket: String?,
            pollInterval: TimeInterval,
            idleTimeoutSeconds: Double?
        ) throws -> PeekabooDaemon.Configuration {
            let normalizedMode = mode.lowercased()
            if normalizedMode == "mcp" {
                throw ValidationError(
                    "Standalone MCP daemon mode is unavailable; use `peekaboo mcp` so the MCP transport " +
                        "owns its lifecycle."
                )
            }
            return if normalizedMode == "auto" {
                .auto(
                    bridgeSocketPath: bridgeSocket ?? PeekabooBridgeConstants.daemonSocketPath,
                    windowPollInterval: pollInterval,
                    idleTimeout: idleTimeoutSeconds ?? CommandRuntime.defaultDaemonIdleTimeoutSeconds
                )
            } else {
                .manual(
                    bridgeSocketPath: bridgeSocket ?? PeekabooBridgeConstants.daemonSocketPath,
                    windowPollInterval: pollInterval
                )
            }
        }

        mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
            if let modeOption = values.singleOption("mode") {
                self.mode = modeOption
            }
            if let socketOption = values.singleOption("bridge-socket") {
                self.bridgeSocket = socketOption
            }
            self.pollInterval = try values.decodeOption("pollInterval", as: CLIDuration.self)
            self.idleTimeout = try values.decodeOption("idleTimeout", as: CLIDuration.self)
        }
    }
}
