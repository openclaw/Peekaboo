import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooBridge
import Testing
@testable import PeekabooCore

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
    func `cancelled idle timers cannot reschedule and cancel their successors`() async throws {
        let daemon = PeekabooDaemon(configuration: .init(
            mode: .auto,
            bridgeSocketPath: "/tmp/peekaboo-test.sock",
            allowlistedTeams: [],
            windowTrackingEnabled: false,
            hostKind: .onDemand,
            idleTimeout: 0.25,
            bridgeHostingEnabled: false))

        for _ in 0..<50 {
            #expect(await daemon.admitActivity(operation: .listApplications))
            await daemon.recordActivityEnd(operation: .listApplications)
        }

        let expectedGeneration = daemon.idleShutdownGenerationForTesting
        #expect(expectedGeneration == 50)

        for _ in 0..<20 {
            await Task.yield()
        }
        try await Task.sleep(for: .milliseconds(20))

        #expect(daemon.idleShutdownGenerationForTesting == expectedGeneration)
        #expect(await daemon.requestStop())
        await daemon.waitUntilStopped()
    }

    @Test
    func `daemon status only advertises operations decodable by every supported client`() async throws {
        var requestedOperations = PeekabooBridgeOperation.remoteDefaultAllowlist
        requestedOperations.insert(._appleScriptProbe)
        let daemon = PeekabooDaemon(configuration: .init(
            mode: .manual,
            bridgeSocketPath: "/tmp/peekaboo-test.sock",
            allowlistedTeams: [],
            allowedOperations: requestedOperations,
            windowTrackingEnabled: false,
            hostKind: .onDemand))

        let bridge = try #require(await daemon.daemonStatus().bridge)
        let operations = bridge.allowedOperations
        #expect(operations.contains(.permissionsStatus))
        #expect(!operations.contains(.targetedHotkey))
        #expect(!operations.contains(.requestPostEventPermission))
        #expect(!operations.contains(.launchApplicationWithOptions))
        #expect(!operations.contains(.invalidateImplicitLatestSnapshot))
        #expect(!operations.contains(._appleScriptProbe))
        #expect(bridge.availableOperationNames?.contains(PeekabooBridgeOperation.launchApplicationWithOptions.rawValue)
            == true)
        #expect(bridge.availableOperationNames?.contains(
            PeekabooBridgeOperation.invalidateImplicitLatestSnapshot.rawValue) == true)
        #expect(bridge.availableOperationNames?.contains(PeekabooBridgeOperation._appleScriptProbe.rawValue) == false)

        let data = try JSONEncoder.peekabooBridgeEncoder().encode(bridge)
        let legacy = try JSONDecoder.peekabooBridgeDecoder().decode(LegacyBridgeStatus.self, from: data)
        #expect(legacy.allowedOperations == operations)
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
        try await WindowMovementTrackingProviderScope.withExclusiveAccess {
            let daemon = PeekabooDaemon(configuration: .embeddedMCP())
            try await daemon.startChecked()
            #expect(WindowMovementTracking.provider != nil)

            #expect(await daemon.requestStop())
            await daemon.waitUntilStopped()

            #expect(WindowMovementTracking.provider == nil)
        }
    }

    @Test
    func `legacy MCP configuration still hosts its requested bridge`() {
        let configuration = PeekabooDaemon.Configuration.mcp(bridgeSocketPath: "/tmp/legacy-mcp.sock")

        #expect(configuration.bridgeSocketPath == "/tmp/legacy-mcp.sock")
        #expect(configuration.bridgeHostingEnabled)
        #expect(configuration.exitOnStop)
    }
}

private struct LegacyBridgeStatus: Decodable {
    let socketPath: String
    let hostKind: PeekabooBridgeHostKind
    let allowedOperations: [PeekabooBridgeOperation]
}
