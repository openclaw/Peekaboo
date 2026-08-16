import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooCLI

struct MCPToolCommandOutputTests {
    @Test
    func `Browser CLI envelope projects canonical failure and exact target metadata`() throws {
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .responseLost,
            unitCount: .one
        )
        let targetReceipt = DesktopActionTargetReceipt(
            processIdentifier: 4242,
            processStartIdentity: 9_007_199_254_740_993,
            windowID: 73
        )
        var metadata = try #require(try Value(outcome.projection).objectValue)
        metadata["target_identity"] = .object([
            "kind": .string("window"),
            "pid": .int(4242),
            "process_start_identity_decimal": .string("9007199254740993"),
            "window_id": .int(73),
        ])
        metadata["target_receipt"] = try Value(targetReceipt)
        let response = ToolResponse.error(
            "Browser response was lost. Observe the page before retrying.",
            meta: .object(metadata)
        )

        let envelope = MCPToolCommandOutput.envelope(tool: "browser", response: response)

        #expect(!envelope.success)
        #expect(envelope.effect == outcome.effect)
        #expect(envelope.outcome == outcome.projection)
        #expect(envelope.target_identity?.kind == .window)
        #expect(envelope.target_identity?.pid == 4242)
        #expect(envelope.target_identity?.process_start_identity_decimal == "9007199254740993")
        #expect(envelope.target_identity?.window_id == 73)
        #expect(envelope.target_receipt == targetReceipt)
        #expect(envelope.error?.code == "INTERACTION_FAILED")
        #expect(envelope.error?.retry_safe == false)
        #expect(envelope.error?.mutation_dispatched == true)
        #expect(envelope.data.meta == response.meta)
    }

    @Test
    func `Browser CLI envelope preserves policy refusal code`() throws {
        let outcome = DesktopActionOutcome.refused(reason: .foregroundConsentRequired)
        var metadata = try #require(try Value(outcome.projection).objectValue)
        metadata["error_code"] = .string("AGENT_EXECUTION_POLICY_REFUSAL")
        let response = ToolResponse.error(
            "Browser connect requires explicit foreground authority.",
            meta: .object(metadata)
        )

        let envelope = MCPToolCommandOutput.envelope(tool: "browser", response: response)

        #expect(envelope.outcome == outcome.projection)
        #expect(envelope.effect == .refused)
        #expect(envelope.error?.code == "AGENT_EXECUTION_POLICY_REFUSAL")
        #expect(envelope.error?.retry_safe == true)
        #expect(envelope.error?.mutation_dispatched == false)
    }

    @Test
    func `Browser CLI envelope keeps validation code for noncanonical errors`() {
        let response = ToolResponse.error("Unsupported browser action")

        let envelope = MCPToolCommandOutput.envelope(tool: "browser", response: response)

        #expect(envelope.outcome == nil)
        #expect(envelope.effect == nil)
        #expect(envelope.error?.code == "VALIDATION_ERROR")
        #expect(envelope.error?.retry_safe == nil)
        #expect(envelope.error?.mutation_dispatched == nil)
    }
}
