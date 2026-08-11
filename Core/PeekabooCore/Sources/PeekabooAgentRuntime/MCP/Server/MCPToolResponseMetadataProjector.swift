import MCP
import PeekabooFoundation
import TachikomaMCP

enum MCPToolResponseMetadataProjector {
    private static let safetyKeys: Set<String> = [
        "effect",
        "error_code",
        "mutation_dispatched",
        "requires_fresh_observation",
        "retry_safe",
    ]

    private static let captureErrorKeys: Set<String> = [
        "decode_failures",
        "first_decode_error",
        "frames_dropped",
        "last_capture_error",
        "last_decode_error",
        "source",
    ]

    private static let captureSuccessKeys: Set<String> = [
        "contact",
        "contact_columns",
        "contact_rows",
        "contact_sampled_indexes",
        "contact_thumb_height",
        "contact_thumb_width",
        "diff_algorithm",
        "diff_scale",
        "frames",
        "metadata",
        "stats",
        "video_in",
        "video_out",
        "warnings",
    ]

    private static let permissionKeys: Set<String> = [
        "accessibility",
        "event_synthesizing",
        "event_synthesizing_limits",
        "permission_snapshot_available",
        "required_permissions_granted",
        "screen_recording",
    ]

    static func externalFields(from value: Value?, toolName: String?) -> [String: Value] {
        guard case let .object(fields)? = value else { return [:] }
        var allowed = Self.safetyKeys
        allowed.insert("coordinate_context")
        if toolName == "capture" {
            allowed.formUnion(Self.captureErrorKeys)
            allowed.formUnion(Self.captureSuccessKeys)
        }
        if toolName == "permissions" {
            allowed.formUnion(Self.permissionKeys)
        }
        return fields.filter { allowed.contains($0.key) }
    }

    static func agentFields(from value: Value?) -> [String: Value] {
        guard case let .object(fields)? = value else { return [:] }
        let allowed = Self.safetyKeys
            .union(Self.captureErrorKeys)
            .union(Self.permissionKeys)
        return fields.filter { allowed.contains($0.key) }
    }

    static func errorResponse(
        for failure: DesktopActionFailure,
        invalidatedSnapshotID: String?) -> ToolResponse
    {
        let outcome = failure.outcome
        let retrySafe = switch outcome.retrySafety {
        case .safe: true
        case .unsafe, .notApplicable: false
        }
        var fields: [String: Value] = [
            "effect": .string(outcome.effect.rawValue),
            "mutation_dispatched": .bool(outcome.dispatchState.mutationDispatched),
            "retry_safe": .bool(retrySafe),
        ]
        if outcome.dispatchState.mutationDispatched {
            fields["requires_fresh_observation"] = .bool(true)
        }
        if let invalidatedSnapshotID {
            fields["invalidated_snapshot"] = .string(invalidatedSnapshotID)
        }

        return ToolResponse.error(
            self.message(for: failure),
            meta: .object(fields))
    }

    private static func message(for failure: DesktopActionFailure) -> String {
        var components = [failure.message]
        for detail in [failure.causeDescription, failure.hint].compactMap(\.self)
            where !detail.isEmpty && !components.contains(detail)
        {
            components.append(detail)
        }
        return components.joined(separator: " ")
    }
}
