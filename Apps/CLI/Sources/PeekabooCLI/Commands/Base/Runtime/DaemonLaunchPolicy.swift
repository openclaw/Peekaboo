import Darwin
import Foundation
import MachO
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

    enum LegacyStopRaceResolution: Equatable {
        case keepReplacement
        case useLegacy(socketPath: String)
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

    static func runtimeBuildIdentity(
        executableURL: URL? = Bundle.main.executableURL,
        executableUUIDProvider: (URL) -> [String] = executableUUIDs
    ) -> String {
        let protocolVersion = PeekabooBridgeConstants.protocolVersion
        let identityPrefix = "\(protocolVersion.major).\(protocolVersion.minor)|" +
            PeekabooBridgeConstants.buildIdentifier
        let resolvedURL = executableURL?.resolvingSymlinksInPath()
        if let resolvedURL {
            let executableUUIDs = executableUUIDProvider(resolvedURL).sorted()
            if !executableUUIDs.isEmpty {
                return "\(identityPrefix)|\(executableUUIDs.joined(separator: ","))"
            }
        }

        let executablePath = resolvedURL?.path ?? CommandLine.arguments.first ?? "unknown"
        let attributes = try? FileManager.default.attributesOfItem(atPath: executablePath)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationBits = (attributes?[.modificationDate] as? Date)?
            .timeIntervalSinceReferenceDate.bitPattern ?? 0
        return [
            identityPrefix,
            executablePath,
            "\(fileSize)",
            "\(modificationBits)",
        ].joined(separator: "|")
    }

    private enum ByteOrder {
        case little
        case big
    }

    private nonisolated static func executableUUIDs(_ executableURL: URL) -> [String] {
        guard let data = try? Data(contentsOf: executableURL, options: .mappedIfSafe) else {
            return []
        }
        return self.machoUUIDs(in: data)
    }

    nonisolated static func machoUUIDs(in data: Data) -> [String] {
        guard let magic = readUInt32(data, at: 0, order: .little) else { return [] }
        switch magic {
        case UInt32(FAT_CIGAM), UInt32(FAT_CIGAM_64):
            return self.fatMachOUUIDs(
                in: data,
                order: .big,
                uses64BitArchitectureRecords: magic == UInt32(FAT_CIGAM_64)
            )
        case UInt32(FAT_MAGIC), UInt32(FAT_MAGIC_64):
            return self.fatMachOUUIDs(
                in: data,
                order: .little,
                uses64BitArchitectureRecords: magic == UInt32(FAT_MAGIC_64)
            )
        default:
            return self.machOUUID(in: data, sliceOffset: 0).map { [$0] } ?? []
        }
    }

    private nonisolated static func fatMachOUUIDs(
        in data: Data,
        order: ByteOrder,
        uses64BitArchitectureRecords: Bool
    ) -> [String] {
        guard let architectureCount = readUInt32(data, at: 4, order: order) else { return [] }
        let recordSize = uses64BitArchitectureRecords ? 32 : 20
        guard architectureCount <= 64 else { return [] }

        var uuids: [String] = []
        for index in 0..<Int(architectureCount) {
            let recordOffset = 8 + index * recordSize
            let rawSliceOffset: UInt64? = if uses64BitArchitectureRecords {
                self.readUInt64(data, at: recordOffset + 8, order: order)
            } else {
                self.readUInt32(data, at: recordOffset + 8, order: order).map(UInt64.init)
            }
            guard let rawSliceOffset, rawSliceOffset <= UInt64(Int.max) else { return [] }
            if let uuid = machOUUID(in: data, sliceOffset: Int(rawSliceOffset)) {
                uuids.append(uuid)
            }
        }
        return uuids
    }

    private nonisolated static func machOUUID(in data: Data, sliceOffset: Int) -> String? {
        guard let magic = readUInt32(data, at: sliceOffset, order: .little) else { return nil }
        let order: ByteOrder
        let headerSize: Int
        switch magic {
        case UInt32(MH_MAGIC):
            order = .little
            headerSize = 28
        case UInt32(MH_MAGIC_64):
            order = .little
            headerSize = 32
        case UInt32(MH_CIGAM):
            order = .big
            headerSize = 28
        case UInt32(MH_CIGAM_64):
            order = .big
            headerSize = 32
        default:
            return nil
        }

        guard let commandCount = readUInt32(data, at: sliceOffset + 16, order: order),
              let commandBytes = readUInt32(data, at: sliceOffset + 20, order: order),
              commandCount <= 16384
        else { return nil }
        var commandOffset = sliceOffset + headerSize
        let commandsEnd = commandOffset + Int(commandBytes)
        guard commandsEnd >= commandOffset, commandsEnd <= data.count else { return nil }

        for _ in 0..<Int(commandCount) {
            guard let command = readUInt32(data, at: commandOffset, order: order),
                  let rawCommandSize = readUInt32(data, at: commandOffset + 4, order: order)
            else { return nil }
            let commandSize = Int(rawCommandSize)
            guard commandSize >= 8, commandOffset + commandSize <= commandsEnd else { return nil }

            if command == UInt32(LC_UUID), commandSize >= 24 {
                let uuidRange = (commandOffset + 8)..<(commandOffset + 24)
                return data[uuidRange].map { String(format: "%02x", $0) }.joined()
            }

            commandOffset += commandSize
        }
        return nil
    }

    private nonisolated static func readUInt32(_ data: Data, at offset: Int, order: ByteOrder) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 4)]
        return bytes.enumerated().reduce(UInt32(0)) { partial, pair in
            let shift = switch order {
            case .little: pair.offset * 8
            case .big: (3 - pair.offset) * 8
            }
            return partial | UInt32(pair.element) << UInt32(shift)
        }
    }

    private nonisolated static func readUInt64(_ data: Data, at offset: Int, order: ByteOrder) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        let bytes = data[offset..<(offset + 8)]
        return bytes.enumerated().reduce(UInt64(0)) { partial, pair in
            let shift = switch order {
            case .little: pair.offset * 8
            case .big: (7 - pair.offset) * 8
            }
            return partial | UInt64(pair.element) << UInt64(shift)
        }
    }

    static func autoStartSocketPath(
        daemonSocketPath: String,
        defaultSocketWasOccupiedAndRejected: Bool,
        runtimeBuildIdentity: String
    ) -> String {
        guard defaultSocketWasOccupiedAndRejected,
              let buildScopedSocketPath = buildScopedDaemonSocketPath(
                  daemonSocketPath: daemonSocketPath,
                  runtimeBuildIdentity: runtimeBuildIdentity
              )
        else {
            return daemonSocketPath
        }

        return buildScopedSocketPath
    }

    static func buildScopedDaemonSocketPath(
        daemonSocketPath: String,
        runtimeBuildIdentity: String
    ) -> String? {
        guard self.standardizedSocketPath(daemonSocketPath) ==
            self.standardizedSocketPath(PeekabooBridgeConstants.daemonSocketPath)
        else { return nil }
        return URL(fileURLWithPath: daemonSocketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("daemon-\(self.stableHash(runtimeBuildIdentity)).sock")
            .path
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
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
        daemonSocketPath: String,
        buildScopedDaemonSocketPath: String? = nil
    ) -> ImplicitRuntimeCandidateRole? {
        let candidate = self.standardizedSocketPath(socketPath)
        if candidate == self.standardizedSocketPath(daemonSocketPath) ||
            buildScopedDaemonSocketPath.map(self.standardizedSocketPath) == candidate {
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
           let migrationArguments = migratedDaemonArguments(
               socketPath: socketPath,
               status: legacyStatus,
               fallbackIdleTimeoutSeconds: fallbackIdleTimeoutSeconds
           ) {
            if DaemonControlClient.supportsSafeMigration(legacyStatus),
               DaemonControlClient.isIdleForMigration(legacyStatus) {
                launchArguments = migrationArguments

                guard let replacement = await launchDaemon(
                    socketPath: socketPath,
                    arguments: launchArguments
                )
                else {
                    return await self.compatibleLegacyFallbackSocketPath {
                        await legacyClient.fetchReusableDaemonStatus()
                    }
                }

                do {
                    let stopped = try await legacyClient.stopAndWait(
                        waitSeconds: DaemonControlClient.defaultShutdownWaitSeconds,
                        expectedPID: legacyStatus.pid,
                        requireIdentityMatch: true
                    )
                    if !stopped {
                        if let currentLegacyStatus = await legacyClient.fetchReusableDaemonStatus() {
                            return await self.resolveLegacyStopRace(
                                legacyStatus: currentLegacyStatus,
                                client: client,
                                replacement: replacement,
                                replacementSocketPath: socketPath
                            )
                        }
                    }
                } catch {
                    if let currentLegacyStatus = await legacyClient.fetchReusableDaemonStatus() {
                        return await self.resolveLegacyStopRace(
                            legacyStatus: currentLegacyStatus,
                            client: client,
                            replacement: replacement,
                            replacementSocketPath: socketPath
                        )
                    }
                }
                return await client.fetchReusableDaemonStatus() != nil ? socketPath : nil
            }

            if let fallback = self.compatibleLegacyFallbackSocketPath(for: legacyStatus) {
                return fallback
            }
            // An incompatible legacy host cannot satisfy this caller. Leave it running and
            // start the current daemon on the free canonical socket instead.
            launchArguments = self.daemonArguments(
                socketPath: socketPath,
                mode: .auto,
                idleTimeoutSeconds: fallbackIdleTimeoutSeconds
            )
        }

        return await self.launchDaemon(
            socketPath: socketPath,
            arguments: launchArguments
        ) != nil ? socketPath : nil
    }

    static func compatibleLegacyFallbackSocketPath(for status: PeekabooDaemonStatus) -> String? {
        guard DaemonControlPlanner.supportsCurrentDaemon(status) else {
            return nil
        }
        return PeekabooBridgeConstants.peekabooSocketPath
    }

    static func compatibleLegacyFallbackSocketPath(
        refreshingWith fetchStatus: () async -> PeekabooDaemonStatus?
    ) async -> String? {
        guard let currentStatus = await fetchStatus() else { return nil }
        return self.compatibleLegacyFallbackSocketPath(for: currentStatus)
    }

    static func legacyStopRaceResolution(for status: PeekabooDaemonStatus) -> LegacyStopRaceResolution {
        if let fallback = self.compatibleLegacyFallbackSocketPath(for: status) {
            return .useLegacy(socketPath: fallback)
        }
        return .keepReplacement
    }

    static func legacyStopRaceSocketPath(
        replacementCleanupSucceeded: Bool,
        replacementIsReusable: Bool,
        legacySocketPath: String,
        replacementSocketPath: String
    ) -> String? {
        if replacementCleanupSucceeded {
            return legacySocketPath
        }
        return replacementIsReusable ? replacementSocketPath : nil
    }

    private static func resolveLegacyStopRace(
        legacyStatus: PeekabooDaemonStatus,
        client: DaemonControlClient,
        replacement: LaunchResult,
        replacementSocketPath: String
    ) async -> String? {
        switch self.legacyStopRaceResolution(for: legacyStatus) {
        case .keepReplacement:
            return await client.fetchReusableDaemonStatus() != nil ? replacementSocketPath : nil
        case let .useLegacy(socketPath):
            let cleanedUp = await self.stopReplacement(client: client, replacement: replacement)
            var replacementIsReusable = false
            if !cleanedUp {
                replacementIsReusable = await client.fetchReusableDaemonStatus() != nil
            }
            return self.legacyStopRaceSocketPath(
                replacementCleanupSucceeded: cleanedUp,
                replacementIsReusable: replacementIsReusable,
                legacySocketPath: socketPath,
                replacementSocketPath: replacementSocketPath
            )
        }
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
            guard !Task.isCancelled else { break }
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
            guard !Task.isCancelled else { break }
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
            guard !Task.isCancelled else { break }
        }

        return await client.fetchControllableDaemonStatus()?.pid != expectedPID
    }

    private static func standardizedSocketPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return (expanded as NSString).standardizingPath
    }
}
