import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct ClickSnapshotWindowSelectionTests {
    @Test
    @MainActor
    func `Explicit exact-window snapshot does not depend on a second broad window lookup`() async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        let snapshotID = try await Self.storeSnapshot(window: window, in: fixture.snapshots)

        let result = try await InProcessCommandRunner.run(
            [
                "click", "--on", "B1", "--snapshot", snapshotID,
                "--app", application.name, "--window-id", "42", "--json",
            ],
            services: fixture.services
        )

        #expect(result.exitStatus == 0, "\(result.combinedOutput)")
        #expect(windows.exactWindowLookupCount == 0)
        #expect(fixture.automation.targetedClickCalls.count == 1)
        #expect(fixture.automation.targetedClickCalls.first?.targetWindowID == 42)
    }

    @Test
    @MainActor
    func `Stale exact-window receipt refuses once without selector fallback`() async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = StubWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        fixture.automation.clickError = PeekabooError.snapshotStale("window identity changed")
        let snapshotID = try await Self.storeSnapshot(window: window, in: fixture.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotID, "--window-id", "42", "--json"],
            services: fixture.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("window identity changed"))
        #expect(fixture.automation.targetedClickCalls.count == 1)
    }

    @MainActor
    private static func makeFixture(
        application: ServiceApplicationInfo,
        window: ServiceWindowInfo,
        windows: any WindowManagementServiceProtocol
    ) -> TestServicesFactory.AutomationTestContext {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        return TestServicesFactory.makeAutomationTestContext(
            automation: automation,
            applications: StubApplicationService(
                applications: [application],
                windowsByApp: [application.name: [window]]
            ),
            windows: windows
        )
    }

    @MainActor
    private static func storeSnapshot(
        window: ServiceWindowInfo,
        in snapshots: StubSnapshotManager
    ) async throws -> String {
        let snapshotID = try await snapshots.createSnapshot()
        let identity = try #require(window.mutationIdentity)
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/screenshot.png",
                elements: DetectedElements(buttons: [DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Save",
                    bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
                )]),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 1,
                    method: "stub",
                    windowContext: WindowContext(
                        applicationName: "TestApp",
                        applicationBundleId: "com.example.test",
                        applicationProcessId: 12345,
                        windowTitle: window.title,
                        windowID: window.windowID,
                        windowBounds: window.bounds,
                        windowMutationIdentity: identity
                    ),
                    truncationInfo: nil
                )
            )
        )
        return snapshotID
    }

    private static func makeApplication() -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 12345,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.test",
            name: "TestApp",
            isActive: false,
            windowCount: 1,
            activationPolicy: .regular
        )
    }

    private static func makeWindow() -> ServiceWindowInfo {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        return ServiceWindowInfo(
            windowID: 42,
            title: "Editor",
            bounds: bounds,
            isMainWindow: true,
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 12345,
                ownerProcessStartIdentity: 7,
                capturedBounds: bounds
            )
        )
    }
}

@MainActor
private final class SnapshotReceiptOnlyWindowService: StubWindowService {
    private(set) var exactWindowLookupCount = 0

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        if case .windowId = target {
            self.exactWindowLookupCount += 1
            throw PeekabooError.windowNotFound(criteria: "fixture rejects redundant exact-window enumeration")
        }
        return try await super.listWindows(target: target)
    }
}
