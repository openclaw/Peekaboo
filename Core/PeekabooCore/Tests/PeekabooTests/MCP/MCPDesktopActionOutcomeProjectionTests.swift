import CoreGraphics
import Foundation
import MCP
import PeekabooBridgeTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct MCPDesktopActionOutcomeProjectionTests {
    @Test
    func `canonical projection drives the complete seven state MCP matrix`() throws {
        for expectation in DesktopActionOutcomeFixtures.canonicalCases {
            let outcome = expectation.outcome
            let fields = try MCPToolResponseMetadataProjector.fields(for: outcome.projection)

            #expect(fields["state"] == .string(expectation.state.rawValue))
            #expect(fields["mutation_dispatched"] == .bool(expectation.mutationDispatched))
            #expect(fields["retry_safe"] == .bool(expectation.retrySafe))
            #expect(fields["requires_fresh_observation"] == .bool(expectation.requiresFreshObservation))
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
    func `canonical outcome removes stale inferred fields that its projection omits`() throws {
        let metadata = try MCPToolResponseMetadataProjector.metadata(
            merging: [
                "delivery_mode": .string("foreground"),
                "effect": .string("unverifiable"),
                "custom": .string("preserved"),
            ],
            outcome: .refused(reason: .permissionDenied))
        let fields = try #require(metadata?.objectValue)

        #expect(fields["delivery_mode"] == nil)
        #expect(fields["effect"] == .string("refused"))
        #expect(fields["custom"] == .string("preserved"))
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
    func `failure metadata carries canonical target receipt and safety filters preserve it`() throws {
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: 42,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73)
        let failure = DesktopActionFailure.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Dialog input partially dispatched")
            .attributed(to: receipt)

        let response = try MCPToolResponseMetadataProjector.errorResponse(
            for: failure,
            invalidatedSnapshotID: nil)
        let meta = try #require(response.meta?.objectValue)
        let target = try #require(meta["target_receipt"]?.objectValue)
        #expect(target["pid"] == .int(42))
        #expect(target["process_start_identity_decimal"] == .string("9007199254740993"))
        #expect(target["window_id"] == .int(73))

        let external = MCPToolResponseMetadataProjector.externalFields(from: response.meta, toolName: "dialog")
        let agent = MCPToolResponseMetadataProjector.agentFields(from: response.meta)
        #expect(external["target_receipt"] == meta["target_receipt"])
        #expect(agent["target_receipt"] == meta["target_receipt"])
    }

    @Test
    func `process target identity is reserved and preserved only from Peekaboo metadata`() {
        let identity: Value = .object([
            "kind": .string("process"),
            "pid": .int(42),
            "process_start_identity_decimal": .string("9007199254740993"),
        ])
        let trusted: Value = .object([
            "target_identity": identity,
            "untrusted": .string("drop"),
        ])

        #expect(MCPToolResponseMetadataProjector.externalFields(
            from: trusted,
            toolName: "browser")["target_identity"] == identity)
        #expect(MCPToolResponseMetadataProjector.agentFields(from: trusted)["target_identity"] == identity)

        let provider = MCPToolResponseMetadataProjector.providerFields(from: trusted)
        #expect(provider["target_identity"] == nil)
        #expect(provider["provider_meta"]?.objectValue == ["untrusted": .string("drop")])
    }

    @Test
    @MainActor
    func `action tool projects every native outcome state without inferring from invalidation`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001))
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotID = await snapshot.id

        for outcome in DesktopActionOutcomeFixtures.canonicalOutcomes {
            automation.actionOutcome = outcome
            let response = try await ActionTool(context: context).execute(arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXPress",
                "snapshot": snapshotID,
            ]))

            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
            #expect(response.isError == !outcome.isConfirmed)
            guard case let .object(meta) = response.meta else { continue }
            let expectedInvalidatedSnapshot: Value? = outcome.dispatchState.mutationDispatched
                ? .string(snapshotID)
                : nil
            #expect(meta["invalidated_snapshot"] == expectedInvalidatedSnapshot)
        }
    }

    @Test
    @MainActor
    func `element action tools project one canonical process generation target`() async throws {
        let automation = StubAutomationService()
        let process = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 1001)
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(processIdentity: process)
        automation.uiAutomationOutcomeScript.append(
            DesktopActionOutcome.confirmedNoChange(),
            for: .performAction)
        automation.uiAutomationOutcomeScript.append(
            DesktopActionOutcome.confirmedNoChange(),
            for: .setValue)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(
            in: context.uiSnapshots,
            processIdentity: process)
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
        ]

        for response in responses {
            let meta = try #require(response.meta?.objectValue)
            let identity = try #require(meta["target_identity"]?.objectValue)
            let receipt = try #require(meta["target_receipt"]?.objectValue)
            #expect(!response.isError)
            #expect(meta["state"] == .string("confirmed_no_change"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(identity["kind"] == .string("process"))
            #expect(identity["pid"] == .int(Int(process.processIdentifier)))
            #expect(identity["process_start_identity_decimal"] == .string("1001"))
            #expect(identity["window_id"] == nil)
            #expect(receipt["pid"] == .int(Int(process.processIdentifier)))
            #expect(receipt["process_start_identity_decimal"] == .string("1001"))
            #expect(receipt["window_id"] == nil)
        }
        #expect(automation.lastPerformAction?.target == "B1")
        #expect(automation.lastSetValue?.target == "T1")
    }

    @Test
    @MainActor
    func `element action tools reject a result from another process generation`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(processIdentifier: 43, processStartIdentity: 1002))
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
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
        ]

        for response in responses {
            let meta = try #require(response.meta?.objectValue)
            #expect(response.isError)
            #expect(meta["state"] == .string("indeterminate"))
            #expect(meta["mutation_dispatched"] == .bool(true))
            #expect(meta["retry_safe"] == .bool(false))
            #expect(meta["requires_fresh_observation"] == .bool(true))
            #expect(meta["target_identity"] == nil)
            let receipt = try #require(meta["target_receipt"]?.objectValue)
            #expect(receipt["pid"] == .int(42))
            #expect(receipt["process_start_identity_decimal"] == .string("1001"))
        }
        #expect(automation.lastPerformAction?.target == "B1")
        #expect(automation.lastSetValue?.target == "T1")
    }

    @Test
    @MainActor
    func `element action tools reject confirmed results without target identity`() async throws {
        for tool in ["action", "set_value"] {
            let automation = StubAutomationService()
            automation.actionOutcome = .confirmedNoChange()
            automation.uiAutomationOutcomeTargetIdentity = nil
            let context = await MCPToolTestHelpers.makeContext(automation: automation)
            await context.uiSnapshots.removeOwner()
            let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
            let snapshotID = await snapshot.id

            let response = if tool == "action" {
                try await ActionTool(context: context).execute(arguments: ToolArguments(raw: [
                    "on": "B1",
                    "action": "AXPress",
                    "snapshot": snapshotID,
                ]))
            } else {
                try await SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
                    "on": "T1",
                    "value": "hello",
                    "snapshot": snapshotID,
                ]))
            }

            let meta = try #require(response.meta?.objectValue)
            #expect(response.isError)
            #expect(meta["state"] == .string("indeterminate"))
            #expect(meta["mutation_dispatched"] == .bool(true))
            #expect(meta["retry_safe"] == .bool(false))
            #expect(meta["requires_fresh_observation"] == .bool(true))
            #expect(meta["target_identity"] == nil)
            let receipt = try #require(meta["target_receipt"]?.objectValue)
            #expect(receipt["pid"] == .int(42))
            #expect(receipt["process_start_identity_decimal"] == .string("1001"))
        }
    }

    @Test
    @MainActor
    func `element action tools refuse receiptless legacy providers before dispatch`() async throws {
        let automation = LegacyElementActionAutomationService(accessibilityGranted: true)
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
        ]

        for response in responses {
            let meta = try #require(response.meta?.objectValue)
            #expect(response.isError)
            #expect(meta["state"] == .string("refused"))
            #expect(meta["refusal_reason"] == .string("runtime_incompatible"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }
        #expect(automation.setValueCallCount == 0)
        #expect(automation.performActionCallCount == 0)
    }

    @Test
    @MainActor
    func `set value refuses an outcome provider without result target binding before dispatch`() async throws {
        let automation = StubAutomationService()
        automation.supportsSetValueResultTargetBinding = false
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotID = await snapshot.id

        let response = try await SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "value": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(
            reason: .runtimeIncompatible,
            in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(automation.lastSetValue == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test
    @MainActor
    func `element action tools project missing generation as a zero dispatch snapshot refusal`() async throws {
        let automation = StubAutomationService()
        let failure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Snapshot target receipt has no capture-time process-generation receipt.",
            standardErrorCode: .snapshotStale)
        automation.uiAutomationOutcomeScript.appendFailure(
            failure,
            for: .performAction)
        automation.uiAutomationOutcomeScript.appendFailure(
            failure,
            for: .setValue)
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
        ]

        for response in responses {
            let meta = try #require(response.meta?.objectValue)
            #expect(response.isError)
            #expect(meta["state"] == .string("refused"))
            #expect(meta["refusal_reason"] == .string("target_unavailable"))
            #expect(meta["error_code"] == .string("SNAPSHOT_STALE"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["invalidated_snapshot"] == nil)
        }
        #expect(automation.lastPerformAction == nil)
        #expect(automation.lastSetValue == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test
    @MainActor
    func `returned non dispatched outcome preserves its request snapshot`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .refused(reason: .permissionDenied)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotID = await snapshot.id

        let response = try await ActionTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "B1",
            "action": "AXPress",
            "snapshot": snapshotID,
        ]))

        let meta = try #require(response.meta?.objectValue)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["invalidated_snapshot"] == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    @MainActor
    func `snapshot independent dispatched failure invalidates the session implicit latest`() async throws {
        let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())
        let snapshot = await uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        let failure = DesktopActionFailure.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            message: "Raw input was dispatched")

        let response = try await MCPDesktopActionFailureHandler.response(
            for: failure,
            uiSnapshots: uiSnapshots,
            snapshotID: nil)

        #expect(response.isError)
        #expect(response.meta?.objectValue?["invalidated_snapshot"] == .string(snapshotID))
        #expect(await uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `all outcome backed mutation tools publish the canonical native projection`() async throws {
        let automation = StubAutomationService()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let elementOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted)
        automation.actionOutcome = outcome
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(processIdentifier: 42, processStartIdentity: 1001))
        automation.uiAutomationOutcomeScript.append(elementOutcome, for: .performAction)
        automation.uiAutomationOutcomeScript.append(elementOutcome, for: .setValue)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotID = await snapshot.id

        let elementResponses = try await [
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
        ]
        let otherResponses = try await [
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

        for response in elementResponses {
            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(elementOutcome, in: response)
        }
        for response in otherResponses {
            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        }
    }

    @Test
    @MainActor
    func `scroll partial failure projects exact accepted prefix without retry permission`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.appendFailure(
            DesktopActionFailure.partial(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one,
                message: "One of three page units was accepted"),
            for: .scroll)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshotID = await Self.makeExactScrollSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "amount": 3,
            "on": "T1",
            "snapshot": snapshotID,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("partial"))
        #expect(meta["effect"] == .string("partial"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["escalation"] == .string("recover_side_effect"))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
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
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `scroll setup focus invalidates despite a no change leaf`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: MCPFocusResultWindowService())
        await context.uiSnapshots.removeOwner()
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "on": "T1",
            "snapshot": snapshotID,
            "foreground": true,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `scroll setup focus makes a refused leaf indeterminate`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .refused(reason: .permissionDenied)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: MCPFocusResultWindowService())
        await context.uiSnapshots.removeOwner()
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await ScrollTool(context: context).execute(arguments: ToolArguments(raw: [
            "direction": "down",
            "on": "T1",
            "snapshot": snapshotID,
            "foreground": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }
}

@MainActor
private final class LegacyElementActionAutomationService: MockAutomationService,
ElementActionAutomationServiceProtocol {
    let supportsProcessGenerationBoundElementMutations = true
    private(set) var setValueCallCount = 0
    private(set) var performActionCallCount = 0

    func setValue(target: String, value _: UIElementValue, snapshotId _: String?) async throws
        -> ElementActionResult
    {
        self.setValueCallCount += 1
        return ElementActionResult(target: target, actionName: "AXSetValue", anchorPoint: nil)
    }

    func performAction(target: String, actionName: String, snapshotId _: String?) async throws
        -> ElementActionResult
    {
        self.performActionCallCount += 1
        return ElementActionResult(target: target, actionName: actionName, anchorPoint: nil)
    }
}

extension MCPDesktopActionOutcomeProjectionTests {
    @Test
    @MainActor
    func `multi chord homogeneous success publishes one canonical aggregate`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground))
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["total_presses"] == .int(2))
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["requires_fresh_observation"] == .bool(false))
    }

    @Test
    @MainActor
    func `multi chord confirmed no change does not fabricate dispatch`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["total_presses"] == .int(2))
        #expect(meta["state"] == .string("confirmed_no_change"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["delivery_mode"] == nil)
        #expect(automation.uiAutomationOutcomeScript.callCount(for: .hotkey) == 2)
    }

    @Test
    @MainActor
    func `heterogeneous no change chords do not fabricate foreground delivery`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.append(.confirmedNoChange(route: .local), for: .hotkey)
        automation.uiAutomationOutcomeScript.append(.confirmedNoChange(route: .bridge), for: .hotkey)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected text response")
            return
        }
        let meta = try #require(response.meta?.objectValue)
        #expect(text.contains("all chords confirmed no change"))
        #expect(!text.contains("Dispatched"))
        #expect(!text.contains("unverifiable"))
        #expect(meta["delivery_mode"] == nil)
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["invalidated_snapshot"] == nil)
    }

    @Test
    @MainActor
    func `target focus remains canonical with authoritative no change chords`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.append(.confirmedNoChange(route: .local), for: .hotkey)
        automation.uiAutomationOutcomeScript.append(.confirmedNoChange(route: .bridge), for: .hotkey)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: MCPFocusResultWindowService())

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "app": "Example",
            "foreground": true,
        ]))

        #expect(!response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected text response")
            return
        }
        let meta = try #require(response.meta?.objectValue)
        #expect(text.contains("effect confirmed"))
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
        #expect(meta["dispatched_unit_count"] == .int(1))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["requires_fresh_observation"] == .bool(false))
    }

    @Test
    @MainActor
    func `multi chord legacy success publishes canonical unverified aggregate`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a", "cmd+c"],
            "foreground": true,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["total_presses"] == .int(2))
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["effect"] == .string("unverifiable"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["requires_fresh_observation"] == .bool(true))
        #expect(meta["dispatched_unit_count"] == .int(2))
    }

    @Test
    @MainActor
    func `press stops a sequence after a nonconfirmed native leaf`() async throws {
        let outcomes: [DesktopActionOutcome] = [
            .refused(reason: .permissionDenied),
            .indeterminate(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .completionUnknown),
        ]

        for outcome in outcomes {
            let automation = StubAutomationService()
            automation.actionOutcome = outcome
            let context = await MCPToolTestHelpers.makeContext(automation: automation)

            let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
                "keys": ["cmd+a", "cmd+c"],
                "foreground": true,
            ]))

            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
            #expect(automation.uiAutomationOutcomeScript.callCount(for: .hotkey) == 1)
        }
    }

    @Test
    func `multi chord leaf failure preserves cumulative canonical partial semantics`() throws {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(
            .reportedOutcome(
                .confirmedChange(delivery: .init(mechanism: .globalEvents, mode: .foreground)),
                defaultDispatchedUnitCount: .one))
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(1),
            message: "Second chord completed but cleanup failed")
        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)
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
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: nil,
            delivery: nil,
            unitCount: DesktopActionOutcome.DispatchUnitCount(1)))
        let leafFailure = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Hotkey was refused")

        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.delivery == nil)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(aggregate.outcome.retrySafety == .unsafe)
        #expect(aggregate.outcome.escalation == .observeBeforeRetry)
    }

    @Test
    func `press does not assign a partial leaf delivery to completed target focus`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: nil,
            delivery: nil,
            unitCount: DesktopActionOutcome.DispatchUnitCount(1)))
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(1),
            message: "Chord completed but cleanup failed")

        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.delivery == nil)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(aggregate.outcome.escalation == .observeBeforeRetry)
    }

    @Test
    @MainActor
    func `type refuses to discard an unconfirmed native focus outcome`() async throws {
        let automation = StubAutomationService()
        let outcome = DesktopActionOutcome.suspectedNoop(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        automation.actionOutcome = outcome
        let context = await Self.makeBackgroundTypingContext(automation: automation)
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
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
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
        let context = await Self.makeBackgroundTypingContext(automation: automation)
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
    @MainActor
    func `type aggregates a returned refusal after confirmed focus`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        automation.uiAutomationOutcomeScript.append(.refused(reason: .permissionDenied), for: .typeActions)
        let context = await Self.makeBackgroundTypingContext(automation: automation)
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
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `generic typing error after no change focus does not invent a mutation`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        automation.targetedTypeError = PeekabooError.invalidInput("typing refused before dispatch")
        let context = await Self.makeBackgroundTypingContext(automation: automation)
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == nil)
        #expect(response.meta?.objectValue?["state"] == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    @MainActor
    func `returned dispatched type outcome invalidates its explicit snapshot through failure handling`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let snapshot = await context.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "snapshot": snapshotID,
            "foreground": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("dispatched_unverified"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(await context.uiSnapshots.getSnapshot(id: nil) == nil)
    }

    @Test
    @MainActor
    func `confirmed no-change type leaf is an error with no typed-character claims`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedNoChange()
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("refused"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["characters_typed"] == .null)
    }

    @Test
    @MainActor
    func `missing type outcome is an error with no typed-character claims`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.setDefaultOutcome(nil)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
        ]))

        #expect(response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("indeterminate"))
        #expect(meta["characters_typed"] == .null)
    }

    @Test
    @MainActor
    func `every non-confirmed typing state is MCP error without typed-character claims`() async throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
        let outcomes: [DesktopActionOutcome?] = [
            nil,
            .confirmedNoChange(),
            .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted),
            .suspectedNoop(delivery: delivery),
            .partial(delivery: delivery),
            .refused(reason: .targetUnavailable),
            .indeterminate(delivery: delivery, evidence: .completionUnknown),
        ]

        for outcome in outcomes {
            let automation = StubAutomationService()
            automation.uiAutomationOutcomeScript.setDefaultOutcome(outcome)
            let context = await MCPToolTestHelpers.makeContext(automation: automation)
            let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
                "text": "hello",
                "foreground": true,
            ]))

            #expect(response.isError)
            #expect(response.meta?.objectValue?["characters_typed"] == .null)
        }
    }

    @Test
    func `type conservatively counts a receiptless completed focus before refusal`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.dispatched(
            route: nil,
            delivery: nil,
            unitCount: DesktopActionOutcome.DispatchUnitCount(1)))
        let leafFailure = DesktopActionFailure.refused(
            reason: .permissionDenied,
            message: "Typing was refused")

        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(aggregate.outcome.retrySafety == .unsafe)
        #expect(aggregate.outcome.escalation == .observeBeforeRetry)
    }

    @Test
    func `type composes delivery for heterogeneous partial typing after focus`() {
        let focusOutcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let leafFailure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Typing completed but cleanup failed")

        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)

        #expect(aggregate.outcome.state == .partial)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(aggregate.outcome.delivery == .init(mechanism: .composite, mode: .background))
        #expect(aggregate.outcome.escalation == .recoverSideEffect)
        #expect(!aggregate.outcome.projection.requiresFreshObservation)
    }

    @Test
    func `type preserves partial recovery for one homogeneous delivery`() {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .processTargetedEvents,
            mode: .background)
        let focusOutcome = DesktopActionOutcome.confirmedChange(delivery: delivery)
        let leafFailure = DesktopActionFailure.partial(
            delivery: delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Typing completed but cleanup failed")

        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)

        #expect(aggregate.outcome.state == .partial)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(aggregate.outcome.delivery == delivery)
        #expect(aggregate.outcome.escalation == .recoverSideEffect)
        #expect(!aggregate.outcome.projection.requiresFreshObservation)
    }

    @Test
    func `type omits a partial leaf route from a heterogeneous aggregate`() {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .processTargetedEvents,
            mode: .background)
        let focusOutcome = DesktopActionOutcome.confirmedChange(
            route: .local,
            delivery: delivery)
        let leafFailure = DesktopActionFailure.partial(
            route: .bridge,
            delivery: delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(1),
            message: "Typing completed but cleanup failed")

        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
        let aggregate = sequence.failure(combining: leafFailure, message: leafFailure.message)

        #expect(aggregate.outcome.state == .indeterminate)
        #expect(aggregate.outcome.route == .bridge)
        #expect(aggregate.outcome.delivery == nil)
        #expect(aggregate.outcome.dispatchState.unitCount?.rawValue == 2)
    }

    @Test
    func `type preserves confirmed no change when no composite unit dispatched`() {
        let outcome = DesktopActionOutcome.confirmedNoChange()
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(.confirmedNoChange()))
        sequence.record(.outcome(outcome))
        let aggregate = sequence.successResolution().outcome

        #expect(aggregate == outcome)
        #expect(aggregate?.state == .confirmedNoChange)
        #expect(aggregate?.dispatchState.mutationDispatched == false)
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
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
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
    func `type aggregates homogeneous successful focus and typing outcomes`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let context = await Self.makeBackgroundTypingContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["delivery_mechanism"] == .string("accessibility_action"))
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
        #expect(meta["requires_fresh_observation"] == .bool(false))
    }

    @Test
    @MainActor
    func `type treats an authoritative no change leaf as non-success after focus`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        automation.uiAutomationOutcomeScript.append(.confirmedNoChange(), for: .typeActions)
        let context = await Self.makeBackgroundTypingContext(automation: automation)
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
        #expect(meta["characters_typed"] == .null)
        #expect(meta["summary"] == nil)
    }

    @Test
    @MainActor
    func `type composes heterogeneous successful focus and typing delivery`() async throws {
        let automation = StubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .background))
        automation.uiAutomationOutcomeScript.append(
            .confirmedChange(delivery: .init(mechanism: .processTargetedEvents, mode: .background)),
            for: .typeActions)
        let context = await Self.makeBackgroundTypingContext(automation: automation)
        let snapshotID = await Self.makeTextFieldSnapshot(uiSnapshots: context.uiSnapshots)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "text": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(!response.isError)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["state"] == .string("confirmed_change"))
        #expect(meta["effect"] == .string("confirmed"))
        #expect(meta["mutation_dispatched"] == .bool(true))
        #expect(meta["retry_safe"] == .bool(false))
        #expect(meta["delivery_mechanism"] == .string("composite"))
        #expect(meta["delivery_mode"] == .string("background"))
        #expect(meta["dispatched_unit_count"] == .int(2))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["invalidated_snapshot"] == .string(snapshotID))
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
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
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
            try MCPToolTestHelpers.expectCanonicalRefusalMetadata(
                reason: .runtimeIncompatible,
                in: response)
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["escalation"] == .string("update_runtime"))
        }
    }

    @Test
    @MainActor
    func `set value maps a Bridge result binding refusal without invalidating its snapshot`() async throws {
        let automation = StubAutomationService()
        automation.uiAutomationOutcomeScript.appendFailure(
            DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "This Bridge host cannot return a verifiable set-value result.",
                hint: "Update and relaunch Peekaboo before retrying set-value."),
            for: .setValue)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        await context.uiSnapshots.removeOwner()
        let snapshot = await MCPToolTestHelpers.createElementActionSnapshot(in: context.uiSnapshots)
        let snapshotID = await snapshot.id

        let response = try await SetValueTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "T1",
            "value": "hello",
            "snapshot": snapshotID,
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(
            .refused(route: .bridge, reason: .runtimeIncompatible),
            in: response)
        let meta = try #require(response.meta?.objectValue)
        #expect(meta["route"] == .string("bridge"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["invalidated_snapshot"] == nil)
        #expect(await context.uiSnapshots.getSnapshot(id: snapshotID) != nil)
    }

    @Test
    @MainActor
    func `mutation tool validation emits canonical predispatch refusals`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        let responses = try await [
            TypeTool(context: context).execute(arguments: ToolArguments(raw: [:])),
            PressTool(context: context).execute(arguments: ToolArguments(raw: [
                "keys": ["cmd+a"],
                "count": 0,
                "foreground": true,
            ])),
            PressTool(context: context).execute(arguments: ToolArguments(raw: [
                "keys": ["cmd+a"],
                "count": 1.5,
                "foreground": true,
            ])),
            ScrollTool(context: context).execute(arguments: ToolArguments(raw: [:])),
        ]

        for response in responses {
            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .invalidRequest, in: response)
        }
    }

    @Test
    @MainActor
    func `missing type snapshot is a canonical target refusal`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(automation: automation)

        let response = try await TypeTool(context: context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "snapshot": "missing-snapshot",
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .targetUnavailable, in: response)
    }

    @MainActor
    private static func makeBackgroundTypingContext(
        automation: any UIAutomationServiceProtocol) async -> MCPToolContext
    {
        let applications = MockApplicationService(applications: [
            ServiceApplicationInfo(
                processIdentifier: 777,
                processStartIdentity: 77,
                bundleIdentifier: "com.example.focus-editor",
                name: "Focus Editor",
                activationPolicy: .regular),
            ServiceApplicationInfo(
                processIdentifier: 778,
                processStartIdentity: 78,
                bundleIdentifier: "com.example.editor",
                name: "Editor",
                activationPolicy: .regular),
        ])
        return await MCPToolTestHelpers.makeContext(
            automation: automation,
            applications: applications)
    }

    @MainActor
    private static func makeExactScrollSnapshot(uiSnapshots: MCPToolUISnapshotStore) async -> String {
        let snapshot = await uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        await snapshot.setScreenshot(
            path: "/tmp/scroll-outcome.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 778,
                    processStartIdentity: 78,
                    bundleIdentifier: "com.example.editor",
                    name: "Editor"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Editor",
                    bounds: bounds,
                    mutationIdentity: WindowMutationIdentity(
                        windowID: 42,
                        ownerProcessIdentifier: 778,
                        ownerProcessStartIdentity: 78,
                        capturedBounds: bounds))))
        await snapshot.setUIElements([
            UIElement(
                id: "T1",
                elementId: "T1",
                role: "scrollArea",
                title: nil,
                label: "Editor",
                value: nil,
                description: nil,
                help: nil,
                roleDescription: "scroll area",
                identifier: nil,
                frame: CGRect(x: 10, y: 10, width: 100, height: 30),
                isActionable: true),
        ])
        return snapshotID
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
}
