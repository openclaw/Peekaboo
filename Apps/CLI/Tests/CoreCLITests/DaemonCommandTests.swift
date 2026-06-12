import Commander
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
            "--poll-interval-ms",
            "500",
            "--idle-timeout-seconds",
            "2.5",
        ]
        let command = try DaemonCommand.Run.parse(args)
        #expect(command.mode == "auto")
        #expect(command.bridgeSocket == "/tmp/peekaboo.sock")
        #expect(command.pollIntervalMs == 500)
        #expect(command.idleTimeoutSeconds == 2.5)
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
}
