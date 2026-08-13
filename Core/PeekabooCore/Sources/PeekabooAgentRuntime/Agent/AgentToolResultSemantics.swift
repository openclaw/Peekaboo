import Foundation
import MCP
import PeekabooFoundation
import Tachikoma

/// Peekaboo-owned interpretation of Tachikoma's generic Agent tool-result carrier.
enum AgentToolResultSemantics {
    static func isFailure(_ result: AgentToolResult) -> Bool {
        result.failure != nil || result.isError || self.valueEncodesFailure(result.result)
    }

    static func valueEncodesFailure(_ value: AnyAgentToolValue) -> Bool {
        switch self.actionOutcomeResolution(from: value) {
        case .absent:
            self.legacyValueEncodesFailure(value)
        case let .valid(projection):
            !projection.outcome.isConfirmed
        case .invalid:
            true
        }
    }

    static func legacyValueEncodesFailure(_ value: AnyAgentToolValue) -> Bool {
        if let string = value.stringValue {
            return string.hasPrefix("Error:")
        }

        guard let payload = value.objectValue else { return false }
        if payload["success"]?.boolValue == false {
            return true
        }
        guard let error = payload["error"], !error.isNull else { return false }
        if let message = error.stringValue {
            return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    static func actionOutcome(from result: AgentToolResult) -> DesktopActionOutcome.Projection? {
        self.actionOutcomeResolution(from: result.result).projection
    }

    static func actionOutcomeResolution(
        from value: AnyAgentToolValue) -> MCPToolResponseMetadataProjector.ActionOutcomeResolution
    {
        guard let payload = value.objectValue else { return .absent }
        let containers = [
            payload,
            payload["metadata"]?.objectValue,
            payload["meta"]?.objectValue,
        ]
        var resolvedProjection: DesktopActionOutcome.Projection?
        for container in containers.compactMap(\.self) {
            let outcomeFields = container.filter {
                MCPToolResponseMetadataProjector.actionOutcomeKeys.contains($0.key)
            }
            guard MCPToolResponseMetadataProjector.requiredActionOutcomeKeys
                .isSubset(of: Set(outcomeFields.keys))
            else {
                continue
            }
            guard let convertedFields = self.convertedOutcomeFields(outcomeFields) else {
                return .invalid
            }
            let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(
                from: .object(convertedFields))
            switch resolution {
            case .absent:
                continue
            case .invalid:
                return .invalid
            case let .valid(projection):
                if let resolvedProjection, resolvedProjection != projection {
                    return .invalid
                }
                resolvedProjection = projection
            }
        }
        return resolvedProjection.map(MCPToolResponseMetadataProjector.ActionOutcomeResolution.valid) ?? .absent
    }

    private static func convertedOutcomeFields(
        _ fields: [String: AnyAgentToolValue]) -> [String: Value]?
    {
        var converted: [String: Value] = [:]
        converted.reserveCapacity(fields.count)
        for (key, field) in fields {
            guard let value = self.scalarOutcomeValue(field) else { return nil }
            converted[key] = value
        }
        return converted
    }

    private static func scalarOutcomeValue(_ value: AnyAgentToolValue) -> Value? {
        if value.isNull {
            return .null
        }
        if let bool = value.boolValue {
            return .bool(bool)
        }
        if let int = value.intValue {
            return .int(int)
        }
        if let string = value.stringValue, string.utf8.count <= 128 {
            return .string(string)
        }
        return nil
    }
}
