import Foundation
import PeekabooCore
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.tags(.safe))
struct CLIDesktopFixtureTests {
    @Test
    func `separate fixtures do not share watermarks`() throws {
        let first = try CLIDesktopFixture()
        defer { first.removeDirectory() }
        let second = try CLIDesktopFixture()
        defer { second.removeDirectory() }
        let cutoff = Date()
        let mutation = try first.watermarkStore.beginMutation(at: cutoff)
        try first.watermarkStore.completeMutation(mutation, through: cutoff)

        #expect(first.root != second.root)
        #expect(first.watermarkStore.effectiveWatermark() == cutoff)
        #expect(second.watermarkStore.effectiveWatermark() == nil)
    }

    @Test
    func `separate fixtures allow independent lanes`() async throws {
        let first = try CLIDesktopFixture()
        defer { first.removeDirectory() }
        let second = try CLIDesktopFixture()
        defer { second.removeDirectory() }

        let result = try await first.laneCoordinator.run(scope: .global, access: .write) {
            try await second.laneCoordinator.run(scope: .global, access: .write) { 42 }
        }
        #expect(result == 42)
    }

    @Test
    func `borrowed coordinator retains same root exclusion`() async throws {
        let fixture = try CLIDesktopFixture()
        defer { fixture.removeDirectory() }
        let borrowed = DesktopOperationLaneCoordinator(coordinationRootURL: fixture.root)

        try await fixture.laneCoordinator.run(scope: .global, access: .write) {
            do {
                try await borrowed.run(scope: .global, access: .write) {
                    Issue.record("A second coordinator must not bypass the same-root lane")
                }
                Issue.record("Expected nested same-root acquisition to fail")
            } catch DesktopOperationLaneError.nestedAcquisition {
                // The real lane retains ownership until the outer operation returns.
            }
        }
        let result = try await borrowed.run(scope: .global, access: .write) { 42 }
        #expect(result == 42)
    }

    #if DEBUG
    @Test(arguments: [false, true])
    @MainActor
    func `Bridge fixture stops hosts on success and failure`(bodyThrows: Bool) async throws {
        var root: URL?
        var retainedHost: PeekabooBridgeHost?

        do {
            let result = try await CLIBridgeHostFixture.withHosts { fixture in
                root = fixture.desktop.root
                let server = PeekabooBridgeServer(
                    services: CLISnapshotBridgeServices(
                        snapshots: InMemorySnapshotManager(),
                        directory: fixture.desktop.root
                    ),
                    allowlistedTeams: [],
                    allowlistedBundles: [],
                    allowedOperations: CLISnapshotBridgeServices.snapshotOperations,
                    desktopOperationLaneCoordinator: fixture.desktop.laneCoordinator,
                    screenCaptureKitProcessCapabilityRegistrar: {},
                    screenCaptureKitOwnershipPreparer: {},
                    screenCaptureKitOwnerClaimProvider: CLISnapshotBridgeServices.unexpectedScreenCaptureKitClaim,
                    permissionStatusEvaluator: { _ in CLISnapshotBridgeServices.grantedPermissions() }
                )
                let host = PeekabooBridgeHost(
                    socketPath: fixture.desktop.root.appendingPathComponent("cleanup.sock").path,
                    server: server,
                    allowedTeamIDs: [],
                    requestTimeoutSec: 2
                )
                retainedHost = host
                try await fixture.start(host)
                #expect(await host.listenerReadinessNotificationCountForTesting() != nil)
                if bodyThrows {
                    throw FixtureBodyError.expected
                }
                return 42
            }
            #expect(!bodyThrows)
            #expect(result == 42)
        } catch FixtureBodyError.expected {
            #expect(bodyThrows)
        }

        let host = try #require(retainedHost)
        let directory = try #require(root)
        #expect(await host.listenerReadinessNotificationCountForTesting() == nil)
        #expect(await host.isRetainingOwnershipForRequestsForTesting == false)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
    #endif
}

private enum FixtureBodyError: Error {
    case expected
}
