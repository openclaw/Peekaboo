import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct ClickCommandTests {
    @Test
    func `Click command  requires argument or option`() throws {
        var command = try ClickCommand.parse([])
        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `Click command  parses coordinates correctly`() async throws {
        let context = await makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "100,200", "--foreground", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.clickCalls }
        let call = try #require(calls.first)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 100, y: 200))
        } else {
            Issue.record("Expected coordinates click target")
        }
    }

    @Test
    func `Click command  validates coordinate format`() throws {
        var command = try ClickCommand.parse(["--coords", "invalid", "--json"])
        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `Long press uses foreground stationary click type`() async throws {
        let context = await makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "100,200", "--long-press", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.clickCalls }
        let call = try #require(calls.first)
        #expect(call.clickType == .longPress)
        #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
    }

    @Test
    func `Long press rejects conflicting click variants`() throws {
        var command = try ClickCommand.parse(["--coords", "100,200", "--long-press", "--right"])

        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `Click command defaults to background coordinate clicks when pid is supplied`() async throws {
        let context = await makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "100,200", "--pid", "12345", "--global-coords", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.targetedClickCalls }
        let call = try #require(calls.first)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 100, y: 200))
        } else {
            Issue.record("Expected coordinates click target")
        }
        #expect(call.targetProcessIdentifier == 12345)
        #expect(call.targetWindowID == nil)
    }

    @Test
    func `Click command pins background coordinate clicks to exact window`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let context = await makeContext(application: application, windows: [selectedWindow])

        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "10,10", "--window-id", "42", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.targetedClickCalls }
        let call = try #require(calls.first)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 20, y: 30))
        } else {
            Issue.record("Expected coordinates click target")
        }
        #expect(call.targetProcessIdentifier == application.processIdentifier)
        #expect(call.targetWindowID == selectedWindow.windowID)
    }

    @Test
    func `Click command preserves exact window routing for global coordinates`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let context = await makeContext(application: application, windows: [selectedWindow])

        let result = try await InProcessCommandRunner.run(
            ["click", "--coords", "100,200", "--window-id", "42", "--global-coords", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.targetedClickCalls }
        let call = try #require(calls.first)
        if case let .coordinates(point) = call.target {
            #expect(point == CGPoint(x: 100, y: 200))
        } else {
            Issue.record("Expected coordinates click target")
        }
        #expect(call.targetProcessIdentifier == application.processIdentifier)
        #expect(call.targetWindowID == selectedWindow.windowID)
    }

    @Test
    func `Click command default element click uses cached snapshot without waiting`() async throws {
        let context = await makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await automationState(context) { $0.waitForElementCalls }
        let calls = await automationState(context) { $0.targetedClickCalls }
        #expect(waitCalls.isEmpty)
        let call = try #require(calls.first)
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 12345)
        if case let .elementId(id) = call.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected element ID click target")
        }
    }

    @Test
    func `Click command default query click resolves cached snapshot without waiting`() async throws {
        let context = await makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--snapshot", snapshotId, "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await automationState(context) { $0.waitForElementCalls }
        let calls = await automationState(context) { $0.targetedClickCalls }
        #expect(waitCalls.isEmpty)
        let call = try #require(calls.first)
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 12345)
        if case let .elementId(id) = call.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected resolved element ID click target")
        }
    }

    @Test
    func `Background click lookup failures preserve the implicit latest snapshot`() async throws {
        let testCases = [
            ["--on", "missing"],
            ["Missing query"],
            ["--on", "B1", "--app", "MissingApp"],
        ]

        for arguments in testCases {
            let context = await makeContext()
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
            )
            let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)

            let result = try await InProcessCommandRunner.run(
                ["click"] + arguments + ["--snapshot", snapshotId, "--json"],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(context.snapshots.invalidationCutoffs.isEmpty)
            #expect(await context.snapshots.getMostRecentSnapshot() == snapshotId)
            let calls = await automationState(context) { $0.targetedClickCalls }
            #expect(calls.isEmpty)
        }
    }

    @Test
    func `Click command pins element and query clicks to matching window selectors`() async throws {
        let application = Self.makeApplication()
        let otherWindow = Self.makeWindow(id: 41, title: "Other", index: 0)
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 1)
        let testCases = [
            (target: ["--on", "B1"], selector: ["--window-id", "42"]),
            (target: ["Save"], selector: ["--app", application.name, "--window-title", "Editor"]),
            (target: ["--on", "B1"], selector: ["--app", application.name, "--window-index", "1"]),
        ]

        for testCase in testCases {
            let context = await makeContext(application: application, windows: [otherWindow, selectedWindow])
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
            )
            let snapshotId = try await storeSnapshot(
                element: element,
                windowID: selectedWindow.windowID,
                windowTitle: selectedWindow.title,
                in: context.snapshots
            )

            let result = try await InProcessCommandRunner.run(
                ["click"] + testCase.target + ["--snapshot", snapshotId, "--json"] + testCase.selector,
                services: context.services
            )

            #expect(result.exitStatus == 0)
            let calls = await automationState(context) { $0.targetedClickCalls }
            let call = try #require(calls.first)
            #expect(calls.count == 1)
            #expect(call.snapshotId == snapshotId)
            #expect(call.targetProcessIdentifier == application.processIdentifier)
            #expect(call.targetWindowID == selectedWindow.windowID)
            if case let .elementId(id) = call.target {
                #expect(id == "B1")
            } else {
                Issue.record("Expected exact cached element target")
            }
        }
    }

    @Test
    func `Click command rejects window selectors that contradict cached snapshot`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 41, title: "Other", index: 0)
        let snapshotWindow = Self.makeWindow(id: 42, title: "Editor", index: 1)
        let testCases = [
            (target: ["--on", "B1"], selector: ["--window-id", "41"]),
            (target: ["Save"], selector: ["--app", application.name, "--window-title", "Other"]),
            (target: ["--on", "B1"], selector: ["--app", application.name, "--window-index", "0"]),
        ]

        for testCase in testCases {
            let context = await makeContext(application: application, windows: [selectedWindow, snapshotWindow])
            let element = DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
            )
            let snapshotId = try await storeSnapshot(
                element: element,
                windowID: snapshotWindow.windowID,
                windowTitle: snapshotWindow.title,
                in: context.snapshots
            )

            let result = try await InProcessCommandRunner.run(
                ["click"] + testCase.target + ["--snapshot", snapshotId, "--json"] + testCase.selector,
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(result.combinedOutput.contains("window 42"))
            #expect(result.combinedOutput.contains("window 41"))
            let calls = await automationState(context) { $0.targetedClickCalls }
            #expect(calls.isEmpty)
        }
    }

    @Test
    func `Click command rejects window selector when snapshot has no exact window`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let context = await makeContext(application: application, windows: [selectedWindow])
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--window-id", "42", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("does not identify an exact window"))
        let calls = await automationState(context) { $0.targetedClickCalls }
        #expect(calls.isEmpty)
    }

    @Test
    func `Foreground click accepts legacy snapshot without exact window metadata`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let context = await makeContext(application: application, windows: [selectedWindow])
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)
        await MainActor.run {
            context.automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: element, waitTime: 0),
                for: .elementId("B1")
            )
        }

        let result = try await InProcessCommandRunner.run(
            [
                "click", "--on", "B1", "--snapshot", snapshotId,
                "--window-id", "42", "--foreground", "--no-auto-focus", "--json",
            ],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let foregroundCalls = await automationState(context) { $0.clickCalls }
        let backgroundCalls = await automationState(context) { $0.targetedClickCalls }
        #expect(foregroundCalls.count == 1)
        #expect(backgroundCalls.isEmpty)
    }

    @Test
    func `Click command succeeds when post-click diagnostics become stale`() async throws {
        let context = await makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Close",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)
        context.snapshots.uiAutomationSnapshotError = .snapshotStale("target changed after click")

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.targetedClickCalls }
        #expect(calls.count == 1)
        #expect(context.snapshots.invalidationCutoffs.count == 1)
        #expect(await context.snapshots.getMostRecentSnapshot() == nil)
        #expect(try await context.snapshots.getDetectionResult(snapshotId: snapshotId) != nil)
    }

    @Test
    func `Foreground click failure after focus invalidates latest snapshot`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 12345,
            bundleIdentifier: "com.example.peekaboo-focus-mutation-fixture",
            name: "PeekabooFocusMutationFixture",
            isActive: false,
            windowCount: 0,
            activationPolicy: .regular
        )
        let context = await makeContext(application: application)
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            [
                "click", "--on", "B1", "--snapshot", snapshotId,
                "--app", application.name, "--foreground", "--json",
            ],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        let applications = try #require(context.services.applications as? StubApplicationService)
        #expect(applications.activateCalls == [application.name])
        #expect(context.snapshots.invalidationCutoffs.count == 1)
        #expect(await context.snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Click command reuses latest snapshot for element lookup with app target`() async throws {
        let context = await makeContext()
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, in: context.snapshots)
        await MainActor.run {
            context.automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: element, waitTime: 0),
                for: .query("Save")
            )
        }

        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--app", "TextEdit", "--json", "--no-auto-focus"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await automationState(context) { $0.waitForElementCalls }
        let clickCalls = await automationState(context) { $0.clickCalls }
        #expect(waitCalls.first?.snapshotId == snapshotId)
        #expect(clickCalls.first?.snapshotId == snapshotId)
    }

    private func makeContext(
        application: ServiceApplicationInfo? = nil,
        windows: [ServiceWindowInfo] = []
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let applications = application.map { [$0] } ?? []
            var windowsByApp: [String: [ServiceWindowInfo]] = [:]
            if let application {
                windowsByApp[application.name] = windows
                windowsByApp["PID:\(application.processIdentifier)"] = windows
                if let bundleIdentifier = application.bundleIdentifier {
                    windowsByApp[bundleIdentifier] = windows
                }
            }
            return TestServicesFactory.makeAutomationTestContext(
                applications: StubApplicationService(applications: applications, windowsByApp: windowsByApp),
                windows: StubWindowService(windowsByApp: windowsByApp)
            )
        }
    }

    private func storeSnapshot(
        element: DetectedElement,
        windowID: Int? = nil,
        windowTitle: String? = nil,
        in snapshots: StubSnapshotManager
    ) async throws -> String {
        let snapshotId = try await snapshots.createSnapshot()
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "stub",
                windowContext: WindowContext(
                    applicationName: "TestApp",
                    applicationBundleId: "com.example.test",
                    applicationProcessId: 12345,
                    windowTitle: windowTitle,
                    windowID: windowID
                )
            )
        )
        try await snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)
        return snapshotId
    }

    private static func makeApplication() -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 12345,
            bundleIdentifier: "com.example.test",
            name: "TestApp",
            isActive: false,
            windowCount: 2,
            activationPolicy: .regular
        )
    }

    private static func makeWindow(id: Int, title: String, index: Int) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: CGRect(x: 10, y: 20, width: 400, height: 300),
            isMainWindow: index == 0,
            index: index
        )
    }

    private func automationState<T: Sendable>(
        _ context: TestServicesFactory.AutomationTestContext,
        _ operation: @MainActor (StubAutomationService) -> T
    ) async -> T {
        await MainActor.run {
            operation(context.automation)
        }
    }
}
