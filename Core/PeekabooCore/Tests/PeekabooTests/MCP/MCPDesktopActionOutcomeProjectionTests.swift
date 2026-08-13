import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPDesktopActionOutcomeProjectionTests {
    @Test
    func `canonical projection drives the complete seven state MCP matrix`() throws {
        let expectations: [ProjectionExpectation] = [
            .init(state: .confirmedChange, dispatched: true, retrySafe: false, fresh: false, escalation: .none),
            .init(state: .confirmedNoChange, dispatched: false, retrySafe: false, fresh: false, escalation: .none),
            .init(state: .partial, dispatched: true, retrySafe: false, fresh: false, escalation: .recoverSideEffect),
            .init(
                state: .dispatchedUnverified,
                dispatched: true,
                retrySafe: false,
                fresh: true,
                escalation: .observeBeforeRetry),
            .init(state: .suspectedNoop, dispatched: true, retrySafe: true, fresh: false, escalation: .refreshTarget),
            .init(state: .refused, dispatched: false, retrySafe: true, fresh: false, escalation: .grantPermission),
            .init(
                state: .indeterminate,
                dispatched: true,
                retrySafe: false,
                fresh: true,
                escalation: .observeBeforeRetry),
        ]

        for (outcome, expectation) in zip(BridgeTestFixtures.canonicalActionOutcomes, expectations) {
            let fields = try MCPToolResponseMetadataProjector.fields(for: outcome.projection)

            #expect(fields["state"] == .string(expectation.state.rawValue))
            #expect(fields["mutation_dispatched"] == .bool(expectation.dispatched))
            #expect(fields["retry_safe"] == .bool(expectation.retrySafe))
            #expect(fields["requires_fresh_observation"] == .bool(expectation.fresh))
            #expect(fields["escalation"] == .string(expectation.escalation.rawValue))

            let external = MCPToolResponseMetadataProjector.externalFields(
                from: .object(fields.merging(["untrusted": .string("drop")]) { current, _ in current }),
                toolName: "click")
            let agent = MCPToolResponseMetadataProjector.agentFields(
                from: .object(fields.merging(["untrusted": .string("drop")]) { current, _ in current }))
            #expect(external == fields)
            #expect(agent == fields)
        }
    }

    @Test
    func `partial failure stays dispatched without demanding fresh observation`() throws {
        let twoUnits = try #require(DesktopActionOutcome.DispatchUnitCount(rawValue: 2))
        let failure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: twoUnits,
            message: "Primary change completed but cleanup failed",
            hint: "Recover the remaining side effect.")

        let response = try MCPToolResponseMetadataProjector.errorResponse(
            for: failure,
            invalidatedSnapshotID: "snapshot-1")
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected canonical partial failure metadata")
            return
        }
        #expect(meta["state"] == .string("partial"))
        #expect(meta["effect"] == .string("partial"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["escalation"] == .string("recover_side_effect"))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["invalidated_snapshot"] == .string("snapshot-1"))

        let wireResult = PeekabooMCPServer.callToolResult(from: response, toolName: "click")
        let wireData = try JSONEncoder().encode(wireResult)
        let wireJSON = try #require(JSONSerialization.jsonObject(with: wireData) as? [String: Any])
        let wireMeta = try #require(wireJSON["_meta"] as? [String: Any])
        #expect(wireMeta["state"] as? String == "partial")
        #expect(wireMeta["escalation"] as? String == "recover_side_effect")
        #expect(wireMeta["mutation_dispatched"] as? Bool == true)
        #expect(wireMeta["retry_safe"] as? Bool == false)
        #expect(wireMeta["requires_fresh_observation"] as? Bool == false)
    }

    @Test
    func `pre-dispatch refusal merges presentation metadata around canonical fields`() throws {
        let response = MCPToolResponseMetadataProjector.preDispatchRefusalResponse(
            message: "Invalid numeric argument",
            reason: .invalidRequest,
            additionalFields: [
                "error_code": .string("VALIDATION_ERROR"),
                "retry_safe": .bool(false),
            ])
        let meta = try #require(response.meta?.objectValue)

        #expect(meta["error_code"] == .string("VALIDATION_ERROR"))
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("invalid_request"))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(false))
    }

    @Test
    @MainActor
    func `action tool projects every native outcome state without inferring from invalidation`() async throws {
        let automation = StubAutomationService()
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        for outcome in BridgeTestFixtures.canonicalActionOutcomes {
            automation.actionOutcome = outcome
            let response = try await ActionTool(context: context).execute(arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXPress",
                "snapshot": snapshotID,
            ]))

            try Self.expect(outcome: outcome, in: response)
            guard case let .object(meta) = response.meta else { continue }
            #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        }
    }

    @Test
    @MainActor
    func `all outcome backed mutation tools publish the canonical native projection`() async throws {
        let automation = StubAutomationService()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        automation.actionOutcome = outcome
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let responses = try await [
            ActionTool(context: context).execute(arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXPress",
                "snapshot": snapshotID,
            ])),
            SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
                "on": "T1",
                "value": "hello",
                "snapshot": snapshotID,
            ])),
            ClickTool(context: context).execute(arguments: ToolArguments(raw: [
                "coords": "10,20",
                "foreground": true,
            ])),
            TypeTool(context: context).execute(arguments: ToolArguments(raw: [
                "text": "hello",
                "foreground": true,
            ])),
            ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
                "direction": "down",
                "foreground": true,
            ])),
            PressTool(context: context).execute(arguments: ToolArguments(raw: [
                "keys": ["cmd+a"],
                "foreground": true,
            ])),
        ]

        for response in responses {
            try Self.expect(outcome: outcome, in: response)
        }
    }

    @Test
    @MainActor
    func `legacy mutation service does not receive fabricated outcome metadata`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        _ = await context.uiSnapshots.createSnapshot()

        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "foreground": true,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        for key in [
            "state",
            "effect",
            "evidence",
            "dispatch_state",
            "mutation_dispatched",
            "retry_safety",
            "retry_safe",
            "requires_fresh_observation",
        ] {
            #expect(meta[key] == nil)
        }
        #expect(meta["invalidated_snapshot"] != nil)
    }

    @Test
    @MainActor
    func `multi chord success preserves legacy safety metadata without inventing a canonical state`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["total_presses"] == .int(2))
        #expect(meta["state"] == nil)
        #expect(meta["effect"] == .string("unverifiable"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    func `multi chord leaf failure preserves cumulative canonical partial semantics`() throws {
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(1),
            message: "Second chord completed but cleanup failed")
        let aggregate = PressTool.aggregateSequenceFailure(
            leafFailure,
            completedPresses: 1,
            setupFocusCompleted: false)
        let response = try MCPToolResponseMetadataProjector.errorResponse(
            for: aggregate,
            invalidatedSnapshotID: nil)

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("partial"))
        #expect(meta["effect"] == .string("partial"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(false))
    }

    @Test
    func `press includes completed target focus before first chord refusal`() {
        let leafFailure = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Hotkey was refused")

        let aggregate = PressTool.aggregateSequenceFailure(
            leafFailure,
            completedPresses: 0,
            setupFocusCompleted: true)

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.delivery == nil)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(aggregate.outcome.retrySafety == .unsafe)
        #expect(aggregate.outcome.escalation == .observeBeforeRetry)
    }

    @Test
    @MainActor
    func `type refuses to discard an unconfirmed native focus outcome`() async throws {
        let automation = StubAutomationService()
        let outcome = DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        automation.actionOutcome = outcome
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/focus-outcome.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 777,
                    processStartIdentity: 77,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))
        await snapshot.setUIElements([
            UIElement(
                id: "T1",
                elementId: "T1",
                role: "textField",
                title: nil,
                label: "Editor",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "text field",
                identifier: nil,
                frame: CGRect(x: 10, y: 10, width: 100, height: 30),
                isActionable: true),
        ])

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(response.isError)
        try Self.expect(outcome: outcome, in: response)
        #expect(automation.lastProcessTargetedTypeIdentity == nil)
    }

    @Test
    @MainActor
    func `type aggregates a confirmed focus click with a native typing failure`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        automation.targetedTypeError = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Typing was refused")
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    func `type conservatively counts a receiptless completed focus before refusal`() {
        let leafFailure = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Typing was refused")

        let aggregate = TypeTool.aggregateTypingFailure(
            leafFailure,
            after: TypeFocusResult(completed: true, outcome: nil))

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(aggregate.outcome.retrySafety == .unsafe)
        #expect(aggregate.outcome.escalation == .observeBeforeRetry)
    }

    @Test
    func `type preserves partial recovery semantics after confirmed focus`() {
        let focusOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Typing completed but cleanup failed")

        let aggregate = TypeTool.aggregateTypingFailure(
            leafFailure,
            after: TypeFocusResult(completed: true, outcome: focusOutcome))

        #expect(aggregate.outcome.state == .partial)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(aggregate.outcome.escalation == .recoverSideEffect)
        #expect(!aggregate.outcome.projection.requiresFreshObservation)
    }

    @Test
    @MainActor
    func `single press text follows a confirmed native outcome`() async throws {
        let automation = StubAutomationService()
        let outcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground))
        automation.actionOutcome = outcome
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        try Self.expect(outcome: outcome, in: response)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected press text response")
            return
        }
        #expect(text.contains("effect confirmed"))
        #expect(!text.contains("unverifiable"))
        #expect(!text.contains("Observe before continuing"))
    }

    @Test
    @MainActor
    func `type omits a leaf outcome after a separate focus action`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == nil)
        #expect(meta["effect"] == nil)
        #expect(meta["mutation_dispatched"] == nil)
        #expect(meta["requires_fresh_observation"] == .bool(true))
    }

    @Test
    @MainActor
    func `retry safe native refusal preserves the active snapshot`() async throws {
        let automation = StubAutomationService()
        automation.elementActionError = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Accessibility permission is required")
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await ActionTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "action": "AXPress",
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["invalidated_snapshot"] == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    @MainActor
    func `missing click observation requests a target refresh`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["refusal_reason"] == .string("target_unavailable"))
        #expect(meta["escalation"] == .string("refresh_target"))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `element action tools classify an incompatible host canonically`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let responses = try await [
            ActionTool(context: context).execute(arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXPress",
            ])),
            SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
                "on": "T1",
                "value": "hello",
            ])),
        ]

        for response in responses {
            #expect(response.isError)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["state"] == .string("refused"))
            #expect(meta["refusal_reason"] == .string("runtime_incompatible"))
            #expect(meta["escalation"] == .string("update_runtime"))
            #expect(meta["retry_safe"] == .bool(true))
        }
    }

    @MainActor
    private static func makeTextFieldSnapshot(uiSnapshots: MCPToolUISnapshotStore) async -> String {
        let snapshot = await uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/type-outcome.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 200, height: 100),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 778,
                    processStartIdentity: 78,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor")))
        await snapshot.setUIElements([
            UIElement(
                id: "T1",
                elementId: "T1",
                role: "textField",
                title: nil,
                label: "Editor",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "text field",
                identifier: nil,
                frame: CGRect(x: 10, y: 10, width: 100, height: 30),
                isActionable: true),
        ])
        return snapshotID
    }

    private static func expect(outcome: DesktopActionOutcome, in response: ToolResponse) throws {
        let expected = try MCPToolResponseMetadataProjector.fields(for: outcome.projection)
        let actual = try #require(response.meta?.objectValue)
        for (key, value) in expected {
            #expect(actual[key] == value, "Canonical field \(key) was not preserved")
        }
    }

    private struct ProjectionExpectation {
        let state: DesktopActionOutcome.State
        let dispatched: Bool
        let retrySafe: Bool
        let fresh: Bool
        let escalation: DesktopActionOutcome.Escalation
    }
}
