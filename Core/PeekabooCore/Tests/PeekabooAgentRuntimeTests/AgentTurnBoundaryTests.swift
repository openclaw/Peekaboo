import Foundation
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct AgentTurnBoundaryTests {
    @Test
    func `perceive followed by action continues at next provider step`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")

        let decision = boundary.record(toolName: "click")

        guard case let .continueNextStep(reason) = decision else {
            Issue.record("Expected action after perceive to end only the provider step")
            return
        }
        #expect(reason.contains("click"))
        #expect(reason.contains("see"))
    }

    @Test
    func `first action before perception ends the provider step`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` before the next UI action."))
        #expect(boundary.record(toolName: "type") == .skipUntilPerception(
            reason: "Skipped type; call `see` successfully before another UI action."))
    }

    @Test
    func `hyphenated tool names normalize before classification`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: " image ") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: " image ")

        let decision = boundary.record(toolName: "set-value")

        guard case let .continueNextStep(reason) = decision else {
            Issue.record("Expected normalized action name to end the provider step")
            return
        }
        #expect(reason.contains("set_value"))
    }

    @Test
    func `completion tools stop after successful execution`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(
            toolName: "done",
            arguments: ["message": AnyAgentToolValue(string: "Finished export")]) ==
            .stopAgentAfterSuccessfulTool(reason: "Finished export"))
        #expect(boundary.record(
            toolName: "need-info",
            arguments: ["question": AnyAgentToolValue(string: "Which account?")]) ==
            .stopAgentAfterSuccessfulTool(reason: "Need more information: Which account?"))
    }

    @Test
    func `non UI and invalid completion tools do not stop after perceive`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "watch") == .continueTurn)
        #expect(boundary.record(toolName: "sleep") == .continueTurn)
        #expect(boundary.record(toolName: "need_info", arguments: [:]) == .continueTurn)
    }

    @Test
    func `read-only compound tool actions do not stop after perceive`() {
        let readOnlyCalls: [(name: String, action: String)] = [
            ("app", "list"),
            ("dialog", "list"),
            ("dock", "list"),
            ("menu", "list"),
            ("space", "list"),
        ]

        for call in readOnlyCalls {
            let boundary = AgentTurnBoundary()
            #expect(boundary.record(toolName: "see") == .continueTurn)
            boundary.recordSuccessfulCompletion(toolName: "see")
            #expect(boundary.record(
                toolName: call.name,
                arguments: ["action": AnyAgentToolValue(string: call.action)]) == .continueTurn)
        }
    }

    @Test
    func `mutating compound tool actions continue at next provider step`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")

        let decision = boundary.record(
            toolName: "menu",
            arguments: ["action": AnyAgentToolValue(string: "click")])

        guard case let .continueNextStep(reason) = decision else {
            Issue.record("Expected mutating compound action to end the provider step")
            return
        }
        #expect(reason.contains("menu"))
    }

    @Test
    func `perception resets after each mutation boundary`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")
        #expect(boundary.record(toolName: "type") == .continueNextStep(
            reason: "Stopped after type; call `see` again before the next UI action."))
        #expect(boundary.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")
        #expect(boundary.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` again before the next UI action."))
    }

    @Test
    func `validated browser outcome creates fresh perception debt after dispatch`() throws {
        let boundary = AgentTurnBoundary()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted)

        #expect(boundary.record(
            toolName: "browser",
            arguments: ["action": AnyAgentToolValue(string: "click")]) == .continueTurn)
        #expect(try boundary.recordResult(
            toolName: "browser",
            result: Self.canonicalResult(outcome)) == .continueNextStep(
            reason: "Stopped after browser; call `see` before the next UI action."))
        #expect(boundary.requiresFreshPerception)
        #expect(boundary.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    @Test
    func `foreground browser connect outcome creates fresh perception debt`() throws {
        let boundary = AgentTurnBoundary()
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(boundary.record(
            toolName: "browser",
            arguments: ["action": AnyAgentToolValue(string: "connect")]) == .continueTurn)
        #expect(try boundary.recordResult(
            toolName: "browser",
            result: Self.canonicalResult(outcome)) == .continueNextStep(
            reason: "Stopped after browser; call `see` before the next UI action."))
        #expect(boundary.requiresFreshPerception)
    }

    @Test
    func `browser read without mutation outcome does not create fresh perception debt`() {
        let boundary = AgentTurnBoundary()
        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")

        #expect(boundary.record(
            toolName: "browser",
            arguments: ["action": AnyAgentToolValue(string: "list_pages")]) == .continueTurn)
        #expect(boundary.recordResult(
            toolName: "browser",
            result: AnyAgentToolValue(object: [
                "content": AnyAgentToolValue(string: "page list"),
            ])) == .continueTurn)
        #expect(!boundary.requiresFreshPerception)
        #expect(boundary.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` again before the next UI action."))
    }

    @Test
    func `zero dispatch browser refusal does not create fresh perception debt`() throws {
        let boundary = AgentTurnBoundary()
        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)

        #expect(try boundary.recordResult(
            toolName: "browser",
            result: Self.canonicalResult(refusal)) == .continueTurn)
        #expect(!boundary.requiresFreshPerception)
        #expect(boundary.record(toolName: "done") == .stopAgentAfterSuccessfulTool(
            reason: "Task completed successfully."))
    }

    @Test
    func `conditional app launch derives perception debt only from a dispatched canonical outcome`() throws {
        let noOpBoundary = AgentTurnBoundary()
        let launchArguments = [
            "action": AnyAgentToolValue(string: "launch"),
            "name": AnyAgentToolValue(string: "TextEdit"),
        ]

        #expect(noOpBoundary.record(toolName: "app", arguments: launchArguments) == .continueTurn)
        #expect(try noOpBoundary.recordResult(
            toolName: "app",
            result: Self.canonicalResult(.confirmedNoChange(route: .bridge))) == .continueTurn)
        #expect(!noOpBoundary.requiresFreshPerception)
        #expect(noOpBoundary.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` before the next UI action."))

        let dispatchedBoundary = AgentTurnBoundary()
        let indeterminate = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)

        #expect(dispatchedBoundary.record(toolName: "app", arguments: launchArguments) == .continueTurn)
        #expect(try dispatchedBoundary.recordResult(
            toolName: "app",
            result: Self.canonicalResult(indeterminate)) == .continueNextStep(
            reason: "Stopped after app; call `see` before the next UI action."))
        #expect(dispatchedBoundary.requiresFreshPerception)
    }

    @Test
    func `legacy browser metadata remains compatible and cannot create canonical perception debt`() {
        let boundary = AgentTurnBoundary()
        let legacy = AnyAgentToolValue(object: [
            "mutation_dispatched": AnyAgentToolValue(bool: true),
            "requires_fresh_observation": AnyAgentToolValue(bool: true),
            "retry_safe": AnyAgentToolValue(bool: false),
        ])

        #expect(boundary.recordResult(toolName: "browser", result: legacy) == .continueTurn)
        #expect(!boundary.requiresFreshPerception)
    }

    @Test
    func `successful inspect UI satisfies fresh perception sequencing`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")
        #expect(boundary.record(toolName: "type") == .continueNextStep(
            reason: "Stopped after type; call `see` again before the next UI action."))
        #expect(boundary.record(toolName: "inspect_ui") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "inspect_ui")
        #expect(boundary.record(toolName: "click") == .continueNextStep(
            reason: "Stopped after click; call `see` again before the next UI action."))
    }

    @Test
    func `failed fresh perception does not rearm mutation`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see")
        #expect(boundary.record(toolName: "type") == .continueNextStep(
            reason: "Stopped after type; call `see` again before the next UI action."))
        #expect(boundary.record(toolName: "see") == .continueTurn)
        #expect(boundary.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    @Test
    func `Incomplete text-only perception blocks completion until exact verification`() {
        let boundary = AgentTurnBoundary()
        let incompleteSee = AnyAgentToolValue(string: AgentToolMCPBridge.incompleteVisualEvidenceMarker)
        let observationTarget: [String: AnyAgentToolValue] = [
            "app_target": AnyAgentToolValue(string: "PID:42"),
            "window_id": AnyAgentToolValue(int: 7),
        ]
        let verificationTarget: [String: AnyAgentToolValue] = [
            "pid": AnyAgentToolValue(int: 42),
            "window_id": AnyAgentToolValue(int: 7),
        ]

        #expect(boundary.record(toolName: "see", arguments: observationTarget) == .continueTurn)
        boundary.recordSuccessfulCompletion(toolName: "see", arguments: observationTarget)
        #expect(boundary.record(toolName: "type") == .continueNextStep(
            reason: "Stopped after type; call `see` again before the next UI action."))
        #expect(boundary.record(toolName: "see", arguments: observationTarget) == .continueTurn)
        boundary.recordSuccessfulCompletion(
            toolName: "see",
            arguments: observationTarget,
            result: incompleteSee)

        guard case let .skipUntilCompletionEvidence(reason) = boundary.record(toolName: "done") else {
            Issue.record("Expected incomplete text-only evidence to block completion")
            return
        }
        #expect(reason.contains("verify_state"))
        #expect(reason.contains("do not claim"))

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "unknown",
                pid: 42,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "unknown")))
        #expect(boundary.completionEvidenceIssue != nil)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "unsatisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "unsatisfied")))
        #expect(boundary.completionEvidenceIssue?.contains("unsatisfied") == true)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: [
                "pid": AnyAgentToolValue(int: 99),
                "window_id": AnyAgentToolValue(int: 7),
            ],
            result: Self.verificationResult(
                status: "satisfied",
                pid: 99,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "satisfied")))
        #expect(boundary.completionEvidenceIssue?.contains("same app/PID") == true)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "satisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.windowExistsPredicate(status: "satisfied")))
        #expect(boundary.completionEvidenceIssue?.contains("different native predicate") == true)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "satisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "satisfied")))
        #expect(boundary.completionEvidenceIssue == nil)
        #expect(boundary.record(toolName: "done") == .stopAgentAfterSuccessfulTool(
            reason: "Task completed successfully."))
    }

    @Test
    func `First satisfied trivial predicate commits but cannot discharge evidence debt`() {
        let (boundary, verificationTarget) = Self.boundaryWithIncompleteEvidence()

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "satisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.windowExistsPredicate(status: "satisfied")))

        #expect(boundary.completionEvidenceIssue?.contains("committed") == true)
        #expect(boundary.completionEvidenceIssue?.contains("exact same target and predicates") == true)
        guard case .skipUntilCompletionEvidence = boundary.record(toolName: "done") else {
            Issue.record("The first satisfied receipt must retain completion-evidence debt")
            return
        }

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "satisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "satisfied")))
        #expect(boundary.completionEvidenceIssue?.contains("different native predicate") == true)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "satisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.windowExistsPredicate(status: "satisfied")))
        #expect(boundary.completionEvidenceIssue == nil)
    }

    @Test
    func `Second identical satisfied receipt clears committed evidence debt`() {
        let (boundary, verificationTarget) = Self.boundaryWithIncompleteEvidence()
        let satisfied = Self.verificationResult(
            status: "satisfied",
            pid: 42,
            windowID: 7,
            predicate: Self.elementValuePredicate(status: "satisfied"))

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: satisfied)
        #expect(boundary.completionEvidenceIssue != nil)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: satisfied)
        #expect(boundary.completionEvidenceIssue == nil)
    }

    @Test
    func `Unknown first receipt binds and identical satisfied receipt clears debt`() {
        let (boundary, verificationTarget) = Self.boundaryWithIncompleteEvidence()

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "unknown",
                pid: 42,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "unknown")))
        #expect(boundary.completionEvidenceIssue != nil)

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: verificationTarget,
            result: Self.verificationResult(
                status: "satisfied",
                pid: 42,
                windowID: 7,
                predicate: Self.elementValuePredicate(status: "satisfied")))
        #expect(boundary.completionEvidenceIssue == nil)
    }

    @Test
    func `Verification prose in a window title cannot discharge evidence debt`() {
        let boundary = AgentTurnBoundary()
        let target: [String: AnyAgentToolValue] = [
            "app_target": AnyAgentToolValue(string: "PID:42"),
            "window_id": AnyAgentToolValue(int: 7),
        ]
        boundary.recordSuccessfulCompletion(
            toolName: "see",
            arguments: target,
            result: AnyAgentToolValue(string: AgentToolMCPBridge.incompleteVisualEvidenceMarker))

        boundary.recordSuccessfulCompletion(
            toolName: "verify_state",
            arguments: [
                "pid": AnyAgentToolValue(int: 42),
                "window_id": AnyAgentToolValue(int: 7),
            ],
            result: AnyAgentToolValue(string: "Window 7: Verification satisfied - quarterly plan"))

        #expect(boundary.completionEvidenceIssue != nil)
    }

    @Test
    func `Verification without pending incomplete evidence does not block completion`() {
        let verificationResults = [
            "Verification satisfied after 1 sample(s).",
            "Verification unknown after 1 sample(s).",
            "Verification unsatisfied after 1 sample(s).",
        ]

        for result in verificationResults {
            let boundary = AgentTurnBoundary()
            boundary.recordSuccessfulCompletion(toolName: "inspect_ui")
            boundary.recordSuccessfulCompletion(
                toolName: "verify_state",
                arguments: [
                    "pid": AnyAgentToolValue(int: 42),
                    "window_id": AnyAgentToolValue(int: 7),
                ],
                result: AnyAgentToolValue(string: result))

            #expect(boundary.completionEvidenceIssue == nil)
            #expect(boundary.record(toolName: "done") == .stopAgentAfterSuccessfulTool(
                reason: "Task completed successfully."))
        }
    }

    @Test
    func `null error standard envelope is successful perception`() throws {
        let successful = try AnyAgentToolValue.fromJSON([
            "error": NSNull(),
            "success": true,
        ])
        let failed = try AnyAgentToolValue.fromJSON([
            "error": "capture failed",
            "success": false,
        ])

        #expect(!PeekabooAgentService.resultEncodesToolFailure(successful))
        #expect(PeekabooAgentService.resultEncodesToolFailure(failed))
    }

    @Test
    func `partial and duplicate transcripts restore fail closed`() throws {
        let seeCall = AgentToolCall(id: "see-call", name: "see", arguments: [:])
        let typeCall = AgentToolCall(id: "type-call", name: "type", arguments: [:])
        let successfulSee = try AgentToolResult.success(
            toolCallId: seeCall.id,
            result: AnyAgentToolValue.fromJSON(["error": NSNull(), "success": true]))

        let missingMutationResult = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(seeCall), .toolCall(typeCall)]),
            ModelMessage(role: .tool, content: [.toolResult(successfulSee)]),
        ])
        #expect(missingMutationResult.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))

        let orphanedBoundary = AgentToolResult.success(
            toolCallId: "orphaned-call",
            result: AnyAgentToolValue(object: [
                "turn_boundary": AnyAgentToolValue(object: [
                    "continue_next_step": AnyAgentToolValue(bool: true),
                    "disposition": AnyAgentToolValue(string: "continue_next_step"),
                    "reason": AnyAgentToolValue(string: "Fresh perception required"),
                ]),
            ]))
        let unmatchedResult = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .tool, content: [.toolResult(orphanedBoundary)]),
        ])
        #expect(unmatchedResult.record(toolName: "type") == .skipUntilPerception(
            reason: "Skipped type; call `see` successfully before another UI action."))

        let successfulType = AgentToolResult.success(
            toolCallId: typeCall.id,
            result: AnyAgentToolValue(object: [
                "turn_boundary": AnyAgentToolValue(object: [
                    "continue_next_step": AnyAgentToolValue(bool: true),
                    "reason": AnyAgentToolValue(string: "Mutation completed"),
                ]),
            ]))
        let duplicatePerception = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(seeCall), .toolCall(typeCall)]),
            ModelMessage(role: .tool, content: [.toolResult(successfulSee)]),
            ModelMessage(role: .tool, content: [.toolResult(successfulType)]),
            ModelMessage(role: .tool, content: [.toolResult(successfulSee)]),
        ])
        #expect(duplicatePerception.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    @Test
    func `restored transcript preserves incomplete completion evidence`() {
        let seeCall = AgentToolCall(id: "see-call", name: "see", arguments: [
            "app_target": AnyAgentToolValue(string: "PID:42"),
            "window_id": AnyAgentToolValue(int: 7),
        ])
        let incompleteSee = AgentToolResult.success(
            toolCallId: seeCall.id,
            result: AnyAgentToolValue(string: AgentToolMCPBridge.incompleteVisualEvidenceMarker))

        let boundary = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(seeCall)]),
            ModelMessage(role: .tool, content: [.toolResult(incompleteSee)]),
        ])

        guard case let .skipUntilCompletionEvidence(reason) = boundary.record(toolName: "done") else {
            Issue.record("Expected restored incomplete evidence to block completion")
            return
        }
        #expect(reason.contains("verify_state"))
    }

    @Test
    func `restored transcript requires perception after an initial mutation`() {
        let typeCall = AgentToolCall(id: "type-call", name: "type", arguments: [:])
        let successfulType = AgentToolResult.success(
            toolCallId: typeCall.id,
            result: AnyAgentToolValue(string: "typed"))

        let boundary = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(typeCall)]),
            ModelMessage(role: .tool, content: [.toolResult(successfulType)]),
        ])

        #expect(boundary.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    @Test
    func `restored transcript derives browser perception debt from canonical outcome`() throws {
        let browserCall = AgentToolCall(id: "browser-call", name: "browser", arguments: [
            "action": AnyAgentToolValue(string: "click"),
        ])
        let outcome = DesktopActionOutcome.indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown)
        let browserResult = try AgentToolResult.success(
            toolCallId: browserCall.id,
            result: Self.canonicalResult(outcome))

        let boundary = PeekabooAgentService.restoredTurnBoundary(from: [
            ModelMessage(role: .assistant, content: [.toolCall(browserCall)]),
            ModelMessage(role: .tool, content: [.toolResult(browserResult)]),
        ])

        #expect(boundary.record(toolName: "click") == .skipUntilPerception(
            reason: "Skipped click; call `see` successfully before another UI action."))
    }

    private static func verificationResult(
        status: String,
        pid: Int,
        windowID: Int,
        predicate: AnyAgentToolValue) -> AnyAgentToolValue
    {
        AnyAgentToolValue(object: [
            "content": AnyAgentToolValue(string: "Window title may contain arbitrary prose"),
            "verification_receipt": AnyAgentToolValue(object: [
                "status": AnyAgentToolValue(string: status),
                "target": AnyAgentToolValue(object: [
                    "pid": AnyAgentToolValue(int: pid),
                    "window_id": AnyAgentToolValue(int: windowID),
                ]),
                "predicates": AnyAgentToolValue(array: [predicate]),
            ]),
        ])
    }

    private static func canonicalResult(_ outcome: DesktopActionOutcome) throws -> AnyAgentToolValue {
        let data = try JSONEncoder().encode(outcome.projection)
        return try AnyAgentToolValue.fromJSON(JSONSerialization.jsonObject(with: data))
    }

    private static func boundaryWithIncompleteEvidence() -> (
        boundary: AgentTurnBoundary,
        verificationTarget: [String: AnyAgentToolValue])
    {
        let boundary = AgentTurnBoundary()
        boundary.recordSuccessfulCompletion(
            toolName: "see",
            arguments: [
                "app_target": AnyAgentToolValue(string: "PID:42"),
                "window_id": AnyAgentToolValue(int: 7),
            ],
            result: AnyAgentToolValue(string: AgentToolMCPBridge.incompleteVisualEvidenceMarker))
        return (boundary, [
            "pid": AnyAgentToolValue(int: 42),
            "window_id": AnyAgentToolValue(int: 7),
        ])
    }

    private static func elementValuePredicate(status: String) -> AnyAgentToolValue {
        AnyAgentToolValue(object: [
            "kind": AnyAgentToolValue(string: "element_value"),
            "selector": AnyAgentToolValue(object: [
                "identifier": AnyAgentToolValue(string: "total-field"),
            ]),
            "expected_value": AnyAgentToolValue(string: "42"),
            "status": AnyAgentToolValue(string: status),
        ])
    }

    private static func windowExistsPredicate(status: String) -> AnyAgentToolValue {
        AnyAgentToolValue(object: [
            "kind": AnyAgentToolValue(string: "window_exists"),
            "expected": AnyAgentToolValue(bool: true),
            "status": AnyAgentToolValue(string: status),
        ])
    }
}
