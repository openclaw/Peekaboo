import Commander
import Darwin
import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct DaemonCommandTests {
    @Test
    func `DaemonCommand description`() {
        let config = DaemonCommand.commandDescription
        #expect(config.commandName == "daemon")
        #expect(config.abstract == "Manage the headless Peekaboo daemon")
        #expect(config.subcommands.count == 4)
    }

    @Test
    func `Daemon start defaults`() throws {
        let command = try DaemonCommand.Start.parse([])
        #expect(command.bridgeSocket == nil)
        #expect(command.pollIntervalMs == nil)
        #expect(command.waitSeconds == 3)
    }

    @Test
    func `Daemon start accepts an immediate readiness deadline`() throws {
        let command = try DaemonCommand.Start.parse(["--wait", "0"])
        #expect(command.waitSeconds == 0)
    }

    @Test
    func `Daemon stop defaults`() throws {
        let command = try DaemonCommand.Stop.parse([])
        #expect(command.bridgeSocket == nil)
        #expect(command.waitSeconds == DaemonControlClient.defaultShutdownWaitSeconds)
    }

    @Test
    func `Daemon status defaults`() throws {
        let command = try DaemonCommand.Status.parse([])
        #expect(command.bridgeSocket == nil)
    }

    @Test
    func `Daemon run parsing`() throws {
        let args = [
            "--mode",
            "auto",
            "--bridge-socket",
            "/tmp/peekaboo.sock",
            "--poll-interval",
            "500ms",
            "--idle-timeout",
            "2.5s",
        ]
        let command = try DaemonCommand.Run.parse(args)
        #expect(command.mode == "auto")
        #expect(command.bridgeSocket == "/tmp/peekaboo.sock")
        #expect(command.pollInterval?.roundedMilliseconds == 500)
        #expect(command.idleTimeout?.seconds == 2.5)
    }

    @Test
    func `standalone MCP daemon mode is rejected`() {
        #expect(throws: ValidationError.self) {
            try DaemonCommand.Run.configuration(
                mode: "mcp",
                bridgeSocket: nil,
                pollInterval: 1,
                idleTimeoutSeconds: nil
            )
        }
    }

    @Test
    func `legacy migration accepts daemon status only`() {
        let bridge = PeekabooDaemonBridgeStatus(
            socketPath: "/tmp/bridge.sock",
            hostKind: .onDemand,
            allowedOperations: [.daemonStatus, .daemonStop]
        )
        let daemon = PeekabooDaemonStatus(
            running: true,
            mode: .manual,
            bridge: bridge,
            supportsConditionalStop: true
        )
        let legacyMCPDaemon = PeekabooDaemonStatus(
            running: true,
            mode: .mcp,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: "/tmp/bridge.sock",
                hostKind: .inProcess,
                allowedOperations: [.daemonStatus, .daemonStop]
            )
        )
        let appHost = PeekabooDaemonStatus(
            running: true,
            mode: nil,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: "/tmp/bridge.sock",
                hostKind: .gui,
                allowedOperations: [.permissionsStatus]
            )
        )

        #expect(DaemonControlClient.isControllableDaemonStatus(daemon))
        #expect(DaemonControlClient.isControllableDaemonStatus(legacyMCPDaemon))
        #expect(!DaemonControlClient.isControllableDaemonStatus(appHost))
        #expect(DaemonControlClient.isReusableDaemonStatus(daemon))
        #expect(!DaemonControlClient.isReusableDaemonStatus(legacyMCPDaemon))
        #expect(!DaemonControlClient.isReusableDaemonStatus(appHost))
        #expect(DaemonControlClient.migrationMode(for: daemon) == .manual)
        #expect(DaemonControlClient.migrationMode(for: legacyMCPDaemon) == nil)
        #expect(DaemonControlClient.migrationMode(for: appHost) == nil)
        #expect(DaemonControlClient.supportsSafeMigration(daemon))
        #expect(!DaemonControlClient.supportsSafeMigration(legacyMCPDaemon))

        let autoDaemon = PeekabooDaemonStatus(
            running: true,
            mode: .auto,
            bridge: bridge,
            supportsConditionalStop: true
        )
        #expect(DaemonControlClient.migrationMode(for: autoDaemon) == .auto)
        #expect(DaemonControlClient.isIdleForMigration(autoDaemon))

        let busyDaemon = PeekabooDaemonStatus(
            running: true,
            mode: .auto,
            bridge: bridge,
            activity: PeekabooDaemonActivityStatus(
                activeRequests: 1,
                lastActivityAt: nil,
                idleTimeoutSeconds: 300,
                idleExitAt: nil
            ),
            supportsConditionalStop: true
        )
        #expect(!DaemonControlClient.isIdleForMigration(busyDaemon))
    }

    @Test
    func `legacy stop race uses current socket owner compatibility`() {
        let initiallyCompatibleLegacy = Self.target(
            role: .legacyDefault,
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            mode: .auto,
            current: true
        ).status
        let replacementIncompatibleLegacy = Self.target(
            role: .legacyDefault,
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            mode: .auto,
            current: false
        ).status
        let replacementCompatibleLegacy = Self.target(
            role: .legacyDefault,
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            mode: .auto,
            current: true
        ).status

        #expect(DaemonLaunchPolicy.legacyStopRaceResolution(for: initiallyCompatibleLegacy) ==
            .useLegacy(socketPath: PeekabooBridgeConstants.peekabooSocketPath))
        #expect(DaemonLaunchPolicy.legacyStopRaceResolution(for: replacementIncompatibleLegacy) == .keepReplacement)
        #expect(DaemonLaunchPolicy.legacyStopRaceResolution(for: replacementCompatibleLegacy) ==
            .useLegacy(socketPath: PeekabooBridgeConstants.peekabooSocketPath))
    }

    @Test
    func `failed replacement launch refreshes legacy socket owner before fallback`() async {
        let replacementIncompatibleLegacy = Self.target(
            role: .legacyDefault,
            socketPath: PeekabooBridgeConstants.peekabooSocketPath,
            mode: .auto,
            current: false
        ).status
        var refreshCount = 0

        let fallback = await DaemonLaunchPolicy.compatibleLegacyFallbackSocketPath {
            refreshCount += 1
            return replacementIncompatibleLegacy
        }

        #expect(refreshCount == 1)
        #expect(fallback == nil)
    }

    @Test
    func `failed replacement cleanup keeps a reusable replacement`() {
        let replacementSocketPath = "/tmp/replacement.sock"
        let selected = DaemonLaunchPolicy.legacyStopRaceSocketPath(
            replacementCleanupSucceeded: false,
            replacementIsReusable: true,
            legacySocketPath: PeekabooBridgeConstants.peekabooSocketPath,
            replacementSocketPath: replacementSocketPath
        )

        #expect(selected == replacementSocketPath)
        #expect(DaemonLaunchPolicy.legacyStopRaceSocketPath(
            replacementCleanupSucceeded: true,
            replacementIsReusable: false,
            legacySocketPath: PeekabooBridgeConstants.peekabooSocketPath,
            replacementSocketPath: replacementSocketPath
        ) == PeekabooBridgeConstants.peekabooSocketPath)
    }

    @Test
    func `old default daemon does not mask current scoped status`() throws {
        let oldDefault = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/default.sock",
            mode: .manual,
            current: false
        )
        let scoped = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/scoped.sock",
            mode: .manual,
            current: true
        )

        let selected = try #require(DaemonControlPlanner.preferredStatusTarget(
            [oldDefault, scoped],
            explicitSocket: nil
        ))

        #expect(selected.client.socketPath == "/tmp/scoped.sock")
        #expect(DaemonControlPlanner.additionalSocketPaths(
            in: [oldDefault, scoped],
            excluding: selected
        ) == ["/tmp/default.sock"])
    }

    @Test
    func `historical scoped socket discovery rejects unrelated files`() {
        let daemonSocketPath = "/tmp/peekaboo/daemon.sock"
        let currentSocketPath = "/tmp/peekaboo/daemon-aaaaaaaaaaaaaaaa.sock"
        let candidates = [
            DaemonSocketFileCandidate(
                path: "/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock",
                isSocket: true,
                ownerUID: 501
            ),
            DaemonSocketFileCandidate(path: currentSocketPath, isSocket: true, ownerUID: 501),
            DaemonSocketFileCandidate(
                path: "/tmp/peekaboo/daemon-cccccccccccccccc.sock",
                isSocket: false,
                ownerUID: 501
            ),
            DaemonSocketFileCandidate(
                path: "/tmp/peekaboo/daemon-dddddddddddddddd.sock",
                isSocket: true,
                ownerUID: 502
            ),
            DaemonSocketFileCandidate(
                path: "/tmp/other/daemon-eeeeeeeeeeeeeeee.sock",
                isSocket: true,
                ownerUID: 501
            ),
            DaemonSocketFileCandidate(
                path: "/tmp/peekaboo/unrelated.sock",
                isSocket: true,
                ownerUID: 501
            ),
            DaemonSocketFileCandidate(
                path: "/tmp/peekaboo/daemon-ABCDEF0123456789.sock",
                isSocket: true,
                ownerUID: 501
            ),
        ]

        #expect(DaemonControlResolver.historicalBuildScopedSocketPaths(
            daemonSocketPath: daemonSocketPath,
            currentBuildScopedSocketPath: currentSocketPath,
            candidates: candidates,
            currentUID: 501
        ) == ["/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock"])
    }

    @Test
    func `historical scoped target validation rejects spoofed daemon identity`() {
        let socketPath = "/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock"
        let valid = Self.target(
            role: .buildScopedDaemon,
            socketPath: socketPath,
            mode: .manual,
            current: false
        )
        let mismatchedPath = Self.target(
            role: .buildScopedDaemon,
            socketPath: socketPath,
            mode: .manual,
            current: false,
            reportedSocketPath: "/tmp/peekaboo/daemon-cccccccccccccccc.sock"
        )
        let wrongHost = Self.target(
            role: .buildScopedDaemon,
            socketPath: socketPath,
            mode: .manual,
            current: false,
            hostKind: .gui
        )
        let unsafe = Self.target(
            role: .buildScopedDaemon,
            socketPath: socketPath,
            mode: .manual,
            current: false,
            supportsConditionalStop: false
        )

        #expect(DaemonControlResolver.isValidatedHistoricalTarget(
            status: valid.status,
            socketPath: socketPath
        ))
        #expect(!DaemonControlResolver.isValidatedHistoricalTarget(
            status: mismatchedPath.status,
            socketPath: socketPath
        ))
        #expect(!DaemonControlResolver.isValidatedHistoricalTarget(
            status: wrongHost.status,
            socketPath: socketPath
        ))
        #expect(!DaemonControlResolver.isValidatedHistoricalTarget(
            status: unsafe.status,
            socketPath: socketPath
        ))
    }

    @Test
    func `historical cleanup stops only managed automatic daemons past their idle deadline`() {
        let daemonSocketPath = PeekabooBridgeConstants.daemonSocketPath
        let directory = URL(fileURLWithPath: daemonSocketPath).deletingLastPathComponent()
        let currentSocketPath = directory.appendingPathComponent("daemon-aaaaaaaaaaaaaaaa.sock").path
        let eligibleSocketPath = directory.appendingPathComponent("daemon-bbbbbbbbbbbbbbbb.sock").path
        let notYetIdleSocketPath = directory.appendingPathComponent("daemon-abababababababab.sock").path
        let manualSocketPath = directory.appendingPathComponent("daemon-cccccccccccccccc.sock").path
        let busySocketPath = directory.appendingPathComponent("daemon-dddddddddddddddd.sock").path
        let unknownActivitySocketPath = directory.appendingPathComponent("daemon-eeeeeeeeeeeeeeee.sock").path
        let unknownPIDSocketPath = directory.appendingPathComponent("daemon-ffffffffffffffff.sock").path
        let wrongHostSocketPath = directory.appendingPathComponent("daemon-1111111111111111.sock").path
        let wrongIdentitySocketPath = directory.appendingPathComponent("daemon-2222222222222222.sock").path
        let unsafeSocketPath = directory.appendingPathComponent("daemon-3333333333333333.sock").path
        let defaultTarget = Self.target(
            role: .defaultDaemon,
            socketPath: daemonSocketPath,
            mode: .auto,
            current: true,
            pid: 1000
        )
        let targets = [
            Self.target(
                role: .buildScopedDaemon,
                socketPath: eligibleSocketPath,
                mode: .auto,
                current: true,
                pid: 1001,
                idleExitAt: Date(timeIntervalSinceReferenceDate: 999)
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: notYetIdleSocketPath,
                mode: .auto,
                current: true,
                pid: 1010,
                idleExitAt: Date(timeIntervalSinceReferenceDate: 1001)
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: currentSocketPath,
                mode: .auto,
                current: true,
                pid: 1002
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: manualSocketPath,
                mode: .manual,
                current: true,
                pid: 1003
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: busySocketPath,
                mode: .auto,
                current: true,
                activeRequests: 1,
                pid: 1004
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: unknownActivitySocketPath,
                mode: .auto,
                current: true,
                includeActivity: false,
                pid: 1005
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: unknownPIDSocketPath,
                mode: .auto,
                current: true,
                pid: nil
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: wrongHostSocketPath,
                mode: .auto,
                current: true,
                pid: 1007,
                hostKind: .gui
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: wrongIdentitySocketPath,
                mode: .auto,
                current: true,
                pid: 1008,
                reportedSocketPath: eligibleSocketPath
            ),
            Self.target(
                role: .buildScopedDaemon,
                socketPath: unsafeSocketPath,
                mode: .auto,
                current: true,
                pid: 1009,
                supportsConditionalStop: false
            ),
            defaultTarget,
        ]
        let managedRecords: [String: ManagedAutoDaemonRecord] = Dictionary(
            uniqueKeysWithValues: targets.compactMap { target in
                guard let processIdentifier = target.status.pid,
                      let startedAt = target.status.startedAt
                else {
                    return nil
                }
                let socketPath = target.client.socketPath
                return (socketPath, ManagedAutoDaemonRecord(
                    socketPath: socketPath,
                    processIdentifier: processIdentifier,
                    startedAt: startedAt
                ))
            }
        )

        #expect(DaemonControlResolver.historicalAutoDaemonStops(
            targets,
            daemonSocketPath: daemonSocketPath,
            currentBuildScopedSocketPath: currentSocketPath,
            now: Date(timeIntervalSinceReferenceDate: 1000),
            managedRecord: { managedRecords[$0] }
        ) == [HistoricalAutoDaemonStop(socketPath: eligibleSocketPath, expectedPID: 1001)])
    }

    @Test
    func `historical cleanup never targets explicit or custom daemon sockets`() {
        let canonicalDirectory = URL(fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath)
            .deletingLastPathComponent()
        let unownedBuildShapedSocketPath = canonicalDirectory
            .appendingPathComponent("daemon-bbbbbbbbbbbbbbbb.sock")
            .path
        let explicitSocketPath = "/tmp/peekaboo-explicit/daemon-bbbbbbbbbbbbbbbb.sock"
        let explicitTarget = Self.target(
            role: .explicit,
            socketPath: explicitSocketPath,
            mode: .auto,
            current: true,
            pid: 2001
        )
        let customTarget = Self.target(
            role: .buildScopedDaemon,
            socketPath: explicitSocketPath,
            mode: .auto,
            current: true,
            pid: 2002
        )
        let unownedBuildShapedTarget = Self.target(
            role: .buildScopedDaemon,
            socketPath: unownedBuildShapedSocketPath,
            mode: .auto,
            current: true,
            pid: 2003
        )

        #expect(DaemonControlResolver.historicalAutoDaemonStops(
            [explicitTarget],
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            currentBuildScopedSocketPath: nil,
            managedRecord: { _ in nil }
        ).isEmpty)
        #expect(DaemonControlResolver.historicalAutoDaemonStops(
            [customTarget],
            daemonSocketPath: "/tmp/peekaboo-explicit/daemon.sock",
            currentBuildScopedSocketPath: nil,
            managedRecord: { _ in nil }
        ).isEmpty)
        #expect(DaemonControlResolver.historicalAutoDaemonStops(
            [unownedBuildShapedTarget],
            daemonSocketPath: PeekabooBridgeConstants.daemonSocketPath,
            currentBuildScopedSocketPath: nil,
            managedRecord: { _ in nil }
        ).isEmpty)
    }

    @Test
    func `managed auto records require policy owned build scoped identity`() throws {
        let daemonSocketPath = PeekabooBridgeConstants.daemonSocketPath
        let directory = URL(fileURLWithPath: daemonSocketPath).deletingLastPathComponent()
        let buildScopedSocketPath = directory.appendingPathComponent("daemon-bbbbbbbbbbbbbbbb.sock").path
        let automatic = Self.target(
            role: .buildScopedDaemon,
            socketPath: buildScopedSocketPath,
            mode: .auto,
            current: true,
            pid: 3001
        )
        let manual = Self.target(
            role: .buildScopedDaemon,
            socketPath: buildScopedSocketPath,
            mode: .manual,
            current: true,
            pid: 3002
        )
        let canonical = Self.target(
            role: .defaultDaemon,
            socketPath: daemonSocketPath,
            mode: .auto,
            current: true,
            pid: 3003
        )

        let record = try #require(ManagedAutoDaemonRegistry.makeRecord(
            status: automatic.status,
            socketPath: buildScopedSocketPath
        ))
        #expect(ManagedAutoDaemonRegistry.matches(
            record,
            status: automatic.status,
            socketPath: buildScopedSocketPath
        ))
        #expect(ManagedAutoDaemonRegistry.makeRecord(
            status: manual.status,
            socketPath: buildScopedSocketPath
        ) == nil)
        #expect(ManagedAutoDaemonRegistry.makeRecord(
            status: canonical.status,
            socketPath: daemonSocketPath
        ) == nil)
    }

    @Test
    func `managed auto registry prunes only missing canonical build sockets`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-managed-daemon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let daemonSocketPath = directory.appendingPathComponent("daemon.sock").path
        let staleSocketPath = directory.appendingPathComponent("daemon-1111111111111111.sock").path
        let liveSocketPath = directory.appendingPathComponent("daemon-2222222222222222.sock").path
        let staleRecordPath = "\(staleSocketPath).managed-auto.json"
        let liveRecordPath = "\(liveSocketPath).managed-auto.json"
        let unrelatedPath = directory.appendingPathComponent("notes.managed-auto.json").path
        try JSONEncoder().encode(ManagedAutoDaemonRecord(
            socketPath: staleSocketPath,
            processIdentifier: 4001,
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )).write(to: URL(fileURLWithPath: staleRecordPath))
        try JSONEncoder().encode(ManagedAutoDaemonRecord(
            socketPath: liveSocketPath,
            processIdentifier: 4002,
            startedAt: Date(timeIntervalSinceReferenceDate: 100)
        )).write(to: URL(fileURLWithPath: liveRecordPath))
        try Data("unrelated".utf8).write(to: URL(fileURLWithPath: unrelatedPath))
        _ = FileManager.default.createFile(atPath: liveSocketPath, contents: Data())

        ManagedAutoDaemonRegistry.pruneStaleRecords(daemonSocketPath: daemonSocketPath)
        #expect(FileManager.default.fileExists(atPath: staleRecordPath))

        ManagedAutoDaemonRegistry.pruneStaleRecords(
            daemonSocketPath: daemonSocketPath,
            canonicalDaemonSocketPath: daemonSocketPath
        )
        #expect(!FileManager.default.fileExists(atPath: staleRecordPath))
        #expect(FileManager.default.fileExists(atPath: liveRecordPath))
        #expect(FileManager.default.fileExists(atPath: unrelatedPath))
    }
}

// MARK: - Daemon routing and promotion

extension DaemonCommandTests {
    @Test
    func `compatible historical daemon wins over incompatible historical candidate`() throws {
        let incompatible = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/peekaboo/daemon-bbbbbbbbbbbbbbbb.sock",
            mode: .manual,
            current: false
        )
        let compatible = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/peekaboo/daemon-cccccccccccccccc.sock",
            mode: .manual,
            current: true
        )

        let selected = try #require(DaemonControlPlanner.preferredStatusTarget(
            [incompatible, compatible],
            explicitSocket: nil
        ))

        #expect(selected.client.socketPath == compatible.client.socketPath)
        #expect(DaemonControlPlanner.startAction(
            targets: [incompatible, compatible],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/peekaboo/daemon.sock",
            buildScopedSocketPath: "/tmp/peekaboo/daemon-aaaaaaaaaaaaaaaa.sock"
        ) ==
            .useExisting(socketPath: compatible.client.socketPath))
    }

    @Test
    func `old default daemon launches current scoped manual daemon when missing`() {
        let oldDefault = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/default.sock",
            mode: .manual,
            current: false
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [oldDefault],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/default.sock",
            buildScopedSocketPath: "/tmp/scoped.sock"
        ) == .launchManual(socketPath: "/tmp/scoped.sock"))
    }

    @Test
    func `clean daemon start uses canonical socket`() {
        #expect(DaemonControlPlanner.startAction(
            targets: [],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/daemon.sock",
            buildScopedSocketPath: "/tmp/daemon-aaaaaaaaaaaaaaaa.sock"
        ) == .launchManual(socketPath: "/tmp/daemon.sock"))
    }

    @Test
    func `incompatible historical daemon does not block canonical launch`() {
        let historical = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/daemon-bbbbbbbbbbbbbbbb.sock",
            mode: .manual,
            current: false
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [historical],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/daemon.sock",
            buildScopedSocketPath: "/tmp/daemon-aaaaaaaaaaaaaaaa.sock"
        ) == .launchManual(socketPath: "/tmp/daemon.sock"))
    }

    @Test
    func `historical scoped daemon does not suppress canonical legacy migration`() {
        let historical = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/daemon-bbbbbbbbbbbbbbbb.sock",
            mode: .manual,
            current: false
        )
        let legacy = Self.target(
            role: .legacyDefault,
            socketPath: "/tmp/bridge.sock",
            mode: .manual,
            current: false
        )

        #expect(DaemonControlPlanner.shouldMigrateLegacyTarget(
            explicitSocket: nil,
            destinationSocketPath: "/tmp/daemon.sock",
            defaultSocketPath: "/tmp/daemon.sock",
            targets: [historical, legacy]
        ))

        let canonical = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/daemon.sock",
            mode: .manual,
            current: false
        )
        #expect(!DaemonControlPlanner.shouldMigrateLegacyTarget(
            explicitSocket: nil,
            destinationSocketPath: "/tmp/daemon.sock",
            defaultSocketPath: "/tmp/daemon.sock",
            targets: [canonical, historical, legacy]
        ))
    }

    @Test
    func `only a current legacy daemon can replace failed migration`() {
        let oldLegacy = Self.target(
            role: .legacyDefault,
            socketPath: "/tmp/bridge.sock",
            mode: .manual,
            current: false
        )
        let currentLegacy = Self.target(
            role: .legacyDefault,
            socketPath: "/tmp/bridge.sock",
            mode: .manual,
            current: true
        )

        #expect(DaemonLaunchPolicy.compatibleLegacyFallbackSocketPath(for: oldLegacy.status) == nil)
        #expect(DaemonLaunchPolicy.compatibleLegacyFallbackSocketPath(for: currentLegacy.status) ==
            PeekabooBridgeConstants.peekabooSocketPath)
    }

    @Test
    func `incompatible current scoped daemon does not block canonical launch`() {
        let currentPath = "/tmp/daemon-aaaaaaaaaaaaaaaa.sock"
        let current = Self.target(
            role: .buildScopedDaemon,
            socketPath: currentPath,
            mode: .manual,
            current: false
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [current],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/daemon.sock",
            buildScopedSocketPath: currentPath
        ) == .launchManual(socketPath: "/tmp/daemon.sock"))
    }

    @Test
    func `scoped auto daemon is promoted to persistent manual`() {
        let oldDefault = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/default.sock",
            mode: .manual,
            current: false
        )
        let scopedAuto = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/scoped.sock",
            mode: .auto,
            current: true
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [oldDefault, scopedAuto],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/default.sock",
            buildScopedSocketPath: "/tmp/scoped.sock"
        ) ==
            .promoteAutoToManual(socketPath: "/tmp/scoped.sock", pid: 4242))
    }

    @Test
    func `scoped manual daemon is reused`() {
        let oldDefault = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/default.sock",
            mode: .manual,
            current: false
        )
        let scopedManual = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/scoped.sock",
            mode: .manual,
            current: true
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [oldDefault, scopedManual],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/default.sock",
            buildScopedSocketPath: "/tmp/scoped.sock"
        ) == .useExisting(socketPath: "/tmp/scoped.sock"))
    }

    @Test
    func `busy scoped auto daemon rejects promotion`() {
        let oldDefault = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/default.sock",
            mode: .manual,
            current: false
        )
        let scopedBusy = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/scoped.sock",
            mode: .auto,
            current: true,
            activeRequests: 1
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [oldDefault, scopedBusy],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/default.sock",
            buildScopedSocketPath: "/tmp/scoped.sock"
        ) == .rejectBusy(socketPath: "/tmp/scoped.sock"))
    }

    @Test
    func `unsafe scoped auto daemon rejects promotion`() {
        let oldDefault = Self.target(
            role: .defaultDaemon,
            socketPath: "/tmp/default.sock",
            mode: .manual,
            current: false
        )
        let scopedUnsafe = Self.target(
            role: .buildScopedDaemon,
            socketPath: "/tmp/scoped.sock",
            mode: .auto,
            current: true,
            supportsConditionalStop: false
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [oldDefault, scopedUnsafe],
            explicitSocket: nil,
            defaultSocketPath: "/tmp/default.sock",
            buildScopedSocketPath: "/tmp/scoped.sock"
        ) == .rejectUnsafe(socketPath: "/tmp/scoped.sock"))
    }

    @Test
    func `explicit daemon socket remains the only control target`() {
        let explicit = Self.target(
            role: .explicit,
            socketPath: "/tmp/explicit.sock",
            mode: .manual,
            current: false
        )

        #expect(DaemonControlPlanner.startAction(
            targets: [explicit],
            explicitSocket: "/tmp/explicit.sock",
            defaultSocketPath: "/tmp/default.sock",
            buildScopedSocketPath: "/tmp/scoped.sock"
        ) == .useExisting(socketPath: "/tmp/explicit.sock"))
        #expect(DaemonControlPlanner.preferredStatusTarget(
            [explicit],
            explicitSocket: "/tmp/explicit.sock"
        )?.client.socketPath == "/tmp/explicit.sock")
    }

    private static func target(
        role: DaemonControlTargetRole,
        socketPath: String,
        mode: PeekabooDaemonMode,
        current: Bool,
        activeRequests: Int = 0,
        includeActivity: Bool = true,
        pid: pid_t? = 4242,
        startedAt: Date? = Date(timeIntervalSinceReferenceDate: 123),
        idleExitAt: Date? = nil,
        supportsConditionalStop: Bool = true,
        reportedSocketPath: String? = nil,
        hostKind: PeekabooBridgeHostKind = .onDemand
    ) -> DaemonControlTarget {
        let currentNames = [
            PeekabooBridgeOperation.daemonStatus.rawValue,
            PeekabooBridgeOperation.daemonStop.rawValue,
            PeekabooBridgeOperation.launchApplicationWithOptions.rawValue,
            PeekabooBridgeOperation.relaunchApplicationWithOptions.rawValue,
            PeekabooBridgeOperation.invalidateImplicitLatestSnapshot.rawValue,
        ]
        let status = PeekabooDaemonStatus(
            running: true,
            pid: pid,
            startedAt: startedAt,
            mode: mode,
            bridge: PeekabooDaemonBridgeStatus(
                socketPath: reportedSocketPath ?? socketPath,
                hostKind: hostKind,
                allowedOperations: [.daemonStatus, .daemonStop],
                availableOperationNames: current ? currentNames : nil
            ),
            activity: includeActivity
                ? PeekabooDaemonActivityStatus(
                    activeRequests: activeRequests,
                    lastActivityAt: nil,
                    idleTimeoutSeconds: mode == .auto ? 300 : nil,
                    idleExitAt: idleExitAt
                )
                : nil,
            supportsConditionalStop: supportsConditionalStop
        )
        return DaemonControlTarget(
            client: DaemonControlClient(socketPath: socketPath),
            status: status,
            role: role
        )
    }
}
