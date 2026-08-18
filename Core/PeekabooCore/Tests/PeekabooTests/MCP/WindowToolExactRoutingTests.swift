import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

struct WindowToolExactRoutingTests {
    @Test
    @MainActor
    func `background window mutation retains exact authorized window through dispatch`() async throws {
        let service = ExactRoutingWindowService()
        let applications = MockApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.fixture",
                name: "Fixture"),
        ])
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "close",
                "app": "PID:42",
                "window_id": 924,
            ]))

        #expect(!response.isError)
        #expect(service.mutationDispatchCount == 1)
        #expect(service.receivedIdentities.first?.ownerProcessStartIdentity == 7)
        let meta = try #require(response.meta?.objectValue)
        guard case let .object(receipt)? = meta["target_receipt"] else {
            Issue.record("Expected exact window mutation target receipt")
            return
        }
        #expect(receipt["pid"] == .int(42))
        #expect(receipt["window_id"] == .int(924))
    }

    @Test(arguments: ["close", "minimize", "restore", "maximize", "move", "resize", "set-bounds"])
    @MainActor
    func `background window mutations refuse ambiguous partial titles before dispatch`(
        action: String) async throws
    {
        let service = ExactRoutingWindowService()
        let first = Self.authorizedFocusWindow(title: "Document Alpha")
        let second = Self.authorizedFocusWindow(id: 925, title: "Document Beta", index: 1, isMain: false)
        service.listHandler = { target, _ in
            switch target {
            case .application:
                [first, second]
            case let .windowId(windowID):
                [first, second].filter { $0.windowID == windowID }
            default:
                []
            }
        }
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)
        var raw = Self.arguments(action: action)
        raw["app"] = "Fixture"
        raw["title"] = "Document"

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: raw))

        #expect(response.isError)
        #expect(service.mutationDispatchCount == 0)
        #expect(service.listTargets.count == 1)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `background window mutation refuses one title match from a partial catalog`() async throws {
        let service = ExactRoutingWindowService()
        service.mutationInventoryWarnings = ["AX enumeration timed out"]
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "close",
                "app": "Fixture",
                "title": "Fixture",
            ]))

        #expect(response.isError)
        #expect(service.mutationDispatchCount == 0)
        #expect(service.listTargets.map(\.description) == ["application(PID:42)"])
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected partial-inventory refusal text")
            return
        }
        #expect(message.contains("incomplete"))
        #expect(message.contains("AX enumeration timed out"))
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `background window mutation refuses a fuzzy application selector before window lookup`() async throws {
        let service = ExactRoutingWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "close",
                "app": "Fixt",
            ]))

        #expect(response.isError)
        #expect(service.mutationDispatchCount == 0)
        #expect(service.listTargets.isEmpty)
        guard case let .text(message, _, _)? = response.content.first else {
            Issue.record("Expected fuzzy-selector refusal text")
            return
        }
        #expect(message.contains("not allowed for mutation"))
    }

    @Test
    @MainActor
    func `background exact window ID remains admissible with legacy partial catalog evidence`() async throws {
        let service = ExactRoutingWindowService()
        service.mutationInventoryWarnings = ["Legacy host omitted completeness metadata"]
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "close",
                "window_id": 924,
            ]))

        #expect(!response.isError)
        #expect(service.mutationDispatchCount == 1)
        #expect(service.closeTargets.map(\.description) == ["windowId(924)"])
        #expect(service.receivedIdentities.map(\.ownerProcessStartIdentity) == [7])
    }

    @Test
    @MainActor
    func `background target revalidation preserves cancellation before dispatch`() async throws {
        let service = ExactRoutingWindowService()
        service.mutationInventoryErrorAtCall = (2, CancellationError())
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        await #expect(throws: CancellationError.self) {
            _ = try await context.execute(
                tool: WindowTool(context: context),
                arguments: ToolArguments(raw: [
                    "action": "close",
                    "app": "Fixture",
                ]))
        }

        #expect(service.mutationDispatchCount == 0)
        #expect(service.closeTargets.isEmpty)

        let followUpCompleted = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    let response = try await context.execute(
                        tool: WindowTool(context: context),
                        arguments: ToolArguments(raw: [
                            "action": "close",
                            "app": "Fixture",
                        ]))
                    return !response.isError
                } catch {
                    return false
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(250))
                return false
            }

            let completed = await group.next() ?? false
            group.cancelAll()
            return completed
        }

        #expect(followUpCompleted)
        #expect(service.mutationDispatchCount == 1)
        #expect(service.closeTargets.map(\.description) == ["windowId(924)"])
    }

    @Test(arguments: ["close", "minimize", "restore", "maximize", "move", "resize", "set-bounds"])
    @MainActor
    func `background window selectors stay pinned across post-authorization inventory reorder`(
        action: String) async throws
    {
        let selectors: [[String: Any]] = [
            [:],
            ["title": "Primary"],
            ["index": 0],
        ]
        for selector in selectors {
            let service = ExactRoutingWindowService()
            let selected = Self.authorizedFocusWindow(title: "Primary Document")
            let sibling = Self.authorizedFocusWindow(id: 925, title: "Sibling", index: 1, isMain: false)
            service.listHandler = { target, call in
                switch target {
                case .application:
                    call == 1 ? [selected, sibling] : [sibling, selected]
                case let .windowId(windowID):
                    [sibling, selected].filter { $0.windowID == windowID }
                default:
                    []
                }
            }
            let context = await MCPToolTestHelpers.makeContext(
                applications: Self.fixtureApplications(),
                windows: service,
                executionPolicy: .backgroundOnly)
            var raw = Self.arguments(action: action)
            raw["app"] = "Fixture"
            raw.merge(selector) { _, replacement in replacement }

            let response = try await context.execute(
                tool: WindowTool(context: context),
                arguments: ToolArguments(raw: raw))

            #expect(!response.isError)
            #expect(service.mutationDispatchCount == 1)
            #expect(service.listTargets.filter {
                if case .application = $0 {
                    return true
                }
                return false
            }.count == 1)
            #expect(service.listTargets.dropFirst().allSatisfy {
                if case let .windowId(windowID) = $0 {
                    return windowID == 924
                }
                return false
            })
            let meta = try #require(response.meta?.objectValue)
            guard case let .object(receipt)? = meta["target_receipt"] else {
                Issue.record("Expected exact target receipt")
                continue
            }
            #expect(receipt["window_id"] == .int(924))
        }
    }

    @Test(arguments: ["close", "minimize", "restore", "maximize", "move", "resize", "set-bounds"])
    @MainActor
    func `background window mutations reject an exact-window flip after authorization`(
        action: String) async throws
    {
        let service = ExactRoutingWindowService()
        service.replacementWindowStartingAtListCall = (
            2,
            ServiceWindowInfo(
                windowID: 924,
                title: "Replacement",
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                mutationIdentity: .init(
                    windowID: 924,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 8,
                    capturedBounds: CGRect(x: 100, y: 100, width: 800, height: 600))))
        let applications = MockApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.fixture",
                name: "Fixture"),
        ])
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            windows: service,
            executionPolicy: .backgroundOnly)
        var raw: [String: Any] = [
            "action": action,
            "app": "PID:42",
            "window_id": 924,
        ]
        if ["move", "set-bounds"].contains(action) {
            raw["x"] = 20
            raw["y"] = 30
        }
        if ["resize", "set-bounds"].contains(action) {
            raw["width"] = 640
            raw["height"] = 480
        }

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: raw))

        #expect(response.isError)
        #expect(service.mutationDispatchCount == 0)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `close pins a broad selector to the listed exact window`() async throws {
        let service = ExactRoutingWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "close",
                "app": "Fixture",
            ]))

        #expect(!response.isError)
        #expect(service.listTargets.map(\.description) == ["application(PID:42)", "windowId(924)"])
        #expect(service.closeTargets.map(\.description) == ["windowId(924)"])
        #expect(service.closeForegroundFallbacks == [false])
        #expect(service.receivedIdentities.map(\.ownerProcessStartIdentity) == [7])
        #expect(service.receivedIdentities.map(\.capturedBounds) == [
            CGRect(x: 100, y: 100, width: 800, height: 600),
        ])
    }

    @Test
    @MainActor
    func `maximize mutates and reads back the same exact window`() async throws {
        let service = ExactRoutingWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "maximize",
                "app": "Fixture",
                "title": "Fixture",
            ]))

        #expect(!response.isError)
        #expect(service.listTargets.map(\.description) == [
            "application(PID:42)",
            "windowId(924)",
            "windowId(924)",
        ])
        #expect(service.maximizeTargets.map(\.description) == ["windowId(924)"])
        #expect(service.receivedIdentities.map(\.ownerProcessStartIdentity) == [7])
        #expect(service.receivedIdentities.map(\.capturedBounds) == [
            CGRect(x: 100, y: 100, width: 800, height: 600),
        ])
    }

    @Test
    @MainActor
    func `restore preserves exact minimized receipt and response formatting`() async throws {
        let service = ExactRoutingWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "restore",
                "app": "PID:42",
                "window_id": 924,
            ]))

        #expect(!response.isError)
        #expect(service.restoreTargets.map(\.description) == ["windowId(924)"])
        #expect(service.receivedIdentities.last?.capturedBounds == CGRect(x: 100, y: 100, width: 800, height: 600))
        #expect(response.content.contains { block in
            guard case let .text(text, _, _) = block else { return false }
            return text.contains("Restored window 'Fixture'")
        })
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
    }

    @Test
    @MainActor
    func `focus projects provider outcome and exact target receipt`() async throws {
        let service = ExactRoutingWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            windows: service,
            executionPolicy: .foregroundAllowed)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "focus",
                "app": "Safari",
            ]))

        #expect(!response.isError)
        #expect(service.focusTargets.map(\.description) == ["windowId(924)"])
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["delivery_mechanism"] == .string("composite"))
        guard case let .object(receipt)? = meta["target_receipt"] else {
            Issue.record("Expected exact focus target receipt")
            return
        }
        #expect(receipt["pid"] == .int(42))
        #expect(receipt["window_id"] == .int(924))
    }

    @Test
    @MainActor
    func `focus accepts a fresh selection matching authorized current`() async throws {
        let service = ExactRoutingWindowService()
        let context = await MCPToolTestHelpers.makeContext(
            windows: service,
            executionPolicy: .backgroundOnly)
        let plan = try AuthorizedDesktopTargetPlan(
            targetIdentity: Self.authorizedFocusTarget(),
            selectedWindow: Self.authorizedFocusWindow())

        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(plan) {
            try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
                "action": "focus",
                "app": "Safari",
            ]))
        }

        #expect(!response.isError)
        #expect(service.focusTargets.map(\.description) == ["windowId(924)"])
        #expect(service.receivedIdentities.map(\.ownerProcessStartIdentity) == [7])
        #expect(service.receivedIdentities.map(\.capturedBounds) == [
            CGRect(x: 100, y: 100, width: 800, height: 600),
        ])
        #expect(service.listTargets.isEmpty)
    }

    @Test(arguments: [924, 925])
    @MainActor
    func `focus rejects post-authorization same-process window or bounds replacement before dispatch`(
        replacementWindowID: Int) async throws
    {
        let replacementBounds = if replacementWindowID == 924 {
            CGRect(x: 140, y: 120, width: 800, height: 600)
        } else {
            CGRect(x: 100, y: 100, width: 800, height: 600)
        }
        let service = ExactRoutingWindowService()
        service.replacementWindowStartingAtListCall = (
            1,
            ServiceWindowInfo(
                windowID: replacementWindowID,
                title: "Replacement",
                bounds: replacementBounds,
                mutationIdentity: .init(
                    windowID: replacementWindowID,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 7,
                    capturedBounds: replacementBounds)))
        let context = await MCPToolTestHelpers.makeContext(
            windows: service,
            executionPolicy: .backgroundOnly)
        let plan = try AuthorizedDesktopTargetPlan(
            targetIdentity: Self.authorizedFocusTarget(),
            selectedWindow: ServiceWindowInfo(
                windowID: replacementWindowID,
                title: "Replacement",
                bounds: replacementBounds,
                mutationIdentity: .init(
                    windowID: replacementWindowID,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 7,
                    capturedBounds: replacementBounds)))

        let response = try await AuthorizedDesktopTargetPlan.$current.withValue(plan) {
            try await WindowTool(context: context).execute(arguments: ToolArguments(raw: [
                "action": "focus",
                "app": "Safari",
            ]))
        }

        #expect(response.isError)
        #expect(service.focusTargets.isEmpty)
        #expect(service.receivedIdentities.isEmpty)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test(arguments: [
        DesktopActionOutcome.refused(reason: .targetUnavailable),
        DesktopActionOutcome.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one),
        DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one),
        DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one),
    ])
    @MainActor
    func `focus rejects provider returned non-success outcome`(outcome: DesktopActionOutcome) async throws {
        let service = ExactRoutingWindowService()
        service.focusOutcome = outcome
        let context = await MCPToolTestHelpers.makeContext(
            windows: service,
            executionPolicy: .foregroundAllowed)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "focus",
                "app": "Safari",
            ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
    }

    @Test
    @MainActor
    func `focus rejects missing provider outcome canonically`() async throws {
        let service = ExactRoutingWindowService()
        service.focusOutcome = nil
        let context = await MCPToolTestHelpers.makeContext(
            windows: service,
            executionPolicy: .foregroundAllowed)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "focus",
                "app": "Safari",
            ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
            .indeterminate(evidence: .completionUnknown),
            in: response)
    }

    @Test(arguments: [true, false])
    @MainActor
    func `focus rejects missing and mismatched provider target`(omitTarget: Bool) async throws {
        let service = ExactRoutingWindowService()
        if omitTarget {
            service.omitFocusTarget = true
        } else {
            service.focusIdentityOverride = WindowMutationIdentity(
                windowID: 925,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        }
        let context = await MCPToolTestHelpers.makeContext(
            windows: service,
            executionPolicy: .foregroundAllowed)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "focus",
                "app": "Safari",
            ]))
        let expected = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
    }

    @Test
    @MainActor
    func `canonical close failure survives the window tool error boundary`() async throws {
        let service = ExactRoutingWindowService()
        let failure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one,
            message: "Window close was only partially applied")
        service.closeFailure = failure
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "close",
                "app": "Fixture",
            ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(failure.outcome, in: response)
    }

    @Test
    @MainActor
    func `restore readback failure preserves dispatched receipt as retry unsafe`() async throws {
        let service = ExactRoutingWindowService()
        service.postMutationReadbackError = UnexpectedWindowCall()
        service.postMutationReadbackStartingAtListCall = 3
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "restore",
                "app": "Fixture",
            ]))

        let expected = DesktopActionOutcome.indeterminate(
            route: .local,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        guard case let .object(receipt)? = response.meta?.objectValue?["target_receipt"] else {
            Issue.record("Expected readback failure target receipt")
            return
        }
        #expect(receipt["window_id"] == .int(924))
        #expect(service.restoreTargets.map(\.description) == ["windowId(924)"])
    }

    @Test
    @MainActor
    func `maximize empty readback preserves dispatched receipt as retry unsafe`() async throws {
        let service = ExactRoutingWindowService()
        service.postMutationReadbackIsEmpty = true
        service.postMutationReadbackStartingAtListCall = 3
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "maximize",
                "app": "Fixture",
            ]))

        let expected = DesktopActionOutcome.indeterminate(
            route: .local,
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        #expect(service.maximizeTargets.map(\.description) == ["windowId(924)"])
    }

    @Test(arguments: ["restore", "maximize"])
    @MainActor
    func `state readback same ID replacement is an attributed post-dispatch failure`(
        action: String) async throws
    {
        let service = ExactRoutingWindowService()
        service.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        service.postMutationReadbackStartingAtListCall = 3
        service.replacementWindowStartingAtListCall = (
            3,
            ServiceWindowInfo(
                windowID: 924,
                title: "Replacement",
                bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
                mutationIdentity: .init(
                    windowID: 924,
                    ownerProcessIdentifier: 42,
                    ownerProcessStartIdentity: 8,
                    capturedBounds: CGRect(x: 100, y: 100, width: 800, height: 600))))
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": action,
                "app": "Fixture",
            ]))

        #expect(response.isError)
        #expect(service.mutationDispatchCount == 1)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        guard case let .object(receipt)? = meta["target_receipt"] else {
            Issue.record("Expected original exact target receipt")
            return
        }
        #expect(receipt["window_id"] == .int(924))
        #expect(receipt["process_start_identity_decimal"] == .string("7"))
    }

    @Test
    @MainActor
    func `missing restore outcome fails before readback with caller target receipt`() async throws {
        let service = ExactRoutingWindowService()
        service.actionOutcome = nil
        service.postMutationReadbackError = UnexpectedWindowCall()
        service.postMutationReadbackStartingAtListCall = 3
        let context = await MCPToolTestHelpers.makeContext(
            applications: Self.fixtureApplications(),
            windows: service,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: WindowTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "restore",
                "app": "Fixture",
            ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
            .indeterminate(evidence: .completionUnknown),
            in: response)
        guard case let .object(receipt)? = response.meta?.objectValue?["target_receipt"] else {
            Issue.record("Expected missing-outcome target receipt")
            return
        }
        #expect(receipt["window_id"] == .int(924))
        #expect(service.restoreTargets.map(\.description) == ["windowId(924)"])
        #expect(service.listTargets.count == 2)
    }

    @MainActor
    private static func fixtureApplications() -> MockApplicationService {
        MockApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 7,
                bundleIdentifier: "com.example.fixture",
                name: "Fixture"),
        ])
    }

    private static func arguments(action: String) -> [String: Any] {
        var raw: [String: Any] = ["action": action]
        if ["move", "set-bounds"].contains(action) {
            raw["x"] = 20
            raw["y"] = 30
        }
        if ["resize", "set-bounds"].contains(action) {
            raw["width"] = 640
            raw["height"] = 480
        }
        return raw
    }

    private static func authorizedFocusTarget() throws -> DesktopTargetIdentity {
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 924,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: bounds),
            bounds: bounds))
    }

    private static func authorizedFocusWindow(
        id: Int = 924,
        title: String = "Fixture",
        index: Int = 0,
        isMain: Bool = true) -> ServiceWindowInfo
    {
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        return ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMainWindow: isMain,
            index: index,
            mutationIdentity: .init(
                windowID: id,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: bounds))
    }
}

private final class ExactRoutingWindowService: WindowManagementActionResultProviding,
    WindowManagementPinnedFocusActionResultProviding,
    WindowMutationInventoryProviding,
    @unchecked Sendable
{
    nonisolated(unsafe) var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .accessibilityValue, mode: .background),
        unitCount: .one)
    nonisolated(unsafe) var focusOutcome: DesktopActionOutcome? = .dispatchedUnverified(
        delivery: .init(mechanism: .composite, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: DesktopActionOutcome.DispatchUnitCount(3))
    nonisolated(unsafe) var omitFocusTarget = false
    nonisolated(unsafe) var focusIdentityOverride: WindowMutationIdentity?
    private let window = ServiceWindowInfo(
        windowID: 924,
        title: "Fixture",
        bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
        mutationIdentity: .init(
            windowID: 924,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 7,
            capturedBounds: CGRect(x: 100, y: 100, width: 800, height: 600)))

    private(set) nonisolated(unsafe) var listTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var closeTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var closeForegroundFallbacks: [Bool] = []
    private(set) nonisolated(unsafe) var minimizeTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var maximizeTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var restoreTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var focusTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var moveTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var resizeTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var setBoundsTargets: [WindowTarget] = []
    private(set) nonisolated(unsafe) var receivedIdentities: [WindowMutationIdentity] = []
    nonisolated(unsafe) var closeFailure: DesktopActionFailure?
    nonisolated(unsafe) var postMutationReadbackError: (any Error)?
    nonisolated(unsafe) var postMutationReadbackIsEmpty = false
    nonisolated(unsafe) var postMutationReadbackStartingAtListCall = 2
    nonisolated(unsafe) var replacementWindowStartingAtListCall: (Int, ServiceWindowInfo)?
    nonisolated(unsafe) var listHandler: ((WindowTarget, Int) -> [ServiceWindowInfo])?
    nonisolated(unsafe) var mutationInventoryWarnings: [String] = []
    nonisolated(unsafe) var mutationInventoryErrorAtCall: (Int, any Error)?
    private(set) nonisolated(unsafe) var mutationInventoryRequestCount = 0
    private(set) nonisolated(unsafe) var mutationDispatchCount = 0

    func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        self.listTargets.append(target)
        if let listHandler {
            return listHandler(target, self.listTargets.count)
        }
        if self.listTargets.count >= self.postMutationReadbackStartingAtListCall {
            if let postMutationReadbackError {
                throw postMutationReadbackError
            }
            if self.postMutationReadbackIsEmpty {
                return []
            }
        }
        if let replacementWindowStartingAtListCall,
           self.listTargets.count >= replacementWindowStartingAtListCall.0
        {
            return [replacementWindowStartingAtListCall.1]
        }
        return [self.window]
    }

    func windowMutationInventory(
        target: WindowTarget) async throws -> DesktopTargetPlanning.Inventory<ServiceWindowInfo>
    {
        self.mutationInventoryRequestCount += 1
        if let (call, error) = self.mutationInventoryErrorAtCall,
           self.mutationInventoryRequestCount == call
        {
            throw error
        }
        let windows = try await self.listWindows(target: target)
        guard !self.mutationInventoryWarnings.isEmpty else { return .complete(windows) }
        return .partial(windows, warnings: self.mutationInventoryWarnings)
    }

    func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        self.closeTargets.append(target)
        self.closeForegroundFallbacks.append(allowForegroundFallback)
    }

    func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        self.receivedIdentities.append(expectedIdentity)
        try await self.closeWindow(target: target, allowForegroundFallback: allowForegroundFallback)
    }

    func focusWindow(target: WindowTarget) async throws {
        self.focusTargets.append(target)
    }

    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        throw UnexpectedWindowCall()
    }

    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> UIAutomationActionResult<Void>
    {
        self.focusTargets.append(target)
        self.receivedIdentities.append(expectedIdentity)
        guard let identity = self.window.mutationIdentity,
              identity.hasSameStableReceipt(as: expectedIdentity)
        else {
            throw PeekabooError.commandFailed("Focus fixture lacks an exact identity")
        }
        let resultIdentity = self.focusIdentityOverride ?? identity
        guard let resultBounds = resultIdentity.capturedBounds else {
            throw PeekabooError.commandFailed("Focus fixture result lacks bounds")
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.focusOutcome,
            targetIdentity: self.omitFocusTarget ? nil : DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: resultIdentity,
                    bounds: resultBounds)))
    }

    func maximizeWindow(target: WindowTarget) async throws {
        self.maximizeTargets.append(target)
    }

    func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.receivedIdentities.append(expectedIdentity)
        try await self.maximizeWindow(target: target)
    }

    func minimizeWindow(target: WindowTarget) async throws {
        self.minimizeTargets.append(target)
    }

    func restoreWindow(target: WindowTarget) async throws {
        self.restoreTargets.append(target)
    }

    func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        self.receivedIdentities.append(expectedIdentity)
        try await self.restoreWindow(target: target)
    }

    func moveWindow(target: WindowTarget, to _: CGPoint) async throws {
        self.moveTargets.append(target)
    }

    func resizeWindow(target: WindowTarget, to _: CGSize) async throws {
        self.resizeTargets.append(target)
    }

    func setWindowBounds(target: WindowTarget, bounds _: CGRect) async throws {
        self.setBoundsTargets.append(target)
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }

    func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        if let closeFailure {
            throw closeFailure
        }
        try await self.closeWindow(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        self.receivedIdentities.append(expectedIdentity)
        try await self.minimizeWindow(target: target)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        try await self.restoreWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        try await self.maximizeWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        self.receivedIdentities.append(expectedIdentity)
        try await self.moveWindow(target: target, to: position)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        self.receivedIdentities.append(expectedIdentity)
        try await self.resizeWindow(target: target, to: size)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async throws -> DesktopActionResult<Void>
    {
        self.mutationDispatchCount += 1
        self.receivedIdentities.append(expectedIdentity)
        try await self.setWindowBounds(target: target, bounds: bounds)
        return DesktopActionResult(outcome: self.actionOutcome)
    }
}

private struct UnexpectedWindowCall: Error {}
