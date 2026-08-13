import Foundation
import PeekabooFoundation
import Tachikoma

/// The observable outcome of one provider-emitted tool call.
public enum AgentToolExecutionDisposition: String, Sendable, Codable, Equatable {
    case executedSucceeded = "executed/succeeded"
    case executedFailed = "executed/failed"
    case skippedBeforeDispatch = "skipped-before-dispatch"
    case missingResult = "missing-result"
}

/// Whether a mutating tool call reached the desktop mutation boundary.
public enum AgentMutationDispatchState: String, Sendable, Codable, Equatable {
    case dispatched
    case notDispatched = "not_dispatched"
    case possiblyDispatched = "possibly_dispatched"
}

/// A bounded, payload-safe correlation between one tool call and its runtime result.
public struct AgentExecutionTraceEntry: Sendable, Codable, Equatable {
    public let id: String
    public let name: String
    public let arguments: [String: AnyAgentToolValue]
    public let result: AnyAgentToolValue?
    public let isError: Bool?
    public let disposition: AgentToolExecutionDisposition
    public let mutationDispatch: AgentMutationDispatchState?
    public let actionOutcome: DesktopActionOutcome.Projection?

    public init(
        id: String,
        name: String,
        arguments: [String: AnyAgentToolValue],
        result: AnyAgentToolValue?,
        isError: Bool?,
        disposition: AgentToolExecutionDisposition,
        mutationDispatch: AgentMutationDispatchState? = nil,
        actionOutcome: DesktopActionOutcome.Projection? = nil)
    {
        self.id = id
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
        self.disposition = disposition
        self.mutationDispatch = mutationDispatch
        self.actionOutcome = actionOutcome
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case arguments
        case result
        case isError
        case disposition
        case mutationDispatch
        case actionOutcome
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.id, forKey: .id)
        try container.encode(self.name, forKey: .name)
        try container.encode(self.arguments, forKey: .arguments)
        if let result {
            try container.encode(result, forKey: .result)
        } else {
            try container.encodeNil(forKey: .result)
        }
        if let isError {
            try container.encode(isError, forKey: .isError)
        } else {
            try container.encodeNil(forKey: .isError)
        }
        try container.encode(self.disposition, forKey: .disposition)
        try container.encodeIfPresent(self.mutationDispatch, forKey: .mutationDispatch)
        try container.encodeIfPresent(self.actionOutcome, forKey: .actionOutcome)
    }
}

/// A size-limited execution trace suitable for CLI JSON output.
public struct AgentExecutionTrace: Sendable, Codable, Equatable {
    public static let maximumEntries = 512

    public let entries: [AgentExecutionTraceEntry]
    public let totalCallCount: Int
    public let truncated: Bool

    public init(entries: [AgentExecutionTraceEntry], totalCallCount: Int, truncated: Bool) {
        self.entries = entries
        self.totalCallCount = totalCallCount
        self.truncated = truncated
    }
}

extension AgentExecutionResult {
    /// Correlate provider tool calls with runtime tool results without exposing arbitrary result payloads.
    public func executionTrace(maxEntries requestedLimit: Int = AgentExecutionTrace
        .maximumEntries) -> AgentExecutionTrace
    {
        let limit = min(max(requestedLimit, 0), AgentExecutionTrace.maximumEntries)
        var calls: [AgentToolCall] = []
        var totalCallCount = 0

        for message in self.messages {
            for part in message.content {
                guard case let .toolCall(call) = part else { continue }
                totalCallCount += 1
                if calls.count < limit {
                    calls.append(call)
                }
            }
        }

        var requiredResultsByID: [String: Int] = [:]
        for call in calls {
            requiredResultsByID[call.id, default: 0] += 1
        }
        var resultsByID: [String: [AgentToolResult]] = [:]
        for message in self.messages {
            for part in message.content {
                guard case let .toolResult(result) = part,
                      let requiredCount = requiredResultsByID[result.toolCallId],
                      resultsByID[result.toolCallId, default: []].count < requiredCount
                else {
                    continue
                }
                resultsByID[result.toolCallId, default: []].append(result)
            }
        }

        var resultIndicesByID: [String: Int] = [:]
        let entries = calls.map { call in
            let resultIndex = resultIndicesByID[call.id, default: 0]
            let result = resultsByID[call.id].flatMap { results in
                resultIndex < results.count ? results[resultIndex] : nil
            }
            resultIndicesByID[call.id] = resultIndex + 1
            return AgentExecutionTraceBuilder.entry(for: call, result: result)
        }

        return AgentExecutionTrace(
            entries: entries,
            totalCallCount: totalCallCount,
            truncated: totalCallCount > entries.count)
    }
}

private enum AgentExecutionTraceBuilder {
    static func entry(for call: AgentToolCall, result: AgentToolResult?) -> AgentExecutionTraceEntry {
        let isMutatingCall = self.isMutatingToolCall(call)
        let semanticClaims = result.map {
            AgentToolResultSemantics.normalizedClaims(from: $0.result)
        } ?? .empty
        let disposition: AgentToolExecutionDisposition = if let result {
            if self.isConsistentPreDispatchSkip(result, claims: semanticClaims) {
                .skippedBeforeDispatch
            } else if AgentToolResultSemantics.isFailure(result) {
                .executedFailed
            } else {
                .executedSucceeded
            }
        } else {
            .missingResult
        }
        let mutationDispatch = self.mutationDispatchState(
            disposition: disposition,
            isMutatingCall: isMutatingCall,
            claims: semanticClaims)

        return AgentExecutionTraceEntry(
            id: AgentExecutionTraceSanitizer.identifier(call.id),
            name: AgentExecutionTraceSanitizer.identifier(call.name),
            arguments: AgentExecutionTraceSanitizer.arguments(call.arguments, toolName: call.name),
            result: result.map {
                AgentExecutionTraceSanitizer.resultSummary(
                    $0,
                    mutationDispatch: mutationDispatch,
                    claims: semanticClaims,
                    skippedBeforeDispatch: disposition == .skippedBeforeDispatch)
            },
            isError: result.map(AgentToolResultSemantics.isFailure),
            disposition: disposition,
            mutationDispatch: mutationDispatch,
            actionOutcome: semanticClaims.hasInvalidActionSafetyClaim
                ? nil
                : semanticClaims.actionOutcome.projection)
    }

    private static func isConsistentPreDispatchSkip(
        _: AgentToolResult,
        claims: AgentToolResultSemantics.NormalizedClaims) -> Bool
    {
        guard claims.boolean("skipped") == .valid(true) else { return false }
        guard claims.boolean("mutation_dispatched") != .invalid else { return false }

        return switch claims.actionOutcome {
        case .absent:
            switch claims.boolean("mutation_dispatched") {
            case .absent, .valid(false): true
            case .valid(true), .invalid: false
            }
        case let .valid(projection): projection.dispatchState == .none
        case .invalid: false
        }
    }

    private static func mutationDispatchState(
        disposition: AgentToolExecutionDisposition,
        isMutatingCall: Bool,
        claims: AgentToolResultSemantics.NormalizedClaims)
        -> AgentMutationDispatchState?
    {
        if disposition == .skippedBeforeDispatch {
            return isMutatingCall ? .notDispatched : nil
        }
        if case .invalid = claims.boolean("mutation_dispatched") {
            if case .absent = claims.actionOutcome {
                return isMutatingCall ? .possiblyDispatched : nil
            }
            return .possiblyDispatched
        }
        if case let .valid(actionOutcome) = claims.actionOutcome {
            return switch actionOutcome.dispatchState {
            case .none: .notDispatched
            case .dispatched: .dispatched
            case .mayHaveDispatched: .possiblyDispatched
            }
        }
        if case .invalid = claims.actionOutcome {
            return .possiblyDispatched
        }
        guard isMutatingCall else { return nil }
        if case .invalid = claims.boolean("skipped") {
            return .possiblyDispatched
        }
        switch claims.boolean("mutation_dispatched") {
        case .absent:
            return .possiblyDispatched
        case .valid(false):
            return .notDispatched
        case .valid(true):
            return claims.boolean("skipped") == .valid(true) ? .possiblyDispatched : .dispatched
        case .invalid:
            return .possiblyDispatched
        }
    }

    private static func isMutatingToolCall(_ call: AgentToolCall) -> Bool {
        let name = call.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        let mutatingTools: Set = [
            "action", "app", "click", "dialog", "dock", "drag", "menu", "move", "paste", "press",
            "scroll", "set_value", "space", "type", "window",
        ]
        if name == "capture" || name == "image" {
            let focus = call.arguments["capture_focus"]?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "background"
            return focus != "background"
        }
        guard mutatingTools.contains(name) else { return false }

        let readOnlyActions: [String: Set<String>] = [
            "app": ["list"],
            "dialog": ["list"],
            "dock": ["list"],
            "menu": ["list"],
            "space": ["list"],
            "window": ["list"],
        ]
        guard let readOnly = readOnlyActions[name],
              let action = call.arguments["action"]?.stringValue
        else {
            return true
        }
        let normalizedAction = action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        return !readOnly.contains(normalizedAction)
    }
}

private enum AgentExecutionTraceSanitizer {
    private static let maximumDepth = 4
    private static let maximumContainerItems = 24
    private static let maximumNodes = 128
    private static let maximumStringScalars = 256
    private static let maximumTotalStringScalars = 2048
    private static let unvalidatedOutcomeBooleanFields: Set<String> = [
        "mutation_dispatched",
        "requires_fresh_observation",
        "retry_safe",
        "skipped",
        "success",
    ]

    private struct Budget {
        var remainingNodes = AgentExecutionTraceSanitizer.maximumNodes
        var remainingStringScalars = AgentExecutionTraceSanitizer.maximumTotalStringScalars
    }

    static func identifier(_ value: String) -> String {
        var budget = Budget()
        return self.sanitizedString(value, key: nil, budget: &budget)
    }

    static func arguments(
        _ arguments: [String: AnyAgentToolValue],
        toolName: String) -> [String: AnyAgentToolValue]
    {
        var budget = Budget()
        return self.sanitizedObject(arguments, toolName: toolName, depth: 0, budget: &budget)
    }

    static func resultSummary(
        _ result: AgentToolResult,
        mutationDispatch: AgentMutationDispatchState?,
        claims: AgentToolResultSemantics.NormalizedClaims,
        skippedBeforeDispatch: Bool) -> AnyAgentToolValue
    {
        let actionOutcome = claims.actionOutcome.projection
        let suppressRawOutcomeClaims = switch claims.actionOutcome {
        case .absent: false
        case .valid, .invalid: true
        }
        let summary = self.baseResultSummary(
            result.result,
            claims: claims,
            suppressRawOutcomeClaims: suppressRawOutcomeClaims,
            suppressLegacyPresence: actionOutcome?.outcome.isConfirmed == true &&
                result.failure == nil && !result.isError)
        guard var object = summary.objectValue else { return summary }
        let retrySafetyDisputed = mutationDispatch == .possiblyDispatched ||
            claims.boolean("mutation_dispatched") == .invalid ||
            claims.boolean("skipped") == .invalid
        if retrySafetyDisputed {
            object.removeValue(forKey: "retry_safe")
        }
        if let actionOutcome {
            if claims.boolean("mutation_dispatched") != .invalid {
                object["mutation_dispatched"] = AnyAgentToolValue(bool: actionOutcome.mutationDispatched)
            }
            if claims.boolean("requires_fresh_observation") != .invalid {
                object["requires_fresh_observation"] = AnyAgentToolValue(
                    bool: actionOutcome.requiresFreshObservation)
            }
            if claims.boolean("retry_safe") != .invalid, !retrySafetyDisputed {
                object["retry_safe"] = AnyAgentToolValue(bool: actionOutcome.retrySafe)
            }
        }
        if let mutationDispatch {
            object["mutation_dispatch"] = AnyAgentToolValue(string: mutationDispatch.rawValue)
        }
        if skippedBeforeDispatch {
            object["skipped"] = AnyAgentToolValue(bool: true)
            object["mutation_dispatched"] = AnyAgentToolValue(bool: false)
        }
        return AnyAgentToolValue(object: object)
    }

    private static func baseResultSummary(
        _ result: AnyAgentToolValue,
        claims: AgentToolResultSemantics.NormalizedClaims,
        suppressRawOutcomeClaims: Bool,
        suppressLegacyPresence: Bool) -> AnyAgentToolValue
    {
        if result.isNull {
            return AnyAgentToolValue(object: ["value_type": AnyAgentToolValue(string: "null")])
        }
        if let value = result.boolValue {
            return AnyAgentToolValue(object: [
                "value": AnyAgentToolValue(bool: value),
                "value_type": AnyAgentToolValue(string: "boolean"),
            ])
        }
        if result.intValue != nil {
            return AnyAgentToolValue(object: [
                "payload_omitted": AnyAgentToolValue(bool: true),
                "value_type": AnyAgentToolValue(string: "integer"),
            ])
        }
        if result.doubleValue != nil {
            return AnyAgentToolValue(object: [
                "payload_omitted": AnyAgentToolValue(bool: true),
                "value_type": AnyAgentToolValue(string: "number"),
            ])
        }
        if result.stringValue != nil {
            return AnyAgentToolValue(object: [
                "payload_omitted": AnyAgentToolValue(bool: true),
                "value_type": AnyAgentToolValue(string: "string"),
            ])
        }
        if let array = result.arrayValue {
            return AnyAgentToolValue(object: [
                "item_count": AnyAgentToolValue(int: array.count),
                "payload_omitted": AnyAgentToolValue(bool: true),
                "value_type": AnyAgentToolValue(string: "array"),
            ])
        }
        guard let object = result.objectValue else {
            return AnyAgentToolValue(object: [
                "payload_omitted": AnyAgentToolValue(bool: true),
                "value_type": AnyAgentToolValue(string: "unknown"),
            ])
        }

        let publicBooleanFields = [
            "cancelled",
            "completion_evidence_required",
            "mutation_dispatched",
            "perception_required",
            "retry_safe",
            "skipped",
            "success",
        ]
        var summary: [String: AnyAgentToolValue] = [
            "value_type": AnyAgentToolValue(string: "object"),
        ]
        let visibleBooleanFields = self.visiblePublicBooleanFields(
            publicBooleanFields,
            suppressRawOutcomeClaims: suppressRawOutcomeClaims)
        for key in visibleBooleanFields {
            if case let .valid(value) = claims.boolean(key) {
                summary[key] = AnyAgentToolValue(bool: value)
            }
        }
        self.addLegacyPresenceSummary(
            claims: claims,
            suppressLegacyPresence: suppressLegacyPresence,
            to: &summary)
        if case let .valid(boundary) = claims.turnBoundary {
            var boundarySummary: [String: AnyAgentToolValue] = [:]
            boundarySummary["disposition"] = AnyAgentToolValue(string: boundary.disposition.rawValue)
            boundarySummary["stop_after_current_step"] = AnyAgentToolValue(bool: true)
            if boundary.disposition == .continueNextStep {
                boundarySummary["continue_next_step"] = AnyAgentToolValue(bool: true)
            }
            if !boundarySummary.isEmpty {
                summary["turn_boundary"] = AnyAgentToolValue(object: boundarySummary)
            }
        }

        let copiedKeys = Set(publicBooleanFields + ["error", "reason", "turn_boundary"])
        if object.count > copiedKeys.count || object.keys.contains(where: { !copiedKeys.contains($0) }) {
            summary["payload_omitted"] = AnyAgentToolValue(bool: true)
        }
        return AnyAgentToolValue(object: summary)
    }

    private static func addLegacyPresenceSummary(
        claims: AgentToolResultSemantics.NormalizedClaims,
        suppressLegacyPresence: Bool,
        to summary: inout [String: AnyAgentToolValue])
    {
        guard !suppressLegacyPresence else { return }
        if claims.errorPresence == .valid(true) {
            summary["error_present"] = AnyAgentToolValue(bool: true)
        }
        if claims.reasonPresence == .valid(true) {
            summary["reason_present"] = AnyAgentToolValue(bool: true)
        }
    }

    private static func visiblePublicBooleanFields(
        _ fields: [String],
        suppressRawOutcomeClaims: Bool) -> [String]
    {
        guard suppressRawOutcomeClaims else { return fields }
        return fields.filter { !self.unvalidatedOutcomeBooleanFields.contains($0) }
    }

    private static func sanitizedObject(
        _ object: [String: AnyAgentToolValue],
        toolName: String,
        depth: Int,
        budget: inout Budget) -> [String: AnyAgentToolValue]
    {
        var sanitized: [String: AnyAgentToolValue] = [:]
        let keys = object.keys.sorted()
        for (index, key) in keys.prefix(self.maximumContainerItems).enumerated() {
            guard let value = object[key] else { continue }
            let outputKey = self.sanitizedObjectKey(key, index: index, existingKeys: Set(sanitized.keys))
            sanitized[outputKey] = self.sanitizeArgument(
                value,
                key: key,
                toolName: toolName,
                depth: depth + 1,
                budget: &budget)
        }
        if keys.count > self.maximumContainerItems {
            sanitized["__peekaboo_trace_omitted_fields"] = AnyAgentToolValue(
                int: keys.count - self.maximumContainerItems)
        }
        return sanitized
    }

    private static func sanitizeArgument(
        _ value: AnyAgentToolValue,
        key: String,
        toolName: String,
        depth: Int,
        budget: inout Budget) -> AnyAgentToolValue
    {
        guard budget.remainingNodes > 0 else {
            return AnyAgentToolValue(string: "<omitted-budget>")
        }
        budget.remainingNodes -= 1

        guard depth <= self.maximumDepth else {
            return AnyAgentToolValue(string: "<omitted-depth>")
        }

        if value.isNull {
            return AnyAgentToolValue(null: ())
        }
        if let bool = value.boolValue {
            guard self.allowsBoolean(key, toolName: toolName) else {
                return self.redactedSummary(value)
            }
            return AnyAgentToolValue(bool: bool)
        }
        if let int = value.intValue {
            guard self.allowsNumber(key, toolName: toolName) else {
                return self.redactedSummary(value)
            }
            return AnyAgentToolValue(int: int)
        }
        if let double = value.doubleValue {
            guard self.allowsNumber(key, toolName: toolName) else {
                return self.redactedSummary(value)
            }
            return AnyAgentToolValue(double: double)
        }
        if let string = value.stringValue {
            guard self.allowsString(key, toolName: toolName) else {
                return self.redactedSummary(value)
            }
            return AnyAgentToolValue(string: self.sanitizedString(string, key: key, budget: &budget))
        }
        if let array = value.arrayValue {
            guard self.allowsContainer(key, toolName: toolName) else {
                return self.redactedSummary(value)
            }
            var sanitized = array.prefix(self.maximumContainerItems).map { item in
                if let object = item.objectValue {
                    return AnyAgentToolValue(object: self.sanitizedObject(
                        object,
                        toolName: toolName,
                        depth: depth + 1,
                        budget: &budget))
                }
                return self.sanitizeArgument(
                    item,
                    key: key,
                    toolName: toolName,
                    depth: depth + 1,
                    budget: &budget)
            }
            if array.count > self.maximumContainerItems {
                sanitized
                    .append(AnyAgentToolValue(string: "<omitted-items:\(array.count - self.maximumContainerItems)>"))
            }
            return AnyAgentToolValue(array: sanitized)
        }
        if let object = value.objectValue {
            guard self.allowsContainer(key, toolName: toolName) else {
                return self.redactedSummary(value)
            }
            return AnyAgentToolValue(object: self.sanitizedObject(
                object,
                toolName: toolName,
                depth: depth,
                budget: &budget))
        }
        return AnyAgentToolValue(string: "<omitted-unknown>")
    }

    private static func redactedSummary(_ value: AnyAgentToolValue) -> AnyAgentToolValue {
        let valueType: String
        var summary: [String: AnyAgentToolValue] = [
            "redacted": AnyAgentToolValue(bool: true),
        ]
        if value.isNull {
            valueType = "null"
        } else if value.boolValue != nil {
            valueType = "boolean"
        } else if value.intValue != nil {
            valueType = "integer"
        } else if value.doubleValue != nil {
            valueType = "number"
        } else if value.stringValue != nil {
            valueType = "string"
        } else if let array = value.arrayValue {
            valueType = "array"
            summary["item_count"] = AnyAgentToolValue(int: array.count)
        } else if let object = value.objectValue {
            valueType = "object"
            summary["field_count"] = AnyAgentToolValue(int: object.count)
        } else {
            valueType = "unknown"
        }
        summary["value_type"] = AnyAgentToolValue(string: valueType)
        return AnyAgentToolValue(object: summary)
    }

    private static func allowsString(_ key: String, toolName: String) -> Bool {
        let key = self.normalizedKey(key)
        let auditStrings: Set = [
            "action",
            "app",
            "app_target",
            "bundle",
            "bundle_id",
            "bundle_identifier",
            "capture_engine",
            "delivery_mode",
            "direction",
            "element",
            "element_id",
            "engine",
            "format",
            "identifier",
            "item_type",
            "kind",
            "mode",
            "on",
            "operator",
            "predicate",
            "predicate_kind",
            "role",
            "snapshot",
            "snapshot_id",
            "type",
        ]
        if auditStrings.contains(key) {
            return true
        }
        return key == "name" && self.normalizedKey(toolName) == "app"
    }

    private static func allowsNumber(_ key: String, toolName _: String) -> Bool {
        let key = self.normalizedKey(key)
        let auditNumbers: Set = [
            "amount",
            "coords",
            "delay",
            "display_index",
            "duration",
            "element_id",
            "height",
            "index",
            "pid",
            "process_id",
            "screen_index",
            "snapshot_id",
            "space_id",
            "stable_samples",
            "steps",
            "target_pid",
            "timeout",
            "timeout_ms",
            "tolerance",
            "to",
            "width",
            "window_id",
            "x",
            "y",
        ]
        return auditNumbers.contains(key) || key.hasSuffix("_timeout") || key.hasSuffix("_timeout_ms")
    }

    private static func allowsBoolean(_ key: String, toolName _: String) -> Bool {
        let key = self.normalizedKey(key)
        let auditBooleans: Set = [
            "background",
            "clear",
            "double",
            "expected",
            "final_screenshot",
            "foreground",
            "press_return",
            "right",
            "smooth",
            "web_focus",
        ]
        return auditBooleans.contains(key)
    }

    private static func allowsContainer(_ key: String, toolName _: String) -> Bool {
        let key = self.normalizedKey(key)
        return [
            "bounds",
            "coordinates",
            "coords",
            "from",
            "position",
            "predicates",
            "selector",
            "to",
        ].contains(key)
    }

    private static func normalizedKey(_ key: String) -> String {
        key
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }

    private static func sanitizedString(_ value: String, key: String?, budget: inout Budget) -> String {
        if key.map(self.isPathKey) == true || self.looksLikeLocalPath(value) {
            return "<redacted-path>"
        }
        if self.looksLikeURL(value) {
            return "<redacted-url>"
        }
        if self.containsSecret(value) {
            return "<redacted-secret>"
        }
        if self.looksLikeBinaryPayload(value) {
            return "<omitted-binary>"
        }

        let allowedScalars = min(self.maximumStringScalars, budget.remainingStringScalars)
        guard allowedScalars > 0 else { return "<omitted-budget>" }
        let scalars = value.unicodeScalars
        let prefix = scalars.prefix(allowedScalars)
        budget.remainingStringScalars -= prefix.count
        let sanitized = String(prefix)
        return prefix.count < scalars.count ? sanitized + "…" : sanitized
    }

    private static func sanitizedObjectKey(_ key: String, index: Int, existingKeys: Set<String>) -> String {
        let base: String
        if self.containsSecret(key) || self.looksLikeLocalPath(key) || self.looksLikeBinaryPayload(key) {
            base = "__peekaboo_trace_redacted_key"
        } else {
            let prefix = key.unicodeScalars.prefix(self.maximumStringScalars)
            base = String(prefix) + (prefix.count < key.unicodeScalars.count ? "…" : "")
        }
        return existingKeys.contains(base) ? "\(base)_\(index)" : base
    }

    private static func isSensitiveKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized.contains("token") ||
            normalized.contains("secret") ||
            normalized.contains("password") ||
            normalized.contains("credential") ||
            normalized.contains("authorization") ||
            normalized.contains("api_key") ||
            normalized.contains("apikey") ||
            normalized.contains("cookie") ||
            normalized.contains("private_key") ||
            normalized.contains("access_key")
    }

    private static func isBinaryKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return [
            "base64",
            "blob",
            "bytes",
            "data",
            "image",
            "image_data",
            "screenshot",
            "screenshot_data",
        ].contains(normalized)
    }

    private static func isPathKey(_ key: String) -> Bool {
        let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
        return normalized == "file" || normalized == "filename" || normalized.contains("path")
    }

    private static func looksLikeLocalPath(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("./") ||
            trimmed.hasPrefix("../") || trimmed.hasPrefix("file://")
        {
            return true
        }
        let localFragments = ["/Users/", "/tmp/", "/private/", "/var/folders/", "/Volumes/"]
        if localFragments.contains(where: trimmed.contains) {
            return true
        }
        return trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }

    private static func looksLikeURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased()
        else {
            return false
        }
        return ["file", "ftp", "http", "https", "mailto", "ssh", "ws", "wss"].contains(scheme)
    }

    private static func containsSecret(_ value: String) -> Bool {
        let patterns = [
            #"(?i)sk-[a-z0-9_-]{10,}"#,
            #"(?i)bearer\s+[a-z0-9._-]{8,}"#,
            #"(?i)api[_-]?key\s*[:=]\s*[a-z0-9._-]{6,}"#,
            #"(?i)(?:password|secret|cookie|authorization)\s*[:=]\s*\S{4,}"#,
            #"(?i)sess[a-z0-9]{12,}"#,
            #"(?i)token\s*[:=]\s*[a-z0-9._-]{12,}"#,
            #"(?i)gh[pousr]_[a-z0-9]{12,}"#,
            #"AKIA[0-9A-Z]{16}"#,
        ]
        if patterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) {
            return true
        }
        guard let components = URLComponents(string: value), components.scheme != nil else { return false }
        if components.user != nil || components.password != nil {
            return true
        }
        return components.queryItems?.contains(where: { self.isSensitiveKey($0.name) }) == true
    }

    private static func looksLikeBinaryPayload(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("data:image/") || trimmed.hasPrefix("iVBORw0KGgo") ||
            trimmed.hasPrefix("/9j/")
        {
            return true
        }
        guard trimmed.count > self.maximumStringScalars else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=_-")
        return trimmed.unicodeScalars.allSatisfy(allowed.contains)
    }
}
