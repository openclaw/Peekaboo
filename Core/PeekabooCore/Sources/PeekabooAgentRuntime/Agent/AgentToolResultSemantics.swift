import Foundation
import MCP
import PeekabooFoundation
import Tachikoma

/// Peekaboo-owned interpretation of Tachikoma's generic Agent tool-result carrier.
enum AgentToolResultSemantics {
    private static let legacyErrorPrefix = Array("Error:".utf8)

    enum ClaimResolution<Value: Equatable>: Equatable {
        case absent
        case valid(Value)
        case invalid
    }

    struct TurnBoundaryProjection: Equatable {
        enum Disposition: String, Equatable {
            case continueNextStep = "continue_next_step"
            case stopAgent = "stop_agent"
        }

        let disposition: Disposition
        let reason: String
    }

    private struct CanonicalOutcomeClaims {
        let resolution: MCPToolResponseMetadataProjector.ActionOutcomeResolution
        let carrierIndexes: Set<Int>
    }

    struct NormalizedClaims {
        static var empty: NormalizedClaims {
            NormalizedClaims(
                actionOutcome: .absent,
                legacyBooleans: [:],
                errorPresence: .absent,
                reasonPresence: .absent,
                turnBoundary: .absent)
        }

        let actionOutcome: MCPToolResponseMetadataProjector.ActionOutcomeResolution
        let legacyBooleans: [String: ClaimResolution<Bool>]
        let errorPresence: ClaimResolution<Bool>
        let reasonPresence: ClaimResolution<Bool>
        let turnBoundary: ClaimResolution<TurnBoundaryProjection>

        var hasInvalidClaim: Bool {
            if case .invalid = self.actionOutcome {
                return true
            }
            if self.legacyBooleans.values.contains(.invalid) {
                return true
            }
            return self.errorPresence == .invalid ||
                self.reasonPresence == .invalid ||
                self.turnBoundary == .invalid
        }

        var hasInvalidActionSafetyClaim: Bool {
            ["mutation_dispatched", "requires_fresh_observation", "retry_safe"]
                .contains { self.boolean($0) == .invalid }
        }

        func boolean(_ key: String) -> ClaimResolution<Bool> {
            self.legacyBooleans[key] ?? .absent
        }
    }

    static let legacyBooleanKeys = [
        "cancelled",
        "completion_evidence_required",
        "mutation_dispatched",
        "perception_required",
        "requires_fresh_observation",
        "retry_safe",
        "skipped",
        "success",
    ]

    static func isFailure(_ result: AgentToolResult) -> Bool {
        result.failure != nil || result.isError || self.valueEncodesFailure(result.result)
    }

    static func valueEncodesFailure(_ value: AnyAgentToolValue) -> Bool {
        let claims = self.normalizedClaims(from: value)
        if claims.hasInvalidClaim {
            return true
        }
        return switch claims.actionOutcome {
        case .absent:
            self.legacyValueEncodesFailure(value, claims: claims)
        case let .valid(projection):
            !projection.outcome.isConfirmed
        case .invalid:
            true
        }
    }

    private static func legacyValueEncodesFailure(
        _ value: AnyAgentToolValue,
        claims: NormalizedClaims) -> Bool
    {
        if let string = value.stringValue {
            return string.utf8.starts(with: self.legacyErrorPrefix)
        }

        switch claims.boolean("success") {
        case .invalid:
            return true
        case let .valid(success) where !success:
            return true
        case .absent, .valid:
            break
        }
        return claims.errorPresence == .valid(true) || claims.errorPresence == .invalid
    }

    static func actionOutcome(from result: AgentToolResult) -> DesktopActionOutcome.Projection? {
        self.actionOutcomeResolution(from: result.result).projection
    }

    static func actionOutcomeResolution(
        from value: AnyAgentToolValue) -> MCPToolResponseMetadataProjector.ActionOutcomeResolution
    {
        self.normalizedClaims(from: value).actionOutcome
    }

    static func normalizedClaims(from value: AnyAgentToolValue) -> NormalizedClaims {
        let containers = self.semanticContainers(from: value)
        guard !containers.isEmpty else { return .empty }
        let canonicalOutcome = self.canonicalOutcomeClaims(in: containers)
        let legacyBooleans = Dictionary(uniqueKeysWithValues: self.legacyBooleanKeys.map { key in
            let excludedIndexes = MCPToolResponseMetadataProjector.actionOutcomeKeys.contains(key)
                ? canonicalOutcome.carrierIndexes
                : []
            return (key, self.booleanResolution(
                for: key,
                in: containers,
                excluding: excludedIndexes))
        })
        return NormalizedClaims(
            actionOutcome: canonicalOutcome.resolution,
            legacyBooleans: legacyBooleans,
            errorPresence: self.presenceResolution(for: "error", in: containers),
            reasonPresence: self.presenceResolution(for: "reason", in: containers),
            turnBoundary: self.turnBoundaryResolution(in: containers))
    }

    private static func semanticContainers(
        from value: AnyAgentToolValue) -> [[String: AnyAgentToolValue]]
    {
        guard let payload = value.objectValue else { return [] }
        return [
            payload,
            payload["metadata"]?.objectValue,
            payload["meta"]?.objectValue,
        ].compactMap(\.self)
    }

    private static func canonicalOutcomeClaims(
        in containers: [[String: AnyAgentToolValue]]) -> CanonicalOutcomeClaims
    {
        var carrierIndexes: Set<Int> = []
        var resolvedProjection: DesktopActionOutcome.Projection?
        var invalid = false
        for (index, container) in containers.enumerated() {
            let outcomeFields = Dictionary(uniqueKeysWithValues: MCPToolResponseMetadataProjector
                .actionOutcomeKeys.compactMap { key in
                    container[key].map { (key, $0) }
                })
            guard MCPToolResponseMetadataProjector.requiredActionOutcomeKeys.isSubset(of: Set(outcomeFields.keys))
            else {
                continue
            }
            carrierIndexes.insert(index)
            guard let convertedFields = self.convertedOutcomeFields(outcomeFields) else {
                invalid = true
                continue
            }
            let resolution = MCPToolResponseMetadataProjector.actionOutcomeResolution(
                from: .object(convertedFields))
            switch resolution {
            case .absent:
                continue
            case .invalid:
                invalid = true
            case let .valid(projection):
                if let resolvedProjection, resolvedProjection != projection {
                    invalid = true
                } else {
                    resolvedProjection = projection
                }
            }
        }
        if invalid {
            return CanonicalOutcomeClaims(resolution: .invalid, carrierIndexes: carrierIndexes)
        }
        let resolution = resolvedProjection.map(MCPToolResponseMetadataProjector.ActionOutcomeResolution.valid) ??
            .absent
        return CanonicalOutcomeClaims(resolution: resolution, carrierIndexes: carrierIndexes)
    }

    private static func booleanResolution(
        for key: String,
        in containers: [[String: AnyAgentToolValue]],
        excluding excludedIndexes: Set<Int>) -> ClaimResolution<Bool>
    {
        let claims = containers.enumerated().compactMap { index, container in
            excludedIndexes.contains(index) ? nil : container[key]
        }
        guard !claims.isEmpty else { return .absent }
        let values = claims.compactMap(\.boolValue)
        guard values.count == claims.count, Set(values).count == 1, let value = values.first else {
            return .invalid
        }
        return .valid(value)
    }

    private static func presenceResolution(
        for key: String,
        in containers: [[String: AnyAgentToolValue]]) -> ClaimResolution<Bool>
    {
        let claims = containers.compactMap { $0[key] }
        guard !claims.isEmpty else { return .absent }
        let values = claims.map { value in
            guard !value.isNull else { return false }
            guard let string = value.stringValue else { return true }
            guard self.isWithinUTF8Limit(string, maximum: 4096) else { return true }
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard Set(values).count == 1, let value = values.first else { return .invalid }
        return .valid(value)
    }

    private static func turnBoundaryResolution(
        in containers: [[String: AnyAgentToolValue]]) -> ClaimResolution<TurnBoundaryProjection>
    {
        let claims = containers.compactMap { $0["turn_boundary"] }
        guard !claims.isEmpty else { return .absent }
        var projections: [TurnBoundaryProjection] = []
        projections.reserveCapacity(claims.count)
        for claim in claims {
            guard let object = claim.objectValue,
                  let projection = self.turnBoundaryProjection(from: object)
            else {
                return .invalid
            }
            projections.append(projection)
        }
        guard let projection = projections.first,
              projections.dropFirst().allSatisfy({ $0 == projection })
        else {
            return .invalid
        }
        return .valid(projection)
    }

    private static func turnBoundaryProjection(
        from object: [String: AnyAgentToolValue]) -> TurnBoundaryProjection?
    {
        let booleanKeys = ["continue_next_step", "stop_agent", "stop_after_current_step"]
        var booleans: [String: Bool] = [:]
        for key in booleanKeys {
            guard let claim = object[key] else { continue }
            guard let value = claim.boolValue else { return nil }
            booleans[key] = value
        }

        let disposition: TurnBoundaryProjection.Disposition?
        if let claim = object["disposition"] {
            guard let value = claim.stringValue,
                  self.isWithinUTF8Limit(value, maximum: 32),
                  let parsed = TurnBoundaryProjection.Disposition(rawValue: value)
            else {
                return nil
            }
            disposition = parsed
        } else {
            disposition = nil
        }

        let reason: String?
        if let claim = object["reason"] {
            guard let value = claim.stringValue,
                  self.isWithinUTF8Limit(value, maximum: 4096),
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            reason = value
        } else {
            reason = nil
        }

        let continueNextStep = booleans["continue_next_step"]
        let stopAgent = booleans["stop_agent"]
        let stopAfterCurrentStep = booleans["stop_after_current_step"]
        let continues = disposition == .continueNextStep || continueNextStep == true
        let stops = disposition == .stopAgent || stopAgent == true ||
            (stopAfterCurrentStep == true && !continues)
        guard !(continues && stops),
              !(disposition == .continueNextStep && continueNextStep == false),
              !(disposition == .stopAgent && stopAgent == false),
              !((continues || stops) && stopAfterCurrentStep == false),
              !(continues || stops) || reason != nil
        else {
            return nil
        }

        let normalizedDisposition: TurnBoundaryProjection.Disposition? = if continues {
            .continueNextStep
        } else if stops {
            .stopAgent
        } else {
            nil
        }
        guard let normalizedDisposition, let reason else { return nil }
        return TurnBoundaryProjection(
            disposition: normalizedDisposition,
            reason: reason)
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
        if let string = value.stringValue, self.isWithinUTF8Limit(string, maximum: 128) {
            return .string(string)
        }
        return nil
    }

    private static func isWithinUTF8Limit(_ value: String, maximum: Int) -> Bool {
        value.utf8.prefix(maximum + 1).count <= maximum
    }
}
