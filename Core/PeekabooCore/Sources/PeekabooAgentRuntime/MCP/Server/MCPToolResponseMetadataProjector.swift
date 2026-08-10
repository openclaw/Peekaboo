import MCP

enum MCPToolResponseMetadataProjector {
    private static let safetyKeys: Set<String> = [
        "effect",
        "error_code",
        "mutation_dispatched",
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

    static func externalFields(from value: Value?, toolName: String?) -> [String: Value] {
        guard case let .object(fields)? = value else { return [:] }
        var allowed = Self.safetyKeys
        allowed.insert("coordinate_context")
        if toolName == "capture" {
            allowed.formUnion(Self.captureErrorKeys)
            allowed.formUnion(Self.captureSuccessKeys)
        }
        return fields.filter { allowed.contains($0.key) }
    }

    static func agentFields(from value: Value?) -> [String: Value] {
        guard case let .object(fields)? = value else { return [:] }
        let allowed = Self.safetyKeys.union(Self.captureErrorKeys)
        return fields.filter { allowed.contains($0.key) }
    }
}
