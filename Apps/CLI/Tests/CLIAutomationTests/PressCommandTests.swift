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
    func `Background sequence pins one unchanged process generation`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 4201, processStartIdentity: 71)
        let applications = await self.makeApplicationService(identity: identity)
        let context = await self.makeContext(applications: applications) { automation, _ in
            automation.currentHotkeyProcessIdentity = { processIdentifier in
                applications.applications.first {
                    $0.processIdentifier == processIdentifier
                }?.processIdentity
            }
        }

        let result = try await self.runPress(
            arguments: ["a", "b", "--pid", "4201", "--delay", "0", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.map(\.keys) == ["a", "b"])
        #expect(calls.map(\.expectedProcessIdentity) == [identity, identity])
    }

    @Test
    func `Background sequence stops indeterminate after PID is reused`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 4202, processStartIdentity: 72)
        let replacement = ApplicationProcessIdentity(processIdentifier: 4202, processStartIdentity: 73)
        let applications = await self.makeApplicationService(identity: identity)
        let context = await self.makeContext(applications: applications) { automation, _ in
            automation.currentHotkeyProcessIdentity = { processIdentifier in
                applications.applications.first {
                    $0.processIdentifier == processIdentifier
                }?.processIdentity
            }
            automation.afterPinnedHotkey = {
                applications.applications = [Self.application(identity: replacement)]
            }
        }

        let result = try await self.runPress(
            arguments: ["a", "b", "--pid", "4202", "--delay", "0"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("outcome is indeterminate"))
        #expect(result.combinedOutput.contains("do not retry blindly"))
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.map(\.keys) == ["a"])
        #expect(calls.first?.expectedProcessIdentity == identity)
    }

    @Test
    func `Background sequence stops indeterminate after target exits`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 4203, processStartIdentity: 74)
        let applications = await self.makeApplicationService(identity: identity)
        let context = await self.makeContext(applications: applications) { automation, _ in
            automation.currentHotkeyProcessIdentity = { processIdentifier in
                applications.applications.first {
                    $0.processIdentifier == processIdentifier
                }?.processIdentity
            }
            automation.afterPinnedHotkey = {
                applications.applications = []
            }
        }

        let result = try await self.runPress(
            arguments: ["a", "b", "--pid", "4203", "--delay", "0"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("outcome is indeterminate"))
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.map(\.keys) == ["a"])
    }

    @Test
    func `Snapshot window receipt rejects a replaced process before first chord`() async throws {
        let captured = ApplicationProcessIdentity(processIdentifier: 4205, processStartIdentity: 76)
        let replacement = ApplicationProcessIdentity(processIdentifier: 4205, processStartIdentity: 77)
        let applications = await self.makeApplicationService(identity: replacement)
        let context = await self.makeContext(applications: applications)
        let snapshotId = "press-stale-process"
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/press-stale-process.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "stub",
                windowContext: WindowContext(
                    applicationName: "PressTarget",
                    applicationBundleId: "com.example.press-target",
                    applicationProcessId: captured.processIdentifier,
                    windowID: 905,
                    windowBounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                    windowMutationIdentity: WindowMutationIdentity(
                        windowID: 905,
                        ownerProcessIdentifier: captured.processIdentifier,
                        ownerProcessStartIdentity: captured.processStartIdentity
                    )
                )
            )
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)

        let result = try await self.runPress(
            arguments: ["a", "--snapshot", snapshotId],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("changed process generation"))
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.isEmpty)
    }

    @Test
    func `Cancellation during sequence delay never delivers a later chord`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 4204, processStartIdentity: 75)
        let applications = await self.makeApplicationService(identity: identity)
        let context = await self.makeContext(applications: applications) { automation, _ in
            automation.currentHotkeyProcessIdentity = { _ in identity }
        }
        let command = Task {
            try await self.runPress(
                arguments: ["a", "b", "--pid", "4204", "--delay", "5s"],
                context: context
            )
        }

        for _ in 0..<100 {
            let count = await self.automationState(context) { $0.targetedHotkeyCalls.count }
            if count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        command.cancel()
        let result = try await command.value

        #expect(result.exitStatus != 0)
        #expect(result.combinedOutput.contains("outcome is indeterminate"))
        let calls = await self.automationState(context) { $0.targetedHotkeyCalls }
        #expect(calls.map(\.keys) == ["a"])
    }

    @Test
    func `Snapshot argument is forwarded`() async throws {
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

        #expect(result.exitStatus == 0)
        let calls = await self.automationState(context) { $0.hotkeyCalls }
        let call = try #require(calls.first)
        #expect(call.keys == "escape")
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
        applications: any ApplicationServiceProtocol = StubApplicationService(applications: []),
        configure: (@MainActor (StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let context = TestServicesFactory.makeAutomationTestContext(applications: applications)
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
#endif
