import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct ScrollCoordinateCommandTests {
    @Test(arguments: [false, true])
    func `coordinate scroll keeps CLI relative and global bases explicit`(global: Bool) async throws {
        let fixture = try await self.fixture()
        let arguments = [
            "scroll",
            "--direction",
            "down",
            "--at",
            global ? "120,230" : "20,30",
            "--snapshot",
            fixture.snapshotID,
            "--json",
            "--no-remote",
        ] + (global ? ["--global"] : [])
        let result = try await InProcessCommandRunner.run(arguments, services: fixture.services)
        #expect(result.exitStatus == 0, "\(result.combinedOutput)")
        let call = try #require(fixture.automation.scrollCalls.first?.request)
        #expect(call.point == CGPoint(x: 120, y: 230))
        #expect(call.target == nil && !call.foreground)
        #expect(call.expectedWindow?.identity.windowID == 42)
        #expect(fixture.automation.scrollCalls.count == 1)
        #expect(fixture.automation.currentMouseLocationCalls == 0)
        #expect(fixture.applications.activateCalls.isEmpty && fixture.windows.focusCalls.isEmpty)
        #expect(result.stdout.contains("dispatched_unverified"))

        let replay = try await InProcessCommandRunner.run(arguments, services: fixture.services)
        #expect(replay.exitStatus != 0)
        #expect(fixture.automation.scrollCalls.count == 1)
    }

    @Test
    func `coordinate scroll rejects invalid selector shapes before input`() async throws {
        let fixture = try await self.fixture()
        for arguments in [
            ["--at", "20,30", "--on", "S1"],
            ["--at", "20,30", "--foreground"],
            ["--at", "nan,30"], ["--at", "20,infinity"], ["--at", "20,"],
            ["--global", "--on", "S1"], ["--at", "20,30", "--smooth"],
            ["--at", "20,30", "--delay", "1"],
        ] {
            let result = try await InProcessCommandRunner.run(
                ["scroll", "--direction", "down", "--snapshot", fixture.snapshotID, "--json", "--no-remote"] +
                    arguments,
                services: fixture.services
            )
            #expect(result.exitStatus != 0)
        }
        for snapshotArguments in [[], ["--snapshot", "latest"]] {
            let missing = try await InProcessCommandRunner.run(
                ["scroll", "--direction", "down", "--at", "20,30", "--json", "--no-remote"] + snapshotArguments,
                services: fixture.services
            )
            #expect(missing.exitStatus != 0 && missing.stdout.contains("explicit exact-window"))
        }
        #expect(fixture.automation.scrollCalls.isEmpty && fixture.automation.currentMouseLocationCalls == 0)
        #expect(fixture.applications.activateCalls.isEmpty && fixture.windows.focusCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func `coordinate scroll refuses out-of-window points and moved snapshots`(moved: Bool) async throws {
        let fixture = try await self.fixture(moved: moved)
        let result = try await InProcessCommandRunner.run(
            [
                "scroll",
                "--direction",
                "down",
                "--at",
                moved ? "20,30" : "500,30",
                "--snapshot",
                fixture.snapshotID,
                "--json",
                "--no-remote",
            ],
            services: fixture.services
        )
        #expect(result.exitStatus != 0)
        #expect(fixture.automation.scrollCalls.isEmpty)
        #expect(result.stdout.contains(moved ? "SNAPSHOT_STALE" : "INVALID_INPUT"))
    }

    @Test
    func `coordinate scroll refuses an execution service without coordinate support`() async throws {
        let fixture = try await self.fixture()
        fixture.automation.supportsBackgroundCoordinateScroll = false
        let result = try await InProcessCommandRunner.run(
            [
                "scroll",
                "--direction",
                "down",
                "--at",
                "20,30",
                "--snapshot",
                fixture.snapshotID,
                "--json",
                "--no-remote",
            ], services: fixture.services
        )
        #expect(result.exitStatus != 0 && result.stdout.contains("runtime_incompatible"))
        #expect(fixture.automation.scrollCalls.isEmpty)
    }

    private func fixture(moved: Bool = false) async throws -> CoordinateFixture {
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        let linked = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: snapshotID,
            processIdentity: .init(processIdentifier: 12345, processStartIdentity: 7),
            windowID: 42,
            bounds: CGRect(x: 100, y: 200, width: 400, height: 300)
        )
        try await snapshots.storeDetectionResult(snapshotId: snapshotID, result: linked.detectionResult)
        let application = linked.desktopTarget.application
        let window = moved ? AutomationTestFixtures.window(
            windowID: 42,
            bounds: CGRect(x: 110, y: 200, width: 400, height: 300),
            processIdentity: linked.desktopTarget.processIdentity
        ) : linked.desktopTarget.window
        let applications = StubApplicationService(applications: [application])
        let windows = StubWindowService(windowsByApp: ["PID:12345": [window]])
        let automation = OutcomeStubAutomationService()
        automation.supportsBackgroundCoordinateScroll = true
        automation.actionOutcomeTargetIdentity = try linked.targetIdentity
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        return CoordinateFixture(
            snapshotID: snapshotID,
            automation: automation,
            applications: applications,
            windows: windows,
            services: TestServicesFactory.makePeekabooServices(
                applications: applications, windows: windows, snapshots: snapshots, automation: automation
            )
        )
    }

    private struct CoordinateFixture {
        let snapshotID: String
        let automation: OutcomeStubAutomationService
        let applications: StubApplicationService
        let windows: StubWindowService
        let services: PeekabooServices
    }
}
