import CoreGraphics
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

struct MCPInteractionTargetTests {
    @MainActor
    @Test
    func `background app target retains its discovered process generation`() async throws {
        let expected = ApplicationProcessIdentity(processIdentifier: 4242, processStartIdentity: 71)
        let applications = MockApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: expected.processIdentifier,
            processStartIdentity: expected.processStartIdentity,
            bundleIdentifier: "com.example.editor",
            name: "Editor")])
        let context = await MCPToolTestHelpers.makeContext(applications: applications)
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: nil,
            windowIndex: nil,
            windowID: nil))

        let identity = try await target.requireBackgroundProcessIdentity(
            applications: context.applications,
            windows: context.windows)

        #expect(identity == expected)
    }

    @MainActor
    @Test
    func `background app target refuses missing process generation`() async throws {
        let applications = MockApplicationService(applications: [ServiceApplicationInfo(
            processIdentifier: 4242,
            bundleIdentifier: "com.example.editor",
            name: "Editor")])
        let context = await MCPToolTestHelpers.makeContext(applications: applications)
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: nil,
            windowIndex: nil,
            windowID: nil))

        await #expect(throws: MCPInteractionTargetError.targetProcessIdentityUnavailable) {
            _ = try await target.requireBackgroundProcessIdentity(
                applications: context.applications,
                windows: context.windows)
        }
    }

    @MainActor
    @Test
    func `background keyboard window adapter enforces complete immutable receipts`() async throws {
        let processIdentity = AutomationTestFixtures.processIdentity(
            processIdentifier: 4242,
            processStartIdentity: 71)
        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let applications = MockApplicationService(applications: [AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "com.example.editor",
            name: "Editor")])
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: nil,
            windowIndex: nil,
            windowID: 42))
        let malformedWindows = [
            Self.window(
                windowID: 42,
                processIdentity: processIdentity,
                bounds: bounds,
                capturedBounds: nil),
            Self.window(
                windowID: 42,
                processIdentity: processIdentity,
                bounds: bounds,
                capturedBounds: bounds.offsetBy(dx: 1, dy: 0)),
            Self.window(
                windowID: 0,
                processIdentity: processIdentity,
                bounds: bounds,
                capturedBounds: bounds),
            Self.window(
                windowID: Int(UInt32.max) + 1,
                processIdentity: processIdentity,
                bounds: bounds,
                capturedBounds: bounds),
        ]

        for window in malformedWindows {
            if window.windowID == 42 {
                await #expect(throws: MCPInteractionTargetError.backgroundWindowTargetMismatch) {
                    _ = try await target.requireBackgroundKeyboardTarget(
                        applications: applications,
                        windows: ReceiptWindowService(window: window))
                }
            } else {
                await #expect(throws: MCPInteractionTargetError.backgroundWindowTargetAmbiguous) {
                    _ = try await target.requireBackgroundKeyboardTarget(
                        applications: applications,
                        windows: ReceiptWindowService(window: window))
                }
            }
        }

        let valid = Self.window(
            windowID: 42,
            processIdentity: processIdentity,
            bounds: bounds,
            capturedBounds: bounds)
        let resolved = try await target.requireBackgroundKeyboardTarget(
            applications: applications,
            windows: ReceiptWindowService(window: valid))
        #expect(resolved.exactWindow?.identity == valid.mutationIdentity)
        #expect(resolved.exactWindow?.bounds == bounds)
    }

    @MainActor
    @Test
    func `background keyboard window adapter preserves missing and ambiguous selector errors`() async throws {
        let processIdentity = AutomationTestFixtures.processIdentity(
            processIdentifier: 4242,
            processStartIdentity: 71)
        let applications = MockApplicationService(applications: [AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "com.example.editor",
            name: "Editor")])
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: "Document",
            windowIndex: nil,
            windowID: nil))

        await #expect(throws: MCPInteractionTargetError.backgroundWindowTargetAmbiguous) {
            _ = try await target.requireBackgroundKeyboardTarget(
                applications: applications,
                windows: EmptyRecordingWindowService())
        }

        let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)
        let first = Self.window(
            windowID: 42,
            processIdentity: processIdentity,
            bounds: bounds,
            capturedBounds: bounds)
        let second = Self.window(
            windowID: 43,
            processIdentity: processIdentity,
            bounds: bounds.offsetBy(dx: 700, dy: 0),
            capturedBounds: bounds.offsetBy(dx: 700, dy: 0))
        await #expect(throws: MCPInteractionTargetError.backgroundWindowTargetAmbiguous) {
            _ = try await target.requireBackgroundKeyboardTarget(
                applications: applications,
                windows: ReceiptWindowService(window: first, additionalWindow: second))
        }
    }

    @MainActor
    @Test
    func `MCP background keyboard refuses fuzzy application selectors`() async throws {
        let applications = MockApplicationService(applications: [AutomationTestFixtures.application(
            processIdentifier: 4242,
            processStartIdentity: 71,
            bundleIdentifier: "com.example.editor",
            name: "Editor",
            isHiddenKnown: true,
            activationPolicy: .regular)])
        let target = try Self.makeTarget(Selectors(
            app: "Edit",
            pid: nil,
            windowTitle: nil,
            windowIndex: nil,
            windowID: nil))

        do {
            _ = try await target.requireBackgroundKeyboardTarget(
                applications: applications,
                windows: EmptyRecordingWindowService())
            Issue.record("Expected fuzzy background target planning to fail")
        } catch let error as MCPInteractionTargetError {
            #expect(error.refusalReason == .targetUnavailable)
            #expect(error.localizedDescription.contains("not allowed for mutation"))
        }
    }

    @MainActor
    @Test
    func `MCP background keyboard refuses one title match from a partial catalog`() async throws {
        let processIdentity = AutomationTestFixtures.processIdentity(
            processIdentifier: 4242,
            processStartIdentity: 71)
        let applications = MockApplicationService(applications: [AutomationTestFixtures.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "com.example.editor",
            name: "Editor",
            isHiddenKnown: true,
            activationPolicy: .regular)])
        let window = Self.window(
            windowID: 42,
            processIdentity: processIdentity,
            bounds: CGRect(x: 10, y: 20, width: 640, height: 480),
            capturedBounds: CGRect(x: 10, y: 20, width: 640, height: 480))
        let target = try Self.makeTarget(Selectors(
            app: "Editor",
            pid: nil,
            windowTitle: "Document",
            windowIndex: nil,
            windowID: nil))

        do {
            _ = try await target.requireBackgroundKeyboardTarget(
                applications: applications,
                windows: ReceiptWindowService(
                    window: window,
                    inventoryWarnings: ["AX enumeration timed out"]))
            Issue.record("Expected partial window inventory to fail")
        } catch let error as MCPInteractionTargetError {
            #expect(error.refusalReason == .targetUnavailable)
            #expect(error.localizedDescription.contains("incomplete"))
            #expect(error.localizedDescription.contains("AX enumeration timed out"))
        }
    }

    @MainActor
    @Test
    func `legacy nil focus outcome refuses before foreground typing`() async throws {
        try await self.expectForegroundTypingRefusal(
            outcome: nil,
            expectedState: .indeterminate,
            expectedRoute: .local)
    }

    @MainActor
    @Test
    func `current suspected no-op focus refuses before foreground typing`() async throws {
        try await self.expectForegroundTypingRefusal(
            outcome: .suspectedNoop(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one),
            expectedState: .suspectedNoop,
            expectedRoute: .local)
    }

    @MainActor
    @Test
    func `remote suspected no-op focus retains bridge route and exact target`() async throws {
        try await self.expectForegroundTypingRefusal(
            outcome: .suspectedNoop(
                route: .bridge,
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                unitCount: .one),
            expectedState: .suspectedNoop,
            expectedRoute: .bridge)
    }

    @Test
    func `focus composition drops an incompatible leaf target`() throws {
        let service = MCPFocusResultWindowService()
        let bounds = try #require(service.identity.capturedBounds)
        let targetIdentity = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: service.identity,
            bounds: bounds))
        let focus = MCPInteractionFocusResult(
            target: .windowId(service.identity.windowID),
            actionResult: UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                    unitCount: .one),
                targetIdentity: targetIdentity))
        let leaf = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Leaf selected another process")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 999,
                processStartIdentity: 1))

        let composed = focus.preservingFailure(leaf, operation: "Focused leaf")

        #expect(composed.outcome.state == .indeterminate)
        #expect(composed.targetReceipt == nil)
    }

    @Test
    func `focus combination matches canonical coalesced sequence semantics`() throws {
        let service = MCPFocusResultWindowService()
        let bounds = try #require(service.identity.capturedBounds)
        let focusTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: service.identity,
            bounds: bounds))
        let processTarget = try DesktopTargetIdentity(processIdentity: focusTarget.processIdentity)
        let focusOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let leafOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one)
        let focus = MCPInteractionFocusResult(
            target: .windowId(service.identity.windowID),
            actionResult: UIAutomationActionResult(
                payload: (),
                outcome: focusOutcome,
                targetIdentity: focusTarget))
        let leaf = UIAutomationActionResult(
            payload: "done",
            outcome: leafOutcome,
            targetIdentity: processTarget)

        let result = try focus.combining(leaf, operation: "Focused leaf")
        var canonical = UIAutomationActionResultSequenceAccumulator(
            targetProjectionPolicy: .coalescedIdentity)
        canonical.record(
            outcome: focusOutcome,
            targetIdentity: focusTarget,
            attribution: .sequenceTarget,
            defaultDispatchedUnitCount: .one)
        canonical.record(
            outcome: leafOutcome,
            targetIdentity: processTarget,
            attribution: .operationTarget,
            defaultDispatchedUnitCount: .one)
        let canonicalResult = try canonical.result(
            payload: "done",
            operation: "Focused leaf",
            requiresOutcome: true,
            requiresCompatibleTarget: true)

        #expect(result.outcome == canonicalResult.outcome)
        #expect(result.targetIdentity == canonicalResult.targetIdentity)
        #expect(result.targetIdentity == focusTarget)
    }

    @Test
    func `focus cancellation after dispatch remains retry unsafe and exact`() throws {
        let service = MCPFocusResultWindowService()
        let bounds = try #require(service.identity.capturedBounds)
        let focusTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: service.identity,
            bounds: bounds))
        let focus = MCPInteractionFocusResult(
            target: .windowId(service.identity.windowID),
            actionResult: UIAutomationActionResult(
                payload: (),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: focusTarget))

        let failure = focus.preservingFailure(CancellationError(), operation: "Focused leaf")

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(failure.targetReceipt == focusTarget.actionTargetReceipt)
    }

    @Test
    func `focus and completed leaf target mismatch retains both dispatched units`() throws {
        let service = MCPFocusResultWindowService()
        let bounds = try #require(service.identity.capturedBounds)
        let focusTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: service.identity,
            bounds: bounds))
        let focus = MCPInteractionFocusResult(
            target: .windowId(service.identity.windowID),
            actionResult: UIAutomationActionResult(
                payload: (),
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                    unitCount: .one),
                targetIdentity: focusTarget))
        let otherIdentity = WindowMutationIdentity(
            windowID: 701,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1,
            capturedBounds: bounds)
        let leaf = try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: otherIdentity,
                bounds: bounds)))

        do {
            _ = try focus.combining(leaf, operation: "Focused leaf")
            Issue.record("Expected the completed leaf target mismatch to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
            #expect(failure.targetReceipt == nil)
        }
    }

    enum InvalidConsumerFixture: CaseIterable, Sendable {
        case applicationAndPID
        case windowIDAndTitle
        case titleWithoutOwner
        case indexWithoutOwner

        var arguments: [String: Any] {
            switch self {
            case .applicationAndPID:
                ["app": "Preview", "pid": 42]
            case .windowIDAndTitle:
                ["app": "Preview", "window_id": 7, "window_title": "Main"]
            case .titleWithoutOwner:
                ["window_title": "Main"]
            case .indexWithoutOwner:
                ["window_index": 2]
            }
        }

        var message: String {
            switch self {
            case .applicationAndPID:
                "app and pid are mutually exclusive"
            case .windowIDAndTitle:
                "window_id, window_title, and window_index are mutually exclusive"
            case .titleWithoutOwner, .indexWithoutOwner:
                "require app or pid"
            }
        }
    }

    struct Selectors: Sendable {
        let app: String?
        let pid: Int?
        let windowTitle: String?
        let windowIndex: Int?
        let windowID: Int?
    }

    @Test(arguments: InteractionTargetSelectorFixtures.validCases)
    func `valid selector combinations construct`(_ selectors: InteractionTargetSelectorCase) throws {
        _ = try Self.makeTarget(selectors)
    }

    @Test(arguments: InteractionTargetSelectorFixtures.applicationAndProcessIdentifierCases)
    func `app and pid fail closed during construction`(_ selectors: InteractionTargetSelectorCase) {
        #expect(throws: MCPInteractionTargetError.applicationAndProcessIdentifier) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.multipleWindowSelectorCases)
    func `multiple window selectors fail closed during construction`(_ selectors: InteractionTargetSelectorCase) {
        #expect(throws: MCPInteractionTargetError.multipleWindowSelectors) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.windowSelectorRequiresApplicationCases)
    func `relative window selectors require an owner during construction`(_ selectors: InteractionTargetSelectorCase) {
        #expect(throws: MCPInteractionTargetError.windowSelectorRequiresApp) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test
    func `PID prefixed app and explicit pid remain mutually exclusive`() {
        #expect(throws: MCPInteractionTargetError.applicationAndProcessIdentifier) {
            _ = try Self.makeTarget(Selectors(
                app: "PID:42",
                pid: 42,
                windowTitle: nil,
                windowIndex: nil,
                windowID: nil))
        }
    }

    @Test(arguments: [
        Selectors(app: nil, pid: 0, windowTitle: nil, windowIndex: nil, windowID: nil),
        Selectors(app: nil, pid: Int(Int32.max) + 1, windowTitle: nil, windowIndex: nil, windowID: nil),
    ])
    func `invalid process identifiers fail during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.invalidProcessIdentifier) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test(arguments: [
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: nil, windowID: 0),
        Selectors(app: nil, pid: nil, windowTitle: nil, windowIndex: nil, windowID: Int(UInt32.max) + 1),
    ])
    func `invalid window identifiers fail during construction`(_ selectors: Selectors) {
        #expect(throws: MCPInteractionTargetError.invalidWindowId) {
            _ = try Self.makeTarget(selectors)
        }
    }

    @Test
    func `negative window index fails during construction`() {
        #expect(throws: MCPInteractionTargetError.invalidWindowIndex) {
            _ = try Self.makeTarget(Selectors(
                app: "Preview",
                pid: nil,
                windowTitle: nil,
                windowIndex: -1,
                windowID: nil))
        }
    }

    @Test
    func `valid title target retains its owner`() throws {
        let target = try Self.makeTarget(Selectors(
            app: "Preview",
            pid: nil,
            windowTitle: "Main",
            windowIndex: nil,
            windowID: nil))

        switch try target.toWindowTarget() {
        case let .applicationAndTitle(app, title):
            #expect(app == "Preview")
            #expect(title == "Main")
        default:
            Issue.record("Expected application title target")
        }
    }

    @MainActor
    @Test(arguments: InvalidConsumerFixture.allCases)
    func `all MCP interaction consumers reject invalid selectors before execution`(
        fixture: InvalidConsumerFixture) async throws
    {
        let context = await MCPToolTestHelpers.makeContext()
        let arguments = fixture.arguments
        let responses = try await [
            TypeTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "text": "hello",
            ]) { current, _ in current })),
            PressTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "keys": ["cmd+c"],
            ]) { current, _ in current })),
            PasteTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "text": "hello",
            ]) { current, _ in current })),
            DialogTool(context: context).execute(arguments: ToolArguments(raw: arguments.merging([
                "action": "list",
            ]) { current, _ in current })),
        ]

        for response in responses {
            #expect(response.isError)
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected selector validation error")
                continue
            }
            #expect(text.contains(fixture.message))
        }
        for response in responses.prefix(3) {
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
                .refused(reason: .invalidRequest),
                in: response)
        }
    }

    @MainActor
    @Test
    func `foreground interaction consumers refuse ambiguous partial window titles before dispatch`() async throws {
        let windows = AmbiguousForegroundWindowService()
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            clipboard: AmbiguousFocusClipboardService())
        let selector: [String: Any] = [
            "app": "Editor",
            "window_title": "Document",
            "foreground": true,
        ]

        let responses = try await [
            TypeTool(context: context).execute(arguments: ToolArguments(raw: selector.merging([
                "text": "hello",
            ]) { current, _ in current })),
            PressTool(context: context).execute(arguments: ToolArguments(raw: selector.merging([
                "keys": ["cmd+c"],
            ]) { current, _ in current })),
            PasteTool(context: context).execute(arguments: ToolArguments(raw: selector.merging([
                "text": "hello",
                "restore_delay_ms": 0,
            ]) { current, _ in current })),
            DialogTool(context: context).execute(arguments: ToolArguments(raw: selector.merging([
                "action": "click",
                "button": "OK",
            ]) { current, _ in current })),
        ]

        for response in responses {
            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
                .refused(reason: .targetUnavailable),
                in: response)
        }
        #expect(windows.focusCalls == 0)
        #expect(automation.lastTypeActions == nil)
        #expect(automation.lastHotkeyKeys == nil)
    }

    private static func makeTarget(_ selectors: Selectors) throws -> MCPInteractionTarget {
        try MCPInteractionTarget(
            app: selectors.app,
            pid: selectors.pid,
            windowTitle: selectors.windowTitle,
            windowIndex: selectors.windowIndex,
            windowId: selectors.windowID)
    }

    private static func makeTarget(_ selectors: InteractionTargetSelectorCase) throws -> MCPInteractionTarget {
        try self.makeTarget(Selectors(
            app: selectors.hasApplication ? "Preview" : nil,
            pid: selectors.hasProcessIdentifier ? 42 : nil,
            windowTitle: selectors.hasWindowTitle ? "Main" : nil,
            windowIndex: selectors.hasWindowIndex ? 2 : nil,
            windowID: selectors.hasWindowID ? 7 : nil))
    }

    private static func window(
        windowID: Int,
        processIdentity: ApplicationProcessIdentity,
        bounds: CGRect,
        capturedBounds: CGRect?) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: windowID,
            title: "Document",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: processIdentity.processIdentifier,
                ownerProcessStartIdentity: processIdentity.processStartIdentity,
                capturedBounds: capturedBounds))
    }

    @MainActor
    private func expectForegroundTypingRefusal(
        outcome: DesktopActionOutcome?,
        expectedState: DesktopActionOutcome.State,
        expectedRoute: DesktopActionOutcome.Route) async throws
    {
        let automation = MockAutomationService(accessibilityGranted: true)
        let windows = MCPFocusResultWindowService(outcome: outcome)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "app": "Editor",
            "foreground": true,
            "text": "must not type",
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string(expectedState.rawValue))
        #expect(response.meta?.objectValue?["route"] == .string(expectedRoute.rawValue))
        #expect(response.meta?.objectValue?["target_receipt"]?.objectValue?["window_id"] == .int(700))
        #expect(automation.lastTypeActions == nil)
        #expect(windows.focusCalls == 1)
    }
}

@MainActor
private final class AmbiguousFocusClipboardService: ClipboardServiceProtocol {
    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        nil
    }

    func set(_: ClipboardWriteRequest) throws -> ClipboardReadResult {
        throw ClipboardServiceError.writeFailed("Ambiguous focus must fail before clipboard mutation")
    }

    func clear() {}
    func save(slot _: String) throws {}

    func restore(slot: String) throws -> ClipboardReadResult {
        throw ClipboardServiceError.slotNotFound(slot)
    }
}

private final class AmbiguousForegroundWindowService: WindowManagementPinnedFocusActionResultProviding,
    @unchecked Sendable
{
    private(set) nonisolated(unsafe) var focusCalls = 0

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        [
            Self.window(id: 701, index: 0),
            Self.window(id: 702, index: 1),
        ]
    }

    func focusWindow(target _: WindowTarget) async throws {
        self.focusCalls += 1
    }

    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        self.focusCalls += 1
        throw PeekabooError.commandFailed("Ambiguous focus must not dispatch")
    }

    func focusWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        self.focusCalls += 1
        throw PeekabooError.commandFailed("Ambiguous focus must not dispatch")
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func restoreWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    private static func window(id: Int, index: Int) -> ServiceWindowInfo {
        let bounds = CGRect(x: index * 20, y: index * 20, width: 640, height: 480)
        return ServiceWindowInfo(
            windowID: id,
            title: "Document \(index)",
            bounds: bounds,
            index: index,
            mutationIdentity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: 89,
                ownerProcessStartIdentity: 890,
                capturedBounds: bounds))
    }
}

final class MCPFocusResultWindowService: WindowManagementPinnedFocusActionResultProviding, @unchecked Sendable {
    let identity = WindowMutationIdentity(
        windowID: 700,
        ownerProcessIdentifier: 89,
        ownerProcessStartIdentity: 890,
        capturedBounds: CGRect(x: 20, y: 30, width: 640, height: 480))
    nonisolated(unsafe) var outcome: DesktopActionOutcome?
    private(set) nonisolated(unsafe) var focusCalls = 0

    init(outcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
        unitCount: .one))
    {
        self.outcome = outcome
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        [ServiceWindowInfo(
            windowID: self.identity.windowID,
            title: "Editor",
            bounds: self.identity.capturedBounds ?? .zero,
            mutationIdentity: self.identity)]
    }

    func focusWindow(target _: WindowTarget) async throws {
        throw PeekabooError.commandFailed("Legacy void focus must not be used")
    }

    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.commandFailed("Unpinned focus must not be used")
    }

    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        self.focusCalls += 1
        guard case let .windowId(windowID) = target,
              windowID == self.identity.windowID,
              expectedIdentity.hasSameStableReceipt(as: self.identity),
              let bounds = self.identity.capturedBounds
        else {
            throw PeekabooError.commandFailed("Unexpected exact focus target")
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: self.identity,
                bounds: bounds)))
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func restoreWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private actor ReceiptWindowService: WindowManagementServiceProtocol, WindowMutationInventoryProviding {
    let window: ServiceWindowInfo
    let additionalWindow: ServiceWindowInfo?
    let inventoryWarnings: [String]

    init(
        window: ServiceWindowInfo,
        additionalWindow: ServiceWindowInfo? = nil,
        inventoryWarnings: [String] = [])
    {
        self.window = window
        self.additionalWindow = additionalWindow
        self.inventoryWarnings = inventoryWarnings
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        [self.window, self.additionalWindow].compactMap(\.self)
    }

    func windowMutationInventory(
        target _: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        let windows = [self.window, self.additionalWindow].compactMap(\.self)
        if self.inventoryWarnings.isEmpty {
            return .complete(windows)
        }
        return .partial(windows, warnings: self.inventoryWarnings)
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
