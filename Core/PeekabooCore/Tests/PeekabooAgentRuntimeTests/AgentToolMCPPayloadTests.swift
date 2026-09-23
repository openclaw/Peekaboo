import Foundation
import MCP
import PeekabooFoundation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct AgentToolMCPPayloadTests {
    @Test
    func `Resource text and native metadata content survive alias removal`() throws {
        let resourceText = #"{"text":"resource text","content":{"text":"nested text"}}"#
        let response = ToolResponse(
            content: [.resource(resource: .text(
                resourceText,
                uri: "https://example.com/fixture",
                mimeType: "application/json"))],
            meta: .object([
                "details": .object([
                    "text": .string("native metadata text"),
                    "content": .object(["text": .string("native nested content")]),
                ]),
            ]))

        let bridged = AgentToolMCPBridge.convert(response)
        let payload = try #require(bridged.value.objectValue)
        let resource = try #require(payload["result"]?.objectValue)
        let details = try #require(payload["meta"]?.objectValue?["details"]?.objectValue)

        #expect(resource["type"]?.stringValue == "resource")
        #expect(resource["uri"]?.stringValue == "https://example.com/fixture")
        #expect(resource["mime_type"]?.stringValue == "application/json")
        #expect(resource["text"]?.stringValue == resourceText)
        #expect(details["text"]?.stringValue == "native metadata text")
        #expect(details["content"]?.objectValue?["text"]?.stringValue == "native nested content")
        #expect(payload["text"] == nil)
        #expect(payload["content"] == nil)
        #expect(bridged.failure == nil)
    }

    @Test
    func `Multiple text parts retain order and native metadata arrays`() throws {
        let parts = ["first observation", "", "last observation"]
        let response = ToolResponse(
            content: parts.map { .text(text: $0, annotations: nil, _meta: nil) },
            meta: .object([
                "content": .array([.object(["text": .string("native array entry")])]),
            ]))

        let payload = try #require(AgentToolMCPBridge.convert(response).value.objectValue)

        #expect(payload["result"]?.arrayValue?.count == parts.count)
        #expect(payload["result"]?.arrayValue?.compactMap(\.stringValue) == parts)
        #expect(payload["meta"]?.objectValue?["content"]?.arrayValue?.first?
            .objectValue?["text"]?.stringValue == "native array entry")
        #expect(payload["text"] == nil)
        #expect(payload["content"] == nil)
    }

    @Test
    func `Error payload retains structured content and safe failure metadata`() throws {
        let response = ToolResponse(
            content: [
                .text(text: "Native action failed", annotations: nil, _meta: nil),
                .resource(resource: .text("Failure detail", uri: "https://example.com/failure")),
            ],
            isError: true,
            meta: .object([
                "error_code": .string("NATIVE_ACTION_FAILED"),
                "mutation_dispatched": .bool(true),
                "retry_safe": .bool(false),
                "private_diagnostic": .string("not an agent safety field"),
            ]),
            structuredContent: .object([
                "text": .string("structured failure"),
                "content": .object(["text": .string("nested failure detail")]),
            ]))

        let bridged = AgentToolMCPBridge.convert(response)
        let failure = try #require(bridged.failure)
        let storedFailure = try #require(failure.resultValue.objectValue)

        #expect(failure.message == "Native action failed\nFailure detail")
        #expect(failure.content.count == 2)
        #expect(failure.content.first?.stringValue == "Native action failed")
        #expect(failure.content.last?.objectValue?["text"]?.stringValue == "Failure detail")
        #expect(failure.structuredValue?.objectValue?["text"]?.stringValue == "structured failure")
        #expect(failure.structuredValue?.objectValue?["content"]?.objectValue?["text"]?.stringValue ==
            "nested failure detail")
        #expect(failure.metadata?.objectValue?["error_code"]?.stringValue == "NATIVE_ACTION_FAILED")
        #expect(failure.metadata?.objectValue?["mutation_dispatched"]?.boolValue == true)
        #expect(failure.metadata?.objectValue?["retry_safe"]?.boolValue == false)
        #expect(failure.metadata?.objectValue?["private_diagnostic"] == nil)
        #expect(storedFailure["content"]?.arrayValue == failure.content)
        #expect(storedFailure["structuredValue"] == failure.structuredValue)
        #expect(storedFailure["metadata"] == failure.metadata)
        #expect(AgentToolResultSemantics.valueEncodesFailure(bridged.value))
        #expect(throws: failure) { try bridged.executionValue() }
    }

    @Test(arguments: [false, true])
    func `Unconfirmed action outcomes retain root and metadata safety crosschecks`(_ partial: Bool) throws {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .background)
        let outcome: DesktopActionOutcome = partial
            ? .partial(delivery: delivery)
            : .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted)
        let response = try ToolResponse.text(
            "Native action was dispatched",
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: ["target_identity": .object(["pid": .int(42), "window_id": .int(7)])],
                outcome: outcome))
        let bridged = AgentToolMCPBridge.convert(response)
        var payload = try #require(bridged.value.objectValue)
        let metadata = try #require(payload["meta"]?.objectValue)

        for key in MCPToolResponseMetadataProjector.actionOutcomeKeys where metadata[key] != nil {
            #expect(payload[key] == metadata[key])
        }
        #expect(payload["target_identity"] == metadata["target_identity"])
        #expect(payload["result"]?.stringValue == "Native action was dispatched")
        #expect(payload["text"] == nil)
        #expect(payload["content"] == nil)
        #expect(AgentToolResultSemantics.actionOutcomeResolution(from: bridged.value).projection == outcome.projection)
        #expect(AgentToolResultSemantics.valueEncodesFailure(bridged.value))

        payload["retry_safe"] = AnyAgentToolValue(bool: true)
        let conflictingValue = AnyAgentToolValue(object: payload)
        if case .invalid = AgentToolResultSemantics.actionOutcomeResolution(from: conflictingValue) {
            #expect(AgentToolResultSemantics.valueEncodesFailure(conflictingValue))
        } else {
            Issue.record("A conflicting promoted safety claim must fail closed")
        }
    }

    @Test
    func `Previously saved aliases remain readable without a history migration`() throws {
        let text = "Saved native action result"
        let legacyValue = AnyAgentToolValue(object: [
            "result": AnyAgentToolValue(string: text),
            "text": AnyAgentToolValue(string: text),
            "content": AnyAgentToolValue(string: text),
            "mutation_dispatched": AnyAgentToolValue(bool: true),
            "retry_safe": AnyAgentToolValue(bool: false),
            "meta": AnyAgentToolValue(object: [
                "mutation_dispatched": AnyAgentToolValue(bool: true),
                "retry_safe": AnyAgentToolValue(bool: false),
                "summary": AnyAgentToolValue(object: ["notes": AnyAgentToolValue(string: "saved summary")]),
            ]),
        ])
        let savedResult = AgentToolResult.success(toolCallId: "legacy-call", result: legacyValue)
        let decoded = try JSONDecoder().decode(
            AgentToolResult.self,
            from: JSONEncoder().encode(savedResult))
        let payload = try #require(try decoded.result.toJSON() as? [String: Any])
        let claims = AgentToolResultSemantics.normalizedClaims(from: decoded.result)

        #expect(decoded == savedResult)
        #expect(payload["text"] as? String == text)
        #expect(payload["content"] as? String == text)
        #expect(claims.boolean("mutation_dispatched") == .valid(true))
        #expect(claims.boolean("retry_safe") == .valid(false))
        #expect(!claims.hasInvalidClaim)
        #expect(ToolEventSummary.from(resultJSON: payload)?.notes == "saved summary")
    }
}
