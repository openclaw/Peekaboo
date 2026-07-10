import Darwin
import Foundation
import MachO
import PeekabooBridge

enum DaemonLaunchPolicy {
    /// Retains the Foundation process until its termination source has reaped the child.
    private final nonisolated class ProcessExitObserver: @unchecked Sendable {
        private let lock = NSLock()
        private var retainedProcess: Process?
        private var didExit = false
        private var nextWaiterID = 0
        private var waiters: [Int: CheckedContinuation<Bool, Never>] = [:]

        init(process: Process) {
            self.retainedProcess = process
        }

        func processDidExit() {
            self.lock.lock()
            guard !self.didExit else {
                self.lock.unlock()
                return
            }
            self.didExit = true
            self.retainedProcess = nil
            let continuations = Array(self.waiters.values)
            self.waiters.removeAll()
            self.lock.unlock()

            for continuation in continuations {
                continuation.resume(returning: true)
            }
        }

        func wait(timeout: TimeInterval) async -> Bool {
            await withCheckedContinuation { continuation in
                self.lock.lock()
                guard !self.didExit else {
                    self.lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                self.nextWaiterID += 1
                let waiterID = self.nextWaiterID
                self.waiters[waiterID] = continuation
                self.lock.unlock()

                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + max(0, timeout)
                ) {
                    self.timeout(waiterID: waiterID)
                }
            }
        }

        private func timeout(waiterID: Int) {
            self.lock.lock()
            let continuation = self.waiters.removeValue(forKey: waiterID)
            self.lock.unlock()
            continuation?.resume(returning: false)
        }
    }

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

    enum DaemonLaunchError: LocalizedError {
        case executableNotFound(argument: String?)
        case launchFailed(executableURL: URL, underlyingError: any Error)
        case exited(executableURL: URL, status: Int32, logURL: URL)
        case timedOut(timeout: TimeInterval, logURL: URL)

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(argument):
                let executable = argument.map { "'\($0)'" } ?? "the current executable"
                return "Could not resolve \(executable) to launch the Peekaboo daemon"
            case let .launchFailed(executableURL, underlyingError):
                return "Could not launch the Peekaboo daemon at \(executableURL.path): " +
                    underlyingError.localizedDescription
            case let .exited(executableURL, status, logURL):
                return "Peekaboo daemon at \(executableURL.path) exited before becoming ready " +
                    "(status \(status)); see \(logURL.path)"
            case let .timedOut(timeout, logURL):
                let seconds = timeout.rounded() == timeout
                    ? String(Int(timeout))
                    : String(format: "%.1f", timeout)
                return "Peekaboo daemon did not become ready within \(seconds)s; see \(logURL.path)"
            }
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

    static func daemonExecutableURL(
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        ),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> URL? {
        // Foundation's Process launches an exact filesystem path; it never searches PATH for a bare argv[0].
        if let bundleExecutableURL, bundleExecutableURL.isFileURL {
            return bundleExecutableURL.standardizedFileURL
        }

        guard let argument = arguments.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !argument.isEmpty
        else { return nil }

        if argument.contains("/") {
            return URL(fileURLWithPath: argument, relativeTo: currentDirectoryURL).standardizedFileURL
        }

        guard let path = environment["PATH"] else { return nil }
        for pathComponent in path.split(separator: ":", omittingEmptySubsequences: false) {
            let directoryURL = pathComponent.isEmpty
                ? currentDirectoryURL
                : URL(fileURLWithPath: String(pathComponent), relativeTo: currentDirectoryURL)
            let candidate = directoryURL.appendingPathComponent(argument).standardizedFileURL
            if isExecutableFile(candidate.path) {
                return candidate
            }
        }
        return nil
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

    @MainActor
    static func startOnDemandDaemon(socketPath: String, environment: [String: String]) async -> String? {
        try? await DaemonStartupGate.withExclusiveStartup(
            lockURL: DaemonPaths.daemonStartupLockURL(socketPath: socketPath)
        ) { _ in
            await self.startOnDemandDaemonWithStartupLockHeld(
                socketPath: socketPath,
                environment: environment
            )
        }
    }

    @MainActor
    private static func startOnDemandDaemonWithStartupLockHeld(
        socketPath: String,
        environment: [String: String]
    ) async -> String? {
        let client = DaemonControlClient(socketPath: socketPath)

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

                guard let replacement = try? await launchDaemon(
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

        do {
            _ = try await self.launchDaemon(
                socketPath: socketPath,
                arguments: launchArguments
            )
            return socketPath
        } catch {
            return nil
        }
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
        timeout: TimeInterval = 3,
        executableURL: URL? = nil,
        logHandle: FileHandle? = nil
    ) async throws -> LaunchResult {
        try Task.checkCancellation()
        guard let executableURL = executableURL ?? self.daemonExecutableURL() else {
            throw DaemonLaunchError.executableNotFound(argument: CommandLine.arguments.first)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let daemonLogURL = DaemonPaths.daemonLogURL()
        let outputHandle = logHandle ?? DaemonPaths.openDaemonLogForAppend() ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw DaemonLaunchError.launchFailed(executableURL: executableURL, underlyingError: error)
        }
        let exitObserver = ProcessExitObserver(process: process)
        process.terminationHandler = { _ in
            exitObserver.processDidExit()
        }

        let deadline = Date().addingTimeInterval(timeout)
        let client = DaemonControlClient(socketPath: socketPath)
        while Date() < deadline {
            let status = await client.fetchReusableDaemonStatus()
            if Task.isCancelled {
                await self.terminateLaunchedProcess(process, exitObserver: exitObserver)
                throw CancellationError()
            }
            if let status {
                let processID = process.processIdentifier
                if status.pid != processID {
                    await self.terminateLaunchedProcess(process, exitObserver: exitObserver)
                }
                return LaunchResult(status: status, processID: processID)
            }
            if !process.isRunning {
                throw DaemonLaunchError.exited(
                    executableURL: executableURL,
                    status: process.terminationStatus,
                    logURL: daemonLogURL
                )
            }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                await self.terminateLaunchedProcess(process, exitObserver: exitObserver)
                throw error
            }
        }
        if !process.isRunning {
            throw DaemonLaunchError.exited(
                executableURL: executableURL,
                status: process.terminationStatus,
                logURL: daemonLogURL
            )
        }
        await self.terminateLaunchedProcess(process, exitObserver: exitObserver)
        throw DaemonLaunchError.timedOut(timeout: timeout, logURL: daemonLogURL)
    }

    private static func terminateLaunchedProcess(
        _ process: Process,
        exitObserver: ProcessExitObserver
    ) async {
        guard process.isRunning else { return }

        process.terminate()
        let exitedAfterTermination = await exitObserver.wait(timeout: 0.5)
        guard !exitedAfterTermination else { return }
        guard process.isRunning else { return }

        _ = kill(process.processIdentifier, SIGKILL)
        // `Process.waitUntilExit()` can itself block indefinitely on a wedged Foundation
        // process source. The termination handler retains and eventually reaps the child,
        // while this caller waits for only a bounded SIGKILL grace period.
        _ = await exitObserver.wait(timeout: 1)
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
