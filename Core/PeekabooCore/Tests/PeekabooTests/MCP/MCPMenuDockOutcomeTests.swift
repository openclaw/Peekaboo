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

    @Test(arguments: ["fuzzy", "different"])
    func `background menu click validates selector against retained authority`(_ scenario: String) async throws {
        let authorizedIdentity = ApplicationProcessIdentity(
            processIdentifier: 844,
            processStartIdentity: 100)
        let requestedPID: Int32 = scenario == "different" ? 845 : 844
        let requestedGeneration: UInt64 = scenario == "different" ? 200 : 100
        let requestedName = scenario == "different" ? "Other" : "Fixture"
        let selector = scenario == "different" ? requestedName : "Fixt"
        let applications = MenuGenerationApplicationService(
            generations: [requestedGeneration, requestedGeneration],
            processIdentifier: requestedPID,
            applicationName: requestedName)
        let menu = GenerationPinnedMenuService()
        let context = await Self.makeContext(
            menu: menu,
            applications: applications,
            executionPolicy: .backgroundOnly)
        let authority = try AuthorizedDesktopTargetPlan(
            targetIdentity: DesktopTargetIdentity(processIdentity: authorizedIdentity))

        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(authority) {
            try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
                "action": "click",
                "app": selector,
                "path": "File > Save",
            ]))
        }

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("refused"))
        #expect(response.meta?.objectValue?["dispatch_state"] == .string("none"))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(true))
        #expect(menu.requests.isEmpty)
    }

    @Test
    func `foreground menu click validates selector against retained authority before focus`() async throws {
        let windows = ForegroundMenuWindowService()
        let menu = ResultMenuService()
        let applications = MenuGenerationApplicationService(
            generations: [7, 7, 7],
            processIdentifier: 42)
        let context = await Self.makeContext(
            menu: menu,
            windows: windows,
            applications: applications,
            executionPolicy: .backgroundOnly)
        let authority = try AuthorizedDesktopTargetPlan(
            targetIdentity: DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
                processIdentifier: 43,
                processStartIdentity: 8)))

        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(authority) {
            try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
                "action": "click",
                "app": "Fixture",
                "path": "File > Save",
                "foreground": true,
            ]))
        }

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("refused"))
        #expect(response.meta?.objectValue?["dispatch_state"] == .string("none"))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(true))
        #expect(windows.focusCalls == 0)
        #expect(menu.pathRequests.isEmpty)
    }

    @Test
    func `foreground menu click retains an authorized exact window`() async throws {
        let windows = ForegroundMenuWindowService()
        let menu = ResultMenuService()
        menu.outcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one)
        menu.targetIdentity = try DesktopTargetIdentity(processIdentity: windows.identity.processIdentity)
        let context = await Self.makeContext(
            menu: menu,
            windows: windows,
            executionPolicy: .backgroundOnly)
        let bounds = try #require(windows.identity.capturedBounds)
        let authority = try AuthorizedDesktopTargetPlan(
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: windows.identity,
                bounds: bounds)),
            selectedWindow: ServiceWindowInfo(
                windowID: windows.identity.windowID,
                title: "Fixture",
                bounds: bounds,
                mutationIdentity: windows.identity))

        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(authority) {
            try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
                "action": "click",
                "app": "Fixture",
                "path": "File > Save",
                "foreground": true,
            ]))
        }

        #expect(!response.isError)
        #expect(windows.focusCalls == 1)
        #expect(menu.pathRequests.count == 1)
        let inventoryTarget = try #require(windows.inventoryTargets.first)
        guard case let .windowId(windowID) = inventoryTarget else {
            Issue.record("Expected the retained exact window inventory target")
            return
        }
        #expect(windowID == windows.identity.windowID)
    }

    @Test(arguments: ["path", "item"])
    func `foreground menu click keeps the planned process generation`(_ selection: String) async throws {
        let windows = ForegroundMenuWindowService()
        let menu = ResultMenuService()
        menu.outcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one)
        menu.targetIdentity = try DesktopTargetIdentity(processIdentity: windows.identity.processIdentity)
        let context = await Self.makeContext(menu: menu, windows: windows)
        var arguments: [String: Any] = [
            "action": "click",
            "app": "Fixture",
            "foreground": true,
        ]
        arguments[selection] = selection == "path" ? "File > Save" : "Save"

        let response = try await MenuTool(context: context).execute(
            arguments: ToolArguments(raw: arguments))

        #expect(!response.isError)
        #expect(windows.focusCalls == 1)
        #expect(menu.legacyResultCalls == 0)
        let inventoryTarget = try #require(windows.inventoryTargets.first)
        guard case let .application(identifier) = inventoryTarget else {
            Issue.record("Expected a process-pinned window inventory")
            return
        }
        #expect(identifier == "PID:42")
        if selection == "path" {
            let request = try #require(menu.pathRequests.first)
            #expect(request.appIdentifier == "PID:42")
            #expect(request.expectedIdentity == windows.identity.processIdentity)
            #expect(request.deliveryMode == .foreground)
        } else {
            let request = try #require(menu.nameRequests.first)
            #expect(request.appIdentifier == "PID:42")
            #expect(request.expectedIdentity == windows.identity.processIdentity)
            #expect(request.deliveryMode == .foreground)
        }
    }

    @Test(arguments: ["missing", "both"])
    func `foreground menu click validates one selector before focus`(_ shape: String) async throws {
        let windows = ForegroundMenuWindowService()
        let menu = ResultMenuService()
        let context = await Self.makeContext(menu: menu, windows: windows)
        var arguments: [String: Any] = [
            "action": "click",
            "app": "Fixture",
            "foreground": true,
        ]
        if shape == "both" {
            arguments["path"] = "File > Save"
            arguments["item"] = "Save"
        }

        let response = try await MenuTool(context: context).execute(
            arguments: ToolArguments(raw: arguments))

        #expect(response.isError)
        #expect(windows.inventoryTargets.isEmpty)
        #expect(windows.focusCalls == 0)
        #expect(menu.pathRequests.isEmpty)
        #expect(menu.nameRequests.isEmpty)
    }

    @Test
    func `foreground menu click refuses a legacy menu service before focus`() async throws {
        let windows = ForegroundMenuWindowService()
        let menu = LegacyForegroundMenuService()
        let applications = MenuGenerationApplicationService(
            generations: [7, 7, 7],
            processIdentifier: 42)
        let context = await Self.makeContext(
            menu: menu,
            windows: windows,
            applications: applications)

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
        #expect(windows.focusCalls == 0)
        #expect(menu.legacyMutationCalls == 0)
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
        #expect(menu.listIdentifiers == ["PID:42"])
    }

    @Test
    func `foreground menu list discards a replacement generation and preserves focus mutation`() async throws {
        let windows = ForegroundMenuWindowService()
        windows.focusOutcome = .confirmedChange(
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one)
        let menu = ResultMenuService()
        menu.menuStructure = MenuStructure(
            application: ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 8,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Replacement"),
            menus: [Menu(title: "Replacement", items: [])])
        let context = await Self.makeContext(menu: menu, windows: windows)

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "list",
            "app": "Fixture",
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("indeterminate"))
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(true))
        #expect(response.meta?.objectValue?["retry_safe"] == .bool(false))
        #expect(response.meta?.objectValue?["dispatched_unit_count"] == .int(1))
        #expect(response.meta?.objectValue?["target_receipt"]?.objectValue?["window_id"] == .int(924))
        #expect(windows.focusCalls == 1)
        #expect(menu.listIdentifiers == ["PID:42"])
    }

    @Test
    func `foreground menu list refuses a fuzzy selector before focus or listing`() async throws {
        let windows = ForegroundMenuWindowService()
        let menu = ResultMenuService()
        menu.menuStructure = Self.menuStructure()
        let applications = MenuGenerationApplicationService(
            generations: [7, 7, 7],
            processIdentifier: 42)
        let context = await Self.makeContext(
            menu: menu,
            windows: windows,
            applications: applications)

        let response = try await MenuTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "list",
            "app": "Fixt",
            "foreground": true,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["state"] == .string("refused"))
        #expect(response.meta?.objectValue?["dispatch_state"] == .string("none"))
        #expect(windows.focusCalls == 0)
        #expect(menu.listCalls == 0)
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
                generations: windows is ForegroundMenuWindowService
                    ? [7, 7, 7]
                    : [9_007_199_254_740_993, 9_007_199_254_740_993, 9_007_199_254_740_993],
                processIdentifier: 42,
                applicationName: windows is ForegroundMenuWindowService ? "Fixture" : "TextEdit")
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
            executionPolicy: executionPolicy ?? (windows == nil ? base.executionPolicy : .foregroundAllowed))
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
    WindowMutationInventoryProviding,
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
    private(set) nonisolated(unsafe) var inventoryTargets: [WindowTarget] = []

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

    func windowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        self.inventoryTargets.append(target)
        return .complete([self.window])
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
private final class MenuGenerationApplicationService: StubApplicationService,
    ApplicationMutationInventoryProviding
{
    private let generations: [UInt64]
    private let processIdentifier: Int32
    private let applicationName: String
    private var readIndex = 0

    init(
        generations: [UInt64],
        processIdentifier: Int32 = 844,
        applicationName: String = "Fixture")
    {
        self.generations = generations
        self.processIdentifier = processIdentifier
        self.applicationName = applicationName
        super.init()
    }

    override func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.nextApplication(identifier: identifier)
    }

    func applicationMutationInventory() async throws
        -> DesktopTargetPlanning.Inventory<ServiceApplicationInfo>
    {
        .complete([self.nextApplication(identifier: "Fixture")])
    }

    private func nextApplication(identifier _: String) -> ServiceApplicationInfo {
        let generation = self.generations[min(self.readIndex, self.generations.count - 1)]
        self.readIndex += 1
        return ServiceApplicationInfo(
            processIdentifier: self.processIdentifier,
            processStartIdentity: generation,
            bundleIdentifier: "dev.peekaboo.menu-generation-fixture",
            name: self.applicationName)
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
private final class LegacyForegroundMenuService: MenuServiceProtocol {
    private(set) var legacyMutationCalls = 0

    func listMenus(for _: String) throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func listFrontmostMenus() throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuItem(app _: String, itemPath _: String) {
        self.legacyMutationCalls += 1
    }

    func clickMenuItemByName(app _: String, itemName _: String) {
        self.legacyMutationCalls += 1
    }

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
    var legacyResultCalls = 0
    var pathRequests: [MenuItemActionRequest] = []
    var nameRequests: [MenuItemByNameActionRequest] = []
    var listIdentifiers: [String] = []

    func clickMenuItemActionResult(
        app _: String,
        itemPath _: String) throws -> UIAutomationActionResult<Void>
    {
        self.pathResultCalls += 1
        self.legacyResultCalls += 1
        return try self.menuActionResult()
    }

    func clickMenuItemByNameActionResult(
        app _: String,
        itemName _: String) throws -> UIAutomationActionResult<Void>
    {
        self.nameResultCalls += 1
        self.legacyResultCalls += 1
        return try self.menuActionResult()
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) throws -> UIAutomationActionResult<Void> {
        self.pathResultCalls += 1
        self.pathRequests.append(request)
        return try self.menuActionResult()
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) throws
        -> UIAutomationActionResult<Void>
    {
        self.nameResultCalls += 1
        self.nameRequests.append(request)
        return try self.menuActionResult()
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

    func listMenus(for identifier: String) throws -> MenuStructure {
        self.listCalls += 1
        self.listIdentifiers.append(identifier)
        if let genericFailure {
            throw genericFailure
        }
        guard let menuStructure else {
            throw PeekabooError.notImplemented("stub")
        }
        return menuStructure
    }

    private func menuActionResult() throws -> UIAutomationActionResult<Void> {
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
