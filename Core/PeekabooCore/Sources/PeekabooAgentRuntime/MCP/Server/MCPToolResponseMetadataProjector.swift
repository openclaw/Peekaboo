import MCP
import PeekabooFoundation
import TachikomaMCP

enum MCPToolResponseMetadataProjector {
    private static let actionOutcomeKeys: Set<String> = [
        "delivery_mechanism",
        "delivery_mode",
        "dispatch_state",
        "dispatched_unit_count",
        "effect",
        "escalation",
        "evidence",
        "mutation_dispatched",
        "refusal_reason",
        "requires_fresh_observation",
        "retry_safe",
        "retry_safety",
        "route",
        "state",
    ]

    private static let safetyKeys = Self.actionOutcomeKeys.union([
        "error_code",
        "execution_policy",
    ])

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

    static func fields(
        for projection: DesktopActionOutcome.Projection) throws -> [String: Value]
    {
        guard case let .object(fields) = try Value(projection) else {
            throw ProjectionError.expectedObject
        }
        return fields
    }

    static func metadata(
        merging base: [String: Value] = [:],
        outcome: DesktopActionOutcome?) throws -> Value?
    {
        var fields = base
        if let outcome {
            try fields.merge(self.fields(for: outcome.projection)) { _, canonical in canonical }
        }
        return fields.isEmpty ? nil : .object(fields)
    }

    static func errorResponse(
        for failure: DesktopActionFailure,
        invalidatedSnapshotID: String?,
        additionalFields: [String: Value] = [:]) throws -> ToolResponse
    {
        var fields = additionalFields
        try fields.merge(self.fields(for: failure.outcome.projection)) { _, canonical in canonical }
        if let invalidatedSnapshotID {
            fields["invalidated_snapshot"] = .string(invalidatedSnapshotID)
        }

        return ToolResponse.error(
            self.message(for: failure),
            meta: .object(fields))
    }

    static func preDispatchRefusalResponse(
        message: String,
        reason: DesktopActionOutcome.RefusalReason,
        additionalFields: [String: Value] = [:]) -> ToolResponse
    {
        let failure = DesktopActionFailure.refused(reason: reason, message: message)
        do {
            return try self.errorResponse(
                for: failure,
                invalidatedSnapshotID: nil,
                additionalFields: additionalFields)
        } catch {
            let metadata: Value? = additionalFields.isEmpty ? nil : .object(additionalFields)
            return ToolResponse.error(message, meta: metadata)
        }
    }

    private enum ProjectionError: Error {
        case expectedObject
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
