import Foundation
import PeekabooCore
import PeekabooFoundation
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
            ["click", "--at", "100,200", "--foreground", "--json"],
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
        var command = try ClickCommand.parse(["--at", "invalid", "--json"])
        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `Click command refuses empty or conflicting target shapes before dispatch`() async throws {
        let invalidArguments = [
            ["click", "Save", "--on", "B1"],
            ["click", "Save", "--at", "10,20"],
            ["click", "--on", "B1", "--at", "10,20"],
            ["click", "Save", "--on", "B1", "--at", "10,20"],
            ["click", " ", "--on", " "],
        ]

        for arguments in invalidArguments {
            let context = await makeContext()
            let result = try await InProcessCommandRunner.run(arguments + ["--json"], services: context.services)

            #expect(result.exitStatus == 1)
            #expect(result.combinedOutput.contains("click target") || result.combinedOutput.contains("element query"))
            #expect(await self.automationState(context) { $0.clickCalls }.isEmpty)
            #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
            #expect(context.snapshots.invalidationCutoffs.isEmpty)
        }
    }

    @Test
    func `Long press uses foreground stationary click type`() async throws {
        let context = await makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--at", "100,200", "--long-press", "--foreground", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let calls = await automationState(context) { $0.clickCalls }
        let call = try #require(calls.first)
        #expect(call.clickType == .longPress)
        #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
    }

    @Test
    func `Targetless long press requires explicit foreground before mutation`() async throws {
        let context = await makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "--at", "100,200", "--long-press", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("requires explicit --foreground"))
        #expect(await self.automationState(context) { $0.clickCalls }.isEmpty)
        #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
        #expect(context.snapshots.invalidationCutoffs.isEmpty)
    }

    @Test
    @MainActor
    func `Targeted long press requires explicit foreground before focus or mutation`() async throws {
        let application = Self.makeApplication()
        let targetWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let applications = StubApplicationService(
            applications: [application],
            windowsByApp: [application.name: [targetWindow]]
        )
        let windows = StubWindowService(windowsByApp: [application.name: [targetWindow]])
        let context = TestServicesFactory.makeAutomationTestContext(
            applications: applications,
            windows: windows
        )

        let result = try await InProcessCommandRunner.run(
            [
                "click", "--at", "100,200", "--app", application.name,
                "--long-press", "--json",
            ],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("requires explicit --foreground"))
        #expect(applications.activateCalls.isEmpty)
        #expect(windows.focusCalls.isEmpty)
        #expect(context.automation.clickCalls.isEmpty)
        #expect(context.automation.targetedClickCalls.isEmpty)
        #expect(context.snapshots.invalidationCutoffs.isEmpty)
    }

    @Test
    func `Long press rejects conflicting click variants`() throws {
        var command = try ClickCommand.parse(["--at", "100,200", "--long-press", "--right"])

        #expect(throws: (any Error).self) {
            try command.validate()
        }
    }

    @Test
    func `All conflicting click variants refuse before runtime mutation`() async throws {
        let variants = ["--double", "--right", "--middle", "--triple", "--long-press"]
        for first in variants.indices {
            for second in variants.indices where first < second {
                let context = await makeContext()
                let result = try await InProcessCommandRunner.run(
                    ["click", "--at", "100,200", "--foreground", variants[first], variants[second], "--json"],
                    services: context.services
                )

                #expect(result.exitStatus == 1)
                #expect(result.combinedOutput.contains("mutually exclusive"))
                #expect(await self.automationState(context) { $0.clickCalls }.isEmpty)
                #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
                #expect(context.snapshots.invalidationCutoffs.isEmpty)
            }
        }
    }

    @Test
    func `Foreground middle and triple variants forward their exact click types`() async throws {
        for (flag, expected) in [("--middle", ClickType.middle), ("--triple", .triple)] {
            let context = await makeContext()
            let result = try await InProcessCommandRunner.run(
                ["click", "--at", "100,200", "--foreground", flag, "--json"],
                services: context.services
            )

            #expect(result.exitStatus == 0)
            let call = try #require(await self.automationState(context) { $0.clickCalls.first })
            #expect(call.clickType == expected)
            #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
        }
    }

    @Test
    func `Background middle and triple variants preserve exact snapshot window`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)

        for (flag, expected) in [("--middle", ClickType.middle), ("--triple", .triple)] {
            let context = await makeContext(application: application, windows: [selectedWindow])
            let snapshotId = try await storeSnapshot(
                element: DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Target",
                    bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
                ),
                windowID: selectedWindow.windowID,
                windowTitle: selectedWindow.title,
                in: context.snapshots
            )
            let result = try await InProcessCommandRunner.run(
                ["click", "--on", "B1", "--snapshot", snapshotId, flag, "--json"],
                services: context.services
            )

            #expect(result.exitStatus == 0)
            let call = try #require(await self.automationState(context) { $0.targetedClickCalls.first })
            #expect(call.clickType == expected)
            #expect(call.targetWindowID == selectedWindow.windowID)
        }
    }

    @Test
    func `Background stateless click rejects same ID generation and bounds drift`() async throws {
        let application = Self.makeApplication()
        let snapshotWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let mismatchedWindows = [
            Self.makeWindow(id: 42, title: "Editor", index: 0, processStartIdentity: 8),
            Self.makeWindow(
                id: 42,
                title: "Editor",
                index: 0,
                bounds: CGRect(x: 30, y: 40, width: 400, height: 300)
            ),
        ]

        for selectedWindow in mismatchedWindows {
            let context = await makeContext(application: application, windows: [selectedWindow])
            let snapshotId = try await storeSnapshot(
                element: DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Target",
                    bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
                ),
                windowID: snapshotWindow.windowID,
                windowTitle: snapshotWindow.title,
                in: context.snapshots
            )

            let result = try await InProcessCommandRunner.run(
                [
                    "click", "--on", "B1", "--snapshot", snapshotId,
                    "--window-id", String(selectedWindow.windowID), "--middle", "--json",
                ],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(result.combinedOutput.contains("no longer matches"))
            #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
        }
    }

    @Test
    func `Click command refuses PID only background coordinates without snapshot`() async throws {
        for snapshotArguments in [[], ["--snapshot", ""]] {
            let context = await makeContext()
            let result = try await InProcessCommandRunner.run(
                ["click", "--at", "100,200", "--pid", "12345", "--global"] +
                    snapshotArguments + ["--json"],
                services: context.services
            )

            #expect(result.exitStatus == 1)
            #expect(result.combinedOutput.contains("require --snapshot"))
            let calls = await automationState(context) { $0.targetedClickCalls }
            #expect(calls.isEmpty)
            #expect(context.snapshots.invalidationCutoffs.isEmpty)
        }
    }

    @Test
    func `Click command pins background coordinate clicks to exact window`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let context = await makeContext(application: application, windows: [selectedWindow])
        let snapshotId = try await storeSnapshot(
            element: DetectedElement(id: "B1", type: .button, bounds: .zero),
            windowID: selectedWindow.windowID,
            windowTitle: selectedWindow.title,
            in: context.snapshots
        )

        let result = try await InProcessCommandRunner.run(
            [
                "click", "--at", "10,10", "--window-id", "42",
                "--snapshot", snapshotId, "--json",
            ],
            services: context.services
        )
        #expect(result.exitStatus == 0, "Unexpected click refusal: \(result.combinedOutput)")
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
        let snapshotId = try await storeSnapshot(
            element: DetectedElement(id: "B1", type: .button, bounds: .zero),
            windowID: selectedWindow.windowID,
            windowTitle: selectedWindow.title,
            in: context.snapshots
        )

        let result = try await InProcessCommandRunner.run(
            [
                "click", "--at", "100,200", "--window-id", "42", "--global",
                "--snapshot", snapshotId, "--json",
            ],
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
        let snapshotId = try await storeSnapshot(element: element, windowID: 42, in: context.snapshots)

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
        #expect(call.expectedProcessIdentity == ApplicationProcessIdentity(
            processIdentifier: 12345,
            processStartIdentity: 7
        ))
        if case let .elementId(id) = call.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected element ID click target")
        }
    }

    @Test
    func `Background element click rejects a snapshot from a prior process generation`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 12345,
            processStartIdentity: 8,
            bundleIdentifier: "com.example.test",
            name: "TestApp",
            activationPolicy: .regular
        )
        let context = await self.makeContext(application: application)
        let snapshotId = try await self.storeSnapshot(
            element: DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
            ),
            windowID: 42,
            in: context.snapshots
        )

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--app", "TestApp", "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(await self.automationState(context) { $0.targetedClickCalls.isEmpty })
        #expect(result.combinedOutput.contains("different process generation"))
    }

    @Test
    func `Background element click rejects snapshot PID without capture generation`() async throws {
        let context = await self.makeContext()
        let snapshotId = try await self.storeSnapshot(
            element: DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
            ),
            windowID: 42,
            includeMutationIdentity: false,
            in: context.snapshots
        )

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--json"],
            services: context.services
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("no capture-time process-generation receipt"))
        #expect(await self.automationState(context) { $0.targetedClickCalls.isEmpty })
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
        let snapshotId = try await storeSnapshot(element: element, windowID: 42, in: context.snapshots)

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
    func `Click command rejects exact window selector when snapshot lacks capture receipt`() async throws {
        let application = Self.makeApplication()
        let selectedWindow = Self.makeWindow(id: 42, title: "Editor", index: 0)
        let context = await makeContext(application: application, windows: [selectedWindow])
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
            includeMutationIdentity: false,
            in: context.snapshots
        )

        let result = try await InProcessCommandRunner.run(
            ["click", "--on", "B1", "--snapshot", snapshotId, "--window-id", "42", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("no capture-time process-generation receipt"))
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
        let snapshotId = try await storeSnapshot(element: element, windowID: 42, in: context.snapshots)
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
            processStartIdentity: 7,
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
        #expect(applications.activateCalls == ["PID:\(application.processIdentifier)"])
        #expect(context.snapshots.invalidationCutoffs.count == 1)
        #expect(await context.snapshots.getMostRecentSnapshot() == nil)
    }

    @Test
    func `Click command reuses latest snapshot for element lookup with app target`() async throws {
        let application = Self.makeApplication()
        let context = await makeContext(application: application)
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        let snapshotId = try await storeSnapshot(element: element, windowID: 42, in: context.snapshots)
        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--app", application.name, "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 0)
        let waitCalls = await automationState(context) { $0.waitForElementCalls }
        let foregroundClickCalls = await automationState(context) { $0.clickCalls }
        let backgroundClickCalls = await automationState(context) { $0.targetedClickCalls }
        #expect(waitCalls.isEmpty)
        #expect(foregroundClickCalls.isEmpty)
        #expect(backgroundClickCalls.first?.snapshotId == snapshotId)
    }

    @Test
    func `Click focus options require explicit foreground delivery`() async throws {
        let context = await makeContext()
        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--app", "TextEdit", "--no-auto-focus", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("Focus options require --foreground for click"))
        #expect(await self.automationState(context) { $0.clickCalls }.isEmpty)
        #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
    }

    private func makeContext(
        application: ServiceApplicationInfo? = nil,
        windows: [ServiceWindowInfo] = []
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let automation = OutcomeStubAutomationService()
            automation.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one
            )
            let resolvedApplication = application ?? Self.makeApplication()
            let applications = [resolvedApplication]
            var windowsByApp: [String: [ServiceWindowInfo]] = [:]
            windowsByApp[resolvedApplication.name] = windows
            windowsByApp["PID:\(resolvedApplication.processIdentifier)"] = windows
            if let bundleIdentifier = resolvedApplication.bundleIdentifier {
                windowsByApp[bundleIdentifier] = windows
            }
            return TestServicesFactory.makeAutomationTestContext(
                automation: automation,
                applications: StubApplicationService(applications: applications, windowsByApp: windowsByApp),
                windows: StubWindowService(windowsByApp: windowsByApp)
            )
        }
    }

    private func storeSnapshot(
        element: DetectedElement,
        windowID: Int? = nil,
        windowTitle: String? = nil,
        includeMutationIdentity: Bool = true,
        in snapshots: StubSnapshotManager
    ) async throws -> String {
        let snapshotId = try await snapshots.createSnapshot()
        let windowBounds = windowID == nil ? nil : CGRect(x: 10, y: 20, width: 400, height: 300)
        let mutationIdentity: WindowMutationIdentity? = if includeMutationIdentity, let windowID {
            WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: 12345,
                ownerProcessStartIdentity: 7,
                capturedBounds: windowBounds
            )
        } else {
            nil
        }
        let captureCoordinateContext: CaptureCoordinateContext? = if let windowID, let windowBounds {
            CaptureCoordinateContext(
                metadata: CaptureMetadata(
                    size: windowBounds.size,
                    mode: .window,
                    windowInfo: ServiceWindowInfo(
                        windowID: windowID,
                        title: windowTitle ?? "",
                        bounds: windowBounds,
                        mutationIdentity: mutationIdentity
                    )
                ),
                referenceID: snapshotId
            )
        } else {
            nil
        }
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
                    windowID: windowID,
                    windowBounds: windowBounds,
                    windowMutationIdentity: mutationIdentity
                ),
                truncationInfo: nil,
                captureCoordinateContext: captureCoordinateContext
            )
        )
        try await snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)
        return snapshotId
    }

    private static func makeApplication() -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 12345,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.test",
            name: "TestApp",
            isActive: false,
            windowCount: 2,
            activationPolicy: .regular
        )
    }

    private static func makeWindow(
        id: Int,
        title: String,
        index: Int,
        bounds: CGRect = CGRect(x: 10, y: 20, width: 400, height: 300),
        processStartIdentity: UInt64 = 7
    ) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMainWindow: index == 0,
            index: index,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: 12345,
                ownerProcessStartIdentity: processStartIdentity,
                capturedBounds: bounds
            )
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

extension ClickCommandTests {
    @Test
    func `background click refuses a fuzzy application selector before dispatch`() async throws {
        let application = Self.makeApplication()
        let context = await self.makeContext(application: application)
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 20, y: 30, width: 80, height: 30)
        )
        _ = try await self.storeSnapshot(element: element, windowID: 42, in: context.snapshots)

        let result = try await InProcessCommandRunner.run(
            ["click", "Save", "--app", "Test", "--json"],
            services: context.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("not allowed for mutation"))
        #expect(await self.automationState(context) { $0.targetedClickCalls }.isEmpty)
        #expect(await self.automationState(context) { $0.clickCalls }.isEmpty)
    }
}
