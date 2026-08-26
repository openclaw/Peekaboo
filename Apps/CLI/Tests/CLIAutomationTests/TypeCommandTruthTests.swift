import CoreGraphics
import Foundation
import PeekabooAutomation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
@MainActor
struct TypeCommandTruthTests {
    private static let pid: pid_t = 2468
    private static let generation: UInt64 = 71
    private static let windowID = 901
    private static let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)

    @Test
    func `Exact-window Type never reports dispatched-unverified events as typed characters`() async throws {
        let automation = self.automation(focused: self.textFocus())
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let context = self.context(automation: automation)

        let result = try await self.runType(["Hello", "--app", "TextEdit", "--json"], context: context)

        #expect(result.exitStatus == 1)
        #expect(automation.exactTypeActionsCalls.count == 1)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.success == false)
        #expect(payload.outcome?.state == .dispatchedUnverified)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(!result.combinedOutput.contains("typedText"))
        #expect(!result.combinedOutput.contains("totalCharacters"))
    }

    @Test
    func `Missing typing outcome is non-success and never publishes typed fields`() async throws {
        let automation = self.automation(focused: self.textFocus())
        automation.actionOutcome = nil
        let context = self.context(automation: automation)

        let result = try await self.runType(["Hello", "--app", "TextEdit", "--json"], context: context)

        #expect(result.exitStatus != 0)
        #expect(automation.exactTypeActionsCalls.count == 1)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.success == false)
        #expect(payload.data == nil)
        #expect(!result.combinedOutput.contains("typedText"))
        #expect(!result.combinedOutput.contains("totalCharacters"))
    }

    @Test
    func `Every non-confirmed typing state is CLI non-success without typed fields`() async throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
        let outcomes: [DesktopActionOutcome?] = [
            nil,
            .confirmedNoChange(),
            .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted),
            .suspectedNoop(delivery: delivery),
            .partial(delivery: delivery),
            .refused(reason: .targetUnavailable),
            .indeterminate(delivery: delivery, evidence: .completionUnknown),
        ]

        for outcome in outcomes {
            let automation = OutcomeStubAutomationService()
            automation.actionOutcome = outcome
            let services = TestServicesFactory.makePeekabooServices(automation: automation)
            let result = try await InProcessCommandRunner.run(
                ["type", "Hello", "--foreground", "--json"],
                services: services
            )

            #expect(result.exitStatus != 0)
            #expect(!result.combinedOutput.contains("typedText"))
            #expect(!result.combinedOutput.contains("totalCharacters"))
        }
    }

    @Test
    func `Confirmed escaped backslash reports the planned receiver literal`() async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(delivery: .init(
            mechanism: .globalEvents,
            mode: .foreground
        ))
        let services = TestServicesFactory.makePeekabooServices(automation: automation)

        let result = try await InProcessCommandRunner.run(
            ["type", "\\\\", "--foreground", "--json"],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<TypeCommandResult>.self
        )

        #expect(result.exitStatus == 0)
        #expect(payload.data.requestedText == "\\\\")
        #expect(payload.data.typedText == "\\")
    }

    @Test
    func `CLI prefers authoritative special key event count over legacy arithmetic`() async throws {
        let cases: [(arguments: [String], result: TypeResult, expectedSpecialKeys: Int)] = [
            (
                ["type", "x\\n", "--foreground", "--json"],
                TypeResult(totalCharacters: 1, keyPresses: 1, specialKeyPresses: 1),
                1
            ),
            (
                ["type", "x", "--clear", "--foreground", "--json"],
                TypeResult(totalCharacters: 1, keyPresses: 2, specialKeyPresses: 2),
                2
            ),
        ]

        for testCase in cases {
            let automation = OutcomeStubAutomationService()
            automation.actionOutcome = .confirmedChange(delivery: .init(
                mechanism: .composite,
                mode: .foreground
            ))
            automation.typeActionsResultProvider = { _, _, _ in testCase.result }
            let services = TestServicesFactory.makePeekabooServices(automation: automation)

            let command = try await InProcessCommandRunner.run(testCase.arguments, services: services)
            #expect(command.exitStatus == 0, "Unexpected type failure: \(command.combinedOutput)")
            let payload = try ExternalCommandRunner.decodeJSONResponse(
                from: command,
                as: CodableJSONResponse<TypeCommandResult>.self
            )

            #expect(payload.data.specialKeyPresses == testCase.expectedSpecialKeys)
        }
    }

    @Test
    func `Type revalidates matching snapshot focus before exact-window dispatch`() async throws {
        let focused = self.textFocus()
        let automation = self.automation(focused: focused)
        automation.actionOutcome = .confirmedChange(delivery: .init(
            mechanism: .windowTargetedEvents,
            mode: .background
        ))
        let context = self.context(automation: automation)
        let snapshotID = try await self.storeSnapshot(focused: focused, context: context)

        let result = try await self.runType(
            ["Hello", "--snapshot", snapshotID, "--pid", String(Self.pid), "--window-id", "901", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        #expect(try #require(automation.exactTypeActionsCalls.first).target.focusedElement == focused)
    }

    @Test
    func `Type refuses a stale button receipt when AXPress did not move keyboard focus`() async throws {
        let automation = self.automation(focused: self.textFocus(identifier: "basic-text-field"))
        automation.actionOutcome = .confirmedChange(delivery: .init(
            mechanism: .windowTargetedEvents,
            mode: .background
        ))
        let context = self.context(automation: automation)
        let staleButton = FocusedElementIdentity(
            processIdentifier: Self.pid,
            windowID: Self.windowID,
            role: "AXButton",
            title: "Focus",
            identifier: "focus-basic-button",
            frame: CGRect(x: 40, y: 60, width: 120, height: 30)
        )
        let snapshotID = try await self.storeSnapshot(focused: staleButton, context: context)

        let result = try await self.runType(
            ["Hello", "--snapshot", snapshotID, "--pid", String(Self.pid), "--window-id", "901", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(automation.exactTypeActionsCalls.isEmpty)
        #expect(result.combinedOutput.contains("Exact focused-element receipt is stale"))
    }

    @Test
    func `Confirmed no-change typing leaf is not successful even when setup focus changed`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedNoChange(route: .bridge)
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, automation: automation)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground", "--json",
            ],
            services: services
        )
        #expect(result.exitStatus != 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.outcome?.state != .confirmedChange)
        #expect(payload.outcome?.dispatchState.mutationDispatched == true)
        #expect(payload.data == nil)
    }

    @Test
    func `Returned unverified typing receipt is non-success and invalidates observations`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted
        )
        let base = TestServicesFactory.makeAutomationTestContext(automation: automation, windows: windows)
        let services = InputExecutionHostServices(host: .remote, base: base.services)
        _ = try await base.snapshots.createSnapshot()

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground", "--json",
            ],
            services: services
        )

        #expect(result.exitStatus == 1)
        #expect(base.snapshots.invalidationCutoffs.count == 1)
        #expect(await base.snapshots.getMostRecentSnapshot() == nil)
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(payload.success == false)
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.outcome?.mutationDispatched == true)
    }

    @Test
    func `Confirmed focus followed by refused typing remains indeterminate`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .refused(route: .bridge, reason: .permissionDenied)
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, automation: automation)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "type", "Hello",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground", "--json",
            ],
            services: services
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let outcome = try #require(object["outcome"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["mutation_dispatched"] as? Bool == true)
        #expect(outcome["retry_safe"] as? Bool == false)
    }

    private func automation(focused: FocusedElementIdentity) -> OutcomeStubAutomationService {
        let automation = OutcomeStubAutomationService()
        automation.targetedFocusedElement = UIFocusInfo(
            role: focused.role,
            title: focused.title,
            value: nil,
            frame: focused.frame,
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            processId: Int(Self.pid),
            windowID: Self.windowID,
            identifier: focused.identifier
        )
        return automation
    }

    private func context(automation: OutcomeStubAutomationService) -> TestServicesFactory.AutomationTestContext {
        let app = ServiceApplicationInfo(
            processIdentifier: Self.pid,
            processStartIdentity: Self.generation,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let window = ServiceWindowInfo(
            windowID: Self.windowID,
            title: "Untitled",
            bounds: Self.bounds,
            mutationIdentity: Self.identity
        )
        return TestServicesFactory.makeAutomationTestContext(
            automation: automation,
            applications: StubApplicationService(applications: [app]),
            windows: StubWindowService(windowsByApp: ["TextEdit": [window]])
        )
    }

    private func storeSnapshot(
        focused: FocusedElementIdentity,
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> String {
        let snapshotID = try await context.snapshots.createSnapshot()
        let windowContext = WindowContext(
            applicationName: "TextEdit",
            applicationBundleId: "com.apple.TextEdit",
            applicationProcessId: Self.pid,
            windowTitle: "Untitled",
            windowID: Self.windowID,
            windowBounds: Self.bounds,
            windowMutationIdentity: Self.identity,
            focusedElement: focused
        )
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/type-truth.png",
                elements: DetectedElements(),
                metadata: DetectionMetadata(
                    detectionTime: 0,
                    elementCount: 0,
                    method: "test",
                    windowContext: windowContext
                )
            )
        )
        return snapshotID
    }

    private func runType(
        _ arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["type"] + arguments, services: context.services)
    }

    private func textFocus(identifier: String = "editor") -> FocusedElementIdentity {
        FocusedElementIdentity(
            processIdentifier: Self.pid,
            windowID: Self.windowID,
            role: "AXTextArea",
            identifier: identifier,
            frame: CGRect(x: 40, y: 120, width: 220, height: 30)
        )
    }

    private static var identity: WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: self.windowID,
            ownerProcessIdentifier: self.pid,
            ownerProcessStartIdentity: self.generation,
            capturedBounds: self.bounds
        )
    }
}
