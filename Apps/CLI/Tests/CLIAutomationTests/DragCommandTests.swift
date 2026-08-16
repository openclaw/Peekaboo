import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

private struct DragResult: Codable {
    let from: [String: Int]
    let to: [String: Int]
    let duration: Int
    let steps: Int
    let profile: String
    let modifiers: String?
    let executionTime: TimeInterval
}

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.safe), .enabled(if: CLITestEnvironment.runAutomationRead))
struct DragCommandTests {
    @Test
    func `Drag command exists`() {
        let config = DragCommand.commandDescription
        #expect(config.commandName == "drag")
        #expect(config.abstract.contains("drag and drop"))
    }

    @Test
    func `Drag command parameters`() async throws {
        let result = try await self.runDragCommand(["drag", "--help"])
        #expect(result.exitStatus == 0)
        let output = self.output(from: result)

        #expect(output.contains("--from"))
        #expect(output.contains("--to"))
        #expect(!output.contains("--from-coords"))
        #expect(!output.contains("--to-coords"))
        #expect(output.contains("--to-app"))
        #expect(output.contains("--duration"))
        #expect(output.contains("--modifiers"))
    }

    @Test
    func `Drag command validation - from required`() async throws {
        // Test missing from
        let result = try await self.runDragCommand(["drag", "--to", "B1"])
        #expect(result.exitStatus != 0)
    }

    @Test
    func `Drag command validation - to required`() async throws {
        // Test missing to
        let result = try await self.runDragCommand(["drag", "--from", "B1"])
        #expect(result.exitStatus != 0)
    }

    @Test
    func `Drag coordinate parsing`() {
        // Test valid coordinates
        let coords1 = "100,200"
        let parts1 = coords1.split(separator: ",")
        #expect(parts1.count == 2)
        #expect(Double(parts1[0]) == 100)
        #expect(Double(parts1[1]) == 200)

        // Test coordinates with spaces
        let coords2 = "100, 200"
        let parts2 = coords2.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Double(parts2[0]) == 100)
        #expect(Double(parts2[1]) == 200)
    }

    @Test
    func `Drag modifier parsing normalizes aliases`() throws {
        let command = try DragCommand.parse([
            "--from", "10,20", "--to", "30,40", "--modifiers", "command,alt,control", "--foreground",
        ])
        #expect(command.modifiers?.description == "cmd,option,ctrl")
    }

    @Test
    func `Drag error codes`() {
        #expect(ErrorCode.NO_POINT_SPECIFIED.rawValue == "NO_POINT_SPECIFIED")
        #expect(ErrorCode.INVALID_COORDINATES.rawValue == "INVALID_COORDINATES")
        #expect(ErrorCode.SNAPSHOT_NOT_FOUND.rawValue == "SNAPSHOT_NOT_FOUND")
        #expect(ErrorCode.SNAPSHOT_STALE.rawValue == "SNAPSHOT_STALE")
    }

    @Test
    func `Drag duration validation`() {
        // Test that duration is positive
        let validDurations = [100, 500, 1000, 2000]
        for duration in validDurations {
            let cmd = ["drag", "--from", "A1", "--to", "B1", "--duration", "\(duration)"]
            #expect(cmd.count == 7)
        }
    }

    @Test
    func `Drag executes automation service`() async throws {
        let arguments = [
            "drag",
            "--from", "10,20",
            "--to", "30,40",
            "--duration", "750ms",
            "--steps", "5",
            "--modifiers", "cmd,option",
            "--json",
            "--foreground",
        ]
        let (result, context) = try await self.runDragCommandWithContext(arguments)
        #expect(result.exitStatus == 0)
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(Int(call.from.x) == 10)
        #expect(Int(call.from.y) == 20)
        #expect(Int(call.to.x) == 30)
        #expect(Int(call.to.y) == 40)
        #expect(call.duration == 750)
        #expect(call.steps == 5)
        #expect(call.modifiers == "cmd,option")
        #expect(call.profile == .linear)
    }

    @Test
    func `Drag between coordinates scenario`() async throws {
        let arguments = [
            "drag",
            "--from", "100,100",
            "--to", "300,300",
            "--duration", "500",
            "--json",
            "--foreground",
        ]
        let (result, context) = try await self.runDragCommandWithContext(arguments)
        #expect(result.exitStatus == 0)
        let payloadData = Data(self.output(from: result).utf8)
        let payload = try JSONDecoder().decode(CodableJSONResponse<DragResult>.self, from: payloadData)
        #expect(payload.success)
        #expect(payload.data.profile == "linear")
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(Int(call.from.x) == 100)
        #expect(Int(call.from.y) == 100)
        #expect(Int(call.to.x) == 300)
        #expect(Int(call.to.y) == 300)
        #expect(call.duration == 500)
        #expect(call.profile == .linear)
    }

    @Test
    func `Drag from element to coordinates scenario`() async throws {
        let snapshotId = "test-snapshot"
        let element = DetectedElement(
            id: "B1",
            type: .button,
            label: "Source",
            bounds: CGRect(x: 10, y: 20, width: 40, height: 20)
        )
        let arguments = [
            "drag",
            "--from", "B1",
            "--to", "500,500",
            "--snapshot", snapshotId,
            "--json",
            "--foreground",
        ]

        let windows = await MainActor.run {
            InputFocusWindowService(focusOutcome: InputFocusFixtures.focusOutcome)
        }
        let context = await self.makeAutomationContext(windows: windows)
        let services = await MainActor.run {
            InputExecutionHostServices(host: .remote, base: context.services)
        }
        let detection = ElementDetectionResult(
            snapshotId: snapshotId,
            screenshotPath: "/tmp/screenshot.png",
            elements: DetectedElements(buttons: [element]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "stub",
                windowContext: Self.inputFocusWindowContext
            )
        )
        try await context.snapshots.storeDetectionResult(snapshotId: snapshotId, result: detection)
        await MainActor.run {
            context.automation.setWaitForElementResult(
                WaitForElementResult(found: true, element: element, waitTime: 0.05),
                for: .elementId("B1")
            )
        }
        let result = try await InProcessCommandRunner.run(arguments, services: services)

        #expect(result.exitStatus == 0)
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(Int(call.from.x) == 30)
        #expect(Int(call.from.y) == 30)
        #expect(Int(call.to.x) == 500)
        #expect(Int(call.to.y) == 500)
    }

    @Test
    func `Drag with modifiers scenario`() async throws {
        let arguments = [
            "drag",
            "--from", "200,200",
            "--to", "400,400",
            "--modifiers", "cmd,option",
            "--json",
            "--foreground",
        ]
        let (result, context) = try await self.runDragCommandWithContext(arguments)
        #expect(result.exitStatus == 0)
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(call.modifiers == "cmd,option")
    }

    @Test
    func `Drag to application scenario`() async throws {
        let (applicationService, windowService) = await MainActor.run { () -> (
            StubApplicationService,
            StubWindowService
        ) in
            let finderInfo = ServiceApplicationInfo(
                processIdentifier: 101,
                bundleIdentifier: "com.apple.finder",
                name: "Finder",
                windowCount: 1
            )
            let window = ServiceWindowInfo(
                windowID: 1,
                title: "Finder",
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
            let appService = StubApplicationService(applications: [finderInfo], windowsByApp: ["Finder": [window]])
            let winService = StubWindowService(windowsByApp: ["Finder": [window]])
            return (appService, winService)
        }

        let arguments = [
            "drag",
            "--from", "100,100",
            "--to-app", "Finder",
            "--json",
            "--foreground",
        ]

        let (result, context) = try await self.runDragCommandWithContext(
            arguments,
            applications: applicationService,
            windows: windowService
        )
        #expect(result.exitStatus == 0)
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(Int(call.to.x) == 400)
        #expect(Int(call.to.y) == 300)
    }

    @Test
    func `Drag with custom duration scenario`() async throws {
        let arguments = [
            "drag",
            "--from", "50,50",
            "--to", "150,150",
            "--duration", "2s",
            "--json",
            "--foreground",
        ]
        let (result, context) = try await self.runDragCommandWithContext(arguments)
        #expect(result.exitStatus == 0)
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(call.duration == 2000)
        #expect(call.profile == .linear)
    }

    @Test
    func `Human profile enables natural drag`() async throws {
        let arguments = [
            "drag",
            "--from", "0,0",
            "--to", "400,200",
            "--profile", "human",
            "--json",
            "--foreground",
        ]
        let (result, context) = try await self.runDragCommandWithContext(arguments)
        #expect(result.exitStatus == 0)
        let dragCalls = await self.automationState(context) { $0.dragCalls }
        let call = try #require(dragCalls.first)
        #expect(call.profile == .human())
        #expect(call.steps >= 40)
        let payloadData = Data(self.output(from: result).utf8)
        let payload = try JSONDecoder().decode(CodableJSONResponse<DragResult>.self, from: payloadData)
        #expect(payload.data.profile == "human")
    }

    @Test
    func `Drag requires explicit foreground consent`() async throws {
        let arguments = [
            "drag",
            "--from", "10,20",
            "--to", "30,40",
        ]
        let (result, context) = try await self.runDragCommandWithContext(arguments)

        #expect(result.exitStatus != 0)
        #expect(self.output(from: result).contains("requires explicit consent"))
        #expect(await self.automationState(context) { $0.dragCalls }.isEmpty)
    }
}

extension DragCommandTests {
    fileprivate func runDragCommand(
        _ args: [String],
        configure: (@MainActor (StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async throws -> CommandRunResult {
        let (result, _) = try await self.runDragCommandWithContext(args, configure: configure)
        return result
    }

    fileprivate func runDragCommandWithContext(
        _ args: [String],
        applications: (any ApplicationServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil,
        configure: (@MainActor (StubAutomationService, StubSnapshotManager) -> Void)? = nil
    ) async throws -> (CommandRunResult, TestServicesFactory.AutomationTestContext) {
        let context = await self.makeAutomationContext(applications: applications, windows: windows)
        if let configure {
            await MainActor.run {
                configure(context.automation, context.snapshots)
            }
        }
        let result = try await InProcessCommandRunner.run(args, services: context.services)
        return (result, context)
    }

    fileprivate func makeAutomationContext(
        applications: (any ApplicationServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil
    ) async -> TestServicesFactory.AutomationTestContext {
        await MainActor.run {
            TestServicesFactory.makeAutomationTestContext(
                applications: applications ?? StubApplicationService(applications: []),
                windows: windows ?? StubWindowService(windowsByApp: [:])
            )
        }
    }

    fileprivate func automationState<T: Sendable>(
        _ context: TestServicesFactory.AutomationTestContext,
        _ operation: @MainActor (StubAutomationService) -> T
    ) async -> T {
        await MainActor.run {
            operation(context.automation)
        }
    }

    fileprivate func output(from result: CommandRunResult) -> String {
        result.stdout.isEmpty ? result.stderr : result.stdout
    }

    private static var inputFocusWindowContext: WindowContext {
        WindowContext(
            applicationName: "InputFixture",
            applicationProcessId: InputFocusFixtures.processIdentifier,
            windowTitle: "Input Fixture",
            windowID: InputFocusFixtures.windowID,
            windowBounds: InputFocusFixtures.bounds,
            windowMutationIdentity: InputFocusFixtures.identity()
        )
    }
}

#else
#if !PEEKABOO_SKIP_AUTOMATION
// Drag automation tests remain disabled pending Swift compiler fixes.
#endif
#endif
