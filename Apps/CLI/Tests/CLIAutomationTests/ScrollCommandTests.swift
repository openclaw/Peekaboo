import CoreGraphics
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
struct ScrollCommandTests {
    @Test
    func `scroll --help surfaces command documentation`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: ["--help"], context: context)

        #expect(result.exitStatus == 0)
        let output = self.output(from: result)
        #expect(output.contains("Scroll the mouse wheel in any direction"))
    }

    @Test
    func `Scroll command requires a direction`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: [], context: context)

        #expect(result.exitStatus == 0)
        let output = self.output(from: result)
        #expect(output.contains("--direction"))
        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        #expect(scrollCalls.isEmpty)
    }

    @Test
    func `Scroll forwards foreground parameters to automation service`() async throws {
        let context = await self.makeContext()

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--amount", "5",
                "--delay", "10",
                "--smooth",
                "--foreground",
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus == 0)

        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        let call = try #require(scrollCalls.first)
        #expect(call.request.direction == .down)
        #expect(call.request.amount == 5)
        #expect(call.request.delay == 10)
        #expect(call.request.smooth == true)
        #expect(call.request.target == nil)
        #expect(call.request.snapshotId == nil)
        #expect(call.request.foreground)

        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScrollResult>.self, from: payloadData)
        #expect(payload.success)
        #expect(payload.data.direction == "down")
        #expect(payload.data.amount == 5)
    }

    @Test
    func `Scroll on element refreshes stale latest snapshot`() async throws {
        let detectorReturnedSnapshotID = "detector-returned-snapshot"
        let appInfo = ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: "com.example.ScrollApp",
            name: "ScrollApp",
            windowCount: 1
        )
        let window = ServiceWindowInfo(
            windowID: 4242,
            title: "Scroll",
            bounds: CGRect(x: 0, y: 0, width: 600, height: 400)
        )
        let automation = await MainActor.run {
            let automation = StubAutomationService()
            automation.detectElementsHandler = { _, _, _ in
                Self.detectionResult(
                    snapshotId: detectorReturnedSnapshotID,
                    element: Self.buttonElement(id: "B1")
                )
            }
            return automation
        }
        let snapshots = StubSnapshotManager()
        let staleSnapshotID = try await snapshots.createSnapshot()
        let context = await MainActor.run {
            TestServicesFactory.makeAutomationTestContext(
                automation: automation,
                snapshots: snapshots,
                applications: StubApplicationService(
                    applications: [appInfo],
                    windowsByApp: ["com.example.ScrollApp": [window]]
                )
            )
        }

        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--on", "B1", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        let call = try #require(scrollCalls.first)
        #expect(call.request.target == "B1")
        let refreshedSnapshotID = try #require(call.request.snapshotId)
        #expect(refreshedSnapshotID != staleSnapshotID)
        #expect(refreshedSnapshotID != detectorReturnedSnapshotID)
        let detectionCalls = await MainActor.run { automation.detectElementsCalls }
        #expect(detectionCalls.first?.snapshotId == refreshedSnapshotID)
        let storedResult = try #require(try await snapshots.getDetectionResult(snapshotId: refreshedSnapshotID))
        #expect(storedResult.snapshotId == refreshedSnapshotID)
        #expect(storedResult.elements.findById("B1") != nil)
        #expect(call.request.expectedWindow?.identity.windowID == 4242)
        #expect(call.request.expectedWindow?.bounds == CGRect(x: 0, y: 0, width: 600, height: 400))
        #expect(call.request.delay == 0)
        #expect(!call.request.foreground)
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(payload.effect == .unverifiable)
        #expect(payload.outcome == nil)
    }

    @Test
    func `Scroll without snapshot still executes`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "up", "--amount", "2", "--foreground"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let scrollCalls = await self.automationState(context) { $0.scrollCalls }
        #expect(scrollCalls.count == 1)
        let call = try #require(scrollCalls.first)
        #expect(call.request.snapshotId == nil)
        #expect(call.request.amount == 2)
        #expect(call.request.foreground)
    }

    @Test
    @MainActor
    func `Targeted foreground scroll refuses unconfirmed focus before global events`() async throws {
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
                "scroll", "--direction", "down",
                "--window-id", String(InputFocusFixtures.windowID),
                "--foreground",
                "--json",
            ],
            services: services
        )
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(result.stdout.utf8))

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.scrollCalls.isEmpty)
        #expect(payload.outcome?.state == .suspectedNoop)
        #expect(payload.target_receipt?.windowID == InputFocusFixtures.windowID)
    }

    @Test
    func `Targetless foreground scroll remains allowed with automatic focus disabled`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--foreground", "--no-auto-focus"],
            context: context
        )

        #expect(result.exitStatus == 0)
        #expect(await self.automationState(context) { $0.scrollCalls }.count == 1)
    }

    @Test
    func `Smooth scrolling adjusts total ticks in JSON output`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--amount", "4", "--smooth", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScrollResult>.self, from: payloadData)
        #expect(payload.data.totalTicks == 40) // 4 * 10 when smooth
    }

    @Test
    func `Scroll without element reports pointer location from automation service`() async throws {
        let context = await self.makeContext { automation, _ in
            automation.stubCurrentMouseLocation = CGPoint(x: 123, y: 456)
        }

        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--foreground", "--json"],
            context: context
        )

        #expect(result.exitStatus == 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(CodableJSONResponse<ScrollResult>.self, from: payloadData)
        #expect(payload.data.location["x"] == 123)
        #expect(payload.data.location["y"] == 456)
    }

    @Test(arguments: [
        "up", "down", "left", "right",
    ])
    func `Direction validation accepts common values`(value: String) async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: ["--direction", value, "--foreground"], context: context)
        #expect(result.exitStatus == 0)
    }

    @Test
    func `Targetless background scroll fails closed`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(arguments: ["--direction", "down"], context: context)

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("Background scroll requires --on"))
        #expect(await self.automationState(context) { $0.scrollCalls }.isEmpty)
    }

    @Test
    func `Smooth background scroll requires foreground`() async throws {
        let context = await self.makeContext()
        let result = try await self.runScroll(
            arguments: ["--direction", "down", "--on", "S1", "--smooth"],
            context: context
        )

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("require --foreground"))
        #expect(await self.automationState(context) { $0.scrollCalls }.isEmpty)
    }

    @Test
    func `background element scroll refuses snapshot without exact window before automation`() async throws {
        let context = await self.makeContext()
        let snapshotID = try await context.snapshots.createSnapshot()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/incomplete-scroll.png",
                elements: DetectedElements(buttons: [Self.buttonElement(id: "B1")]),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "stub")
            )
        )

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--on", "B1",
                "--snapshot", snapshotID,
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(payload.outcome?.state == .refused)
        #expect(payload.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(payload.outcome?.retrySafety == .safe)
        #expect(await self.automationState(context) { $0.scrollCalls }.isEmpty)
    }

    @Test
    func `background receipt planning preserves cancellation instead of snapshot stale`() async throws {
        let automation = await MainActor.run { StubAutomationService() }
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: Self.detectionResult(snapshotId: snapshotID, element: Self.buttonElement(id: "B1"))
        )
        snapshots.uiAutomationSnapshotCancellation = true
        let context = await MainActor.run {
            TestServicesFactory.makeAutomationTestContext(automation: automation, snapshots: snapshots)
        }

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--on", "B1",
                "--snapshot", snapshotID,
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(payload.error?.code != ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(payload.outcome == nil)
        #expect(await MainActor.run { automation.scrollCalls.isEmpty })
    }

    @Test
    func `partial scroll failure preserves exact accepted units in JSON`() async throws {
        let automation = await MainActor.run { OutcomeStubAutomationService() }
        await MainActor.run {
            automation.uiAutomationOutcomeScript.appendFailure(
                DesktopActionFailure.partial(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    unitCount: .one,
                    message: "One of three page units was accepted"
                ),
                for: .scroll
            )
        }
        let snapshots = StubSnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: Self.detectionResult(snapshotId: snapshotID, element: Self.buttonElement(id: "B1"))
        )
        let context = await MainActor.run {
            TestServicesFactory.makeAutomationTestContext(automation: automation, snapshots: snapshots)
        }

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--amount", "3",
                "--on", "B1",
                "--snapshot", snapshotID,
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payload = try JSONDecoder().decode(JSONResponse.self, from: Data(self.output(from: result).utf8))
        #expect(payload.outcome?.state == .partial)
        #expect(payload.outcome?.dispatchState.unitCount == .one)
        #expect(payload.outcome?.retrySafety == .unsafe)
        #expect(payload.outcome?.escalation == .recoverSideEffect)
    }

    @Test
    func `stale background scroll reports canonical retry-safe refusal`() async throws {
        let context = await self.makeContext { automation, _ in
            automation.scrollError = PeekabooError.snapshotStale(
                "target window owner, process generation, or bounds changed"
            )
        }
        let snapshotId = try await context.snapshots.createSnapshot()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--on", "B1",
                "--snapshot", snapshotId,
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: payloadData)
        #expect(!payload.success)
        #expect(payload.error?.code == ErrorCode.SNAPSHOT_STALE.rawValue)
        #expect(payload.outcome?.state == .refused)
        #expect(payload.outcome?.retrySafety == .safe)
        #expect(payload.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(payload.outcome?.refusalReason == .targetUnavailable)
    }

    @Test
    func `unsupported background scroll reports canonical retry-safe refusal`() async throws {
        let context = await self.makeContext { automation, _ in
            automation.scrollError = PeekabooError.invalidInput(
                "Background scroll is unavailable for this target"
            )
        }
        let snapshotId = try await context.snapshots.createSnapshot()
        try await context.snapshots.storeDetectionResult(
            snapshotId: snapshotId,
            result: Self.detectionResult(snapshotId: snapshotId, element: Self.buttonElement(id: "B1"))
        )

        let result = try await self.runScroll(
            arguments: [
                "--direction", "down",
                "--on", "B1",
                "--snapshot", snapshotId,
                "--json",
            ],
            context: context
        )

        #expect(result.exitStatus != 0)
        let payloadData = try #require(self.output(from: result).data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: payloadData)
        #expect(!payload.success)
        #expect(payload.error?.code == ErrorCode.INVALID_INPUT.rawValue)
        #expect(payload.outcome?.state == .refused)
        #expect(payload.outcome?.retrySafety == .safe)
        #expect(payload.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(payload.outcome?.refusalReason == .operationUnsupported)
    }

    // MARK: - Helpers

    private func runScroll(
        arguments: [String],
        context: TestServicesFactory.AutomationTestContext
    ) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(["scroll"] + arguments, services: context.services)
    }

    private func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private func makeContext(
        configure: (@MainActor (StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            let context = TestServicesFactory.makeAutomationTestContext()
            configure?(context.automation, context.snapshots)
            return context
        }
    }

    private func automationState<T: Sendable>(
        _ context: TestServicesFactory.AutomationTestContext,
        _ operation: @MainActor (StubAutomationService) -> T
    ) async -> T {
        await MainActor.run {
            operation(context.automation)
        }
    }

    private static func buttonElement(id: String) -> DetectedElement {
        DetectedElement(
            id: id,
            type: .button,
            label: "Button \(id)",
            bounds: CGRect(x: 20, y: 30, width: 100, height: 40)
        )
    }

    private static func detectionResult(snapshotId: String, element: DetectedElement) -> ElementDetectionResult {
        let windowBounds = CGRect(x: 0, y: 0, width: 600, height: 400)
        return ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/\(snapshotId).png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "stub",
                windowContext: WindowContext(
                    applicationBundleId: "com.example.ScrollApp",
                    applicationProcessId: 42,
                    windowID: 4242,
                    windowBounds: windowBounds,
                    windowMutationIdentity: WindowMutationIdentity(
                        windowID: 4242,
                        ownerProcessIdentifier: 42,
                        ownerProcessStartIdentity: 11,
                        capturedBounds: windowBounds
                    )
                )
            )
        )
    }
}
#endif

@Suite(.tags(.safe))
struct ScrollCommandResultStructTests {
    @Test
    func `Scroll result structure maintains fields`() {
        let result = ScrollResult(
            direction: "down",
            amount: 5,
            location: ["x": 500.0, "y": 300.0],
            totalTicks: 5,
            executionTime: 0.15
        )

        #expect(result.direction == "down")
        #expect(result.amount == 5)
        #expect(result.location["x"] == 500.0)
        #expect(result.location["y"] == 300.0)
        #expect(result.totalTicks == 5)
        #expect(result.targetReceipt == nil)
        #expect(result.executionTime == 0.15)
    }

    @Test
    func `Scroll exact target receipt preserves generation as decimal text`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 9_007_199_254_740_993,
            capturedBounds: bounds
        )
        let result = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "/tmp/shot.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: 123,
                    windowID: 42,
                    windowBounds: bounds,
                    windowMutationIdentity: identity
                )
            )
        )

        let receipt = try #require(ScrollTargetReceipt(snapshotId: "snapshot", detectionResult: result))

        #expect(receipt.processIdentifier == 123)
        #expect(receipt.processStartIdentityDecimal == "9007199254740993")
        #expect(receipt.windowId == 42)
        #expect(receipt.windowBounds == bounds)
    }
}
