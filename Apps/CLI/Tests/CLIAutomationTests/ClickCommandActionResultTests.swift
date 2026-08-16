import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized, .tags(.safe))
struct ClickCommandActionResultTests {
    private static let processIdentifier: pid_t = 12345
    private static let processStartIdentity: UInt64 = 7
    private static let windowID = 42
    private static let windowBounds = CGRect(x: 10, y: 20, width: 400, height: 300)

    @Test
    func `background click refuses non-success outcomes with their canonical receipt`() async throws {
        let outcomes: [DesktopActionOutcome] = [
            .refused(reason: .targetUnavailable),
            .partial(
                delivery: Self.backgroundDelivery,
                unitCount: .one,
            ),
            .indeterminate(
                delivery: Self.backgroundDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
            ),
        ]

        for outcome in outcomes {
            let fixture = try await makeFixture(outcome: outcome)
            let result = try await runBackgroundClick(fixture, exactWindow: true)
            let object = try Self.jsonObject(result.stdout)
            let projection = try #require(object["outcome"] as? [String: Any])
            let error = try #require(object["error"] as? [String: Any])
            let target = try #require(object["target_identity"] as? [String: Any])
            let receipt = try #require(object["target_receipt"] as? [String: Any])

            #expect(result.exitStatus == 1)
            #expect(object["success"] as? Bool == false)
            #expect(projection["state"] as? String == outcome.state.rawValue)
            #expect(error["retry_safe"] as? Bool == (outcome.retrySafety == .safe))
            #expect(error["mutation_dispatched"] as? Bool == outcome.dispatchState.mutationDispatched)
            #expect(target["kind"] as? String == "window")
            #expect(target["pid"] as? Int == Int(Self.processIdentifier))
            #expect(target["window_id"] as? Int == Self.windowID)
            #expect(receipt["pid"] as? Int == Int(Self.processIdentifier))
            #expect(receipt["window_id"] as? Int == Self.windowID)
            #expect(
                receipt["process_start_identity_decimal"] as? String == String(Self.processStartIdentity),
            )
        }
    }

    @Test
    func `background exact-window click projects result target and receipt`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: Self.backgroundDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one,
        )
        let fixture = try await makeFixture(outcome: outcome)
        let result = try await runBackgroundClick(fixture, exactWindow: true)
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let target = try #require(object["target_identity"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])

        #expect(result.exitStatus == 0)
        #expect(object["success"] as? Bool == true)
        #expect(projection["state"] as? String == outcome.state.rawValue)
        #expect(projection["route"] as? String == outcome.route.rawValue)
        #expect(target["kind"] as? String == "window")
        #expect(target["window_id"] as? Int == Self.windowID)
        #expect(receipt["window_id"] as? Int == Self.windowID)
        #expect(receipt["pid"] as? Int == Int(Self.processIdentifier))
        #expect(receipt["process_start_identity_decimal"] as? String == String(Self.processStartIdentity))
    }

    @Test
    func `background click rejects a receiptless legacy result`() async throws {
        let fixture = try await makeFixture(automation: StubAutomationService())
        let result = try await runBackgroundClick(fixture, exactWindow: true)
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(object["success"] as? Bool == false)
        #expect(projection["state"] as? String == DesktopActionOutcome.State.indeterminate.rawValue)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(object["target_identity"] == nil)
        #expect(object["target_receipt"] == nil)
    }

    @Test
    func `post-dispatch cancellation preserves unsafe click result metadata`() async throws {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: Self.backgroundDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one,
        )
        let fixture = try await makeFixture(outcome: outcome)
        let snapshots = try #require(fixture.services.snapshots as? StubSnapshotManager)
        snapshots.uiAutomationSnapshotCancellation = true

        let result = try await runBackgroundClick(fixture, exactWindow: true)
        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == outcome.state.rawValue)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(receipt["pid"] as? Int == Int(Self.processIdentifier))
    }

    private func makeFixture(
        outcome: DesktopActionOutcome,
    ) async throws -> (
        services: PeekabooServices,
        snapshotID: String,
    ) {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = outcome
        return try await self.makeFixture(automation: automation)
    }

    private func makeFixture(
        automation: StubAutomationService,
    ) async throws -> (
        services: PeekabooServices,
        snapshotID: String,
    ) {
        let application = ServiceApplicationInfo(
            processIdentifier: Self.processIdentifier,
            processStartIdentity: Self.processStartIdentity,
            bundleIdentifier: "com.example.test",
            name: "TestApp",
            activationPolicy: .regular,
        )
        let window = ServiceWindowInfo(
            windowID: Self.windowID,
            title: "Editor",
            bounds: Self.windowBounds,
            isMainWindow: true,
            index: 0,
            mutationIdentity: Self.windowIdentity,
        )
        let windowsByApp = [application.name: [window]]
        let context = TestServicesFactory.makeAutomationTestContext(
            automation: automation,
            applications: StubApplicationService(applications: [application], windowsByApp: windowsByApp),
            windows: StubWindowService(windowsByApp: windowsByApp),
        )
        let snapshotID = try await context.snapshots.createSnapshot()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: Self.detectionResult(snapshotID: snapshotID),
        )
        return (context.services, snapshotID)
    }

    private func runBackgroundClick(
        _ fixture: (services: PeekabooServices, snapshotID: String),
        exactWindow: Bool = false,
    ) async throws -> CommandRunResult {
        var arguments = ["click", "--on", "B1", "--snapshot", fixture.snapshotID, "--json", "--no-remote"]
        if exactWindow {
            arguments += ["--window-id", String(Self.windowID)]
        }
        return try await InProcessCommandRunner.run(arguments, services: fixture.services)
    }

    private static var backgroundDelivery: DesktopActionOutcome.Delivery {
        .init(mechanism: .accessibilityAction, mode: .background)
    }

    private static var windowIdentity: WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: windowBounds,
        )
    }

    private static func detectionResult(snapshotID: String) -> ElementDetectionResult {
        ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/click-action-result.png",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Save",
                    bounds: CGRect(x: 20, y: 30, width: 80, height: 30),
                ),
            ]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "stub",
                windowContext: WindowContext(
                    applicationName: "TestApp",
                    applicationBundleId: "com.example.test",
                    applicationProcessId: self.processIdentifier,
                    windowTitle: "Editor",
                    windowID: self.windowID,
                    windowBounds: self.windowBounds,
                    windowMutationIdentity: self.windowIdentity,
                ),
            ),
        )
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
