import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PeekabooBridgePlannerInventoryTransportTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.planner-inventory-tests",
        teamIdentifier: nil,
        processIdentifier: getpid(),
        hostname: nil)

    @Test
    func `planner inventory wire cases retain legacy operation and response families`() throws {
        let applicationInventory = DesktopTargetPlanning.Inventory<ServiceApplicationInfo>.complete([])
        let windowInventory = DesktopTargetPlanning.Inventory<ServiceWindowInfo>.complete([])
        let applicationRequest = PeekabooBridgeRequest.listApplicationMutationInventory
        let windowRequest = PeekabooBridgeRequest.listWindowMutationInventory(
            PeekabooBridgeWindowTargetRequest(target: .application("TextEdit")))

        #expect(applicationRequest.operation == .listApplications)
        #expect(windowRequest.operation == .listWindows)
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .applicationMutationInventory(applicationInventory),
            request: applicationRequest))
        #expect(!PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .applications([]),
            request: applicationRequest))
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .windowMutationInventory(windowInventory),
            request: windowRequest))
        #expect(!PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .windows([]),
            request: windowRequest))
        #expect(PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .applications([]),
            request: .listApplications))
        #expect(!PeekabooBridgeOperationResultSemantics.responseMatchesContract(
            .applicationMutationInventory(applicationInventory),
            request: .listApplications))

        let legacyWindowData = try PeekabooBridgeOperationReceiptCoding.canonicalData(
            PeekabooBridgeRequest.listWindows(PeekabooBridgeWindowTargetRequest(
                target: .application("TextEdit"))))
        let legacyWindowJSON = try #require(String(data: legacyWindowData, encoding: .utf8))
        #expect(legacyWindowJSON ==
            #"{"listWindows":{"_0":{"target":{"app":"TextEdit","kind":"application"}}}}"#)
        #expect(legacyWindowJSON.contains("\"listWindows\""))
        #expect(!legacyWindowJSON.contains("MutationInventory"))
        #expect(!legacyWindowJSON.contains("includeInventoryMetadata"))
    }

    @Test
    func `planner inventory capability starts at protocol 1 30`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 29)
        let legacyServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: previous...previous)
        let currentServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [])

        #expect(PeekabooBridgeConstants.protocolVersion == .init(major: 1, minor: 31))
        #expect(PeekabooBridgeConstants.attestedOperationReceiptVersion == .init(major: 1, minor: 29))
        #expect(PeekabooBridgeConstants.plannerInventoryTransportVersion == .init(major: 1, minor: 30))
        #expect(!legacyServer.hostCapabilities.contains(PeekabooBridgeHostCapability.plannerInventoryTransport))
        #expect(currentServer.hostCapabilities.contains(PeekabooBridgeHostCapability.plannerInventoryTransport))
    }

    @Test
    func `legacy host inventories stay explicit partial and use legacy request cases`() async throws {
        let protocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 456)
        let application = AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "dev.stub",
            name: "StubApp")
        let window = AutomationTestFixtures.window(processIdentity: processIdentity)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: protocolVersion,
            supportedOperations: [.listApplications, .listWindows],
            enabledOperations: [.listApplications, .listWindows])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .applications([application]),
            .windows([window]),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: protocolVersion)

        let applications = try await client.listApplicationMutationInventory()
        let windows = try await client.listWindowMutationInventory(target: .windowId(window.windowID))

        #expect(!applications.isComplete)
        #expect(applications.items == [application])
        #expect(applications.warnings == [
            "Bridge host did not report application mutation inventory completeness.",
        ])
        #expect(!windows.isComplete)
        #expect(windows.items == [window])
        #expect(windows.warnings == [
            "Bridge host did not report window mutation inventory completeness.",
        ])

        let requests = await peer.requests
        #expect(requests.count == 3)
        let applicationRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[1])
        let windowRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: requests[2])
        guard case .listApplications = applicationRequest else {
            Issue.record("Expected legacy listApplications request")
            return
        }
        guard case .listWindows = windowRequest else {
            Issue.record("Expected legacy listWindows request")
            return
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `protocol 1 30 preserves signed partial inventories and downgrade clears transport`() async throws {
        let socketPath = "/tmp/peekaboo-planner-inventory-\(UUID().uuidString).sock"
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 456)
        let window = AutomationTestFixtures.window(
            windowID: 77,
            title: "Fixture",
            processIdentity: processIdentity)
        let application = AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "dev.stub",
            name: "StubApp")
            .withUniqueTestSelectorProof(for: "PID:\(processIdentity.processIdentifier)")
        let graph = try LinkedApplicationInventoryGraph(nodes: [
            .init(application: application, windows: [window]),
        ])
        let applications = ScriptedApplicationInventoryService(graph: graph)
        let windows = ScriptedWindowInventoryService(
            graph: graph,
            focusedWindow: window,
            inventoryCompleteness: .partial,
            inventoryWarnings: ["AX window enumeration timed out"])
        let server = PeekabooBridgeServer(
            services: StubServices(applications: applications, windows: windows),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.listApplications, .findApplication, .getFrontmostApplication, .listWindows])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let current = try await client.handshake(client: Self.clientIdentity)
        #expect(current.negotiatedVersion == .init(major: 1, minor: 31))
        #expect(current.hostCapabilities?.contains(PeekabooBridgeHostCapability.plannerInventoryTransport) == true)

        let remoteApplications = RemoteApplicationService(client: client)
        let remoteWindows = RemoteWindowManagementService(client: client)
        let applicationInventory = try await remoteApplications.applicationMutationInventory()
        let windowInventory = try await remoteWindows.windowMutationInventory(target: .windowId(window.windowID))
        #expect(applicationInventory.isComplete)
        #expect(applicationInventory.items.map(\.processIdentifier) == [123])
        #expect(!windowInventory.isComplete)
        #expect(windowInventory.items == [window])
        #expect(windowInventory.warnings == ["AX window enumeration timed out"])

        let receiptBundle = try #require(await client.lastOperationReceiptBundle())
        try receiptBundle.validate()
        let signedRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: receiptBundle.canonicalRequest)
        guard case .listWindowMutationInventory = signedRequest else {
            Issue.record("Expected signed planner window inventory request")
            return
        }

        let planner = DesktopTargetPlanning.WindowMutationPlanner(
            applications: remoteApplications,
            windows: remoteWindows)
        await #expect(throws: DesktopTargetPlanningError.incompleteWindowInventory(
            selector: "window title 'Fixture'",
            warnings: ["AX window enumeration timed out"]))
        {
            _ = try await planner.plan(selector: InteractionTargetSelector(
                applicationIdentifier: "StubApp",
                windowTitle: "Fixture"))
        }
        let exact = try await planner.plan(selector: InteractionTargetSelector(windowID: window.windowID))
        #expect(exact.identity == window.mutationIdentity)

        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 29)
        let downgraded = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: previous)
        #expect(downgraded.negotiatedVersion == previous)
        let downgradedInventory = try await client.listApplicationMutationInventory()
        #expect(!downgradedInventory.isComplete)
        #expect(downgradedInventory.items.map(\.processIdentifier) == [123])
        let downgradedBundle = try #require(await client.lastOperationReceiptBundle())
        try downgradedBundle.validate()
        let downgradedRequest = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeRequest.self,
            from: downgradedBundle.canonicalRequest)
        guard case .listApplications = downgradedRequest else {
            Issue.record("Expected protocol 1.29 downgrade to retain the legacy request")
            return
        }

        await host.stop()
    }
}
