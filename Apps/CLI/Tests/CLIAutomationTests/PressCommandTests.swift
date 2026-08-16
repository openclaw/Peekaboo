import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(
    .serialized,
    .tags(.safe),
    .enabled(if: CLITestEnvironment.runAutomationRead)
)
struct PressCommandTests {
    @Test
    func `press --help documents command`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["--help"], context: context)

        #expect(result.exitStatus == 0)
        #expect(self.output(from: result).contains("Press keyboard chords or chord sequences"))
    }

    @Test
    func `Press command forwards keys to automation service`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["return", "--foreground", "--json"], context: context)

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "return")
        #expect(call.holdDuration == 50)

        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<PressResult>.self, from: payloadData)
        #expect(payload.success)
        #expect(payload.effect == .unverifiable)
        #expect(payload.data.keys == ["return"])
        #expect(payload.data.totalPresses == 1)
    }

    @Test
    func `Repeat count multiplies key actions`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["tab", "--count", "3", "--foreground"], context: context)

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.map(\.keys) == ["tab", "tab", "tab"])
    }

    @Test
    func `Press command supports multiple keys in sequence`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(
            arguments: ["up", "down", "left", "right", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.map(\.keys) == ["up", "down", "left", "right"])
    }

    @Test
    func `Press command supports xdotool chord sequences`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(
            arguments: ["cmd+shift+t", "Return", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.map(\.keys) == ["cmd,shift,t", "return"])
    }

    @Test
    func `Press command forwards hold duration`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(
            arguments: ["space", "--hold", "250", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "space")
        #expect(call.holdDuration == 250)
    }

    @Test
    func `Background raw press refuses before dispatch with canonical metadata`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 4201, processStartIdentity: 71)
        let applications = await self.makeApplicationService(identity: identity)
        let context = await self.makeContext(applications: applications)

        let result = try await self.runPress(
            arguments: ["a", "b", "--pid", "4201", "--delay", "0", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: payloadData)
        #expect(payload.success == false)
        #expect(payload.effect == .refused)
        #expect(payload.error?.code == "INTERACTION_FAILED")
        #expect(payload.error?.retry_safe == true)
        #expect(payload.error?.mutation_dispatched == false)
        #expect(payload.error?.hint?.contains("--foreground") == true)
        #expect(!payload.debug_logs.contains(where: { $0.contains("Runtime host: remote") }))
        #expect(!payload.debug_logs.contains(where: { $0.contains("onDemand") }))
        #expect(await self.automationState(context) { $0.hotkeyCalls.isEmpty })
        #expect(await self.automationState(context) { $0.targetedHotkeyCalls.isEmpty })
    }

    @Test
    @MainActor
    func `Exact window press uses receipt-pinned background delivery`() async throws {
        let pid: Int32 = 4201
        let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)
        let applications = StubApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 71,
            bundleIdentifier: "com.example.Editor",
            name: "Editor"
        )])
        let windows = StubWindowService(windowsByApp: ["Editor": [ServiceWindowInfo(
            windowID: 901,
            title: "Document",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 901,
                ownerProcessIdentifier: pid,
                ownerProcessStartIdentity: 71,
                capturedBounds: bounds
            )
        )]])
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(delivery: .init(
            mechanism: .windowTargetedEvents,
            mode: .background
        ))
        automation.targetedFocusedElement = UIFocusInfo(
            role: "AXTextArea",
            title: nil,
            value: nil,
            frame: CGRect(x: 40, y: 60, width: 200, height: 100),
            applicationName: "Editor",
            bundleIdentifier: "com.example.Editor",
            processId: Int(pid),
            windowID: 901,
            identifier: "editor"
        )
        let context = await self.makeContext(
            automation: automation,
            applications: applications,
            windows: windows
        )

        let result = try await self.runPress(
            arguments: ["return", "--window-id", "901", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let call = try #require(automation.exactHotkeyCalls.first)
        #expect(call.keys == "return")
        #expect(call.target.windowIdentity.windowID == 901)
        let payload = try JSONDecoder().decode(
            CodableJSONResponse<PressResult>.self,
            from: Data(result.stdout.utf8)
        )
        #expect(payload.data.deliveryMode == "background")
        #expect(payload.data.targetPID == Int(pid))
        #expect(payload.data.targetWindowID == 901)
    }

    @Test
    @MainActor
    func `Remote targeted foreground press refuses suspected noop before global input`() async throws {
        let windows = InputFocusWindowService(
            focusOutcome: .suspectedNoop(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one
            )
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, automation: automation)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "press", "return",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(payload.outcome?.state == .suspectedNoop)
        #expect(payload.target_receipt?.windowID == InputFocusFixtures.windowID)
    }

    @Test
    @MainActor
    func `Remote targeted foreground press refuses confirmed background focus before global input`() async throws {
        let windows = InputFocusWindowService(
            focusOutcome: .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one
            )
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, automation: automation)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "press", "return",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.target_receipt?.windowID == InputFocusFixtures.windowID)
    }

    @Test
    @MainActor
    func `Remote targeted foreground press composes exact focus and leaf receipts`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        automation.actionOutcomeTargetIdentity = try InputFocusFixtures.targetIdentity()
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, automation: automation)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "press", "return",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try JSONDecoder().decode(
            CodableJSONResponse<PressResult>.self,
            from: Data(result.stdout.utf8)
        )

        #expect(result.exitStatus == 0)
        #expect(payload.outcome?.state == .confirmedChange)
        #expect(payload.outcome?.route == .bridge)
        #expect(payload.outcome?.deliveryMechanism == .composite)
        #expect(payload.outcome?.deliveryMode == .foreground)
        #expect(payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(payload.target_receipt?.windowID == InputFocusFixtures.windowID)
    }

    @Test
    @MainActor
    func `Remote targeted foreground press rejects a mismatched leaf target`() async throws {
        let windows = InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = InputFocusFixtures.typeOutcome
        automation.actionOutcomeTargetIdentity = try InputFocusFixtures.targetIdentity(windowID: 902)
        let services = InputExecutionHostServices(
            host: .remote,
            base: TestServicesFactory.makePeekabooServices(windows: windows, automation: automation)
        )

        let result = try await InProcessCommandRunner.run(
            [
                "press", "return",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))

        #expect(result.exitStatus == 1)
        #expect(automation.hotkeyCalls.map(\.keys) == ["return"])
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(payload.target_identity == nil)
        #expect(payload.target_receipt == nil)
    }

    @Test
    func `Background target resolution cancellation is not projected as a target refusal`() async throws {
        let context = await self.makeContext(windows: CancellingPressWindowService())

        let result = try await self.runPress(
            arguments: ["return", "--window-id", "901", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))
        #expect(payload.outcome == nil)
        #expect(payload.error?.code != ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(await self.automationState(context) { $0.hotkeyCalls.isEmpty })
        #expect(await self.automationState(context) { $0.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Deprecated background alias remains accepted but cannot authorize raw press`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(
            arguments: ["return", "--focus-background", "--json"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("require explicit foreground consent"))
        #expect(await self.automationState(context) { $0.hotkeyCalls.isEmpty })
        #expect(await self.automationState(context) { $0.targetedHotkeyCalls.isEmpty })
    }

    @Test
    func `Cancellation during sequence delay never delivers a later chord`() async throws {
        let context = await self.makeContext()
        let command = Task {
            try await self.runPress(
                arguments: ["a", "b", "--foreground", "--delay", "5s"],
                context: context
            )
        }

        for _ in 0..<100 {
            let count = await self.automationState(context) { $0.hotkeyCalls.count }
            if count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        command.cancel()
        let result = try await command.value

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("outcome is indeterminate"))
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.map(\.keys) == ["a"])
    }

    @Test
    func `Foreground snapshot without an exact target refuses before global input`() async throws {
        let snapshotId = "snapshot-42"
        let context = await self.makeContext()
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "stub")
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)

        let result = try await self.runPress(
            arguments: ["escape", "--snapshot", snapshotId, "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 1)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.isEmpty)
    }

    @Test
    func `Invalid key results in failure`() async throws {
        let context = await self.makeContext()
        let result = try await self.runPress(arguments: ["notakey"], context: context)

        #expect(result.exitStatus != 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        #expect(calls.isEmpty)
    }

    // MARK: - Helpers

    private func runPress(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["press"] + arguments, services: context.services)
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func makeContext(
        automation: StubAutomationService = StubAutomationService(),
        applications: any ApplicationServiceProtocol = StubApplicationService(applications: []),
        windows: any WindowManagementServiceProtocol = StubWindowService(windowsByApp: [:]),
        configure: (@MainActor (StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let context = TestServicesFactory.makeAutomationTestContext(
                automation: automation,
                applications: applications,
                windows: windows
            )
            configure?(context.automation, context.snapshots)
            return context
        }
    }

    private func makeApplicationService(
        identity: ApplicationProcessIdentity
    ) async -> StubApplicationService {
        await MainActor.run {
            StubApplicationService(applications: [Self.application(identity: identity)])
        }
    }

    private nonisolated static func application(identity: ApplicationProcessIdentity) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity,
            bundleIdentifier: "com.example.press-target",
            name: "PressTarget"
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

private actor CancellingPressWindowService: WindowManagementServiceProtocol {
    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        throw CancellationError()
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
#endif
