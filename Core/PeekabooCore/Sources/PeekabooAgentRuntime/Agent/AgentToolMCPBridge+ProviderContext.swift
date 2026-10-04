import Foundation
import PeekabooAutomation
import Tachikoma

extension AgentToolMCPBridge {
    /// A request-only view. Stored messages, native tool output, traces, and CLI events keep the original payload.
    static func providerContextMessages(_ messages: [ModelMessage]) -> [ModelMessage] {
        var calls: [String: (index: Int, call: AgentToolCall)] = [:]
        var callCounts: [String: Int] = [:]
        var resultCounts: [String: Int] = [:]
        for (index, message) in messages.enumerated() {
            for part in message.content {
                switch part {
                case let .toolCall(call):
                    callCounts[call.id, default: 0] += 1
                    if message.role == .assistant, Self.isOrdinaryMessage(message),
                       message.content.allSatisfy(Self.isAssistantObservationPart)
                    {
                        calls[call.id] = (index, call)
                    }
                case let .toolResult(result):
                    resultCounts[result.toolCallId, default: 0] += 1
                default:
                    break
                }
            }
        }

        return messages.enumerated().map { index, message in
            guard message.role == .tool, Self.isOrdinaryMessage(message), message.content.count == 1,
                  case let .toolResult(result) = message.content[0],
                  !result.toolCallId.isEmpty,
                  callCounts[result.toolCallId] == 1, resultCounts[result.toolCallId] == 1,
                  let source = calls[result.toolCallId], source.index < index,
                  source.call.namespace == nil, source.call.recipient == nil,
                  !AgentToolResultSemantics.isFailure(result),
                  let projected = Self.observationProviderValue(result.result, toolName: source.call.name)
            else { return message }

            return ModelMessage(
                id: message.id,
                role: message.role,
                content: [.toolResult(.success(toolCallId: result.toolCallId, result: projected))],
                timestamp: message.timestamp,
                channel: message.channel,
                metadata: message.metadata)
        }
    }

    private static func isOrdinaryMessage(_ message: ModelMessage) -> Bool {
        message.channel != .thinking &&
            message.metadata?.customData?["tachikoma.internal.boundary"] != "reasoning_only"
    }

    private static func isAssistantObservationPart(_ part: ModelMessage.ContentPart) -> Bool {
        switch part {
        case .toolCall, .text: true
        default: false
        }
    }

    private static func observationProviderValue(
        _ value: AnyAgentToolValue,
        toolName: String) -> AnyAgentToolValue?
    {
        guard toolName == "see" || toolName == "inspect_ui",
              var payload = value.objectValue,
              let text = payload["result"]?.stringValue,
              let metadata = payload["meta"]?.objectValue,
              metadata["truncated"] == nil || metadata["truncated"]?.boolValue == false,
              let table = metadata["ui_elements"]?.arrayValue, !table.isEmpty, table.count <= 1000,
              metadata["element_count"]?.doubleValue == Double(table.count),
              let data = try? JSONEncoder().encode(table), data.count <= 1_000_000,
              let rows = try? JSONDecoder().decode([UIElementSummary].self, from: data),
              validObservationRows(rows)
        else { return nil }

        let section: [String]
        let footer: String
        switch toolName {
        case "see":
            guard rows.allSatisfy({ $0.ax_role?.isEmpty == false }) else { return nil }
            section = SeeElementTextFormatter.section(rows.map(Self.seeElement))
            footer = SeeElementTextFormatter.interactionHint
        case "inspect_ui":
            guard rows.count <= InspectUIElementTextFormatter.maxRenderedElements else { return nil }
            section = InspectUIElementTextFormatter.section(rows)
            footer = InspectUIElementTextFormatter.interactionHint
        default:
            return nil
        }

        let suffix = "\n\n" + section.joined(separator: "\n") + "\n\n" + footer
        // String suffix matching admits canonically equivalent Unicode. Only exact bytes prove duplication.
        guard text.utf8.count >= suffix.utf8.count,
              text.utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
        else { return nil }
        guard let prefix = String(bytes: text.utf8.dropLast(suffix.utf8.count), encoding: .utf8) else { return nil }
        let projected = prefix + "\n\nUI Elements: see meta.ui_elements (canonical element table).\n\n" + footer
        guard projected.utf8.count < text.utf8.count else { return nil }
        payload["result"] = AnyAgentToolValue(string: projected)
        return AnyAgentToolValue(object: payload)
    }

    private static func validObservationRows(_ rows: [UIElementSummary]) -> Bool {
        var ids: Set<String> = []
        return rows.allSatisfy { row in
            guard !row.id.isEmpty, !row.role.isEmpty, ids.insert(row.id).inserted,
                  row.confidence?.isFinite != false, row.bounds.width >= 0, row.bounds.height >= 0
            else { return false }
            return [row.bounds.x, row.bounds.y, row.bounds.width, row.bounds.height].allSatisfy {
                $0.isFinite && Int(exactly: $0.rounded(.towardZero)) != nil
            }
        }
    }

    private static func seeElement(_ row: UIElementSummary) -> UIElement {
        UIElement(
            id: row.id,
            elementId: row.id,
            role: row.ax_role ?? row.role,
            title: row.title,
            label: row.label,
            value: row.value,
            description: row.description,
            help: row.help,
            roleDescription: row.role_description,
            identifier: row.identifier,
            confidence: row.confidence,
            frame: CGRect(x: row.bounds.x, y: row.bounds.y, width: row.bounds.width, height: row.bounds.height),
            isActionable: row.is_actionable,
            isEnabled: row.is_enabled,
            isSelected: row.is_selected,
            isValueSettable: row.is_value_settable,
            keyboardShortcut: row.keyboard_shortcut)
    }
}
