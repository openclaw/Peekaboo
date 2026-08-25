import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit
@testable import PeekabooCore

@Suite(.serialized)
struct MCPComposedInputParityTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `pixel focus type maps exact request but reports unverified dispatch as non-success`() async throws {
        let fixture = try await Self.makeFixture()
        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "500,250",
            "coordinate_space": "image_pixels",
            "snapshot": fixture.snapshotID,
            "text": "hi",
        ]))

        #expect(response.isError)
        let request = try #require(await MainActor.run { fixture.automation.pixelFocusTypeRequests.first })
        #expect(request.point == CGPoint(x: 600, y: 300))
        #expect(request.snapshotID == fixture.snapshotID)
        #expect(request.windowIdentity == fixture.window.mutationIdentity)
        #expect(request.windowBounds == fixture.window.bounds)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["delivery_mode"] == .string("background"))
        #expect(metadata["delivery_mechanism"] == .string("composite"))
        #expect(metadata["dispatched_unit_count"] == .int(3))
        #expect(metadata["target_window_id"] == .int(fixture.window.windowID))
        #expect(metadata["state"] == .string("dispatched_unverified"))
        #expect(metadata["characters_typed"] == .null)
    }

    @Test
    func `pixel focus coordinate authority ignores capture focused element sidecar`() async throws {
        let focusedElement = AutomationTestFixtures.focusedElement(
            processIdentity: .init(processIdentifier: 111, processStartIdentity: 7),
            windowID: 42)
        let fixture = try await Self.makeFixture(focusedElement: focusedElement)

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "500,250",
            "coordinate_space": "image_pixels",
            "snapshot": fixture.snapshotID,
            "text": "hi",
        ]))

        #expect(response.isError)
        let request = try #require(await MainActor.run { fixture.automation.pixelFocusTypeRequests.first })
        #expect(request.windowIdentity == fixture.window.mutationIdentity)
        #expect(request.windowBounds == fixture.window.bounds)
    }

    @Test(arguments: [",10,20", "10,,20", "10,20,", "nan,20", "10,inf"])
    func `pixel focus type rejects malformed coordinate tuples before dispatch`(_ coords: String) async throws {
        let fixture = try await Self.makeFixture()
        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": coords,
            "snapshot": fixture.snapshotID,
            "text": "hi",
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(await MainActor.run { fixture.automation.pixelFocusTypeRequests.isEmpty })
    }

    @Test
    func `pixel focus receipt planning preserves cancellation before dispatch or lease consumption`() async throws {
        let fixture = try await Self.makeFixture()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TypeTool.planPixelFocusReceipt(
                snapshotID: fixture.snapshotID,
                snapshots: fixture.snapshots)
        }

        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(await MainActor.run { fixture.automation.pixelFocusTypeRequests.isEmpty })
        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `pixel focus execution propagates receipt cancellation before dispatch`() async throws {
        let fixture = try await Self.makeFixture()
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
                "coords": "500,250",
                "coordinate_space": "image_pixels",
                "snapshot": fixture.snapshotID,
                "text": "hi",
            ]))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(await MainActor.run { fixture.automation.pixelFocusTypeRequests.isEmpty })
        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `modifier click refuses background then projects truthful foreground restoration`() async throws {
        let fixture = try await Self.makeFixture()
        let refused = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "modifiers": ["cmd", "shift"],
        ]))
        #expect(refused.isError)
        #expect(refused.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })

        for contextual in [
            ["coords": "600,300", "snapshot": fixture.snapshotID, "foreground": true, "modifiers": ["ctrl"]],
            [
                "coords": "600,300", "snapshot": fixture.snapshotID, "foreground": true,
                "modifiers": ["cmd"], "right": true,
            ],
        ] as [[String: Any]] {
            let contextualResponse = try await ClickTool(context: fixture.context).execute(
                arguments: ToolArguments(raw: contextual))
            #expect(contextualResponse.isError)
            #expect(contextualResponse.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        }
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd", "shift"],
        ]))

        #expect(!response.isError)
        let request = try #require(await MainActor.run { fixture.automation.foregroundModifierClickRequests.first })
        #expect(request.point == CGPoint(x: 600, y: 300))
        #expect(request.modifiers == [.command, .shift])
        #expect(request.snapshotID == fixture.snapshotID)
        #expect(request.windowIdentity == fixture.window.mutationIdentity)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["delivery_mode"] == .string("foreground"))
        #expect(metadata["cursor_restoration"] == .string("restored"))
        #expect(metadata["focus_restoration"] == .string("preserved_newer_state"))
        #expect(metadata["modifiers"] == .array([.string("command"), .string("shift")]))
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
    }

    @Test
    func `modifier click adapter forwards typed refusal without owning the host lease`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickRefusalReason = .targetUnavailable
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
        let subsequentLease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(
            subsequentLease,
            requiresFreshObservation: false)
    }

    @Test
    func `modifier click adapter refuses a service without host leaf leasing`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.supportsForegroundModifierClickSnapshotLease = false
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
    }

    @Test
    func `modifier click adapter preserves prelane cancellation without a client lease`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Modifier-click was cancelled before acquiring its foreground operation lane.")
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `already focused pre click cancellation refuses without consuming snapshot`() async throws {
        let automation = await MainActor.run { AlreadyFocusedCancellingModifierClickService() }
        let fixture = try await Self.makeFixture(automation: automation)
        let operation = Task {
            try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
                "coords": "600,300",
                "snapshot": fixture.snapshotID,
                "foreground": true,
                "modifiers": ["cmd"],
            ]))
        }
        let response = try await operation.value

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("request_cancelled"))
        #expect(await MainActor.run { !automation.clickAttempted })
        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `input drift before first focus write refuses without consuming snapshot`() async throws {
        let automation = await MainActor.run { PreFocusInputDriftModifierClickService() }
        let fixture = try await Self.makeFixture(automation: automation)
        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(await MainActor.run { !automation.focusMutationAttempted && !automation.clickAttempted })
        #expect(await MainActor.run { automation.priorStatePreserved })
        let lease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `modifier click adapter preserves postdispatch failure without owning the host lease`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Modifier-click was cancelled after dispatch began.")
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
        let hostLease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(hostLease, requiresFreshObservation: false)
    }

    @Test
    func `modifier click adapter preserves typed receipt refusal without a client lease`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = SnapshotTargetReceiptPreDispatchError(
                .incompleteExactWindow)
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
        let subsequentLease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(
            subsequentLease,
            requiresFreshObservation: false)
    }

    @Test
    func `unknown modifier click failure is retry unsafe without a client lease`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = MCPComposedInputTestError.unknownServiceFailure
        }

        let response = try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "coords": "600,300",
            "snapshot": fixture.snapshotID,
            "foreground": true,
            "modifiers": ["cmd"],
        ]))

        #expect(response.isError)
        let metadata = try #require(response.meta?.objectValue)
        #expect(metadata["state"] == .string("indeterminate"))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["requires_fresh_observation"] == .bool(true))
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
        let hostLease = try await fixture.snapshots.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.snapshots.finishSnapshotMutation(hostLease, requiresFreshObservation: false)
    }

    @Test
    func `raw prelease modifier click cancellation remains canonical cancellation`() async throws {
        let fixture = try await Self.makeFixture()
        await MainActor.run {
            fixture.automation.foregroundModifierClickError = CancellationError()
        }
        let operation = Task {
            try await ClickTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
                "coords": "600,300",
                "snapshot": fixture.snapshotID,
                "foreground": true,
                "modifiers": ["cmd"],
            ]))
        }

        await #expect(throws: CancellationError.self) {
            _ = try await operation.value
        }
        #expect(await MainActor.run { fixture.automation.foregroundModifierClickRequests.isEmpty })
        let adapterLeaseCalls = await MainActor.run {
            (fixture.snapshots.beginCalls, fixture.snapshots.finishCalls)
        }
        #expect(adapterLeaseCalls.0.isEmpty)
        #expect(adapterLeaseCalls.1.isEmpty)
    }

    @Test
    func `pixel focus type rejects ambiguous authority before dispatch`() async throws {
        let fixture = try await Self.makeFixture()
        let invalidArguments: [[String: Any]] = [
            ["coords": "600,300", "text": "hi"],
            ["coords": "600,300", "text": "hi", "snapshot": fixture.snapshotID, "foreground": true],
            ["coords": "600,300", "text": "hi", "snapshot": fixture.snapshotID, "app": "TextEdit"],
            ["coords": "600,300", "text": "hi", "snapshot": fixture.snapshotID, "on": "T1"],
        ]

        for arguments in invalidArguments {
            let response = try await TypeTool(context: fixture.context).execute(
                arguments: ToolArguments(raw: arguments))
            #expect(response.isError)
            #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        }
        #expect(await MainActor.run { fixture.automation.pixelFocusTypeRequests.isEmpty })
    }

    @Test
    func `composed input schemas expose closed coordinate and modifier vocabularies`() async throws {
        let fixture = try await Self.makeFixture()
        let typeProperties = try #require(TypeTool(context: fixture.context).inputSchema
            .objectValue?["properties"]?.objectValue)
        let clickProperties = try #require(ClickTool(context: fixture.context).inputSchema
            .objectValue?["properties"]?.objectValue)

        let coords = try #require(typeProperties["coords"]?.objectValue)
        guard case let .string(coordsDescription)? = coords["description"] else {
            Issue.record("Expected a pixel-focus coordinate description")
            return
        }
        let normalizedCoordsDescription = coordsDescription
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        #expect(normalizedCoordsDescription.contains("focus-only Accessibility targeting"))
        #expect(normalizedCoordsDescription.contains("never clicks, presses, or selects"))
        #expect(typeProperties["coordinate_space"]?.objectValue?["enum"] == .array(
            CaptureCoordinateSpace.allCases.map { .string($0.rawValue) }))
        #expect(clickProperties["modifiers"]?.objectValue?["items"]?.objectValue?["enum"] == .array([
            .string("cmd"), .string("shift"), .string("option"),
        ]))
    }

    private static func makeFixture(
        automation providedAutomation: MockAutomationService? = nil,
        focusedElement: FocusedElementIdentity? = nil) async throws
        -> MCPComposedInputFixture
    {
        await self.uiSnapshots.removeAllSnapshots()
        let fixture = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: SnapshotReferenceFixtures.id(301),
            processIdentity: .init(processIdentifier: 111, processStartIdentity: 7),
            bundleIdentifier: "com.example.composed-input",
            applicationName: "ComposedInput",
            windowID: 42,
            windowTitle: "Composed Input Window",
            bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
            focusedElement: focusedElement)
        let window = fixture.desktopTarget.window
        let snapshot = await self.uiSnapshots.createSnapshot(id: fixture.snapshotID)
        let snapshotID = fixture.snapshotID
        let application = fixture.desktopTarget.application
        await snapshot.setScreenshot(
            path: "/tmp/composed-input.png",
            metadata: CaptureMetadata(
                size: window.bounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: window),
            context: fixture.desktopTarget.windowContext)
        let automation = await MainActor.run {
            providedAutomation ?? MockAutomationService(accessibilityGranted: true)
        }
        let storedSnapshots = try await InMemorySnapshotManager.containing(fixture.detectionResult)
        let snapshots = await MainActor.run {
            SnapshotMutationRecordingManager(wrapping: storedSnapshots)
        }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window),
            snapshots: snapshots,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: .unrestricted)
        return MCPComposedInputFixture(
            context: context,
            automation: automation,
            snapshots: snapshots,
            snapshotID: snapshotID,
            window: window)
    }
}

private struct MCPComposedInputFixture {
    let context: MCPToolContext
    let automation: MockAutomationService
    let snapshots: SnapshotMutationRecordingManager
    let snapshotID: String
    let window: ServiceWindowInfo
}

private enum MCPComposedInputTestError: Error {
    case unknownServiceFailure
}

@MainActor
private final class AlreadyFocusedCancellingModifierClickService: MockAutomationService {
    private(set) var clickAttempted = false

    init() {
        super.init(accessibilityGranted: true)
    }

    override func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: request.windowIdentity,
            bounds: request.windowBounds)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-already-focused-cancel-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, dispatchGuard in
                    do {
                        try dispatchGuard.validate(.setMainWindow)
                    } catch ForegroundModifierClickError.focusTargetSatisfied {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return .confirmedNoChange()
                    }
                    Issue.record("Already-focused target must not dispatch another focus write")
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { exactWindow.identity.processIdentity },
                currentFocusedExactWindow: { exactWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { [weak self] _, _, _ in
                    self?.clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))
        return try await executor.execute(request)
    }
}

@MainActor
private final class PreFocusInputDriftModifierClickService: MockAutomationService {
    private(set) var focusMutationAttempted = false
    private(set) var clickAttempted = false
    private(set) var priorStatePreserved = false

    init() {
        super.init(accessibilityGranted: true)
    }

    override func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let prior = ApplicationProcessIdentity(processIdentifier: 900, processStartIdentity: 9000)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var activity = SharedInputActivityToken.trackedZero
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-prefocus-input-drift-\(UUID().uuidString)",
            isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            self.priorStatePreserved = frontmost == prior && focusedWindow == nil
            try? FileManager.default.removeItem(at: root)
        }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    activity = activity.afterMouseMove()
                    try dispatchGuard.validate(.applicationActivation)
                    self.focusMutationAttempted = true
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { [weak self] _, _, _ in
                    self?.clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                sharedInputActivityToken: { activity }))
        return try await executor.execute(request)
    }
}
