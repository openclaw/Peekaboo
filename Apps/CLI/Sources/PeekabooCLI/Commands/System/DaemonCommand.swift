import Commander
import Darwin
import Foundation
import PeekabooBridge

/// Manage the Peekaboo headless daemon lifecycle.
@MainActor
struct DaemonCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "daemon",
        abstract: "Manage the headless Peekaboo daemon",
        discussion: """
        Control the on-demand Peekaboo daemon.

        Examples:
          peekaboo daemon start
          peekaboo daemon status
          peekaboo daemon stop
        """,
        subcommands: [Start.self, Stop.self, Status.self, Run.self],
        defaultSubcommand: Status.self,
        showHelpOnEmptyInvocation: false
    )
}

struct DaemonControlClient {
    static let defaultShutdownWaitSeconds =
        Int(ceil(PeekabooBridgeConstants.defaultRequestTimeoutSeconds)) + 2

    let socketPath: String
    let requestTimeoutSec: TimeInterval

    init(
        socketPath: String,
        requestTimeoutSec: TimeInterval = PeekabooBridgeConstants.defaultRequestTimeoutSeconds
    ) {
        self.socketPath = socketPath
        self.requestTimeoutSec = requestTimeoutSec
    }

    func fetchStatus() async -> PeekabooDaemonStatus? {
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: self.requestTimeoutSec)
        do {
            return try await client.daemonStatus()
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            if envelope.code == .operationNotSupported {
                return await self.fallbackHandshake(client: client)
            }
            return nil
        } catch {
            return nil
        }
    }

    func stopDaemon(expectedPID: pid_t? = nil) async throws -> Bool {
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: self.requestTimeoutSec)
        if let expectedPID {
            return try await client.daemonStop(expectedPID: expectedPID)
        }
        return try await client.daemonStop()
    }

    func fetchControllableDaemonStatus() async -> PeekabooDaemonStatus? {
        guard let status = await fetchStatus(),
              Self.isControllableDaemonStatus(status)
        else {
            return nil
        }
        return status
    }

    func fetchReusableDaemonStatus() async -> PeekabooDaemonStatus? {
        guard let status = await fetchStatus(),
              Self.isReusableDaemonStatus(status)
        else {
            return nil
        }
        return status
    }

    static func isControllableDaemonStatus(_ status: PeekabooDaemonStatus) -> Bool {
        status.mode != nil
    }

    static func isReusableDaemonStatus(_ status: PeekabooDaemonStatus) -> Bool {
        status.mode == .auto || status.mode == .manual
    }

    static func migrationMode(for status: PeekabooDaemonStatus) -> PeekabooDaemonMode? {
        self.isReusableDaemonStatus(status) ? status.mode : nil
    }

    static func isIdleForMigration(_ status: PeekabooDaemonStatus) -> Bool {
        status.activity?.activeRequests ?? 0 == 0
    }

    static func supportsSafeMigration(_ status: PeekabooDaemonStatus) -> Bool {
        status.supportsConditionalStop == true
    }

    func stopAndWait(
        waitSeconds: Int,
        expectedPID: pid_t?,
        requireIdentityMatch: Bool = false
    ) async throws -> Bool {
        var requestError: (any Error)?
        var accepted = false
        do {
            accepted = try await self.stopDaemon(
                expectedPID: requireIdentityMatch ? expectedPID : nil
            )
        } catch {
            requestError = error
        }

        if !accepted, requestError == nil {
            return false
        }

        let deadline = Date().addingTimeInterval(TimeInterval(waitSeconds))
        while Date() < deadline {
            if await self.fetchControllableDaemonStatus() == nil {
                if let expectedPID {
                    if !Self.isProcessAlive(expectedPID) {
                        return true
                    }
                } else if requestError == nil {
                    return true
                }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        if let requestError {
            throw requestError
        }
        return false
    }

    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    private func fallbackHandshake(client: PeekabooBridgeClient) async -> PeekabooDaemonStatus? {
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: Host.current().name
        )
        do {
            let handshake = try await client.handshake(client: identity)
            let bridge = PeekabooDaemonBridgeStatus(
                socketPath: socketPath,
                hostKind: handshake.hostKind,
                allowedOperations: handshake.supportedOperations,
                availableOperationNames: handshake.supportedOperations.map(\.rawValue).sorted()
            )
            return PeekabooDaemonStatus(
                running: true,
                pid: nil,
                startedAt: nil,
                mode: nil,
                bridge: bridge,
                permissions: handshake.permissions,
                snapshots: nil,
                windowTracker: nil
            )
        } catch {
            return nil
        }
    }
}

struct DaemonControlTarget {
    let client: DaemonControlClient
    let status: PeekabooDaemonStatus
    let role: DaemonControlTargetRole

    var isLegacyDefault: Bool {
        self.role == .legacyDefault
    }
}

enum DaemonControlTargetRole: Equatable {
    case explicit
    case defaultDaemon
    case buildScopedDaemon
    case legacyDefault
}

struct DaemonSocketFileCandidate: Equatable {
    let path: String
    let isSocket: Bool
    let ownerUID: uid_t
}

enum DaemonStartAction: Equatable {
    case useExisting(socketPath: String)
    case launchManual(socketPath: String)
    case promoteAutoToManual(socketPath: String, pid: pid_t)
    case rejectBusy(socketPath: String)
    case rejectUnsafe(socketPath: String)
    case rejectIncompatible(socketPath: String)
}

enum DaemonControlPlanner {
    private static let currentOperationNames: Set<String> = [
        PeekabooBridgeOperation.launchApplicationWithOptions.rawValue,
        PeekabooBridgeOperation.relaunchApplicationWithOptions.rawValue,
        PeekabooBridgeOperation.invalidateImplicitLatestSnapshot.rawValue,
    ]

    static func supportsCurrentDaemon(_ status: PeekabooDaemonStatus) -> Bool {
        guard let bridge = status.bridge else { return false }
        let availableNames = Set(
            bridge.availableOperationNames ?? bridge.allowedOperations.map(\.rawValue)
        )
        return self.currentOperationNames.isSubset(of: availableNames)
    }

    static func preferredStatusTarget(
        _ targets: [DaemonControlTarget],
        explicitSocket: String?
    ) -> DaemonControlTarget? {
        if explicitSocket != nil {
            return targets.first
        }

        let defaultTarget = targets.first { $0.role == .defaultDaemon }
        if let defaultTarget, self.isCurrentReusableTarget(defaultTarget) {
            return defaultTarget
        }
        let scopedTargets = targets.filter { $0.role == .buildScopedDaemon }
        if let scopedTarget = scopedTargets.first(where: self.isCurrentReusableTarget) {
            return scopedTarget
        }
        return defaultTarget ?? scopedTargets.first ?? targets.first
    }

    static func additionalSocketPaths(
        in targets: [DaemonControlTarget],
        excluding selected: DaemonControlTarget
    ) -> [String] {
        targets
            .filter { $0.client.socketPath != selected.client.socketPath }
            .map(\.client.socketPath)
    }

    static func startAction(
        targets: [DaemonControlTarget],
        explicitSocket: String?,
        defaultSocketPath: String,
        buildScopedSocketPath: String?
    ) -> DaemonStartAction {
        if let explicitSocket {
            guard let target = targets.first else {
                return .launchManual(socketPath: explicitSocket)
            }
            return self.action(forExisting: target)
        }

        let defaultTarget = targets.first { $0.role == .defaultDaemon }
        let scopedTargets = targets.filter { $0.role == .buildScopedDaemon }
        if let defaultTarget, self.isCurrentReusableTarget(defaultTarget) {
            return self.action(forExisting: defaultTarget)
        }
        if let scopedTarget = scopedTargets.first(where: self.isCurrentReusableTarget) {
            return self.action(forExisting: scopedTarget)
        }
        if defaultTarget != nil, let buildScopedSocketPath {
            if scopedTargets.contains(where: { $0.client.socketPath == buildScopedSocketPath }) {
                return .rejectIncompatible(socketPath: buildScopedSocketPath)
            }
            return .launchManual(socketPath: buildScopedSocketPath)
        }
        if let defaultTarget {
            return .rejectIncompatible(socketPath: defaultTarget.client.socketPath)
        }
        return .launchManual(socketPath: defaultSocketPath)
    }

    static func shouldMigrateLegacyTarget(
        explicitSocket: String?,
        destinationSocketPath: String,
        defaultSocketPath: String,
        targets: [DaemonControlTarget]
    ) -> Bool {
        explicitSocket == nil &&
            NSString(string: destinationSocketPath).standardizingPath ==
            NSString(string: defaultSocketPath).standardizingPath &&
            !targets.contains { $0.role == .defaultDaemon }
    }

    private static func action(forExisting target: DaemonControlTarget) -> DaemonStartAction {
        guard DaemonControlClient.isReusableDaemonStatus(target.status) else {
            return .rejectIncompatible(socketPath: target.client.socketPath)
        }
        guard target.status.mode == .auto else {
            return .useExisting(socketPath: target.client.socketPath)
        }
        guard DaemonControlClient.isIdleForMigration(target.status) else {
            return .rejectBusy(socketPath: target.client.socketPath)
        }
        guard DaemonControlClient.supportsSafeMigration(target.status),
              let pid = target.status.pid
        else {
            return .rejectUnsafe(socketPath: target.client.socketPath)
        }
        return .promoteAutoToManual(socketPath: target.client.socketPath, pid: pid)
    }

    private static func isCurrentReusableTarget(_ target: DaemonControlTarget) -> Bool {
        DaemonControlClient.isReusableDaemonStatus(target.status) && self.supportsCurrentDaemon(target.status)
    }
}

enum DaemonControlResolver {
    private static let historicalProbeTimeoutSeconds: TimeInterval = 1

    static func defaultSocketPaths() -> [String] {
        let buildScopedPath = DaemonLaunchPolicy.buildScopedDaemonSocketPath(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            runtimeBuildIdentity: DaemonLaunchPolicy.runtimeBuildIdentity()
        )
        return [PeekabooBridgeConstants.daemonSocketPath, buildScopedPath].compactMap(\.self)
    }

    static func historicalBuildScopedSocketPaths(
        daemonSocketPath: String,
        currentBuildScopedSocketPath: String?,
        candidates: [DaemonSocketFileCandidate],
        currentUID: uid_t = getuid()
    ) -> [String] {
        let daemonDirectory = Self.standardizedSocketPath(
            URL(fileURLWithPath: daemonSocketPath).deletingLastPathComponent().path
        )
        let excludedPaths = Set([daemonSocketPath, currentBuildScopedSocketPath].compactMap { path in
            path.map(Self.standardizedSocketPath)
        })
        return candidates
            .filter { candidate in
                candidate.isSocket &&
                    candidate.ownerUID == currentUID &&
                    Self.standardizedSocketPath(
                        URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path
                    ) == daemonDirectory &&
                    Self.isBuildScopedSocketName(URL(fileURLWithPath: candidate.path).lastPathComponent) &&
                    !excludedPaths.contains(Self.standardizedSocketPath(candidate.path))
            }
            .map(\.path)
            .sorted()
    }

    static func isValidatedHistoricalTarget(
        status: PeekabooDaemonStatus,
        socketPath: String
    ) -> Bool {
        guard status.running,
              DaemonControlClient.isReusableDaemonStatus(status),
              DaemonControlClient.supportsSafeMigration(status),
              status.pid.map({ $0 > 0 }) == true,
              let bridge = status.bridge,
              bridge.hostKind == .onDemand,
              standardizedSocketPath(bridge.socketPath) == standardizedSocketPath(socketPath)
        else {
            return false
        }
        let operationNames = Set(bridge.availableOperationNames ?? bridge.allowedOperations.map(\.rawValue))
        return operationNames.contains(PeekabooBridgeOperation.daemonStatus.rawValue) &&
            operationNames.contains(PeekabooBridgeOperation.daemonStop.rawValue)
    }

    static func targets(explicitSocket: String?) async -> [DaemonControlTarget] {
        if let explicitSocket {
            let client = DaemonControlClient(socketPath: explicitSocket)
            guard let status = await client.fetchStatus() else { return [] }
            return [DaemonControlTarget(client: client, status: status, role: .explicit)]
        }

        var targets: [DaemonControlTarget] = []
        let defaultSocketPaths = self.defaultSocketPaths()
        for (index, socketPath) in defaultSocketPaths.enumerated() {
            let client = DaemonControlClient(socketPath: socketPath)
            if let status = await client.fetchControllableDaemonStatus() {
                targets.append(DaemonControlTarget(
                    client: client,
                    status: status,
                    role: index == 0 ? .defaultDaemon : .buildScopedDaemon
                ))
            }
        }

        await targets.append(contentsOf: self.validatedHistoricalTargets(
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            currentBuildScopedSocketPath: defaultSocketPaths.dropFirst().first
        ))

        let legacyClient = DaemonControlClient(socketPath: PeekabooBridgeConstants.peekabooSocketPath)
        if let status = await legacyClient.fetchControllableDaemonStatus() {
            targets.append(DaemonControlTarget(
                client: legacyClient,
                status: status,
                role: .legacyDefault
            ))
        }
        return targets
    }

    static func validatedHistoricalTargets(
        daemonSocketPath: String,
        currentBuildScopedSocketPath: String?
    ) async -> [DaemonControlTarget] {
        var targets: [DaemonControlTarget] = []
        for socketPath in self.discoveredHistoricalBuildScopedSocketPaths(
            daemonSocketPath: daemonSocketPath,
            currentBuildScopedSocketPath: currentBuildScopedSocketPath
        ) {
            let client = DaemonControlClient(
                socketPath: socketPath,
                requestTimeoutSec: self.historicalProbeTimeoutSeconds
            )
            guard let status = await client.fetchControllableDaemonStatus(),
                  self.isValidatedHistoricalTarget(status: status, socketPath: socketPath)
            else {
                continue
            }
            targets.append(DaemonControlTarget(
                client: client,
                status: status,
                role: .buildScopedDaemon
            ))
        }
        return targets
    }

    private static func discoveredHistoricalBuildScopedSocketPaths(
        daemonSocketPath: String,
        currentBuildScopedSocketPath: String?
    ) -> [String] {
        let directoryURL = URL(fileURLWithPath: daemonSocketPath).deletingLastPathComponent()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        else {
            return []
        }
        let candidates = urls.compactMap { url -> DaemonSocketFileCandidate? in
            var info = stat()
            guard lstat(url.path, &info) == 0 else { return nil }
            return DaemonSocketFileCandidate(
                path: url.path,
                isSocket: info.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK),
                ownerUID: info.st_uid
            )
        }
        return self.historicalBuildScopedSocketPaths(
            daemonSocketPath: daemonSocketPath,
            currentBuildScopedSocketPath: currentBuildScopedSocketPath,
            candidates: candidates
        )
    }

    static func isBuildScopedSocketName(_ name: String) -> Bool {
        guard name.hasPrefix("daemon-"), name.hasSuffix(".sock") else { return false }
        let hash = name.dropFirst("daemon-".count).dropLast(".sock".count)
        return hash.count == 16 && hash.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    private static func standardizedSocketPath(_ path: String) -> String {
        NSString(string: path).standardizingPath
    }
}

enum DaemonPaths {
    static func daemonLogURL() -> URL {
        URL(fileURLWithPath: ConfigurationManager.baseDir, isDirectory: true)
            .appendingPathComponent("daemon.log")
    }

    static func openDaemonLogForAppend() -> FileHandle? {
        self.openFileForAppend(at: self.daemonLogURL())
    }

    static func daemonStartupLockURL(socketPath: String? = nil) -> URL {
        if let socketPath = socketPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !socketPath.isEmpty {
            let socketURL = URL(
                fileURLWithPath: (socketPath as NSString).expandingTildeInPath
            ).standardizedFileURL
            let defaultSocketURL = URL(
                fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath
            ).standardizedFileURL
            // Build-scoped fallback daemons share lifecycle promotion with the canonical daemon.
            let isBuildScopedDefault = socketURL.deletingLastPathComponent() ==
                defaultSocketURL.deletingLastPathComponent() &&
                DaemonControlResolver.isBuildScopedSocketName(socketURL.lastPathComponent)
            if socketURL != defaultSocketURL, !isBuildScopedDefault {
                return URL(fileURLWithPath: "\(socketURL.path).start.lock")
            }
        }

        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".peekaboo", isDirectory: true)
            .appendingPathComponent("daemon-start.lock")
    }

    static func openFileForAppend(at fileURL: URL) -> FileHandle? {
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        return handle
    }
}

enum DaemonStatusPrinter {
    static func render(status: PeekabooDaemonStatus) {
        print("Peekaboo Daemon")
        print("==============")

        guard status.running else {
            print("Status: not running")
            return
        }

        if let mode = status.mode {
            print("Mode: \(mode.rawValue)")
        }
        if let pid = status.pid {
            print("PID: \(pid)")
        }
        if let startedAt = status.startedAt {
            print("Started: \(Self.formatDate(startedAt))")
        }

        if let bridge = status.bridge {
            print("")
            print("Bridge")
            print("------")
            print("Socket: \(bridge.socketPath)")
            print("Host: \(bridge.hostKind.rawValue)")
            print("Ops: \(bridge.availableOperationNames?.count ?? bridge.allowedOperations.count)")
        }

        if let permissions = status.permissions {
            print("")
            print("Permissions")
            print("-----------")
            print("Screen Recording: \(permissions.screenRecording ? "granted" : "missing")")
            print("Accessibility: \(permissions.accessibility ? "granted" : "missing")")
            if permissions.appleScript {
                print("AppleScript: granted")
            }
        }

        if let snapshots = status.snapshots {
            print("")
            print("Snapshots")
            print("---------")
            print("Backend: \(snapshots.backend)")
            print("Count: \(snapshots.snapshotCount)")
            if let lastAccessedAt = snapshots.lastAccessedAt {
                print("Last Access: \(Self.formatDate(lastAccessedAt))")
            }
            print("Path: \(snapshots.storagePath)")
        }

        if let tracker = status.windowTracker {
            print("")
            print("Window Tracker")
            print("--------------")
            print("Tracked Windows: \(tracker.trackedWindows)")
            if let lastEventAt = tracker.lastEventAt {
                print("Last Event: \(Self.formatDate(lastEventAt))")
            }
            if let lastPollAt = tracker.lastPollAt {
                print("Last Poll: \(Self.formatDate(lastPollAt))")
            }
            print("AX Observers: \(tracker.axObserverCount)")
            print("Poll Interval: \(tracker.cgPollIntervalMs)ms")
        }

        if let browser = status.browser {
            print("")
            print("Browser MCP")
            print("-----------")
            print("Connected: \(browser.isConnected ? "yes" : "no")")
            print("Tools: \(browser.toolCount)")
            print("Detected Chrome: \(browser.detectedBrowsers.count)")
        }

        if let activity = status.activity {
            print("")
            print("Activity")
            print("--------")
            print("Active Requests: \(activity.activeRequests)")
            if let lastActivityAt = activity.lastActivityAt {
                print("Last Activity: \(Self.formatDate(lastActivityAt))")
            }
            if let idleTimeoutSeconds = activity.idleTimeoutSeconds {
                print("Idle Timeout: \(String(format: "%.0f", idleTimeoutSeconds))s")
            }
            if let idleExitAt = activity.idleExitAt {
                print("Idle Exit: \(Self.formatDate(idleExitAt))")
            }
        }
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
