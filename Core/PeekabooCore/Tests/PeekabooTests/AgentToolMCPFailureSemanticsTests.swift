import Foundation
import MCP
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
struct AgentToolMCPFailureSemanticsTests {
    @Test
    func `Canonical outcomes drive custom tool trace classification without reconstruction`() throws {
        for (index, outcome) in DesktopActionOutcomeFixtures.canonicalOutcomes.enumerated() {
            let value = try Value(outcome.projection).toAnyAgentToolValue()
            let call = AgentToolCall(id: "outcome-\(index)", name: "custom_outcome", arguments: [:])
            let result = AgentToolResult.success(toolCallId: call.id, result: value)
            let entry = try #require(Self.execution(call: call, result: result).executionTrace().entries.first)

            #expect(entry.actionOutcome == outcome.projection)
            #expect(entry.isError == !outcome.isConfirmed)
            #expect(entry.disposition == (outcome.isConfirmed ? .executedSucceeded : .executedFailed))
            switch outcome.dispatchState {
            case .none:
                #expect(entry.mutationDispatch == .notDispatched)
            case .dispatched:
                #expect(entry.mutationDispatch == .dispatched)
            case .mayHaveDispatched:
                #expect(entry.mutationDispatch == .possiblyDispatched)
            }
        }
    }

    @Test
    func `Partial metadata stays untyped while malformed canonical metadata fails closed`() throws {
        let call = AgentToolCall(id: "metadata", name: "custom_outcome", arguments: [:])
        let partial = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "dispatch_state": AnyAgentToolValue(string: "queued"),
                "retry_safety": AnyAgentToolValue(string: "provider_managed"),
            ]))
        let confirmed = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        var malformedFields = try #require(try Self.value(confirmed.projection).objectValue)
        malformedFields["effect"] = AnyAgentToolValue(string: "refused")
        let malformed = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: malformedFields))

        #expect(!AgentToolResultSemantics.isFailure(partial))
        #expect(AgentToolResultSemantics.actionOutcome(from: partial) == nil)
        #expect(AgentToolResultSemantics.isFailure(malformed))
        #expect(AgentToolResultSemantics.actionOutcome(from: malformed) == nil)
    }

    @Test
    func `Ordinary state payload stays successful and cannot mask nested canonical metadata`() throws {
        let generic = AgentToolResult.success(
            toolCallId: "generic",
            result: AnyAgentToolValue(object: [
                "route": AnyAgentToolValue(string: "local"),
                "state": AnyAgentToolValue(string: "ready"),
            ]))
        let outcome = DesktopActionOutcome.refused(reason: .permissionDenied)
        let nested = try AgentToolResult.success(
            toolCallId: "nested",
            result: AnyAgentToolValue(object: [
                "meta": Self.value(outcome.projection),
                "state": AnyAgentToolValue(string: "ready"),
            ]))

        #expect(!AgentToolResultSemantics.isFailure(generic))
        #expect(AgentToolResultSemantics.actionOutcome(from: generic) == nil)
        #expect(AgentToolResultSemantics.isFailure(nested))
        #expect(AgentToolResultSemantics.actionOutcome(from: nested) == outcome.projection)
    }

    @Test
    func `Conflicting canonical containers fail closed while identical copies agree`() throws {
        let confirmed = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        let refused = DesktopActionOutcome.refused(reason: .permissionDenied)
        let confirmedValue = try Self.value(confirmed.projection)
        let refusedValue = try Self.value(refused.projection)
        var conflictingPayload = try #require(confirmedValue.objectValue)
        conflictingPayload["metadata"] = refusedValue
        var identicalPayload = try #require(confirmedValue.objectValue)
        identicalPayload["metadata"] = confirmedValue
        let conflict = AgentToolResult.success(
            toolCallId: "conflict",
            result: AnyAgentToolValue(object: conflictingPayload))
        let identical = AgentToolResult.success(
            toolCallId: "identical",
            result: AnyAgentToolValue(object: identicalPayload))
        var malformedRoot = try #require(confirmedValue.objectValue)
        malformedRoot["effect"] = AnyAgentToolValue(string: "refused")
        malformedRoot["meta"] = AnyAgentToolValue(object: [
            "mutation_dispatched": AnyAgentToolValue(bool: false),
            "requires_fresh_observation": AnyAgentToolValue(bool: false),
            "retry_safe": AnyAgentToolValue(bool: true),
        ])
        malformedRoot["metadata"] = confirmedValue
        let malformedThenValid = AgentToolResult.success(
            toolCallId: "malformed-then-valid",
            result: AnyAgentToolValue(object: malformedRoot))
        let conflictCall = AgentToolCall(id: "conflict", name: "click", arguments: [:])
        let conflictEntry = try #require(
            Self.execution(call: conflictCall, result: conflict).executionTrace().entries.first)

        #expect(AgentToolResultSemantics.isFailure(conflict))
        #expect(AgentToolResultSemantics.actionOutcome(from: conflict) == nil)
        #expect(conflictEntry.disposition == .executedFailed)
        #expect(conflictEntry.mutationDispatch == .possiblyDispatched)
        #expect(conflictEntry.result?.objectValue?["retry_safe"] == nil)
        #expect(!AgentToolResultSemantics.isFailure(identical))
        #expect(AgentToolResultSemantics.actionOutcome(from: identical) == confirmed.projection)

        let malformedEntry = try #require(Self.execution(
            call: AgentToolCall(id: "malformed-then-valid", name: "click", arguments: [:]),
            result: malformedThenValid).executionTrace().entries.first)
        let malformedSummary = try #require(malformedEntry.result?.objectValue)
        #expect(AgentToolResultSemantics.isFailure(malformedThenValid))
        #expect(malformedEntry.actionOutcome == nil)
        #expect(malformedEntry.mutationDispatch == .possiblyDispatched)
        #expect(malformedSummary["mutation_dispatched"] == nil)
        #expect(malformedSummary["requires_fresh_observation"] == nil)
        #expect(malformedSummary["retry_safe"] == nil)
    }

    @Test
    func `Outcome inspection ignores deeply nested and wide unrelated payloads`() throws {
        var unrelated = AnyAgentToolValue(string: "private leaf")
        for _ in 0..<512 {
            unrelated = AnyAgentToolValue(object: ["next": unrelated])
        }
        let call = AgentToolCall(id: "deep-generic", name: "custom_state", arguments: [:])
        let result = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "state": AnyAgentToolValue(string: "ready"),
                "unrelated": unrelated,
            ]))
        let trace = Self.execution(call: call, result: result).executionTrace()
        let encoded = try JSONEncoder().encode(trace)

        #expect(!AgentToolResultSemantics.isFailure(result))
        #expect(AgentToolResultSemantics.actionOutcome(from: result) == nil)
        #expect(trace.entries.first?.disposition == .executedSucceeded)
        #expect(encoded.count < 1000)

        var wide = Dictionary(uniqueKeysWithValues: (0..<10000).map { index in
            ("unrelated-\(index)-" + String(repeating: "x", count: 128), AnyAgentToolValue(bool: true))
        })
        wide["state"] = AnyAgentToolValue(string: "ready")
        let wideResult = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: wide))
        let wideTrace = Self.execution(call: call, result: wideResult).executionTrace()
        #expect(!AgentToolResultSemantics.isFailure(wideResult))
        #expect(wideTrace.entries.first?.disposition == .executedSucceeded)
        #expect(try JSONEncoder().encode(wideTrace).count < 1000)
    }

    @Test
    func `Partial wrapper claims cannot override a validated nested outcome`() throws {
        let outcome = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown)
        let call = AgentToolCall(id: "partial-wrapper", name: "click", arguments: [:])
        let result = try AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "metadata": Self.value(outcome.projection),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "requires_fresh_observation": AnyAgentToolValue(bool: false),
                "retry_safe": AnyAgentToolValue(bool: true),
                "success": AnyAgentToolValue(bool: true),
            ]))
        let entry = try #require(Self.execution(call: call, result: result).executionTrace().entries.first)
        let summary = try #require(entry.result?.objectValue)

        #expect(entry.disposition == .executedFailed)
        #expect(entry.actionOutcome == outcome.projection)
        #expect(entry.mutationDispatch == .possiblyDispatched)
        #expect(summary["mutation_dispatched"]?.boolValue == true)
        #expect(summary["requires_fresh_observation"]?.boolValue == true)
        #expect(summary["retry_safe"] == nil)
        #expect(summary["success"] == nil)
    }

    @Test
    func `Validated canonical success outranks legacy wrapper failure fields`() throws {
        let outcome = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        let call = AgentToolCall(id: "legacy-wrapper", name: "click", arguments: [:])
        let result = try AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(string: "stale wrapper error"),
                "metadata": Self.value(outcome.projection),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "requires_fresh_observation": AnyAgentToolValue(bool: true),
                "retry_safe": AnyAgentToolValue(bool: true),
                "success": AnyAgentToolValue(bool: false),
            ]))
        let entry = try #require(Self.execution(call: call, result: result).executionTrace().entries.first)
        let summary = try #require(entry.result?.objectValue)

        #expect(!AgentToolResultSemantics.isFailure(result))
        #expect(entry.disposition == .executedSucceeded)
        #expect(entry.actionOutcome == outcome.projection)
        #expect(entry.mutationDispatch == .dispatched)
        #expect(summary["mutation_dispatched"]?.boolValue == true)
        #expect(summary["requires_fresh_observation"]?.boolValue == false)
        #expect(summary["retry_safe"]?.boolValue == false)
        #expect(summary["error_present"] == nil)
        #expect(summary["success"] == nil)
    }

    @Test
    func `Conflicting legacy wrappers make canonical derived claims conservative`() throws {
        let outcome = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        let call = AgentToolCall(id: "legacy-wrapper-conflict", name: "click", arguments: [:])
        let result = try AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "meta": AnyAgentToolValue(object: [
                    "mutation_dispatched": AnyAgentToolValue(bool: true),
                    "requires_fresh_observation": AnyAgentToolValue(bool: false),
                    "retry_safe": AnyAgentToolValue(bool: false),
                ]),
                "metadata": Self.value(outcome.projection),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "requires_fresh_observation": AnyAgentToolValue(bool: true),
                "retry_safe": AnyAgentToolValue(bool: true),
            ]))
        let entry = try #require(Self.execution(call: call, result: result).executionTrace().entries.first)
        let summary = try #require(entry.result?.objectValue)

        #expect(AgentToolResultSemantics.isFailure(result))
        #expect(entry.disposition == .executedFailed)
        #expect(entry.actionOutcome == nil)
        #expect(entry.mutationDispatch == .possiblyDispatched)
        #expect(summary["mutation_dispatched"] == nil)
        #expect(summary["requires_fresh_observation"] == nil)
        #expect(summary["retry_safe"] == nil)
    }

    @Test
    func `Explicit failure carriers retain presence beside a confirmed outcome`() throws {
        let outcome = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        let metadata = try Self.value(outcome.projection)
        let call = AgentToolCall(id: "explicit-failure", name: "click", arguments: [:])
        let flagged = AgentToolResult(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(string: "explicit MCP failure"),
                "metadata": metadata,
                "reason": AnyAgentToolValue(string: "provider rejected completion"),
            ]),
            isError: true)
        let typed = AgentToolResult(
            toolCallId: call.id,
            failure: AgentToolExecutionFailure(
                message: "typed execution failure",
                metadata: metadata))

        for (index, result) in [flagged, typed].enumerated() {
            let entry = try #require(Self.execution(call: call, result: result).executionTrace().entries.first)
            let summary = try #require(entry.result?.objectValue)

            #expect(entry.disposition == .executedFailed)
            #expect(entry.isError == true)
            #expect(entry.actionOutcome == outcome.projection)
            #expect(entry.mutationDispatch == .dispatched)
            #expect(summary["error_present"]?.boolValue == true)
            #expect(summary["reason_present"]?.boolValue == (index == 0 ? true : nil))
        }
    }

    @Test
    func `Container-valued canonical fields fail before recursive conversion`() throws {
        var nested = AnyAgentToolValue(string: "private canonical leaf")
        for _ in 0..<512 {
            nested = AnyAgentToolValue(object: ["next": nested])
        }
        let call = AgentToolCall(id: "nested-canonical", name: "click", arguments: [:])
        let confirmed = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        var fields = try #require(try Self.value(confirmed.projection).objectValue)
        fields["state"] = nested
        let result = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: fields))
        let trace = Self.execution(call: call, result: result).executionTrace()
        let encoded = try JSONEncoder().encode(trace)

        #expect(AgentToolResultSemantics.isFailure(result))
        #expect(trace.entries.first?.disposition == .executedFailed)
        #expect(trace.entries.first?.mutationDispatch == .possiblyDispatched)
        #expect(trace.entries.first?.actionOutcome == nil)
        #expect(encoded.count < 1000)

        let customCall = AgentToolCall(id: "nested-custom", name: "custom_outcome", arguments: [:])
        let customResult = AgentToolResult.success(toolCallId: customCall.id, result: result.result)
        let customEntry = try #require(
            Self.execution(call: customCall, result: customResult).executionTrace().entries.first)
        #expect(customEntry.disposition == .executedFailed)
        #expect(customEntry.mutationDispatch == .possiblyDispatched)
    }

    @Test
    func `Skipped marker cannot override canonical or invalid dispatch`() throws {
        let confirmed = DesktopActionOutcome.confirmedChange(delivery: .init(
            mechanism: .accessibilityAction,
            mode: .background))
        let refused = DesktopActionOutcome.refused(reason: .permissionDenied)
        var dispatchedFields = try #require(try Self.value(confirmed.projection).objectValue)
        dispatchedFields["skipped"] = AnyAgentToolValue(bool: true)
        var invalidFields = dispatchedFields
        invalidFields["retry_safe"] = AnyAgentToolValue(bool: true)
        let call = AgentToolCall(id: "skipped-conflict", name: "click", arguments: [:])
        let dispatched = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: dispatchedFields))
        let invalid = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: invalidFields))
        let legacyConflict = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "mutation_dispatched": AnyAgentToolValue(bool: true),
                "skipped": AnyAgentToolValue(bool: true),
            ]))
        let disputedCanonicalSkip = try AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "meta": AnyAgentToolValue(object: [
                    "mutation_dispatched": AnyAgentToolValue(bool: true),
                    "skipped": AnyAgentToolValue(bool: true),
                ]),
                "metadata": Self.value(refused.projection),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "skipped": AnyAgentToolValue(bool: true),
            ]))
        let dispatchedEntry = try #require(
            Self.execution(call: call, result: dispatched).executionTrace().entries.first)
        let invalidEntry = try #require(
            Self.execution(call: call, result: invalid).executionTrace().entries.first)
        let legacyConflictEntry = try #require(
            Self.execution(call: call, result: legacyConflict).executionTrace().entries.first)
        let disputedCanonicalSkipEntry = try #require(
            Self.execution(call: call, result: disputedCanonicalSkip).executionTrace().entries.first)

        #expect(dispatchedEntry.disposition == .executedSucceeded)
        #expect(dispatchedEntry.mutationDispatch == .dispatched)
        #expect(dispatchedEntry.actionOutcome == confirmed.projection)
        #expect(dispatchedEntry.result?.objectValue?["skipped"] == nil)
        #expect(dispatchedEntry.result?.objectValue?["mutation_dispatched"]?.boolValue == true)
        #expect(invalidEntry.disposition == .executedFailed)
        #expect(invalidEntry.mutationDispatch == .possiblyDispatched)
        #expect(invalidEntry.actionOutcome == nil)
        #expect(invalidEntry.result?.objectValue?["skipped"] == nil)
        #expect(invalidEntry.result?.objectValue?["mutation_dispatched"] == nil)
        #expect(legacyConflictEntry.disposition == .executedSucceeded)
        #expect(legacyConflictEntry.mutationDispatch == .possiblyDispatched)
        #expect(legacyConflictEntry.actionOutcome == nil)
        #expect(legacyConflictEntry.result?.objectValue?["skipped"]?.boolValue == true)
        #expect(legacyConflictEntry.result?.objectValue?["mutation_dispatched"]?.boolValue == true)
        #expect(disputedCanonicalSkipEntry.disposition == .executedFailed)
        #expect(disputedCanonicalSkipEntry.mutationDispatch == .possiblyDispatched)
        #expect(disputedCanonicalSkipEntry.actionOutcome == nil)
        #expect(disputedCanonicalSkipEntry.result?.objectValue?["skipped"] == nil)
        #expect(disputedCanonicalSkipEntry.result?.objectValue?["mutation_dispatched"] == nil)
        #expect(disputedCanonicalSkipEntry.result?.objectValue?["retry_safe"] == nil)
    }

    @Test
    func `Legacy semantic claim matrix rejects duplicate disagreement`() throws {
        let call = AgentToolCall(id: "legacy-conflict", name: "click", arguments: [:])

        for key in AgentToolResultSemantics.legacyBooleanKeys {
            let result = AgentToolResult.success(
                toolCallId: call.id,
                result: AnyAgentToolValue(object: [
                    key: AnyAgentToolValue(bool: true),
                    "metadata": AnyAgentToolValue(object: [
                        key: AnyAgentToolValue(bool: false),
                    ]),
                ]))
            let claims = AgentToolResultSemantics.normalizedClaims(from: result.result)
            let entry = try #require(Self.execution(call: call, result: result).executionTrace().entries.first)
            let summary = try #require(entry.result?.objectValue)

            #expect(claims.boolean(key) == .invalid, "Expected conflict for \(key)")
            #expect(AgentToolResultSemantics.isFailure(result))
            #expect(entry.disposition == .executedFailed)
            #expect(summary[key] == nil, "Trace published disputed \(key)")
            #expect(entry.mutationDispatch == .possiblyDispatched)
            if key == "skipped" {
                #expect(entry.disposition != .skippedBeforeDispatch)
            }
        }

        let compatible = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "metadata": AnyAgentToolValue(object: [
                    "mutation_dispatched": AnyAgentToolValue(bool: false),
                    "retry_safe": AnyAgentToolValue(bool: true),
                ]),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "retry_safe": AnyAgentToolValue(bool: true),
            ]))
        let compatibleClaims = AgentToolResultSemantics.normalizedClaims(from: compatible.result)
        let compatibleEntry = try #require(
            Self.execution(call: call, result: compatible).executionTrace().entries.first)
        #expect(compatibleClaims.boolean("retry_safe") == .valid(true))
        #expect(compatibleEntry.result?.objectValue?["retry_safe"]?.boolValue == true)

        let conflictingErrorPresence = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(null: ()),
                "metadata": AnyAgentToolValue(object: [
                    "error": AnyAgentToolValue(string: "nested failure"),
                ]),
            ]))
        let errorClaims = AgentToolResultSemantics.normalizedClaims(from: conflictingErrorPresence.result)
        let errorEntry = try #require(
            Self.execution(call: call, result: conflictingErrorPresence).executionTrace().entries.first)
        #expect(errorClaims.errorPresence == .invalid)
        #expect(AgentToolResultSemantics.isFailure(conflictingErrorPresence))
        #expect(errorEntry.result?.objectValue?["error_present"] == nil)

        let coupledConflict = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "meta": AnyAgentToolValue(object: [
                    "mutation_dispatched": AnyAgentToolValue(bool: false),
                    "retry_safe": AnyAgentToolValue(bool: true),
                ]),
                "mutation_dispatched": AnyAgentToolValue(bool: true),
                "retry_safe": AnyAgentToolValue(bool: true),
            ]))
        let coupledEntry = try #require(
            Self.execution(call: call, result: coupledConflict).executionTrace().entries.first)
        #expect(coupledEntry.mutationDispatch == .possiblyDispatched)
        #expect(coupledEntry.result?.objectValue?["retry_safe"] == nil)
    }

    @Test
    func `Oversized semantic strings resolve conservatively before trimming`() throws {
        let oversizedWhitespace = String(repeating: " ", count: 250_000)
        let call = AgentToolCall(id: "oversized-presence", name: "click", arguments: [:])
        let presenceResult = AgentToolResult.success(
            toolCallId: call.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(string: oversizedWhitespace),
                "reason": AnyAgentToolValue(string: oversizedWhitespace),
            ]))
        let presenceClaims = AgentToolResultSemantics.normalizedClaims(from: presenceResult.result)
        let presenceTrace = try #require(
            Self.execution(call: call, result: presenceResult).executionTrace().entries.first)
        let presenceSummary = try #require(presenceTrace.result?.objectValue)

        #expect(presenceClaims.errorPresence == .valid(true))
        #expect(presenceClaims.reasonPresence == .valid(true))
        #expect(AgentToolResultSemantics.isFailure(presenceResult))
        #expect(presenceSummary["error_present"]?.boolValue == true)
        #expect(presenceSummary["reason_present"]?.boolValue == true)
        #expect(try JSONEncoder().encode(presenceTrace).count < 1000)

        let boundaryResult = AgentToolResult.success(
            toolCallId: "oversized-boundary",
            result: AnyAgentToolValue(object: [
                "turn_boundary": AnyAgentToolValue(object: [
                    "continue_next_step": AnyAgentToolValue(bool: true),
                    "reason": AnyAgentToolValue(string: oversizedWhitespace),
                ]),
            ]))
        let service = try PeekabooAgentService(services: PeekabooServices())
        #expect(AgentToolResultSemantics.normalizedClaims(from: boundaryResult.result).turnBoundary == .invalid)
        #expect(AgentToolResultSemantics.isFailure(boundaryResult))
        #expect(service.turnBoundarySignal(from: boundaryResult) == .stopAgent(
            reason: PeekabooAgentService.invalidTurnBoundaryReason))

        let oversizedCombiningPrefix = "E" + String(repeating: "\u{0301}", count: 250_000) + "rror:"
        #expect(!AgentToolResultSemantics.valueEncodesFailure(
            AnyAgentToolValue(string: oversizedCombiningPrefix)))
        #expect(AgentToolResultSemantics.valueEncodesFailure(
            AnyAgentToolValue(string: "Error: bounded legacy failure")))
    }

    @Test
    func `Multipart MCP error message is bounded before concatenation`() throws {
        let oversized = String(repeating: "x", count: 200_000)
        let content = Array(repeating: MCP.Tool.Content.text(
            text: oversized,
            annotations: nil,
            _meta: nil), count: 64)
        let bridged = AgentToolMCPBridge.convert(ToolResponse(content: content, isError: true))
        let message = try #require(bridged.failure?.message)

        #expect(message.utf8.count < 100_100)
        #expect(message.contains("Content truncated"))
    }

    @Test
    func `Structured failure key selection bounds input width keys and output`() throws {
        let boundedFields = Dictionary(uniqueKeysWithValues: (0..<1000).map { index in
            (String(format: "key-%05d", index), Value.string("value"))
        })
        let boundedResponse = ToolResponse(
            content: [.text(text: "wide failure", annotations: nil, _meta: nil)],
            isError: true,
            structuredContent: .object(boundedFields))
        let bounded = try #require(
            AgentToolMCPBridge.convert(boundedResponse).failure?.structuredValue?.objectValue)

        #expect(bounded.count == 129)
        #expect(bounded["key-00000"]?.stringValue == "value")
        #expect(bounded["key-00127"]?.stringValue == "value")
        #expect(bounded["key-00999"] == nil)
        #expect(bounded["__peekaboo_omitted_fields"]?.intValue == 872)

        let oversizedFields = Dictionary(uniqueKeysWithValues: (0..<10000).map { index in
            (String(format: "key-%05d", index), Value.string("value"))
        })
        let oversizedResponse = ToolResponse(
            content: [.text(text: "oversized failure", annotations: nil, _meta: nil)],
            isError: true,
            structuredContent: .object(oversizedFields))
        let oversized = try #require(
            AgentToolMCPBridge.convert(oversizedResponse).failure?.structuredValue?.objectValue)

        #expect(oversized.count == 2)
        #expect(oversized["__peekaboo_omission_reason"]?.stringValue == "object_field_limit")
        #expect(oversized["__peekaboo_omitted_fields"]?.intValue == 10000)

        let collidingPrefix = String(repeating: "x", count: 512)
        let collidingFields = Dictionary(uniqueKeysWithValues: (0..<512).map { index in
            (collidingPrefix + String(format: "%04d", index), Value.string("value"))
        })
        let collidingResponse = ToolResponse(
            content: [.text(text: "colliding failure", annotations: nil, _meta: nil)],
            isError: true,
            structuredContent: .object(collidingFields))
        let colliding = try #require(
            AgentToolMCPBridge.convert(collidingResponse).failure?.structuredValue?.objectValue)
        #expect(colliding.count == 1)
        #expect(colliding["__peekaboo_omitted_fields"]?.intValue == 512)
    }

    @Test
    func `Structured keys remain distinct after the value text budget is exhausted`() throws {
        let oversized = String(repeating: "x", count: 250_000)
        let response = ToolResponse(
            content: [.text(text: "text budget failure", annotations: nil, _meta: nil)],
            isError: true,
            structuredContent: .object([
                "a-first": .string(oversized),
                "b-second": .string("second"),
                "c-third": .string("third"),
            ]))
        let structured = try #require(
            AgentToolMCPBridge.convert(response).failure?.structuredValue?.objectValue)

        #expect(structured.count == 3)
        #expect(structured["a-first"] != nil)
        #expect(structured["b-second"]?.stringValue == "<omitted-text-budget>")
        #expect(structured["c-third"]?.stringValue == "<omitted-text-budget>")
    }

    @Test
    func `Nonfinite structured failure numbers remain persistable`() throws {
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            let response = ToolResponse(
                content: [.text(text: "numeric failure", annotations: nil, _meta: nil)],
                isError: true,
                structuredContent: .double(value))
            let failure = try #require(AgentToolMCPBridge.convert(response).failure)

            #expect(failure.structuredValue?.stringValue == "<omitted-non-finite-number>")
            _ = try JSONEncoder().encode(AgentToolResult(toolCallId: "numeric", failure: failure))
        }
    }

    @Test
    func `Nonconfirmed MCP success cannot become a successful terminal observation`() async throws {
        let outcome = DesktopActionOutcome.refused(reason: .permissionDenied)
        let response = try ToolResponse.text("incorrect success", meta: Value(outcome.projection))
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tool = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            service.makeAgentTool(from: AgentFailureProbeTool(name: "see", response: response))
        }
        let call = AgentToolCall(id: "nonconfirmed-see", name: "see", arguments: [:])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [tool],
            eventHandler: nil,
            sessionId: "nonconfirmed-success",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)
        let result = try #require(step.toolResults.first)
        let trace = try #require(Self.execution(messages: messages).executionTrace().entries.first)

        #expect(result.failure == nil)
        #expect(result.isError)
        #expect(trace.disposition == .executedFailed)
        #expect(trace.actionOutcome == outcome.projection)
        #expect(context.turnBoundary.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` before the next UI action."))
    }

    @Test
    func `Contradictory and oversized canonical metadata fail closed without leaking into trace`() throws {
        let outcome = try #require(DesktopActionOutcomeFixtures.canonicalOutcomes.first)
        var contradictory = try #require(try Value(outcome.projection).toAnyAgentToolValue().objectValue)
        contradictory["retry_safe"] = AnyAgentToolValue(bool: true)
        var oversizedFields = try #require(try Self.value(outcome.projection).objectValue)
        let oversized = "a" + String(repeating: "\u{0301}", count: 125_000)
        oversizedFields["state"] = AnyAgentToolValue(string: oversized)
        let call = AgentToolCall(id: "malformed", name: "custom_outcome", arguments: [:])
        let results = [
            AgentToolResult.success(
                toolCallId: call.id,
                result: AnyAgentToolValue(object: contradictory)),
            AgentToolResult.success(
                toolCallId: call.id,
                result: AnyAgentToolValue(object: oversizedFields)),
        ]

        for result in results {
            let trace = Self.execution(call: call, result: result).executionTrace()
            let entry = try #require(trace.entries.first)
            let encoded = try JSONEncoder().encode(trace)

            #expect(AgentToolResultSemantics.isFailure(result))
            #expect(entry.disposition == .executedFailed)
            #expect(entry.isError == true)
            #expect(entry.actionOutcome == nil)
            #expect(encoded.count < 1000)
        }

        let mutatingCall = AgentToolCall(id: "invalid-click", name: "click", arguments: [:])
        let mutatingResult = AgentToolResult.success(
            toolCallId: mutatingCall.id,
            result: AnyAgentToolValue(object: contradictory))
        let mutatingEntry = try #require(
            Self.execution(call: mutatingCall, result: mutatingResult).executionTrace().entries.first)
        let summary = try #require(mutatingEntry.result?.objectValue)

        #expect(mutatingEntry.mutationDispatch == .possiblyDispatched)
        #expect(summary["mutation_dispatched"] == nil)
        #expect(summary["requires_fresh_observation"] == nil)
        #expect(summary["retry_safe"] == nil)
        #expect(summary["success"] == nil)
        #expect(summary["mutation_dispatch"]?.stringValue == "possibly_dispatched")
    }

    @Test
    func `MCP failure remains typed bounded and truthful through transcript and trace`() async throws {
        let oversized = String(repeating: "x", count: 250_000)
        let response = ToolResponse(
            content: [
                .text(text: "Target was refused before dispatch", annotations: nil, _meta: nil),
                .image(data: "AQID", mimeType: "image/png", annotations: nil, _meta: nil),
            ],
            isError: true,
            meta: .object([
                "dispatch_state": .string("none"),
                "effect": .string("refused"),
                "escalation": .string("grant_permission"),
                "evidence": .string("request_refused"),
                "mutation_dispatched": .bool(false),
                "private_payload": .string("must not cross the Agent boundary"),
                "refusal_reason": .string("permission_denied"),
                "requires_fresh_observation": .bool(false),
                "retry_safe": .bool(true),
                "retry_safety": .string("safe"),
                "route": .string("local"),
                "state": .string("refused"),
            ]),
            structuredContent: .object([
                "blob": .data(mimeType: "application/octet-stream", Data([9, 8, 7])),
                "details": .string(oversized),
            ]))
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tool = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.unrestricted) {
            service.makeAgentTool(from: AgentFailureProbeTool(response: response))
        }
        let call = AgentToolCall(id: "typed-refusal", name: "click", arguments: [:])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [tool],
            eventHandler: nil,
            sessionId: "typed-failure-session",
            executionPolicy: .unrestricted)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        let result = try #require(step.toolResults.first)
        let failure = try #require(result.failure)
        let metadata = try #require(failure.metadata?.objectValue)
        let structured = try #require(failure.structuredValue?.objectValue)
        let blob = try #require(structured["blob"]?.objectValue)
        let boundary = try #require(metadata["turn_boundary"]?.objectValue)
        let transcript = try JSONEncoder().encode(messages)
        let transcriptText = try #require(String(data: transcript, encoding: .utf8))

        #expect(result.isError)
        #expect(failure.message == "Target was refused before dispatch")
        #expect(metadata["state"]?.stringValue == "refused")
        #expect(metadata["mutation_dispatched"]?.boolValue == false)
        #expect(metadata["retry_safe"]?.boolValue == true)
        #expect(metadata["private_payload"] == nil)
        #expect(boundary["disposition"]?.stringValue == "continue_next_step")
        #expect(failure.content.count == 2)
        #expect(failure.content[1].objectValue?["attached"]?.boolValue == false)
        #expect(blob["data_omitted"]?.boolValue == true)
        #expect(blob["byte_count"]?.intValue == 3)
        #expect(try #require(structured["details"]?.stringValue).count < oversized.count)
        #expect(!transcriptText.contains("AQID"))
        #expect(!transcriptText.contains("must not cross"))

        let execution = Self.execution(messages: messages)
        let trace = try #require(execution.executionTrace().entries.first)
        let summary = try #require(trace.result?.objectValue)

        #expect(trace.disposition == .executedFailed)
        #expect(trace.isError == true)
        #expect(trace.mutationDispatch == .notDispatched)
        #expect(trace.actionOutcome?.state == .refused)
        #expect(summary["error_present"]?.boolValue == true)
        #expect(summary["mutation_dispatched"]?.boolValue == false)
        #expect(summary["retry_safe"]?.boolValue == true)
        #expect(service.turnBoundarySignal(from: result) == .continueNextStep(
            reason: "Stopped after click; call `see` before the next UI action."))
    }

    @Test
    func `Decoded typed failure cannot become a successful resumed observation`() throws {
        let call = AgentToolCall(id: "failed-see", name: "see", arguments: [:])
        let original = AgentToolResult(
            toolCallId: call.id,
            failure: AgentToolExecutionFailure(
                message: "Observation failed",
                content: [AnyAgentToolValue(string: "bounded failure")]))
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["isError"] = false
        let forged = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(AgentToolResult.self, from: forged)
        let messages = [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(decoded)]),
        ]

        let trace = try #require(Self.execution(messages: messages).executionTrace().entries.first)
        let restored = PeekabooAgentService.restoredTurnBoundary(from: messages)

        #expect(decoded.isError == false)
        #expect(decoded.failure != nil)
        #expect(AgentToolResultSemantics.isFailure(decoded))
        #expect(trace.disposition == .executedFailed)
        #expect(trace.isError == true)
        #expect(restored.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` before the next UI action."))
    }

    @Test
    func `Agent policy refusal is typed and traced as skipped before dispatch`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let call = AgentToolCall(
            id: "policy-refusal",
            name: "press",
            arguments: ["keys": AnyAgentToolValue(array: [AnyAgentToolValue(string: "cmd+a")])])
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [],
            eventHandler: nil,
            sessionId: "policy-refusal-session",
            executionPolicy: .backgroundOnly)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [call],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)
        let result = try #require(step.toolResults.first)
        let metadata = try #require(result.failure?.metadata?.objectValue)
        let trace = try #require(Self.execution(messages: messages).executionTrace().entries.first)

        #expect(result.failure != nil)
        #expect(metadata["skipped"]?.boolValue == true)
        #expect(metadata["mutation_dispatched"]?.boolValue == false)
        #expect(metadata["retry_safe"]?.boolValue == true)
        #expect(trace.disposition == .skippedBeforeDispatch)
        #expect(trace.mutationDispatch == .notDispatched)
        #expect(trace.actionOutcome?.state == .refused)
        #expect(trace.result?.objectValue?["skipped"]?.boolValue == true)
    }

    private static func execution(messages: [ModelMessage]) -> AgentExecutionResult {
        AgentExecutionResult(
            content: "",
            messages: messages,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))
    }

    private static func execution(
        call: AgentToolCall,
        result: AgentToolResult) -> AgentExecutionResult
    {
        self.execution(messages: [
            ModelMessage(role: .assistant, content: [.toolCall(call)]),
            ModelMessage(role: .tool, content: [.toolResult(result)]),
        ])
    }

    private static func value(_ projection: DesktopActionOutcome.Projection) throws -> AnyAgentToolValue {
        let data = try JSONEncoder().encode(projection)
        return try AnyAgentToolValue.fromJSON(JSONSerialization.jsonObject(with: data))
    }
}

private struct AgentFailureProbeTool: MCPTool {
    let name: String
    let description = "Returns a deterministic typed error"
    let response: ToolResponse

    init(name: String = "click", response: ToolResponse) {
        self.name = name
        self.response = response
    }

    var inputSchema: Value {
        SchemaBuilder.object(properties: [:], required: [])
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        self.response
    }
}
