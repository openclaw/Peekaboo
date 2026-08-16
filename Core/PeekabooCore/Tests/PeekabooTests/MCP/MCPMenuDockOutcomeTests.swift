import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
@Suite(.serialized)
struct MCPMenuDockOutcomeTests {
    @Test
    func `background menu click carries the authorized process generation into the dispatch leaf`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 844, processStartIdentity: 100)
        let applications = MenuGenerationApplicationService(generations: [100, 100, 100])
        let menu = GenerationPinnedMenuService()
        let context = await Self.makeContext(
            menu: menu,
            applications: applications,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: MenuTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "app": "Fixture",
                "path": "File > Save",
            ]))

        #expect(!response.isError)
        #expect(menu.requests.count == 1)
        #expect(menu.requests.first?.expectedIdentity == identity)
        #expect(menu.requests.first?.appIdentifier == "PID:844")
        #expect(menu.requests.first?.deliveryMode == .background)
        let projection = try #require(
            MCPToolResponseMetadataProjector.actionOutcomeResolution(from: response.meta).projection)
        #expect(projection.deliveryMode == .background)
        #expect(menu.legacyResultCallCount == 0)
    }

    @Test
    func `background menu click refuses a process generation flip before service dispatch`() async throws {
        let applications = MenuGenerationApplicationService(generations: [100, 100, 101])
        let menu = GenerationPinnedMenuService()
        let context = await Self.makeContext(
            menu: menu,
            applications: applications,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: MenuTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "app": "Fixture",
                "path": "File > Save",
            ]))

        #expect(response.isError)
        #expect(menu.requests.isEmpty)
        #expect(menu.legacyResultCallCount == 0)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("target_unavailable"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    func `foreground focus success plus menu refusal preserves focus mutation`() async throws {
        let windows = ForegroundMenuWindowService()
        windows.focusOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let menu = ResultMenuService()
        menu.failure = .preDispatchRefusal(
            reason: .permissionDenied,
            message: "Menu AXPress refused")
        let context = await Self.makeContext(menu: menu, windows: windows)
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "click",
            "app": "Fixture",
            "path": "File > Save",
            "foreground": true,
        ]))

        let expected = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(response.meta?.objectValue?["target_receipt"]?.objectValue?["window_id"] == .int(924))
        #expect(windows.focusCalls == 1)
        #expect(menu.pathResultCalls == 1)
    }

    @Test(arguments: [ForegroundMenuFailure.generic, .cancellation])
    func `foreground focus preserves mutation across menu errors`(failure: ForegroundMenuFailure) async throws {
        let windows = ForegroundMenuWindowService()
        windows.focusOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let menu = ResultMenuService()
        menu.genericFailure = failure.error
        let context = await Self.makeContext(menu: menu, windows: windows)

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "click",
            "app": "Fixture",
            "item": "Save",
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("indeterminate"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(response.meta?.objectValue?["dispatched_unit_count"] == .int(1))
        #expect(response.meta?.objectValue?["target_receipt"]?.objectValue?["window_id"] == .int(924))
        #expect(windows.focusCalls == 1)
        #expect(menu.nameResultCalls == 1)
    }

    @Test
    func `foreground focus refusal dispatches no menu action`() async throws {
        let windows = ForegroundMenuWindowService()
        windows.focusFailure = .preDispatchRefusal(
            reason: .permissionDenied,
            message: "Focus refused")
        let menu = ResultMenuService()
        let context = await Self.makeContext(menu: menu, windows: windows)

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "click",
            "app": "Fixture",
            "path": "File > Save",
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("refused"))
        #expect(response.meta?.objectValue?["dispatch_state"] == .string("none"))
        #expect(windows.focusCalls == 1)
        #expect(menu.pathResultCalls == 0)
        #expect(menu.nameResultCalls == 0)
    }

    @Test
    func `foreground menu refuses a legacy focus service before dispatch`() async throws {
        let windows = EmptyRecordingWindowService()
        let menu = ResultMenuService()
        let context = await Self.makeContext(menu: menu, windows: windows)

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "click",
            "app": "Fixture",
            "path": "File > Save",
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("refused"))
        #expect(response.meta?.objectValue?["refusal_reason"] == .string("runtime_incompatible"))
        #expect(response.meta?.objectValue?["dispatch_state"] == .string("none"))
        #expect(await windows.focusRequests.isEmpty)
        #expect(menu.pathResultCalls == 0)
    }

    @Test
    func `foreground menu list reports focus outcome and exact target`() async throws {
        let windows = ForegroundMenuWindowService()
        windows.focusOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let menu = ResultMenuService()
        menu.menuStructure = Self.menuStructure()
        let context = await Self.makeContext(menu: menu, windows: windows)
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "list",
            "app": "Fixture",
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("confirmed_change"))
        #expect(response.meta?.objectValue?["delivery_mechanism"] == .string("native_framework"))
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(response.meta?.objectValue?["target_receipt"]?.objectValue?["window_id"] == .int(924))
        #expect(windows.focusCalls == 1)
        #expect(menu.listCalls == 1)
    }

    @Test
    func `foreground focus and menu success aggregate mixed mechanisms and exact units`() async throws {
        let windows = ForegroundMenuWindowService()
        windows.focusOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let menu = ResultMenuService()
        menu.outcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(3))
        menu.targetIdentity = try DesktopTargetIdentity(processIdentity: windows.identity.processIdentity)
        let context = await Self.makeContext(menu: menu, windows: windows)

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "click",
            "app": "Fixture",
            "path": "File > Save",
            "foreground": true,
        ]))

        #expect(!response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("confirmed_change"))
        #expect(response.meta?.objectValue?["delivery_mechanism"] == .string("composite"))
        #expect(response.meta?.objectValue?["delivery_mode"] == .string("foreground"))
        #expect(response.meta?.objectValue?["dispatched_unit_count"] == .int(5))
        #expect(response.meta?.objectValue?["target_identity"]?.objectValue?["kind"] == .string("window"))
        #expect(response.meta?.objectValue?["target_receipt"]?.objectValue?["window_id"] == .int(924))
    }

    @Test
    func `menu result adapters preserve real action outcomes and process targets`() async throws {
        let service = ResultMenuService()
        service.targetIdentity = try Self.processTarget()
        let context = await Self.makeContext(menu: service)
        let tool = MenuTool(context: context)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        service.outcome = outcome
        let requests: [[String: Any]] = [
            ["action": "click", "app": "TextEdit", "path": "File > Save"],
            ["action": "click", "app": "TextEdit", "item": "Save"],
        ]

        for request in requests {
            let response = try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: request))

            #expect(!response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
            #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
            #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
            try Self.expectProcessTarget(in: response)
        }
        #expect(service.pathResultCalls == 1)
        #expect(service.nameResultCalls == 1)
        #expect(service.legacyMutationCalls == 0)
    }

    @Test
    func `menu named result adapter refuses missing outcome`() async throws {
        let service = ResultMenuService()
        service.outcome = nil
        service.targetIdentity = try Self.processTarget()
        let context = await Self.makeContext(menu: service)

        let response = try await context.execute(
            tool: MenuTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "app": "TextEdit",
                "item": "Save",
            ]))

        let expected = DesktopActionOutcome.indeterminate(evidence: .completionUnknown)
        #expect(response.isError)
        #expect(service.nameResultCalls == 1)
        #expect(service.legacyMutationCalls == 0)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        try Self.expectProcessReceipt(in: response)
    }

    @Test
    func `targetless Bridge menu result is rejected as indeterminate`() async throws {
        let service = ResultMenuService()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        service.outcome = outcome
        let context = await Self.makeContext(menu: service)

        let response = try await context.execute(
            tool: MenuTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "app": "TextEdit",
                "path": "File > Save",
            ]))

        let meta = try #require(response.meta?.objectValue)
        #expect(response.isError)
        let expected = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: .one)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["target_identity"] == nil)
        try Self.expectProcessReceipt(in: response)
    }

    @Test
    func `menu preserves a targetless pre-dispatch refusal`() async throws {
        let service = ResultMenuService()
        let outcome = DesktopActionOutcome.refused(
            route: .bridge,
            reason: .targetUnavailable)
        service.outcome = outcome
        let context = await Self.makeContext(menu: service)

        let response = try await context.execute(
            tool: MenuTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "app": "TextEdit",
                "path": "File > Save",
            ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        #expect(response.meta?.objectValue?["target_identity"] == nil)
        #expect(response.meta?.objectValue?["target_receipt"] == nil)
    }

    @Test
    func `menu preserves thrown DesktopActionFailure metadata`() async throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73)
        let failure = DesktopActionFailure.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Menu delivery was accepted but not verified")
            .attributed(to: receipt)
        let service = ResultMenuService()
        service.failure = failure
        let context = await Self.makeContext(menu: service)

        let response = try await context.execute(
            tool: MenuTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "click",
                "app": "TextEdit",
                "path": "File > Save",
            ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: response)
        let target = try #require(response.meta?.objectValue?["target_receipt"]?.objectValue)
        #expect(target["pid"] == .int(42))
        #expect(target["process_start_identity_decimal"] == .string("9007199254740993"))
        #expect(target["window_id"] == .int(73))
    }

    @Test
    func `Dock targeted mutations preserve their distinct contracts and process targets`() async throws {
        let service = ResultDockService()
        service.targetIdentity = try Self.processTarget()
        let context = await Self.makeContext(dock: service)
        let tool = DockTool(context: context)
        let cases: [(request: [String: Any], outcome: DesktopActionOutcome)] = [
            (
                ["action": "launch", "app": "Finder", "foreground": true],
                .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one)),
            (
                ["action": "right-click", "app": "Finder", "select": "Options", "foreground": true],
                .dispatchedUnverified(
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: DesktopActionOutcome.DispatchUnitCount(2))),
        ]

        for testCase in cases {
            service.outcome = testCase.outcome
            let response = try await tool.execute(arguments: ToolArguments(raw: testCase.request))
            #expect(!response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(testCase.outcome, in: response)
            #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
            #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
            try Self.expectProcessTarget(in: response)
        }

        #expect(service.resultCalls == ["launch", "right-click"])
        #expect(service.legacyMutationCalls == 0)
    }

    @Test
    func `Dock visibility preserves native background two-unit results`() async throws {
        let service = ResultDockService()
        let outcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        service.outcome = outcome
        let context = await Self.makeContext(dock: service)
        let tool = DockTool(context: context)

        for action in ["hide", "show"] {
            let response = try await tool.execute(arguments: ToolArguments(raw: ["action": action]))
            #expect(!response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
            #expect(response.meta?.objectValue?["target_identity"] == nil)
            #expect(response.meta?.objectValue?["target_receipt"] == nil)
        }

        #expect(service.resultCalls == ["hide", "show"])
        #expect(service.legacyMutationCalls == 0)
    }

    @Test
    func `Dock visibility accepts honest unverified background dispatch`() async throws {
        let service = ResultDockService()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        service.outcome = outcome
        let context = await Self.makeContext(dock: service)

        let response = try await DockTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "hide",
        ]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
    }

    @Test
    func `Dock zero result reports verified no change`() async throws {
        let service = ResultDockService()
        let outcome = DesktopActionOutcome.confirmedNoChange(route: .bridge)
        service.outcome = outcome
        let context = await Self.makeContext(dock: service)

        let response = try await DockTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "hide",
        ]))

        #expect(!response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
    }

    @Test
    func `Dock rejects targetless Bridge launch and context results`() async throws {
        let service = ResultDockService()
        let context = await Self.makeContext(dock: service)
        let tool = DockTool(context: context)
        let cases: [(request: [String: Any], delivery: DesktopActionOutcome.Delivery, units: Int)] = [
            (
                ["action": "launch", "app": "Finder", "foreground": true],
                .init(mechanism: .accessibilityAction, mode: .foreground),
                1),
            (
                ["action": "right-click", "app": "Finder", "select": "Options", "foreground": true],
                .init(mechanism: .composite, mode: .foreground),
                2),
        ]

        for testCase in cases {
            let units = try #require(DesktopActionOutcome.DispatchUnitCount(testCase.units))
            service.outcome = .dispatchedUnverified(
                route: .bridge,
                delivery: testCase.delivery,
                evidence: .deliveryAccepted,
                unitCount: units)

            let response = try await tool.execute(arguments: ToolArguments(raw: testCase.request))
            let expected = DesktopActionOutcome.indeterminate(
                route: .bridge,
                delivery: testCase.delivery,
                evidence: .completionUnknown,
                unitCount: units)
            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
            #expect(response.meta?.objectValue?["target_identity"] == nil)
        }
    }

    private static func makeContext(
        menu: (any MenuServiceProtocol)? = nil,
        dock: (any DockServiceProtocol)? = nil,
        windows: (any WindowManagementServiceProtocol)? = nil,
        applications: (any ApplicationServiceProtocol)? = nil,
        executionPolicy: MCPToolExecutionPolicy? = nil) async -> MCPToolContext
    {
        let base = await MCPToolTestHelpers.makeContext(windows: windows)
        let resolvedApplications: any ApplicationServiceProtocol = if let applications {
            applications
        } else if menu is ResultMenuService {
            MenuGenerationApplicationService(
                generations: [9_007_199_254_740_993],
                processIdentifier: 42)
        } else {
            base.applications
        }
        return MCPToolContext(
            automation: base.automation,
            menu: menu ?? base.menu,
            windows: windows ?? base.windows,
            applications: resolvedApplications,
            dialogs: base.dialogs,
            dock: dock ?? base.dock,
            screenCapture: base.screenCapture,
            desktopObservation: base.desktopObservation,
            snapshots: base.snapshots,
            screens: base.screens,
            agent: base.agent,
            permissions: base.permissions,
            clipboard: base.clipboard,
            browser: base.browser,
            permissionsStatusProvider: base.permissionsStatusProvider,
            snapshotExecutionGate: base.snapshotExecutionGate,
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: executionPolicy ?? base.executionPolicy)
    }

    private static func menuStructure() -> MenuStructure {
        MenuStructure(
            application: ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"),
            menus: [Menu(title: "File", items: [MenuItem(title: "Save", path: "File > Save")])])
    }

    private static func processTarget() throws -> DesktopTargetIdentity {
        try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993))
    }

    private static func expectProcessTarget(in response: ToolResponse) throws {
        let target = try #require(response.meta?.objectValue?["target_identity"]?.objectValue)
        #expect(target["kind"] == .string("process"))
        #expect(target["pid"] == .int(42))
        #expect(target["process_start_identity_decimal"] == .string("9007199254740993"))
        #expect(target["window_id"] == nil)
        try self.expectProcessReceipt(in: response)
    }

    private static func expectProcessReceipt(in response: ToolResponse) throws {
        let receipt = try #require(response.meta?.objectValue?["target_receipt"]?.objectValue)
        #expect(receipt["pid"] == .int(42))
        #expect(receipt["process_start_identity_decimal"] == .string("9007199254740993"))
        #expect(receipt["window_id"] == nil)
    }
}

enum ForegroundMenuFailure: CaseIterable, Sendable {
    case generic
    case cancellation

    var error: any Error {
        switch self {
        case .generic: PeekabooError.operationError(message: "Injected menu error")
        case .cancellation: CancellationError()
        }
    }
}

private final class ForegroundMenuWindowService: WindowManagementPinnedFocusActionResultProviding,
    @unchecked Sendable
{
    let identity = WindowMutationIdentity(
        windowID: 924,
        ownerProcessIdentifier: 42,
        ownerProcessStartIdentity: 7,
        capturedBounds: CGRect(x: 100, y: 100, width: 800, height: 600))
    nonisolated(unsafe) var focusOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
        unitCount: .one)
    nonisolated(unsafe) var focusFailure: DesktopActionFailure?
    private(set) nonisolated(unsafe) var focusCalls = 0

    private var window: ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: self.identity.windowID,
            title: "Fixture",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            mutationIdentity: self.identity)
    }

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        [self.window]
    }

    func focusWindow(target _: WindowTarget) async throws {
        throw ForegroundMenuWindowError.unexpectedLegacyFocus
    }

    func focusWindowActionResult(target _: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        throw ForegroundMenuWindowError.unexpectedLegacyFocus
    }

    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        self.focusCalls += 1
        if let focusFailure {
            throw focusFailure.attributed(to: DesktopActionTargetReceipt(
                processIdentifier: expectedIdentity.ownerProcessIdentifier,
                processStartIdentity: expectedIdentity.ownerProcessStartIdentity,
                windowID: expectedIdentity.windowID))
        }
        guard case let .windowId(windowID) = target,
              windowID == self.identity.windowID,
              expectedIdentity.hasSameStableReceipt(as: self.identity),
              let bounds = self.identity.capturedBounds
        else {
            throw PeekabooError.commandFailed("Unexpected foreground focus target")
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.focusOutcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: self.identity,
                bounds: bounds)))
    }

    func closeWindow(target _: WindowTarget) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func restoreWindow(target _: WindowTarget) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        throw ForegroundMenuWindowError.unexpectedMutation
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        self.window
    }
}

private enum ForegroundMenuWindowError: Error {
    case unexpectedLegacyFocus
    case unexpectedMutation
}

@MainActor
private final class MenuGenerationApplicationService: StubApplicationService {
    private let generations: [UInt64]
    private let processIdentifier: Int32
    private var readIndex = 0

    init(generations: [UInt64], processIdentifier: Int32 = 844) {
        self.generations = generations
        self.processIdentifier = processIdentifier
        super.init()
    }

    override func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let generation = self.generations[min(self.readIndex, self.generations.count - 1)]
        self.readIndex += 1
        return ServiceApplicationInfo(
            processIdentifier: self.processIdentifier,
            processStartIdentity: generation,
            bundleIdentifier: "dev.peekaboo.menu-generation-fixture",
            name: identifier)
    }
}

@MainActor
private final class GenerationPinnedMenuService: MenuServiceGenerationPinnedActionResultProviding {
    private(set) var requests: [MenuItemActionRequest] = []
    private(set) var legacyResultCallCount = 0

    func clickMenuItemActionResult(request: MenuItemActionRequest) throws -> UIAutomationActionResult<Void> {
        self.requests.append(request)
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: request.deliveryMode),
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(processIdentity: request.expectedIdentity))
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) throws
        -> UIAutomationActionResult<Void>
    {
        try self.requests.append(MenuItemActionRequest(
            appIdentifier: request.appIdentifier,
            itemPath: request.itemName,
            expectedIdentity: request.expectedIdentity,
            deliveryMode: request.deliveryMode))
        return try UIAutomationActionResult(
            payload: (),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: request.deliveryMode),
                unitCount: .one),
            targetIdentity: DesktopTargetIdentity(processIdentity: request.expectedIdentity))
    }

    func clickMenuItemActionResult(app _: String, itemPath _: String) -> UIAutomationActionResult<Void> {
        self.legacyResultCallCount += 1
        return UIAutomationActionResult(payload: (), outcome: nil, targetIdentity: nil)
    }

    func clickMenuItemByNameActionResult(app _: String, itemName _: String) -> UIAutomationActionResult<Void> {
        self.legacyResultCallCount += 1
        return UIAutomationActionResult(payload: (), outcome: nil, targetIdentity: nil)
    }

    func clickMenuExtraActionResult(title _: String) -> UIAutomationActionResult<Void> {
        UIAutomationActionResult(payload: (), outcome: nil, targetIdentity: nil)
    }

    func clickMenuBarItemActionResult(named name: String) -> UIAutomationActionResult<ClickResult> {
        UIAutomationActionResult(
            payload: ClickResult(elementDescription: name, location: nil),
            outcome: nil,
            targetIdentity: nil)
    }

    func clickMenuBarItemActionResult(at index: Int) -> UIAutomationActionResult<ClickResult> {
        UIAutomationActionResult(
            payload: ClickResult(elementDescription: String(index), location: nil),
            outcome: nil,
            targetIdentity: nil)
    }

    func listMenus(for _: String) throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func listFrontmostMenus() throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuItem(app _: String, itemPath _: String) {}
    func clickMenuItemByName(app _: String, itemName _: String) {}
    func clickMenuExtra(title _: String) {}
    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) -> CGRect? {
        nil
    }

    func listMenuExtras() -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) -> ClickResult {
        ClickResult(elementDescription: name, location: nil)
    }

    func clickMenuBarItem(at index: Int) -> ClickResult {
        ClickResult(elementDescription: String(index), location: nil)
    }
}

@MainActor
private final class ResultMenuService: MenuServiceGenerationPinnedActionResultProviding {
    var outcome: DesktopActionOutcome?
    var targetIdentity: DesktopTargetIdentity?
    var failure: DesktopActionFailure?
    var genericFailure: (any Error)?
    var menuStructure: MenuStructure?
    var pathResultCalls = 0
    var nameResultCalls = 0
    var listCalls = 0
    var legacyMutationCalls = 0

    func clickMenuItemActionResult(
        app _: String,
        itemPath _: String) throws -> UIAutomationActionResult<Void>
    {
        self.pathResultCalls += 1
        if let failure {
            throw failure
        }
        if let genericFailure {
            throw genericFailure
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func clickMenuItemByNameActionResult(
        app _: String,
        itemName _: String) throws -> UIAutomationActionResult<Void>
    {
        self.nameResultCalls += 1
        if let failure {
            throw failure
        }
        if let genericFailure {
            throw genericFailure
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) throws -> UIAutomationActionResult<Void> {
        try self.clickMenuItemActionResult(
            app: request.appIdentifier,
            itemPath: request.itemPath)
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) throws
        -> UIAutomationActionResult<Void>
    {
        try self.clickMenuItemByNameActionResult(
            app: request.appIdentifier,
            itemName: request.itemName)
    }

    func clickMenuExtraActionResult(title _: String) throws -> UIAutomationActionResult<Void> {
        if let failure {
            throw failure
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func clickMenuBarItemActionResult(named name: String) throws -> UIAutomationActionResult<ClickResult> {
        if let failure {
            throw failure
        }
        return UIAutomationActionResult(
            payload: ClickResult(elementDescription: name, location: nil),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func clickMenuBarItemActionResult(at index: Int) throws -> UIAutomationActionResult<ClickResult> {
        if let failure {
            throw failure
        }
        return UIAutomationActionResult(
            payload: ClickResult(elementDescription: String(index), location: nil),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func listMenus(for _: String) throws -> MenuStructure {
        self.listCalls += 1
        if let genericFailure {
            throw genericFailure
        }
        guard let menuStructure else {
            throw PeekabooError.notImplemented("stub")
        }
        return menuStructure
    }

    func listFrontmostMenus() throws -> MenuStructure {
        throw PeekabooError.notImplemented("stub")
    }

    func clickMenuItem(app _: String, itemPath _: String) {
        self.legacyMutationCalls += 1
    }

    func clickMenuItemByName(app _: String, itemName _: String) {
        self.legacyMutationCalls += 1
    }

    func clickMenuExtra(title _: String) {
        self.legacyMutationCalls += 1
    }

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) -> CGRect? {
        nil
    }

    func listMenuExtras() -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) -> ClickResult {
        self.legacyMutationCalls += 1
        return ClickResult(elementDescription: name, location: nil)
    }

    func clickMenuBarItem(at index: Int) -> ClickResult {
        self.legacyMutationCalls += 1
        return ClickResult(elementDescription: String(index), location: nil)
    }
}

@MainActor
private final class ResultDockService: DockServiceActionResultProviding {
    var outcome: DesktopActionOutcome?
    var targetIdentity: DesktopTargetIdentity?
    var resultCalls = [String]()
    var legacyMutationCalls = 0

    func launchFromDockActionResult(appName _: String) -> UIAutomationActionResult<Void> {
        self.resultCalls.append("launch")
        return UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func rightClickDockItemActionResult(
        appName _: String,
        menuItem _: String?) -> UIAutomationActionResult<Void>
    {
        self.resultCalls.append("right-click")
        return UIAutomationActionResult(
            payload: (),
            outcome: self.outcome,
            targetIdentity: self.targetIdentity)
    }

    func hideDockActionResult() -> DesktopActionResult<Void> {
        self.resultCalls.append("hide")
        return DesktopActionResult(outcome: self.outcome)
    }

    func showDockActionResult() -> DesktopActionResult<Void> {
        self.resultCalls.append("show")
        return DesktopActionResult(outcome: self.outcome)
    }

    func listDockItems(includeAll _: Bool) -> [DockItem] {
        []
    }

    func launchFromDock(appName _: String) {
        self.legacyMutationCalls += 1
    }

    func addToDock(path _: String, persistent _: Bool) {}

    func removeFromDock(appName _: String) {}

    func rightClickDockItem(appName _: String, menuItem _: String?) {
        self.legacyMutationCalls += 1
    }

    func hideDock() {
        self.legacyMutationCalls += 1
    }

    func showDock() {
        self.legacyMutationCalls += 1
    }

    func isDockAutoHidden() -> Bool {
        false
    }

    func findDockItem(name _: String) throws -> DockItem {
        throw PeekabooError.notImplemented("stub")
    }
}
