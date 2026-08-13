import Foundation
import MCP
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

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

    private struct ProjectionExpectation {
        let state: DesktopActionOutcome.State
        let dispatched: Bool
        let retrySafe: Bool
        let fresh: Bool
        let escalation: DesktopActionOutcome.Escalation
    }
}
