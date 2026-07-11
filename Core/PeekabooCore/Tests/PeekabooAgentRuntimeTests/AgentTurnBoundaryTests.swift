import Tachikoma
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct AgentTurnBoundaryTests {
    @Test
    func `perceive followed by action stops after current step`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)

        let decision = boundary.record(toolName: "click")

        guard case let .stopAfterCurrentStep(reason) = decision else {
            Issue.record("Expected action after perceive to stop the turn")
            return
        }
        #expect(reason.contains("click"))
        #expect(reason.contains("see"))
    }

    @Test
    func `action before perceive does not stop`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "click") == .continueTurn)
        #expect(boundary.record(toolName: "type") == .continueTurn)
    }

    @Test
    func `hyphenated tool names normalize before classification`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: " image ") == .continueTurn)

        let decision = boundary.record(toolName: "set-value")

        guard case let .stopAfterCurrentStep(reason) = decision else {
            Issue.record("Expected normalized action name to stop the turn")
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
            .stopAfterSuccessfulTool(reason: "Finished export"))
        #expect(boundary.record(
            toolName: "need-info",
            arguments: ["question": AnyAgentToolValue(string: "Which account?")]) ==
            .stopAfterSuccessfulTool(reason: "Need more information: Which account?"))
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
            ("menu", "list-all"),
            ("space", "list"),
        ]

        for call in readOnlyCalls {
            let boundary = AgentTurnBoundary()
            #expect(boundary.record(toolName: "see") == .continueTurn)
            #expect(boundary.record(
                toolName: call.name,
                arguments: ["action": AnyAgentToolValue(string: call.action)]) == .continueTurn)
        }
    }

    @Test
    func `mutating compound tool actions stop after perceive`() {
        let boundary = AgentTurnBoundary()

        #expect(boundary.record(toolName: "see") == .continueTurn)

        let decision = boundary.record(
            toolName: "menu",
            arguments: ["action": AnyAgentToolValue(string: "click")])

        guard case let .stopAfterCurrentStep(reason) = decision else {
            Issue.record("Expected mutating compound action to stop the turn")
            return
        }
        #expect(reason.contains("menu"))
    }
}
