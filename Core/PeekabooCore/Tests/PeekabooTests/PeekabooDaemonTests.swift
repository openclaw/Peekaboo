import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import Testing

@Suite(.tags(.safe))
@MainActor
struct PeekabooDaemonTests {
    @Test
    func `daemon configuration defaults to the dedicated socket`() {
        let configuration = PeekabooDaemon.Configuration(
            mode: .manual,
            hostKind: .onDemand)

        #expect(configuration.bridgeSocketPath == PeekabooBridgeConstants.daemonSocketPath)
    }

    @Test
    func `auto daemon reports activity and idle deadline`() async {
        let daemon = PeekabooDaemon(configuration: .init(
            mode: .auto,
            bridgeSocketPath: "/tmp/peekaboo-test.sock",
            allowlistedTeams: [],
            windowTrackingEnabled: false,
            hostKind: .onDemand,
            idleTimeout: 10))

        #expect(await daemon.admitActivity(operation: .listApplications))
        var status = await daemon.daemonStatus()
        #expect(status.mode == .auto)
        #expect(status.activity?.activeRequests == 1)
        #expect(status.activity?.idleExitAt == nil)

        await daemon.recordActivityEnd(operation: .listApplications)
        status = await daemon.daemonStatus()
        #expect(status.activity?.activeRequests == 0)
        #expect(status.activity?.idleTimeoutSeconds == 10)
        #expect(status.activity?.idleExitAt != nil)

        _ = await daemon.requestStop()
    }

    @Test
    func `daemon refuses stop while an operational request is active`() async {
        let daemon = PeekabooDaemon(configuration: .embeddedMCP())

        #expect(await daemon.admitActivity(operation: .captureScreen))
        #expect(await daemon.requestStop() == false)
        #expect(await (daemon.daemonStatus()).activity?.activeRequests == 1)

        await daemon.recordActivityEnd(operation: .captureScreen)
        #expect(await daemon.requestStop())
    }

    @Test
    func `daemon rejects activity and mismatched stop after shutdown begins`() async {
        let daemon = PeekabooDaemon(configuration: .embeddedMCP())

        #expect(await daemon.requestStop(expectedPID: getpid() + 1) == false)
        #expect(await daemon.requestStop(expectedPID: getpid()))
        #expect(await daemon.admitActivity(operation: .waitForElement) == false)
    }

    @Test
    func `MCP daemon does not expose a bridge listener`() async {
        let configuration = PeekabooDaemon.Configuration.embeddedMCP()
        #expect(!configuration.bridgeHostingEnabled)
        #expect(!configuration.exitOnStop)

        let daemon = PeekabooDaemon(configuration: configuration)
        let status = await daemon.daemonStatus()

        #expect(status.mode == .mcp)
        #expect(status.bridge == nil)
    }

    @Test
    func `embedded MCP shutdown completes tracker cleanup`() async throws {
        let daemon = PeekabooDaemon(configuration: .embeddedMCP())
        try await daemon.startChecked()
        #expect(WindowMovementTracking.provider != nil)

        #expect(await daemon.requestStop())
        await daemon.waitUntilStopped()

        #expect(WindowMovementTracking.provider == nil)
    }

    @Test
    func `legacy MCP configuration still hosts its requested bridge`() {
        let configuration = PeekabooDaemon.Configuration.mcp(bridgeSocketPath: "/tmp/legacy-mcp.sock")

        #expect(configuration.bridgeSocketPath == "/tmp/legacy-mcp.sock")
        #expect(configuration.bridgeHostingEnabled)
        #expect(configuration.exitOnStop)
    }
}
