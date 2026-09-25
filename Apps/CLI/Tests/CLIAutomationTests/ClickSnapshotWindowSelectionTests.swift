import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct ClickSnapshotWindowSelectionTests {
    @Test(arguments: [["--on", "B1"], ["Save"]], [[], ["--right"], ["--double"]])
    @MainActor
    func `Implicit snapshot window preserves process-capable legacy hosts`(
        targetArguments: [String],
        clickArguments: [String]
    ) async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        fixture.automation.supportsExactWindowTargetedClicks = false
        if let variant = clickArguments.first {
            let automation = try #require(fixture.automation as? OutcomeStubAutomationService)
            automation.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(variant == "--double" ? 5 : 3)
            )
        }
        let snapshotID = try await Self.storeSnapshot(window: window, in: fixture.snapshots)
        let result = try await InProcessCommandRunner.run(
            ["click"] + targetArguments + clickArguments + ["--snapshot", snapshotID, "--json"],
            services: fixture.services
        )

        #expect(result.exitStatus == 0, "\(result.combinedOutput)")
        #expect(fixture.automation.targetedClickCalls.count == 1)
        let call = try #require(fixture.automation.targetedClickCalls.first)
        #expect(call.targetWindowID == nil)
        #expect(call.expectedWindowIdentity == nil)
        #expect(call.expectedProcessIdentity == window.mutationIdentity?.processIdentity)
        #expect(windows.windowLookupCount == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let identity = try #require(object["target_identity"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(identity["kind"] as? String == "process")
        #expect(receipt["window_id"] == nil)
        #expect(receipt["process_start_identity_decimal"] as? String == "7")
    }

    @Test(arguments: [["--window-id", "42"], ["--middle"], ["--triple"]])
    @MainActor
    func `Required exact-window clicks never downgrade on legacy hosts`(extraArguments: [String]) async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        fixture.automation.supportsExactWindowTargetedClicks = false
        let snapshotID = try await Self.storeSnapshot(window: window, in: fixture.snapshots)
        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotID, "--json"] + extraArguments,
            services: fixture.services
        )

        #expect(result.exitStatus == 1)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(windows.windowLookupCount == 0)
    }

    @Test(arguments: [["--on", "B1"], ["Save"]], [[], ["--right"], ["--double"], ["--middle"], ["--triple"]])
    @MainActor
    func `Snapshot-only clicks retain exact dispatch and JSON target receipts`(
        targetArguments: [String],
        clickArguments: [String]
    ) async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        let units = switch clickArguments.first {
        case "--double": 5
        case "--triple": 7
        case "--right", "--middle": 3
        default: 1
        }
        let automation = try #require(fixture.automation as? OutcomeStubAutomationService)
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(
                mechanism: clickArguments.isEmpty ? .accessibilityAction : .windowTargetedEvents,
                mode: .background
            ),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(units)
        )
        let snapshotID = try await Self.storeSnapshot(window: window, in: fixture.snapshots)
        let result = try await InProcessCommandRunner.run(
            ["click"] + targetArguments + clickArguments + ["--snapshot", snapshotID, "--json"],
            services: fixture.services
        )

        #expect(result.exitStatus == 0, "\(result.combinedOutput)")
        #expect(windows.windowLookupCount == 0)
        #expect(fixture.automation.targetedClickCalls.count == 1)
        let call = try #require(fixture.automation.targetedClickCalls.first)
        #expect(call.snapshotId == snapshotID)
        #expect(call.targetWindowID == window.windowID)
        #expect(call.expectedWindowIdentity == window.mutationIdentity)
        #expect(call.expectedWindowBounds == window.bounds)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let identity = try #require(object["target_identity"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(identity["kind"] as? String == "window")
        #expect(identity["window_id"] as? Int == window.windowID)
        #expect(receipt["window_id"] as? Int == window.windowID)
        #expect(receipt["pid"] as? Int == Int(application.processIdentifier))
        #expect(receipt["process_start_identity_decimal"] as? String == "7")
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(outcome["delivery_mode"] as? String == "background")
        #expect(outcome["dispatched_unit_count"] as? Int == units)
        #expect(outcome["state"] as? String == "dispatched_unverified")
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Process-scoped evidence never promotes descriptive window hints`(windowHints: Bool) async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        let snapshotID = try await Self.storeSnapshot(
            window: window,
            in: fixture.snapshots,
            context: WindowContext(
                applicationName: application.name,
                applicationProcessId: application.processIdentifier,
                applicationProcessStartIdentity: 7,
                windowID: windowHints ? window.windowID : nil,
                windowBounds: windowHints ? window.bounds : nil
            )
        )
        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotID, "--json"],
            services: fixture.services
        )

        #expect(result.exitStatus == 0, "\(result.combinedOutput)")
        #expect(windows.windowLookupCount == 0)
        #expect(fixture.automation.targetedClickCalls.count == 1)
        #expect(fixture.automation.targetedClickCalls.first?.targetWindowID == nil)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let identity = try #require(object["target_identity"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(identity["kind"] as? String == "process")
        #expect(receipt["window_id"] == nil)
        #expect(receipt["pid"] as? Int == Int(application.processIdentifier))
        #expect(receipt["process_start_identity_decimal"] as? String == "7")
    }

    @Test
    @MainActor
    func `Window identity supplies captured bounds when the context omits its duplicate`() async throws {
        // This verifies CLI forwarding; native admission still requires its complete snapshot context.
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        let snapshotID = try await Self.storeSnapshot(
            window: window,
            in: fixture.snapshots,
            context: WindowContext(
                applicationName: application.name,
                applicationProcessId: application.processIdentifier,
                windowID: window.windowID,
                windowMutationIdentity: window.mutationIdentity
            )
        )
        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotID, "--json"],
            services: fixture.services
        )

        #expect(result.exitStatus == 0, "\(result.combinedOutput)")
        #expect(fixture.automation.targetedClickCalls.count == 1)
        #expect(fixture.automation.targetedClickCalls.first?.expectedWindowBounds == window.bounds)
        #expect(fixture.automation.targetedClickCalls.first?.expectedWindowIdentity == window.mutationIdentity)
        #expect(windows.windowLookupCount == 0)
    }

    @Test(arguments: [
        "missing-generation",
        "missing-bounds",
        "missing-captured-bounds",
        "wrong-window",
        "wrong-bounds"
    ])
    @MainActor
    func `Incomplete or inconsistent capture receipts refuse before click dispatch`(variant: String) async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = SnapshotReceiptOnlyWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        let snapshotID = try await Self.storeSnapshot(
            window: window,
            in: fixture.snapshots,
            context: WindowContext(
                applicationName: application.name,
                applicationProcessId: application.processIdentifier,
                applicationProcessStartIdentity: variant == "missing-generation" ? nil : 7,
                windowID: variant == "wrong-window" ? 43 : window.windowID,
                windowBounds: variant == "missing-bounds" ? nil :
                    (variant == "wrong-bounds" ? window.bounds.offsetBy(dx: 1, dy: 0) : window.bounds),
                windowMutationIdentity: variant == "missing-generation" ? nil :
                    (["missing-bounds", "missing-captured-bounds"].contains(variant) ? WindowMutationIdentity(
                        windowID: window.windowID,
                        ownerProcessIdentifier: application.processIdentifier,
                        ownerProcessStartIdentity: 7
                    ) : window.mutationIdentity)
            )
        )
        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotID, "--json"],
            services: fixture.services
        )

        #expect(result.exitStatus == 1)
        #expect(fixture.automation.targetedClickCalls.isEmpty)
        #expect(windows.windowLookupCount == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let outcome = try #require(object["outcome"] as? [String: Any])
        let incompleteWindow = ["missing-bounds", "missing-captured-bounds"].contains(variant)
        #expect(error["code"] as? String == (incompleteWindow ? "SNAPSHOT_STALE" : "VALIDATION_ERROR"))
        #expect(error["retry_safe"] as? Bool == true)
        #expect(error["mutation_dispatched"] as? Bool == false)
        #expect(outcome["requires_fresh_observation"] as? Bool == false)
        if incompleteWindow {
            #expect((error["message"] as? String)?.contains("immutable captured bounds") == true)
        }
    }

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

    @Test(arguments: [false, true])
    @MainActor
    func `Stale exact-window receipt refuses once without selector fallback`(explicitSelector: Bool) async throws {
        let application = Self.makeApplication()
        let window = Self.makeWindow()
        let windows = StubWindowService(windowsByApp: [application.name: [window]])
        let fixture = Self.makeFixture(application: application, window: window, windows: windows)
        fixture.automation.clickError = PeekabooError.snapshotStale("window identity changed")
        let snapshotID = try await Self.storeSnapshot(window: window, in: fixture.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotID, "--json"] +
                (explicitSelector ? ["--window-id", "42"] : []),
            services: fixture.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("window identity changed"))
        #expect(fixture.automation.targetedClickCalls.count == 1)
        #expect(fixture.automation.targetedClickCalls.first?.targetWindowID == window.windowID)
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
        in snapshots: StubSnapshotManager,
        context: WindowContext? = nil
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
                    windowContext: context ?? WindowContext(
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
    private(set) var windowLookupCount = 0

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.windowLookupCount += 1
        if case .windowId = target {
            self.exactWindowLookupCount += 1
            throw PeekabooError.windowNotFound(criteria: "fixture rejects redundant exact-window enumeration")
        }
        return try await super.listWindows(target: target)
    }
}
