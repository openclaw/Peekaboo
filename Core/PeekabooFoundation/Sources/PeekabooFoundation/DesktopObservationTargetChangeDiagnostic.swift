import Foundation

/// Bounded, value-free context for an exact-window target change.
public struct DesktopObservationTargetChangeDiagnostic: Codable, Sendable, Equatable {
    public enum Classification: String, Codable, Sendable, CaseIterable {
        case identityUnavailable = "identity_unavailable"
        case identityMismatch = "identity_mismatch"
        case resolvedTargetMismatch = "resolved_target_mismatch"
        case captureReceiptMismatch = "capture_receipt_mismatch"
        case unknown

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum Phase: String, Codable, Sendable, CaseIterable {
        case targetResolution = "target_resolution"
        case beforeOperation = "before_operation"
        case afterCapture = "after_capture"
        case afterOperation = "after_operation"
        case unknown

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum ChangedComponent: String, Codable, Sendable, CaseIterable {
        case windowID = "window_id"
        case ownerPID = "owner_pid"
        case ownerProcessGeneration = "owner_process_generation"
        case bounds
        case unknown

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct PassiveRecovery: Codable, Sendable, Equatable {
        public enum FinalStatus: String, Codable, Sendable, CaseIterable {
            case notAttempted = "not_attempted"
            case exhausted
            case unknown

            public init(from decoder: any Decoder) throws {
                self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        public let attempted: Bool
        public let attemptCount: Int
        public let finalStatus: FinalStatus

        public init(attempted: Bool, attemptCount: Int, finalStatus: FinalStatus) {
            self.attempted = attempted
            self.attemptCount = attemptCount
            self.finalStatus = finalStatus
        }

        public static let notAttempted = Self(attempted: false, attemptCount: 0, finalStatus: .notAttempted)
        public static let exhausted = Self(attempted: true, attemptCount: 1, finalStatus: .exhausted)

        private enum CodingKeys: String, CodingKey {
            case attempted
            case attemptCount = "attempt_count"
            case finalStatus = "final_status"
        }
    }

    public let classification: Classification
    public let phase: Phase
    public let changedComponents: [ChangedComponent]?
    public let passiveRecovery: PassiveRecovery

    public init(
        classification: Classification,
        phase: Phase,
        changedComponents: [ChangedComponent]? = nil,
        passiveRecovery: PassiveRecovery = .notAttempted)
    {
        self.classification = classification
        self.phase = phase
        self.changedComponents = classification == .identityMismatch
            ? changedComponents.map { components in ChangedComponent.allCases.filter { components.contains($0) } }
            : nil
        self.passiveRecovery = passiveRecovery
    }

    public func withPassiveRecovery(_ recovery: PassiveRecovery) -> Self {
        Self(
            classification: self.classification,
            phase: self.phase,
            changedComponents: self.changedComponents,
            passiveRecovery: recovery)
    }

    private enum CodingKeys: String, CodingKey {
        case classification
        case phase
        case changedComponents = "changed_components"
        case passiveRecovery = "passive_recovery"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            classification: container.decode(Classification.self, forKey: .classification),
            phase: container.decode(Phase.self, forKey: .phase),
            changedComponents: container.decodeIfPresent([ChangedComponent].self, forKey: .changedComponents),
            passiveRecovery: container.decode(PassiveRecovery.self, forKey: .passiveRecovery))
    }
}
