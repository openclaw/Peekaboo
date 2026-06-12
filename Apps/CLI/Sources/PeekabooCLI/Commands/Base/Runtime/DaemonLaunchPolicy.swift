import Darwin
import Foundation
import PeekabooBridge

enum DaemonLaunchPolicy {
    enum ImplicitRuntimeCandidateRole: Equatable {
        case reusableDaemon
        case defaultAppFallback
    }

    struct LaunchResult {
        let status: PeekabooDaemonStatus
        let processID: pid_t

        var ownsObservedDaemon: Bool {
            self.status.pid == self.processID
        }
    }

    enum SocketAvailability: Equatable {
        case available
        case reusableDaemon
        case timedOut
    }

    static func shouldAutoStartDaemon(
        options: CommandRuntimeOptions,
        environment: [String: String]
    ) -> Bool {
        options.autoStartDaemon &&
            BridgeSocketResolver.explicitBridgeSocket(options: options, environment: environment) == nil
    }

    static func daemonSocketPath(environment: [String: String]) -> String {
        if let socket = environment["PEEKABOO_DAEMON_SOCKET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socket.isEmpty {
            return socket
        }
        return PeekabooBridgeConstants.daemonSocketPath
    }

    static func daemonIdleTimeoutSeconds(environment: [String: String]) -> TimeInterval {
        guard let raw = environment["PEEKABOO_DAEMON_IDLE_TIMEOUT_SECONDS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = TimeInterval(raw),
            value > 0 else {
            return CommandRuntime.defaultDaemonIdleTimeoutSeconds
        }
        return value
    }

    static func shouldMigrateLegacyDaemon(targetSocketPath: String) -> Bool {
        self.standardizedSocketPath(targetSocketPath) ==
            self.standardizedSocketPath(PeekabooBridgeConstants.daemonSocketPath)
    }

    static func implicitRuntimeCandidateRole(
        socketPath: String,
        daemonSocketPath: String
    ) -> ImplicitRuntimeCandidateRole? {
        let candidate = self.standardizedSocketPath(socketPath)
        if candidate == self.standardizedSocketPath(daemonSocketPath) {
            return .reusableDaemon
        }
        if self.shouldMigrateLegacyDaemon(targetSocketPath: daemonSocketPath),
           candidate == self.standardizedSocketPath(PeekabooBridgeConstants.peekabooSocketPath) {
            return .defaultAppFallback
        }
        return nil
    }

    static func isSelectableImplicitRuntimeCandidate(
        role: ImplicitRuntimeCandidateRole,
        handshake: PeekabooBridgeHandshakeResponse,
        daemonStatus: PeekabooDaemonStatus?
    ) -> Bool {
        switch role {
        case .reusableDaemon:
            daemonStatus.map(DaemonControlClient.isReusableDaemonStatus) == true
        case .defaultAppFallback:
            handshake.hostKind == .gui ||
                daemonStatus.map(DaemonControlClient.isReusableDaemonStatus) == true
        }
    }

    static func onDemandDaemonArguments(socketPath: String, idleTimeoutSeconds: TimeInterval) -> [String] {
        self.daemonArguments(
            socketPath: socketPath,
            mode: .auto,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
    }

    static func daemonArguments(
        socketPath: String,
        mode: PeekabooDaemonMode,
        pollIntervalMs: Int? = nil,
        idleTimeoutSeconds: TimeInterval
    ) -> [String] {
        var arguments = [
            "daemon",
            "run",
            "--mode",
            mode.rawValue,
            "--bridge-socket",
            socketPath,
        ]
        if let pollIntervalMs, pollIntervalMs > 0 {
            arguments.append(contentsOf: [
                "--poll-interval-ms",
                "\(pollIntervalMs)",
            ])
        }
        if mode == .auto {
            arguments.append(contentsOf: [
                "--idle-timeout-seconds",
                String(format: "%.3f", idleTimeoutSeconds),
            ])
        }
        return arguments
    }

    static func migratedDaemonArguments(
        socketPath: String,
        status: PeekabooDaemonStatus,
        fallbackIdleTimeoutSeconds: TimeInterval
    ) -> [String]? {
        guard let mode = DaemonControlClient.migrationMode(for: status) else { return nil }
        let idleTimeoutSeconds = status.activity?.idleTimeoutSeconds.flatMap { $0 > 0 ? $0 : nil }
            ?? fallbackIdleTimeoutSeconds
        return self.daemonArguments(
            socketPath: socketPath,
            mode: mode,
            pollIntervalMs: status.windowTracker?.cgPollIntervalMs,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
    }

    static func startOnDemandDaemon(socketPath: String, environment: [String: String]) async -> String? {
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

        if await client.fetchReusableDaemonStatus() != nil {
            return socketPath
        }

        switch await self.waitForDaemonSocketAvailability(
            socketPath: socketPath,
            client: client,
            timeout: TimeInterval(DaemonControlClient.defaultShutdownWaitSeconds)
        ) {
        case .available:
            break
        case .reusableDaemon:
            return socketPath
        case .timedOut:
            return nil
        }

        let fallbackIdleTimeoutSeconds = self.daemonIdleTimeoutSeconds(environment: environment)
        var launchArguments = self.daemonArguments(
            socketPath: socketPath,
            mode: .auto,
            idleTimeoutSeconds: fallbackIdleTimeoutSeconds
        )
        let legacyClient = DaemonControlClient(socketPath: PeekabooBridgeConstants.peekabooSocketPath)
        if self.shouldMigrateLegacyDaemon(targetSocketPath: socketPath),
           let legacyStatus = await legacyClient.fetchReusableDaemonStatus(),
           let migrationArguments = self.migratedDaemonArguments(
               socketPath: socketPath,
               status: legacyStatus,
               fallbackIdleTimeoutSeconds: fallbackIdleTimeoutSeconds
           ) {
            guard DaemonControlClient.supportsSafeMigration(legacyStatus),
                  DaemonControlClient.isIdleForMigration(legacyStatus)
            else {
                return PeekabooBridgeConstants.peekabooSocketPath
            }
            launchArguments = migrationArguments

            guard let replacement = await self.launchDaemon(
                socketPath: socketPath,
                arguments: launchArguments
            )
            else {
                return await legacyClient.fetchReusableDaemonStatus() != nil
                    ? PeekabooBridgeConstants.peekabooSocketPath
                    : nil
            }

            do {
                let stopped = try await legacyClient.stopAndWait(
                    waitSeconds: DaemonControlClient.defaultShutdownWaitSeconds,
                    expectedPID: legacyStatus.pid,
                    requireIdentityMatch: true
                )
                if !stopped {
                    if await legacyClient.fetchReusableDaemonStatus() != nil {
                        let cleanedUp = await self.stopReplacement(
                            client: client,
                            replacement: replacement
                        )
                        return cleanedUp ? PeekabooBridgeConstants.peekabooSocketPath : nil
                    }
                }
            } catch {
                if await legacyClient.fetchReusableDaemonStatus() != nil {
                    let cleanedUp = await self.stopReplacement(
                        client: client,
                        replacement: replacement
                    )
                    return cleanedUp ? PeekabooBridgeConstants.peekabooSocketPath : nil
                }
            }
            return await client.fetchReusableDaemonStatus() != nil ? socketPath : nil
        }

        return await self.launchDaemon(
            socketPath: socketPath,
            arguments: launchArguments
        ) != nil ? socketPath : nil
    }

    static func waitForDaemonSocketAvailability(
        socketPath: String,
        client: DaemonControlClient,
        timeout: TimeInterval
    ) async -> SocketAvailability {
        guard self.bridgeLeaseIsHeld(socketPath: socketPath) else {
            return .available
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await client.fetchReusableDaemonStatus() != nil {
                return .reusableDaemon
            }
            if !self.bridgeLeaseIsHeld(socketPath: socketPath) {
                return .available
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return self.bridgeLeaseIsHeld(socketPath: socketPath) ? .timedOut : .available
    }

    private static func bridgeLeaseIsHeld(socketPath: String) -> Bool {
        let fd = open(
            "\(socketPath).lock",
            O_RDWR | O_CLOEXEC | O_NOFOLLOW
        )
        guard fd >= 0 else { return false }
        defer { close(fd) }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
    }

    static func launchDaemon(
        socketPath: String,
        arguments: [String],
        timeout: TimeInterval = 3
    ) async -> LaunchResult? {
        let executable = CommandLine.arguments.first ?? "/usr/local/bin/peekaboo"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let logHandle = DaemonPaths.openDaemonLogForAppend() ?? FileHandle.nullDevice
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        let client = DaemonControlClient(socketPath: socketPath)
        while Date() < deadline {
            if let status = await client.fetchReusableDaemonStatus() {
                let processID = process.processIdentifier
                if status.pid != processID, process.isRunning {
                    process.terminate()
                }
                return LaunchResult(status: status, processID: processID)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            process.terminate()
        }
        return nil
    }

    static func stopReplacement(
        client: DaemonControlClient,
        replacement: LaunchResult
    ) async -> Bool {
        guard replacement.ownsObservedDaemon else { return true }
        let expectedPID = replacement.processID
        let deadline = Date().addingTimeInterval(
            TimeInterval(DaemonControlClient.defaultShutdownWaitSeconds)
        )

        while Date() < deadline {
            guard let status = await client.fetchControllableDaemonStatus(),
                  status.pid == expectedPID
            else {
                return true
            }
            _ = try? await client.stopDaemon(expectedPID: expectedPID)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return await client.fetchControllableDaemonStatus()?.pid != expectedPID
    }

    private static func standardizedSocketPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}
