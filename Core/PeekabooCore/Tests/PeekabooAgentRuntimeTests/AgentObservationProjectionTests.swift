import Foundation
import MCP
import PeekabooAutomation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct AgentObservationProjectionTests {
    @Test(arguments: ["see", "inspect_ui"])
    func `Only the proven listing changes in a provider copy`(_ toolName: String) throws {
        let fixture = try ObservationProjectionFixture(toolName: toolName)
        let messages = fixture.messages()
        let originalBytes = try Self.encoded(messages)
        let projected = AgentToolMCPBridge.providerContextMessages(messages)
        let result = try Self.result(in: projected)
        let object = try #require(result.result.objectValue)
        let text = try #require(object["result"]?.stringValue)

        #expect(text == fixture.header + "\n\nUI Elements: see meta.ui_elements (canonical element table).\n\n" +
            fixture.footer)
        #expect(object.filter { $0.key != "result" } == fixture.payload.filter { $0.key != "result" })
        #expect(result.toolCallId == "observation-call")
        #expect(!result.isError)
        #expect(result.failure == nil)
        #expect(projected[0] == messages[0])
        #expect(projected[1].id == messages[1].id)
        #expect(projected[1].role == messages[1].role)
        #expect(projected[1].timestamp == messages[1].timestamp)
        #expect(projected[1].channel == messages[1].channel)
        #expect(projected[1].metadata == messages[1].metadata)
        #expect(try Self.encoded(messages) == originalBytes)
        #expect(AgentToolMCPBridge.providerContextMessages(projected) == projected)

        let originalPayloadBytes = try Self.jsonBytes(AnyAgentToolValue(object: fixture.payload))
        let projectedPayloadBytes = try Self.jsonBytes(result.result)
        let removedTextBytes = fixture.text.utf8.count - text.utf8.count
        #expect(removedTextBytes > 0)
        #expect(originalPayloadBytes.count > projectedPayloadBytes.count)
        // Escaped JSON size is measured separately from source string bytes, never reported as tokens.
        let oldStringBytes = try Self.jsonBytes(AnyAgentToolValue(string: fixture.text))
        let newStringBytes = try Self.jsonBytes(AnyAgentToolValue(string: text))
        #expect(originalPayloadBytes.count - projectedPayloadBytes.count == oldStringBytes.count - newStringBytes.count)
    }

    @Test(arguments: ["see", "inspect_ui"])
    func `Representative observations have deterministic provider payload byte reductions`(_ toolName: String) throws {
        let fixture = try ObservationProjectionFixture(
            toolName: toolName, detectedElements: ObservationMeasurementElements.make())
        let response = ToolResponse.text(fixture.text, meta: Value.from(fixture.metadataJSON))
        let bridgeValue = AgentToolMCPBridge.convert(response).value
        let bridgePayload = try #require(bridgeValue.objectValue)
        let messages = fixture.messages(payload: bridgePayload)
        let rawContent = try Self.encoded(response.content)
        let rawMetadata = try Self.encoded(response.meta)
        let history = try Self.encoded(messages)
        let original = try Self.encoded(bridgeValue)

        let projectedMessages = AgentToolMCPBridge.providerContextMessages(messages)
        let projectedValue = try Self.result(in: projectedMessages).result
        let projected = try Self.encoded(projectedValue)
        let projectedHistory = try Self.encoded(projectedMessages)
        let projectedPayload = try #require(projectedValue.objectValue)
        let projectedTable = projectedPayload["meta"]?.objectValue?["ui_elements"]
        let projectedText = try #require(projectedPayload["result"]?.stringValue)
        let expectedText = fixture.header + "\n\nUI Elements: see meta.ui_elements (canonical element table).\n\n" +
            fixture.footer
        #expect(Array(projectedText.utf8) == Array(expectedText.utf8))
        #expect(projectedTable?.arrayValue?.count == 24)
        #expect(projectedTable == bridgePayload["meta"]?.objectValue?["ui_elements"])
        #expect(projectedPayload.filter { $0.key != "result" } == bridgePayload.filter { $0.key != "result" })
        #expect(original.count > projected.count)
        #expect(history.count - projectedHistory.count == original.count - projected.count)
        #expect(try Self.encoded(AgentToolMCPBridge.convert(response).value) == original)
        #expect(try Self.encoded(response.content) == rawContent)
        #expect(try Self.encoded(response.meta) == rawMetadata)
        #expect(try Self.encoded(messages) == history)

        // Fixed synthetic minified UTF-8 tool-result payloads; excludes provider/message envelopes and token costs.
        let expected = toolName == "see" ? (original: 12461, projected: 8297) : (original: 12293, projected: 8353)
        #expect(original.count == expected.original)
        #expect(projected.count == expected.projected)
    }

    @Test(arguments: ["see", "inspect_ui"])
    func `Native bridge and unrelated messages remain byte identical`(_ toolName: String) throws {
        let fixture = try ObservationProjectionFixture(toolName: toolName)
        let native = ToolResponse.text(fixture.text, meta: Value.from(fixture.metadataJSON))
        let bridged = AgentToolMCPBridge.convert(native)
        let before = try Self.jsonBytes(bridged.value)
        let imageMessage = ModelMessage.user(
            text: "Transient image evidence",
            images: [.init(data: "synthetic-image", mimeType: "image/png")])
        let bridgedPayload = try #require(bridged.value.objectValue)
        let messages = fixture.messages(payload: bridgedPayload) + [imageMessage]

        let projected = AgentToolMCPBridge.providerContextMessages(messages)

        #expect(try Self.jsonBytes(bridged.value) == before)
        #expect(AgentToolMCPBridge.convert(native).value == bridged.value)
        #expect(messages.last == imageMessage)
        #expect(projected.last == imageMessage)
        #expect(try Self.result(in: projected).result != bridged.value)
    }

    @Test(arguments: ["see", "inspect_ui"])
    func `Native renderer retains its exact public listing`(_ toolName: String) throws {
        let fixture = try ObservationProjectionFixture(toolName: toolName)
        let expectedRole = toolName == "see" ? "AXTextField" : "textField"
        let multiplication = toolName == "see" ? "×" : "x"
        let confidence = toolName == "see" ? " - confidence: 93%" : ""
        let fields = [
            "  element-1", "\"Café 👋\nSecond line\"", "at (-10, 20) size 180\(multiplication)24",
            "value: \"Draft\"", "desc: \"Synthetic field\"", "help: \"Edit safely\"", "shortcut: ⌘E",
            "identifier: fixture.field\(confidence)", "[value settable]",
        ].joined(separator: " - ")
        let expected = """
        UI Elements:

        \(expectedRole) (1 found, 1 actionable):
        \(fields)
        """
        #expect(Array(fixture.section.utf8) == Array(expected.utf8))
    }

    @Test(arguments: InvalidPayload.allCases, ["see", "inspect_ui"])
    func `Unproven result forms pass through unchanged`(_ invalid: InvalidPayload, _ toolName: String) throws {
        let fixture = try ObservationProjectionFixture(toolName: toolName)
        var payload = fixture.payload
        var metadata = try #require(payload["meta"]?.objectValue)
        var table = try #require(metadata["ui_elements"]?.arrayValue)
        var row = try #require(table[0].objectValue)
        switch invalid {
        case .missingTable: metadata["ui_elements"] = nil
        case .emptyTable: metadata["ui_elements"] = AnyAgentToolValue(array: [])
        case .nonArrayTable: metadata["ui_elements"] = AnyAgentToolValue(string: "omitted")
        case .missingCount: metadata["element_count"] = nil
        case .wrongCount: metadata["element_count"] = AnyAgentToolValue(int: 2)
        case .truncated: metadata["truncated"] = AnyAgentToolValue(bool: true)
        case .invalidTruncation: metadata["truncated"] = AnyAgentToolValue(string: "false")
        case .duplicateIDs:
            metadata["element_count"] = AnyAgentToolValue(int: 2)
            metadata["ui_elements"] = AnyAgentToolValue(array: [table[0], table[0]])
        case .missingID, .emptyID, .missingRole, .wrongActionability, .missingBounds, .invalidBounds,
             .overflowBounds, .negativeSize, .nonFiniteBounds, .mismatchedLabel:
            try Self.invalidateRow(&row, invalid: invalid)
        case .multipart: payload["result"] = AnyAgentToolValue(array: [AnyAgentToolValue(string: fixture.text)])
        case .missingText: payload["result"] = nil
        case .unknownTextShape: payload["result"] = AnyAgentToolValue(object: ["text": .init(string: fixture.text)])
        case .extraEvidence:
            payload["result"] = AnyAgentToolValue(string: fixture.text + "\nScreenshot unavailable; verify state.")
        case .clippedText: payload["result"] = AnyAgentToolValue(string: String(fixture.text.dropLast(12)))
        case .normalizationMismatch:
            payload["result"] = AnyAgentToolValue(string: fixture.text.replacingOccurrences(of: "é", with: "e\u{301}"))
        case .errorClaim: payload["error"] = AnyAgentToolValue(string: "Observation failed")
        case .unsuccessfulClaim: payload["success"] = AnyAgentToolValue(bool: false)
        case .invalidSafetyClaim: payload["retry_safe"] = AnyAgentToolValue(string: "yes")
        }
        if row != table[0].objectValue {
            table[0] = AnyAgentToolValue(object: row)
            metadata["ui_elements"] = AnyAgentToolValue(array: table)
        }
        payload["meta"] = AnyAgentToolValue(object: metadata)
        let messages = fixture.messages(payload: payload)
        #expect(AgentToolMCPBridge.providerContextMessages(messages) == messages)
    }

    @Test(arguments: InvalidCorrelation.allCases)
    func `Ambiguous tool provenance passes through unchanged`(_ invalid: InvalidCorrelation) throws {
        let fixture = try ObservationProjectionFixture(toolName: "see")
        var messages = fixture.messages()
        let call = AgentToolCall(id: "observation-call", name: "see", arguments: [:])
        let result = try Self.result(in: messages)
        switch invalid {
        case .missingCall: messages.removeFirst()
        case .backward: messages.reverse()
        case .duplicateCall: messages.append(messages[0])
        case .duplicateResult: messages.append(messages[1])
        case .duplicateInThinking:
            messages.append(ModelMessage(role: .assistant, content: [.toolCall(call)], channel: .thinking))
        case .wrongCallRole: messages[0] = ModelMessage(role: .user, content: [.toolCall(call)])
        case .wrongResultRole: messages[1] = ModelMessage(role: .user, content: [.toolResult(result)])
        case .multipartResult: messages[1] = ModelMessage(
                role: .tool,
                content: [.toolResult(result), .text("evidence")])
        case .thinkingCall: messages[0] = ModelMessage(role: .assistant, content: [.toolCall(call)], channel: .thinking)
        case .thinkingResult: messages[1] = ModelMessage(
                role: .tool,
                content: [.toolResult(result)],
                channel: .thinking)
        case .reasoningBoundary:
            messages[0] = ModelMessage(
                role: .assistant,
                content: [.toolCall(call)],
                metadata: .init(customData: ["tachikoma.internal.boundary": "reasoning_only"]))
        case .unknownTool:
            messages[0] = ModelMessage(role: .assistant, content: [.toolCall(.init(
                id: call.id, name: "verify_state", arguments: [:]))])
        case .namespacedTool:
            messages[0] = ModelMessage(role: .assistant, content: [.toolCall(.init(
                id: call.id, name: "see", arguments: [:], namespace: "other"))])
        case .unknownCallPart:
            messages[0] = ModelMessage(role: .assistant, content: [.toolCall(call), .image(.init(data: "unknown"))])
        case .emptyID:
            messages = [
                ModelMessage(role: .assistant, content: [.toolCall(.init(id: "", name: "see", arguments: [:]))]),
                ModelMessage(role: .tool, content: [.toolResult(.success(toolCallId: "", result: result.result))]),
            ]
        case .error:
            messages[1] = ModelMessage(role: .tool, content: [.toolResult(.init(
                toolCallId: call.id, result: result.result, isError: true))])
        case .typedFailure:
            messages[1] = ModelMessage(role: .tool, content: [.toolResult(.error(
                toolCallId: call.id, failure: .init(message: "Failed", structuredValue: result.result)))])
        }
        #expect(AgentToolMCPBridge.providerContextMessages(messages) == messages)
    }

    @Test
    func `Unknown see role and inspect text omission preserve both representations`() throws {
        let see = try ObservationProjectionFixture(toolName: "see", includeAXRole: false)
        #expect(AgentToolMCPBridge.providerContextMessages(see.messages()) == see.messages())
        let inspect = try ObservationProjectionFixture(toolName: "inspect_ui", count: 121)
        #expect(inspect.text.contains("1 additional elements omitted"))
        #expect(AgentToolMCPBridge.providerContextMessages(inspect.messages()) == inspect.messages())
    }

    private static func result(in messages: [ModelMessage]) throws -> AgentToolResult {
        let results = messages.compactMap { message -> AgentToolResult? in
            guard case let .toolResult(result)? = message.content.first else { return nil }
            return result
        }
        return try #require(results.first)
    }

    private static func invalidateRow(_ row: inout [String: AnyAgentToolValue], invalid: InvalidPayload) throws {
        switch invalid {
        case .missingID: row["id"] = nil
        case .emptyID: row["id"] = AnyAgentToolValue(string: "")
        case .missingRole: row["role"] = nil
        case .wrongActionability: row["is_actionable"] = AnyAgentToolValue(string: "true")
        case .missingBounds: row["bounds"] = nil
        case .invalidBounds:
            row["bounds"] = AnyAgentToolValue(object: ["x": AnyAgentToolValue(string: "10")])
        case .overflowBounds, .negativeSize, .nonFiniteBounds:
            var bounds = try #require(row["bounds"]?.objectValue)
            let width: Double = switch invalid {
            case .overflowBounds: Double(Int.max)
            case .negativeSize: -1
            default: .infinity
            }
            bounds["width"] = AnyAgentToolValue(double: width)
            row["bounds"] = AnyAgentToolValue(object: bounds)
        case .mismatchedLabel: row["label"] = AnyAgentToolValue(string: "Other field")
        default: Issue.record("Expected a row mutation")
        }
    }

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func jsonBytes(_ value: AnyAgentToolValue) throws -> Data {
        try JSONSerialization.data(withJSONObject: value.toJSON(), options: [.sortedKeys, .fragmentsAllowed])
    }

    enum InvalidPayload: CaseIterable {
        case missingTable, emptyTable, nonArrayTable, missingCount, wrongCount, truncated, invalidTruncation
        case duplicateIDs, missingID, emptyID, missingRole, wrongActionability, missingBounds, invalidBounds
        case overflowBounds, negativeSize, nonFiniteBounds, mismatchedLabel, multipart, missingText, unknownTextShape
        case extraEvidence, clippedText, normalizationMismatch, errorClaim, unsuccessfulClaim, invalidSafetyClaim
    }

    enum InvalidCorrelation: CaseIterable {
        case missingCall, backward, duplicateCall, duplicateResult, duplicateInThinking, wrongCallRole, wrongResultRole
        case multipartResult, thinkingCall, thinkingResult, reasoningBoundary, unknownTool, namespacedTool,
             unknownCallPart
        case emptyID, error, typedFailure
    }
}

private struct ObservationProjectionFixture {
    let toolName: String
    let header: String
    let section: String
    let footer: String
    let metadataJSON: [String: Any]
    let payload: [String: AnyAgentToolValue]

    var text: String {
        self.header + "\n\n" + self.section + "\n\n" + self.footer
    }

    init(
        toolName: String,
        includeAXRole: Bool = true,
        count: Int = 1,
        detectedElements: [DetectedElement]? = nil) throws
    {
        self.toolName = toolName
        let elements = detectedElements ?? (1...count).map { index in
            DetectedElement(
                id: "element-\(index)",
                type: .textField,
                label: "Café 👋\nSecond line",
                value: "Draft",
                bounds: CGRect(x: -10.5, y: 20.25, width: 180.75, height: 24.5),
                attributes: [
                    "role": includeAXRole ? "AXTextField" : "",
                    "description": "Synthetic field",
                    "help": "Edit safely",
                    "keyboardShortcut": "⌘E",
                    "identifier": "fixture.field",
                    "confidence": "0.93",
                    "isValueSettable": "true",
                ])
        }
        let rows = elements.map { UIElementSummary($0, mutationTargetingAvailable: true) }
        self.section = (toolName == "see"
            ? SeeElementTextFormatter.section(DetectedElementSnapshotConverter.convert(elements))
            : InspectUIElementTextFormatter.section(rows)).joined(separator: "\n")
        self.footer = toolName == "see"
            ? SeeElementTextFormatter.interactionHint : InspectUIElementTextFormatter.interactionHint
        self.header = """
        Observation header
        Snapshot ID: ps1_fixture
        Application: Synthetic
        Window: Fixture
        Screenshot: inline image attached
        Elements found: \(elements.count)
        Text selection element-1: UTF-16 location 1, length 2
        (Result from cached accessibility tree)
        Warning: preserve this unique evidence — 👀
        """
        self.metadataJSON = try [
            "ui_elements": JSONSerialization.jsonObject(with: JSONEncoder().encode(rows)),
            "element_count": elements.count,
            "snapshot_id": "ps1_fixture",
            "truncated": false,
            "used_cache": true,
            "target_identity": ["pid": 42, "window_id": 7],
            "coordinate_context": ["reference_id": "ps1_fixture", "space": "window", "scale": 2],
            "summary": ["notes": "Preserve the audit summary"],
            "verification_receipt": ["fixture": "not a native receipt"],
            "unknown_future_evidence": ["header": "retained"],
        ]
        self.payload = try [
            "result": AnyAgentToolValue(string: self.header + "\n\n" + self.section + "\n\n" + self.footer),
            "meta": AnyAgentToolValue.fromJSON(self.metadataJSON),
            "target_identity": AnyAgentToolValue.fromJSON(["pid": 42, "window_id": 7]),
            "verification_receipt": AnyAgentToolValue.fromJSON(["fixture": "not a native receipt"]),
            "unknown_root_evidence": AnyAgentToolValue(string: "also retained"),
        ]
    }

    func messages(payload: [String: AnyAgentToolValue]? = nil) -> [ModelMessage] {
        [
            ModelMessage(
                id: "call-message",
                role: .assistant,
                content: [.toolCall(.init(id: "observation-call", name: self.toolName, arguments: [:]))],
                timestamp: Date(timeIntervalSinceReferenceDate: 10)),
            ModelMessage(
                id: "result-message",
                role: .tool,
                content: [.toolResult(.success(
                    toolCallId: "observation-call", result: .init(object: payload ?? self.payload)))],
                timestamp: Date(timeIntervalSinceReferenceDate: 11),
                channel: .commentary,
                metadata: .init(conversationId: "fixture", turnId: "turn", customData: ["source": "fixture"])),
        ]
    }
}

private enum ObservationMeasurementElements {
    static func make() -> [DetectedElement] {
        (0..<24).map { index in
            let group = index / 6 + 1
            let bounds = CGRect(
                x: 20.5 + Double(index % 6) * 80,
                y: 40.25 + Double(group) * 44,
                width: 180.75,
                height: 24.5)
            let id = "measurement-\(index + 1)"
            switch index % 6 {
            case 0:
                return DetectedElement(
                    id: id,
                    type: .textField,
                    label: "Project \(group): Résumé",
                    value: "Draft \(group)\nSynthetic notes",
                    bounds: bounds,
                    attributes: [
                        "role": "AXTextField", "title": "Résumé \(group)", "description": "Editable project notes",
                        "help": "Write a short description", "identifier": "fixture.notes.\(group)",
                        "isValueSettable": "true", "isFocused": "true",
                        "selectedTextRangeLocation": "0", "selectedTextRangeLength": "5",
                    ])
            case 1:
                return DetectedElement(
                    id: id,
                    type: .button,
                    label: "Save \(group)",
                    bounds: bounds,
                    isEnabled: group != 3,
                    attributes: [
                        "role": "AXButton", "title": "Save \(group)", "description": "Store the synthetic document",
                        "keyboardShortcut": "⌘S", "identifier": "fixture.save.\(group)",
                    ])
            case 2:
                return DetectedElement(
                    id: id,
                    type: .staticText,
                    label: "Ready — section \(group) 🦞",
                    bounds: bounds,
                    attributes: [
                        "role": "AXStaticText", "roleDescription": "Status text", "confidence": "0.97",
                        "description": "Status text; no action target", "identifier": "fixture.status.\(group)",
                    ])
            case 3:
                return DetectedElement(
                    id: id,
                    type: .checkbox,
                    label: "Publish synthetic draft \(group)",
                    value: group.isMultiple(of: 2) ? "1" : "0",
                    bounds: bounds,
                    isSelected: group.isMultiple(of: 2),
                    attributes: [
                        "role": "AXCheckBox", "isValueSettable": "true", "identifier": "fixture.publish.\(group)",
                    ])
            case 4:
                return DetectedElement(
                    id: id,
                    type: .link,
                    label: "Review details \(group)",
                    bounds: bounds,
                    attributes: [
                        "role": "AXLink", "description": "Open the synthetic review panel",
                        "help": "Opens review details", "identifier": "fixture.review.\(group)",
                    ])
            default:
                return DetectedElement(
                    id: id,
                    type: .group,
                    label: "Section \(group)",
                    bounds: bounds,
                    attributes: ["role": "AXGroup", "identifier": "fixture.section.\(group)"])
            }
        }
    }
}
