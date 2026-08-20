import Foundation

/// Monitor-owned, path-free evidence for one background certification interval.
///
/// The payload embeds the complete corpus that the monitor sealed. Digests in the corpus are
/// commitments over embedded typed values; none of them authorize a file, socket, command, or
/// caller-supplied byte sequence.
public struct PeekabooBridgeCertificationMonitorSealPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let evidence: Evidence
    public let sealReceipt: SealReceipt

    public init(schemaVersion: Int = 1, evidence: Evidence, sealReceipt: SealReceipt) {
        self.schemaVersion = schemaVersion
        self.evidence = evidence
        self.sealReceipt = sealReceipt
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case evidence
        case sealReceipt
    }

    public init(from decoder: any Decoder) throws {
        try PeekabooBridgeClosedPayload.requireExactKeys(
            CodingKeys.self,
            from: decoder,
            description: "Certification monitor seal")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.evidence = try container.decode(Evidence.self, forKey: .evidence)
        self.sealReceipt = try container.decode(SealReceipt.self, forKey: .sealReceipt)
    }
}

extension PeekabooBridgeCertificationMonitorSealPayload {
    public struct Evidence: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let executionNonce: String
        public let monitorInstanceID: UUID
        public let source: Source
        public let monitorProcess: ProcessIdentity
        public let sentinel: WindowTarget
        public let foregroundController: ProcessIdentity
        public let foregroundTarget: WindowTarget
        public let producerSets: ProducerSets
        public let fences: [Fence]
        public let baselineSample: MonitorSample
        public let finalSample: MonitorSample
        public let foregroundPlan: ForegroundPlan
        public let violationRecords: [ViolationRecord]
        public let contaminationRecords: [ContaminationRecord]
        public let baselineCommitmentSHA256: String
        public let historyCommitmentSHA256: String
        public let crashEvidence: CrashEvidence
        public let restoration: RestorationSummary

        public init(
            schemaVersion: Int = 1,
            executionNonce: String,
            monitorInstanceID: UUID,
            source: Source,
            monitorProcess: ProcessIdentity,
            sentinel: WindowTarget,
            foregroundController: ProcessIdentity,
            foregroundTarget: WindowTarget,
            producerSets: ProducerSets,
            fences: [Fence],
            baselineSample: MonitorSample,
            finalSample: MonitorSample,
            foregroundPlan: ForegroundPlan,
            violationRecords: [ViolationRecord],
            contaminationRecords: [ContaminationRecord],
            baselineCommitmentSHA256: String,
            historyCommitmentSHA256: String,
            crashEvidence: CrashEvidence,
            restoration: RestorationSummary)
        {
            self.schemaVersion = schemaVersion
            self.executionNonce = executionNonce
            self.monitorInstanceID = monitorInstanceID
            self.source = source
            self.monitorProcess = monitorProcess
            self.sentinel = sentinel
            self.foregroundController = foregroundController
            self.foregroundTarget = foregroundTarget
            self.producerSets = producerSets
            self.fences = fences
            self.baselineSample = baselineSample
            self.finalSample = finalSample
            self.foregroundPlan = foregroundPlan
            self.violationRecords = violationRecords
            self.contaminationRecords = contaminationRecords
            self.baselineCommitmentSHA256 = baselineCommitmentSHA256
            self.historyCommitmentSHA256 = historyCommitmentSHA256
            self.crashEvidence = crashEvidence
            self.restoration = restoration
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion
            case executionNonce
            case monitorInstanceID
            case source
            case monitorProcess
            case sentinel
            case foregroundController
            case foregroundTarget
            case producerSets
            case fences
            case baselineSample
            case finalSample
            case foregroundPlan
            case violationRecords
            case contaminationRecords
            case baselineCommitmentSHA256
            case historyCommitmentSHA256
            case crashEvidence
            case restoration
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Certification monitor evidence")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
            self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
            self.source = try container.decode(Source.self, forKey: .source)
            self.monitorProcess = try container.decode(ProcessIdentity.self, forKey: .monitorProcess)
            self.sentinel = try container.decode(WindowTarget.self, forKey: .sentinel)
            self.foregroundController = try container.decode(ProcessIdentity.self, forKey: .foregroundController)
            self.foregroundTarget = try container.decode(WindowTarget.self, forKey: .foregroundTarget)
            self.producerSets = try container.decode(ProducerSets.self, forKey: .producerSets)
            self.fences = try container.decode([Fence].self, forKey: .fences)
            self.baselineSample = try container.decode(MonitorSample.self, forKey: .baselineSample)
            self.finalSample = try container.decode(MonitorSample.self, forKey: .finalSample)
            self.foregroundPlan = try container.decode(ForegroundPlan.self, forKey: .foregroundPlan)
            self.violationRecords = try container.decode([ViolationRecord].self, forKey: .violationRecords)
            self.contaminationRecords = try container.decode(
                [ContaminationRecord].self,
                forKey: .contaminationRecords)
            self.baselineCommitmentSHA256 = try container.decode(
                String.self,
                forKey: .baselineCommitmentSHA256)
            self.historyCommitmentSHA256 = try container.decode(String.self, forKey: .historyCommitmentSHA256)
            self.crashEvidence = try container.decode(CrashEvidence.self, forKey: .crashEvidence)
            self.restoration = try container.decode(RestorationSummary.self, forKey: .restoration)
        }
    }

    public struct Source: Codable, Equatable, Sendable {
        public let producerSourceCommit: String
        public let producerExecutableSHA256: String
        public let monitorSourceSHA256: String
        public let coordinatorSourceSHA256: String

        public init(
            producerSourceCommit: String,
            producerExecutableSHA256: String,
            monitorSourceSHA256: String,
            coordinatorSourceSHA256: String)
        {
            self.producerSourceCommit = producerSourceCommit
            self.producerExecutableSHA256 = producerExecutableSHA256
            self.monitorSourceSHA256 = monitorSourceSHA256
            self.coordinatorSourceSHA256 = coordinatorSourceSHA256
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case producerSourceCommit
            case producerExecutableSHA256
            case monitorSourceSHA256
            case coordinatorSourceSHA256
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor source")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.producerSourceCommit = try container.decode(String.self, forKey: .producerSourceCommit)
            self.producerExecutableSHA256 = try container.decode(String.self, forKey: .producerExecutableSHA256)
            self.monitorSourceSHA256 = try container.decode(String.self, forKey: .monitorSourceSHA256)
            self.coordinatorSourceSHA256 = try container.decode(String.self, forKey: .coordinatorSourceSHA256)
        }
    }

    public struct ProcessIdentity: Codable, Equatable, Hashable, Sendable {
        public let processIdentifier: Int32
        public let processStartIdentity: UInt64
        public let codeSignatureHash: String

        public init(processIdentifier: Int32, processStartIdentity: UInt64, codeSignatureHash: String) {
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.codeSignatureHash = codeSignatureHash
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case processIdentifier
            case processStartIdentity
            case codeSignatureHash
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor process identity")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
            let decimal = try container.decode(String.self, forKey: .processStartIdentity)
            guard let startIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .processStartIdentity,
                    in: container,
                    debugDescription: "Monitor process generation is not canonical")
            }
            self.processStartIdentity = startIdentity
            self.codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.processIdentifier, forKey: .processIdentifier)
            try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
            try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
        }
    }

    public enum TargetScope: String, Codable, Sendable {
        case window
    }

    public struct Bounds: Codable, Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case x
            case y
            case width
            case height
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor target bounds")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.x = try container.decode(Double.self, forKey: .x)
            self.y = try container.decode(Double.self, forKey: .y)
            self.width = try container.decode(Double.self, forKey: .width)
            self.height = try container.decode(Double.self, forKey: .height)
        }
    }

    public struct WindowTarget: Codable, Equatable, Sendable {
        public let scope: TargetScope
        public let processIdentifier: Int32
        public let processStartIdentity: UInt64
        public let windowID: UInt32
        public let bounds: Bounds
        public let isMinimized: Bool?

        public init(
            scope: TargetScope = .window,
            processIdentifier: Int32,
            processStartIdentity: UInt64,
            windowID: UInt32,
            bounds: Bounds,
            isMinimized: Bool?)
        {
            self.scope = scope
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.windowID = windowID
            self.bounds = bounds
            self.isMinimized = isMinimized
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case scope
            case processIdentifier
            case processStartIdentity
            case windowID
            case bounds
            case isMinimized
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor window target")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.scope = try container.decode(TargetScope.self, forKey: .scope)
            self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
            let decimal = try container.decode(String.self, forKey: .processStartIdentity)
            guard let startIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .processStartIdentity,
                    in: container,
                    debugDescription: "Monitor window process generation is not canonical")
            }
            self.processStartIdentity = startIdentity
            self.windowID = try container.decode(UInt32.self, forKey: .windowID)
            self.bounds = try container.decode(Bounds.self, forKey: .bounds)
            self.isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.scope, forKey: .scope)
            try container.encode(self.processIdentifier, forKey: .processIdentifier)
            try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
            try container.encode(self.windowID, forKey: .windowID)
            try container.encode(self.bounds, forKey: .bounds)
            try container.encode(self.isMinimized, forKey: .isMinimized)
        }
    }

    public enum ProducerRole: String, Codable, Sendable {
        case bridge
        case foregroundController = "foreground-controller"
    }

    public struct AllowedProducer: Codable, Equatable, Hashable, Sendable {
        public let processIdentifier: Int32
        public let processStartIdentity: UInt64
        public let role: ProducerRole

        public init(processIdentifier: Int32, processStartIdentity: UInt64, role: ProducerRole) {
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.role = role
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case processIdentifier
            case processStartIdentity
            case role
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Allowed monitor producer")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
            let decimal = try container.decode(String.self, forKey: .processStartIdentity)
            guard let startIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .processStartIdentity,
                    in: container,
                    debugDescription: "Allowed producer generation is not canonical")
            }
            self.processStartIdentity = startIdentity
            self.role = try container.decode(ProducerRole.self, forKey: .role)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.processIdentifier, forKey: .processIdentifier)
            try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
            try container.encode(self.role, forKey: .role)
        }
    }

    public struct ForegroundAuthorization: Codable, Equatable, Sendable {
        public let active: Bool
        public let target: WindowTarget?

        public init(active: Bool, target: WindowTarget?) {
            self.active = active
            self.target = target
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case active
            case target
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor foreground authorization")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.active = try container.decode(Bool.self, forKey: .active)
            self.target = try container.decodeIfPresent(WindowTarget.self, forKey: .target)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.active, forKey: .active)
            try container.encode(self.target, forKey: .target)
        }
    }

    public struct ProducerSet: Codable, Equatable, Sendable {
        public let revision: UInt64
        public let executionNonce: String
        public let monitorInstanceID: UUID
        public let producers: [AllowedProducer]
        public let foreground: ForegroundAuthorization

        public init(
            revision: UInt64,
            executionNonce: String,
            monitorInstanceID: UUID,
            producers: [AllowedProducer],
            foreground: ForegroundAuthorization)
        {
            self.revision = revision
            self.executionNonce = executionNonce
            self.monitorInstanceID = monitorInstanceID
            self.producers = producers
            self.foreground = foreground
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case revision
            case executionNonce
            case monitorInstanceID
            case producers
            case foreground
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor producer set")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let decimal = try container.decode(String.self, forKey: .revision)
            guard let revision = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .revision,
                    in: container,
                    debugDescription: "Monitor producer revision is not canonical")
            }
            self.revision = revision
            self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
            self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
            self.producers = try container.decode([AllowedProducer].self, forKey: .producers)
            self.foreground = try container.decode(ForegroundAuthorization.self, forKey: .foreground)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(self.revision), forKey: .revision)
            try container.encode(self.executionNonce, forKey: .executionNonce)
            try container.encode(self.monitorInstanceID, forKey: .monitorInstanceID)
            try container.encode(self.producers, forKey: .producers)
            try container.encode(self.foreground, forKey: .foreground)
        }
    }

    public struct ProducerSets: Codable, Equatable, Sendable {
        public let baseline: ProducerSet
        public let grant: ProducerSet
        public let revoke: ProducerSet

        public init(baseline: ProducerSet, grant: ProducerSet, revoke: ProducerSet) {
            self.baseline = baseline
            self.grant = grant
            self.revoke = revoke
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case baseline
            case grant
            case revoke
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor producer-set history")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.baseline = try container.decode(ProducerSet.self, forKey: .baseline)
            self.grant = try container.decode(ProducerSet.self, forKey: .grant)
            self.revoke = try container.decode(ProducerSet.self, forKey: .revoke)
        }
    }

    public enum FenceName: String, Codable, CaseIterable, Sendable {
        case baselineStable = "baseline-stable"
        case grantStable = "grant-stable"
        case operationsStart = "operations-start"
        case operationsComplete = "operations-complete"
        case revokeStable = "revoke-stable"
        case finalStable = "final-stable"
    }

    public enum MonitorPhase: String, Codable, Sendable {
        case setup
        case running
        case complete
    }

    public struct Heartbeat: Codable, Equatable, Sendable {
        public let sequence: UInt64
        public let monotonicMicroseconds: UInt64
        public let wallClockMilliseconds: Int64
        public let lastCleanSequence: UInt64
        public let contaminationRetries: Int
        public let contaminationBlocked: Bool
        public let inputAttributionAvailable: Bool
        public let allowedProducerRevision: UInt64
        public let phase: MonitorPhase
        public let cursorMovementObserved: Bool
        public let pendingActivationCount: Int
        public let pendingFocusedWindowChange: Bool
        public let authorizationEpoch: UInt64
        public let transitionAcknowledged: Bool
        public let foregroundActive: Bool
        public let foregroundTargetProcessIdentifier: Int32?
        public let foregroundTargetWindowID: UInt32?
        public let attributedForegroundEventCount: Int
        public let attributedForegroundSourceProcessIdentifiers: [Int32]
        public let foregroundActivityObserved: Bool
        public let executionNonce: String
        public let monitorInstanceID: UUID
        public let historyCommitmentSHA256: String

        public init(
            sequence: UInt64,
            monotonicMicroseconds: UInt64,
            wallClockMilliseconds: Int64,
            lastCleanSequence: UInt64,
            contaminationRetries: Int,
            contaminationBlocked: Bool,
            inputAttributionAvailable: Bool,
            allowedProducerRevision: UInt64,
            phase: MonitorPhase,
            cursorMovementObserved: Bool,
            pendingActivationCount: Int,
            pendingFocusedWindowChange: Bool,
            authorizationEpoch: UInt64,
            transitionAcknowledged: Bool,
            foregroundActive: Bool,
            foregroundTargetProcessIdentifier: Int32?,
            foregroundTargetWindowID: UInt32?,
            attributedForegroundEventCount: Int,
            attributedForegroundSourceProcessIdentifiers: [Int32],
            foregroundActivityObserved: Bool,
            executionNonce: String,
            monitorInstanceID: UUID,
            historyCommitmentSHA256: String)
        {
            self.sequence = sequence
            self.monotonicMicroseconds = monotonicMicroseconds
            self.wallClockMilliseconds = wallClockMilliseconds
            self.lastCleanSequence = lastCleanSequence
            self.contaminationRetries = contaminationRetries
            self.contaminationBlocked = contaminationBlocked
            self.inputAttributionAvailable = inputAttributionAvailable
            self.allowedProducerRevision = allowedProducerRevision
            self.phase = phase
            self.cursorMovementObserved = cursorMovementObserved
            self.pendingActivationCount = pendingActivationCount
            self.pendingFocusedWindowChange = pendingFocusedWindowChange
            self.authorizationEpoch = authorizationEpoch
            self.transitionAcknowledged = transitionAcknowledged
            self.foregroundActive = foregroundActive
            self.foregroundTargetProcessIdentifier = foregroundTargetProcessIdentifier
            self.foregroundTargetWindowID = foregroundTargetWindowID
            self.attributedForegroundEventCount = attributedForegroundEventCount
            self.attributedForegroundSourceProcessIdentifiers = attributedForegroundSourceProcessIdentifiers
            self.foregroundActivityObserved = foregroundActivityObserved
            self.executionNonce = executionNonce
            self.monitorInstanceID = monitorInstanceID
            self.historyCommitmentSHA256 = historyCommitmentSHA256
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case sequence
            case monotonicMicroseconds
            case wallClockMilliseconds
            case lastCleanSequence
            case contaminationRetries
            case contaminationBlocked
            case inputAttributionAvailable
            case allowedProducerRevision
            case phase
            case cursorMovementObserved
            case pendingActivationCount
            case pendingFocusedWindowChange
            case authorizationEpoch
            case transitionAcknowledged
            case foregroundActive
            case foregroundTargetProcessIdentifier
            case foregroundTargetWindowID
            case attributedForegroundEventCount
            case attributedForegroundSourceProcessIdentifiers
            case foregroundActivityObserved
            case executionNonce
            case monitorInstanceID
            case historyCommitmentSHA256
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor heartbeat")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sequence = try Self.decodeUInt64(.sequence, from: container)
            self.monotonicMicroseconds = try Self.decodeUInt64(.monotonicMicroseconds, from: container)
            self.wallClockMilliseconds = try container.decode(Int64.self, forKey: .wallClockMilliseconds)
            self.lastCleanSequence = try Self.decodeUInt64(.lastCleanSequence, from: container)
            self.contaminationRetries = try container.decode(Int.self, forKey: .contaminationRetries)
            self.contaminationBlocked = try container.decode(Bool.self, forKey: .contaminationBlocked)
            self.inputAttributionAvailable = try container.decode(Bool.self, forKey: .inputAttributionAvailable)
            self.allowedProducerRevision = try Self.decodeUInt64(.allowedProducerRevision, from: container)
            self.phase = try container.decode(MonitorPhase.self, forKey: .phase)
            self.cursorMovementObserved = try container.decode(Bool.self, forKey: .cursorMovementObserved)
            self.pendingActivationCount = try container.decode(Int.self, forKey: .pendingActivationCount)
            self.pendingFocusedWindowChange = try container.decode(
                Bool.self,
                forKey: .pendingFocusedWindowChange)
            self.authorizationEpoch = try Self.decodeUInt64(.authorizationEpoch, from: container)
            self.transitionAcknowledged = try container.decode(Bool.self, forKey: .transitionAcknowledged)
            self.foregroundActive = try container.decode(Bool.self, forKey: .foregroundActive)
            self.foregroundTargetProcessIdentifier = try container.decodeIfPresent(
                Int32.self,
                forKey: .foregroundTargetProcessIdentifier)
            self.foregroundTargetWindowID = try container.decodeIfPresent(
                UInt32.self,
                forKey: .foregroundTargetWindowID)
            self.attributedForegroundEventCount = try container.decode(
                Int.self,
                forKey: .attributedForegroundEventCount)
            self.attributedForegroundSourceProcessIdentifiers = try container.decode(
                [Int32].self,
                forKey: .attributedForegroundSourceProcessIdentifiers)
            self.foregroundActivityObserved = try container.decode(Bool.self, forKey: .foregroundActivityObserved)
            self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
            self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
            self.historyCommitmentSHA256 = try container.decode(String.self, forKey: .historyCommitmentSHA256)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(self.sequence), forKey: .sequence)
            try container.encode(String(self.monotonicMicroseconds), forKey: .monotonicMicroseconds)
            try container.encode(self.wallClockMilliseconds, forKey: .wallClockMilliseconds)
            try container.encode(String(self.lastCleanSequence), forKey: .lastCleanSequence)
            try container.encode(self.contaminationRetries, forKey: .contaminationRetries)
            try container.encode(self.contaminationBlocked, forKey: .contaminationBlocked)
            try container.encode(self.inputAttributionAvailable, forKey: .inputAttributionAvailable)
            try container.encode(String(self.allowedProducerRevision), forKey: .allowedProducerRevision)
            try container.encode(self.phase, forKey: .phase)
            try container.encode(self.cursorMovementObserved, forKey: .cursorMovementObserved)
            try container.encode(self.pendingActivationCount, forKey: .pendingActivationCount)
            try container.encode(self.pendingFocusedWindowChange, forKey: .pendingFocusedWindowChange)
            try container.encode(String(self.authorizationEpoch), forKey: .authorizationEpoch)
            try container.encode(self.transitionAcknowledged, forKey: .transitionAcknowledged)
            try container.encode(self.foregroundActive, forKey: .foregroundActive)
            try container.encode(self.foregroundTargetProcessIdentifier, forKey: .foregroundTargetProcessIdentifier)
            try container.encode(self.foregroundTargetWindowID, forKey: .foregroundTargetWindowID)
            try container.encode(self.attributedForegroundEventCount, forKey: .attributedForegroundEventCount)
            try container.encode(
                self.attributedForegroundSourceProcessIdentifiers,
                forKey: .attributedForegroundSourceProcessIdentifiers)
            try container.encode(self.foregroundActivityObserved, forKey: .foregroundActivityObserved)
            try container.encode(self.executionNonce, forKey: .executionNonce)
            try container.encode(self.monitorInstanceID, forKey: .monitorInstanceID)
            try container.encode(self.historyCommitmentSHA256, forKey: .historyCommitmentSHA256)
        }

        private static func decodeUInt64(
            _ key: CodingKeys,
            from container: KeyedDecodingContainer<CodingKeys>) throws -> UInt64
        {
            let decimal = try container.decode(String.self, forKey: key)
            guard let value = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "Monitor heartbeat integer is not canonical")
            }
            return value
        }
    }

    public struct Fence: Codable, Equatable, Sendable {
        public let name: FenceName
        public let heartbeat: Heartbeat

        public init(name: FenceName, heartbeat: Heartbeat) {
            self.name = name
            self.heartbeat = heartbeat
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case heartbeat
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor fence")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(FenceName.self, forKey: .name)
            self.heartbeat = try container.decode(Heartbeat.self, forKey: .heartbeat)
        }
    }

    public struct MonitorSample: Codable, Equatable, Sendable {
        public let frontmostProcessIdentifier: Int32
        public let frontmostWindowID: UInt32
        public let clipboardChangeCount: Int64
        public let clipboardDigest: String

        public init(
            frontmostProcessIdentifier: Int32,
            frontmostWindowID: UInt32,
            clipboardChangeCount: Int64,
            clipboardDigest: String)
        {
            self.frontmostProcessIdentifier = frontmostProcessIdentifier
            self.frontmostWindowID = frontmostWindowID
            self.clipboardChangeCount = clipboardChangeCount
            self.clipboardDigest = clipboardDigest
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case frontmostProcessIdentifier
            case frontmostWindowID
            case clipboardChangeCount
            case clipboardDigest
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor sample")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.frontmostProcessIdentifier = try container.decode(
                Int32.self,
                forKey: .frontmostProcessIdentifier)
            self.frontmostWindowID = try container.decode(UInt32.self, forKey: .frontmostWindowID)
            self.clipboardChangeCount = try container.decode(Int64.self, forKey: .clipboardChangeCount)
            self.clipboardDigest = try container.decode(String.self, forKey: .clipboardDigest)
        }
    }

    public struct SemanticElement: Codable, Equatable, Sendable {
        public let role: String
        public let identifier: String?
        public let title: String?

        public init(role: String, identifier: String?, title: String?) {
            self.role = role
            self.identifier = identifier
            self.title = title
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case role
            case identifier
            case title
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor semantic element")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.role = try container.decode(String.self, forKey: .role)
            self.identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
            self.title = try container.decodeIfPresent(String.self, forKey: .title)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.role, forKey: .role)
            try container.encode(self.identifier, forKey: .identifier)
            try container.encode(self.title, forKey: .title)
        }
    }

    public struct BuildIdentity: Codable, Equatable, Sendable {
        public let sourceCommit: String
        public let executableSHA256: String
        public let signingIdentifier: String
        public let teamIdentifier: String

        public init(
            sourceCommit: String,
            executableSHA256: String,
            signingIdentifier: String,
            teamIdentifier: String)
        {
            self.sourceCommit = sourceCommit
            self.executableSHA256 = executableSHA256
            self.signingIdentifier = signingIdentifier
            self.teamIdentifier = teamIdentifier
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case sourceCommit
            case executableSHA256
            case signingIdentifier
            case teamIdentifier
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor foreground observer build")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.sourceCommit = try container.decode(String.self, forKey: .sourceCommit)
            self.executableSHA256 = try container.decode(String.self, forKey: .executableSHA256)
            self.signingIdentifier = try container.decode(String.self, forKey: .signingIdentifier)
            self.teamIdentifier = try container.decode(String.self, forKey: .teamIdentifier)
        }
    }

    public struct ForegroundPlan: Codable, Equatable, Sendable {
        public let requestMarker: String
        public let expectedValueSHA256: String
        public let baselineValueSHA256: String
        public let observer: ProcessIdentity
        public let observerBuild: BuildIdentity
        public let semanticElement: SemanticElement
        public let target: WindowTarget

        public init(
            requestMarker: String,
            expectedValueSHA256: String,
            baselineValueSHA256: String,
            observer: ProcessIdentity,
            observerBuild: BuildIdentity,
            semanticElement: SemanticElement,
            target: WindowTarget)
        {
            self.requestMarker = requestMarker
            self.expectedValueSHA256 = expectedValueSHA256
            self.baselineValueSHA256 = baselineValueSHA256
            self.observer = observer
            self.observerBuild = observerBuild
            self.semanticElement = semanticElement
            self.target = target
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case requestMarker
            case expectedValueSHA256
            case baselineValueSHA256
            case observer
            case observerBuild
            case semanticElement
            case target
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor foreground plan")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.requestMarker = try container.decode(String.self, forKey: .requestMarker)
            self.expectedValueSHA256 = try container.decode(String.self, forKey: .expectedValueSHA256)
            self.baselineValueSHA256 = try container.decode(String.self, forKey: .baselineValueSHA256)
            self.observer = try container.decode(ProcessIdentity.self, forKey: .observer)
            self.observerBuild = try container.decode(BuildIdentity.self, forKey: .observerBuild)
            self.semanticElement = try container.decode(SemanticElement.self, forKey: .semanticElement)
            self.target = try container.decode(WindowTarget.self, forKey: .target)
        }
    }

    public struct ViolationRecord: Codable, Equatable, Sendable {
        public let kind: String
        public let expected: String
        public let actual: String

        public init(kind: String, expected: String, actual: String) {
            self.kind = kind
            self.expected = expected
            self.actual = actual
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case kind
            case expected
            case actual
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor violation")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = try container.decode(String.self, forKey: .kind)
            self.expected = try container.decode(String.self, forKey: .expected)
            self.actual = try container.decode(String.self, forKey: .actual)
        }
    }

    public struct ContaminationRecord: Codable, Equatable, Sendable {
        public let state: String
        public let retry: Int
        public let sequence: UInt64
        public let sourceProcessIdentifiers: [Int32]
        public let eventTypes: [UInt32]

        public init(
            state: String,
            retry: Int,
            sequence: UInt64,
            sourceProcessIdentifiers: [Int32],
            eventTypes: [UInt32])
        {
            self.state = state
            self.retry = retry
            self.sequence = sequence
            self.sourceProcessIdentifiers = sourceProcessIdentifiers
            self.eventTypes = eventTypes
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case state
            case retry
            case sequence
            case sourceProcessIdentifiers
            case eventTypes
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor contamination")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.state = try container.decode(String.self, forKey: .state)
            self.retry = try container.decode(Int.self, forKey: .retry)
            let decimal = try container.decode(String.self, forKey: .sequence)
            guard let sequence = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .sequence,
                    in: container,
                    debugDescription: "Monitor contamination sequence is not canonical")
            }
            self.sequence = sequence
            self.sourceProcessIdentifiers = try container.decode([Int32].self, forKey: .sourceProcessIdentifiers)
            self.eventTypes = try container.decode([UInt32].self, forKey: .eventTypes)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(self.state, forKey: .state)
            try container.encode(self.retry, forKey: .retry)
            try container.encode(String(self.sequence), forKey: .sequence)
            try container.encode(self.sourceProcessIdentifiers, forKey: .sourceProcessIdentifiers)
            try container.encode(self.eventTypes, forKey: .eventTypes)
        }
    }

    public enum CrashScanDomain: String, Codable, Sendable {
        case currentUserDiagnosticReports
    }

    public struct CrashEntry: Codable, Equatable, Sendable {
        public let name: String
        public let size: Int64
        public let modifiedAtUnixMilliseconds: Int64
        public let sha256: String

        public init(name: String, size: Int64, modifiedAtUnixMilliseconds: Int64, sha256: String) {
            self.name = name
            self.size = size
            self.modifiedAtUnixMilliseconds = modifiedAtUnixMilliseconds
            self.sha256 = sha256
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case name
            case size
            case modifiedAtUnixMilliseconds
            case sha256
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor crash entry")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try container.decode(String.self, forKey: .name)
            self.size = try container.decode(Int64.self, forKey: .size)
            self.modifiedAtUnixMilliseconds = try container.decode(
                Int64.self,
                forKey: .modifiedAtUnixMilliseconds)
            self.sha256 = try container.decode(String.self, forKey: .sha256)
        }
    }

    public struct CrashEvidence: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let scanDomain: CrashScanDomain
        public let prefixes: [String]
        public let baseline: [CrashEntry]
        public let final: [CrashEntry]
        public let newReports: [CrashEntry]

        public init(
            schemaVersion: Int = 1,
            scanDomain: CrashScanDomain,
            prefixes: [String],
            baseline: [CrashEntry],
            final: [CrashEntry],
            newReports: [CrashEntry])
        {
            self.schemaVersion = schemaVersion
            self.scanDomain = scanDomain
            self.prefixes = prefixes
            self.baseline = baseline
            self.final = final
            self.newReports = newReports
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion
            case scanDomain
            case prefixes
            case baseline
            case final
            case newReports
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor crash evidence")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            self.scanDomain = try container.decode(CrashScanDomain.self, forKey: .scanDomain)
            self.prefixes = try container.decode([String].self, forKey: .prefixes)
            self.baseline = try container.decode([CrashEntry].self, forKey: .baseline)
            self.final = try container.decode([CrashEntry].self, forKey: .final)
            self.newReports = try container.decode([CrashEntry].self, forKey: .newReports)
        }
    }

    public struct RestorationSummary: Codable, Equatable, Sendable {
        public let backgroundFinalBoundsSlotIDs: [String]
        public let foregroundPostconditionSHA256: String
        public let sentinelSampleSHA256: String
        public let foregroundRestored: Bool
        public let sentinelRestored: Bool

        public init(
            backgroundFinalBoundsSlotIDs: [String],
            foregroundPostconditionSHA256: String,
            sentinelSampleSHA256: String,
            foregroundRestored: Bool,
            sentinelRestored: Bool)
        {
            self.backgroundFinalBoundsSlotIDs = backgroundFinalBoundsSlotIDs
            self.foregroundPostconditionSHA256 = foregroundPostconditionSHA256
            self.sentinelSampleSHA256 = sentinelSampleSHA256
            self.foregroundRestored = foregroundRestored
            self.sentinelRestored = sentinelRestored
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case backgroundFinalBoundsSlotIDs
            case foregroundPostconditionSHA256
            case sentinelSampleSHA256
            case foregroundRestored
            case sentinelRestored
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor restoration summary")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.backgroundFinalBoundsSlotIDs = try container.decode(
                [String].self,
                forKey: .backgroundFinalBoundsSlotIDs)
            self.foregroundPostconditionSHA256 = try container.decode(
                String.self,
                forKey: .foregroundPostconditionSHA256)
            self.sentinelSampleSHA256 = try container.decode(String.self, forKey: .sentinelSampleSHA256)
            self.foregroundRestored = try container.decode(Bool.self, forKey: .foregroundRestored)
            self.sentinelRestored = try container.decode(Bool.self, forKey: .sentinelRestored)
        }
    }

    public enum SealPhase: String, Codable, Sendable {
        case sealed
    }

    public struct SealReceipt: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let executionNonce: String
        public let monitorInstanceID: UUID
        public let phase: SealPhase
        public let evidenceSHA256: String

        public init(
            schemaVersion: Int = 1,
            executionNonce: String,
            monitorInstanceID: UUID,
            phase: SealPhase = .sealed,
            evidenceSHA256: String)
        {
            self.schemaVersion = schemaVersion
            self.executionNonce = executionNonce
            self.monitorInstanceID = monitorInstanceID
            self.phase = phase
            self.evidenceSHA256 = evidenceSHA256
        }

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case schemaVersion
            case executionNonce
            case monitorInstanceID
            case phase
            case evidenceSHA256
        }

        public init(from decoder: any Decoder) throws {
            try PeekabooBridgeClosedPayload.requireExactKeys(
                CodingKeys.self,
                from: decoder,
                description: "Monitor seal receipt")
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            self.executionNonce = try container.decode(String.self, forKey: .executionNonce)
            self.monitorInstanceID = try container.decode(UUID.self, forKey: .monitorInstanceID)
            self.phase = try container.decode(SealPhase.self, forKey: .phase)
            self.evidenceSHA256 = try container.decode(String.self, forKey: .evidenceSHA256)
        }
    }

    func validate(context: PeekabooBridgeCertificationPayloadValidationContext) throws {
        let evidence = self.evidence
        guard self.schemaVersion == 1,
              evidence.schemaVersion == 1,
              evidence.executionNonce == context.request.executionNonce,
              evidence.monitorInstanceID == context.request.monitorInstanceID,
              PeekabooBridgeCertificationValidation.isLowerHex(evidence.executionNonce, count: 64),
              PeekabooBridgeCertificationValidation.isVersion4(evidence.monitorInstanceID)
        else { throw Self.invalid("run identity") }

        try Self.validateSource(evidence.source, context: context)
        try Self.validateProcess(evidence.monitorProcess)
        try Self.validateProcess(evidence.foregroundController)
        guard evidence.monitorProcess.processIdentifier == context.producer.processIdentifier,
              evidence.monitorProcess.processStartIdentity == context.producer.processStartIdentity,
              evidence.monitorProcess.codeSignatureHash == context.producer.codeSignatureHash
        else { throw Self.invalid("monitor process identity") }

        try Self.validateTarget(evidence.sentinel)
        try Self.validateTarget(evidence.foregroundTarget)
        guard evidence.foregroundController.processIdentifier != evidence.monitorProcess.processIdentifier,
              !Self.sameGeneration(evidence.foregroundController, evidence.foregroundTarget),
              !Self.sameGeneration(evidence.foregroundController, evidence.sentinel),
              !Self.sameGeneration(evidence.foregroundTarget, evidence.sentinel)
        else { throw Self.invalid("distinct monitor actors") }

        try Self.validateForegroundPlan(evidence.foregroundPlan, evidence: evidence)
        try Self.validateProducerSets(evidence.producerSets, evidence: evidence)
        try Self.validateFences(evidence.fences, evidence: evidence)
        try Self.validateSample(evidence.baselineSample, sentinel: evidence.sentinel)
        try Self.validateSample(evidence.finalSample, sentinel: evidence.sentinel)
        guard evidence.baselineSample.clipboardChangeCount == evidence.finalSample.clipboardChangeCount,
              evidence.baselineSample.clipboardDigest == evidence.finalSample.clipboardDigest,
              evidence.violationRecords.isEmpty,
              evidence.contaminationRecords.isEmpty
        else { throw Self.invalid("clean monitor interval") }

        try Self.validateCrashEvidence(evidence.crashEvidence)
        try Self.validateRestoration(evidence.restoration, evidence: evidence)
        guard PeekabooBridgeCertificationValidation.isLowerHex(
            evidence.baselineCommitmentSHA256,
            count: 64),
            PeekabooBridgeCertificationValidation.isLowerHex(evidence.historyCommitmentSHA256, count: 64),
            try evidence.baselineCommitmentSHA256 == (Self.baselineCommitment(for: evidence)),
            try evidence.historyCommitmentSHA256 == (Self.historyCommitment(for: evidence))
        else { throw Self.invalid("derived monitor commitments") }

        let receipt = self.sealReceipt
        guard receipt.schemaVersion == 1,
              receipt.executionNonce == evidence.executionNonce,
              receipt.monitorInstanceID == evidence.monitorInstanceID,
              receipt.phase == .sealed,
              PeekabooBridgeCertificationValidation.isLowerHex(receipt.evidenceSHA256, count: 64),
              try receipt.evidenceSHA256 == (Self.aggregateSHA256(domain: "monitor-evidence", value: evidence))
        else { throw Self.invalid("derived monitor seal receipt") }
    }

    private static func validateSource(
        _ source: Source,
        context: PeekabooBridgeCertificationPayloadValidationContext) throws
    {
        guard source.producerSourceCommit == context.producer.sourceCommit,
              source.producerExecutableSHA256 == context.producer.executableSHA256,
              PeekabooBridgeCertificationValidation.isLowerHex(source.producerSourceCommit, count: 40),
              PeekabooBridgeCertificationValidation.isLowerHex(source.producerExecutableSHA256, count: 64),
              PeekabooBridgeCertificationValidation.isLowerHex(source.monitorSourceSHA256, count: 64),
              PeekabooBridgeCertificationValidation.isLowerHex(source.coordinatorSourceSHA256, count: 64)
        else { throw self.invalid("source identity") }
    }

    private static func validateProcess(_ process: ProcessIdentity) throws {
        guard process.processIdentifier > 0,
              process.processStartIdentity > 0,
              process.processStartIdentity <= UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger),
              PeekabooBridgeCertificationValidation.isLowerHex(process.codeSignatureHash, count: 40)
        else { throw self.invalid("process generation") }
    }

    private static func validateTarget(_ target: WindowTarget) throws {
        let bounds = target.bounds
        guard target.scope == .window,
              target.processIdentifier > 0,
              target.processStartIdentity > 0,
              target.processStartIdentity <= UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger),
              target.windowID > 0,
              bounds.x.isFinite,
              bounds.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              abs(bounds.x) <= 10_000_000,
              abs(bounds.y) <= 10_000_000,
              bounds.width > 0,
              bounds.height > 0,
              bounds.width <= 10_000_000,
              bounds.height <= 10_000_000
        else { throw Self.invalid("window target") }
    }

    private static func validateForegroundPlan(_ plan: ForegroundPlan, evidence: Evidence) throws {
        try self.validateProcess(plan.observer)
        try self.validateTarget(plan.target)
        let marker = "peekaboo-foreground-postcondition:\(evidence.executionNonce)"
        let expectedMarkerDigest = PeekabooBridgeOperationReceiptCoding.sha256(Data(marker.utf8))
        let build = plan.observerBuild
        let semantic = plan.semanticElement
        guard plan.requestMarker == marker,
              plan.expectedValueSHA256 == expectedMarkerDigest,
              PeekabooBridgeCertificationValidation.isLowerHex(plan.baselineValueSHA256, count: 64),
              plan.baselineValueSHA256 != plan.expectedValueSHA256,
              plan.target == evidence.foregroundTarget,
              !Self.sameGeneration(plan.observer, evidence.foregroundController),
              !Self.sameGeneration(plan.observer, evidence.monitorProcess),
              build.signingIdentifier == "boo.peekaboo.peekaboo-certification-controller",
              build.teamIdentifier == PeekabooBridgeCertificationValidation.foundationTeamIdentifier,
              PeekabooBridgeCertificationValidation.isLowerHex(build.sourceCommit, count: 40),
              PeekabooBridgeCertificationValidation.isLowerHex(build.executableSHA256, count: 64),
              Self.isSafeText(semantic.role, maximumBytes: 256),
              Self.isSafeOptionalText(semantic.identifier, maximumBytes: 1024),
              Self.isSafeOptionalText(semantic.title, maximumBytes: 1024),
              semantic.identifier != nil || semantic.title != nil
        else { throw Self.invalid("foreground semantic plan") }
    }

    private static func validateProducerSets(_ sets: ProducerSets, evidence: Evidence) throws {
        try self.validateProducerSet(sets.baseline, evidence: evidence, revision: 1, active: false)
        try self.validateProducerSet(sets.grant, evidence: evidence, revision: 2, active: true)
        try self.validateProducerSet(sets.revoke, evidence: evidence, revision: 3, active: false)
        let foregroundProducer = AllowedProducer(
            processIdentifier: evidence.foregroundController.processIdentifier,
            processStartIdentity: evidence.foregroundController.processStartIdentity,
            role: .foregroundController)
        var expectedGrant = sets.baseline.producers
        expectedGrant.append(foregroundProducer)
        expectedGrant.sort(by: Self.producerPrecedes)
        guard sets.baseline.producers == sets.revoke.producers,
              sets.grant.producers == expectedGrant,
              !sets.baseline.producers.contains(where: { producer in
                  producer.processIdentifier == foregroundProducer.processIdentifier ||
                      producer.role == .foregroundController
              })
        else { throw Self.invalid("grant and revoke producer history") }
    }

    private static func validateProducerSet(
        _ set: ProducerSet,
        evidence: Evidence,
        revision: UInt64,
        active: Bool) throws
    {
        let processKeys = set.producers.map { "\($0.processIdentifier):\($0.processStartIdentity)" }
        guard set.revision == revision,
              set.executionNonce == evidence.executionNonce,
              set.monitorInstanceID == evidence.monitorInstanceID,
              (1...64).contains(set.producers.count),
              set.producers == set.producers.sorted(by: Self.producerPrecedes),
              Set(processKeys).count == processKeys.count,
              set.producers.allSatisfy({ producer in
                  producer.processIdentifier > 0 && producer.processStartIdentity > 0 &&
                      producer.processStartIdentity <=
                      UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger)
              }),
              set.foreground.active == active,
              set.foreground.target == (active ? evidence.foregroundTarget : nil)
        else { throw Self.invalid("producer set") }
    }

    private static func validateFences(_ fences: [Fence], evidence: Evidence) throws {
        let expected: [(FenceName, UInt64, MonitorPhase, Bool)] = [
            (.baselineStable, 1, .setup, false),
            (.grantStable, 2, .setup, true),
            (.operationsStart, 2, .running, true),
            (.operationsComplete, 2, .running, true),
            (.revokeStable, 3, .running, false),
            (.finalStable, 3, .complete, false),
        ]
        guard fences.count == expected.count else { throw Self.invalid("six monitor fences") }
        for (index, fence) in fences.enumerated() {
            let (name, revision, phase, active) = expected[index]
            guard fence.name == name else { throw Self.invalid("ordered monitor fences") }
            try Self.validateHeartbeat(
                fence.heartbeat,
                evidence: evidence,
                revision: revision,
                phase: phase,
                foregroundActive: active,
                activityRequired: name == .operationsComplete,
                historyCommitment: name == .finalStable
                    ? evidence.historyCommitmentSHA256
                    : evidence.baselineCommitmentSHA256)
            if index > 0 {
                try Self.validateClockStep(previous: fences[index - 1].heartbeat, current: fence.heartbeat)
            }
        }
        guard fences[2].heartbeat.wallClockMilliseconds < fences[3].heartbeat.wallClockMilliseconds
        else { throw Self.invalid("foreground activity interval") }
    }

    private static func validateHeartbeat(
        _ heartbeat: Heartbeat,
        evidence: Evidence,
        revision: UInt64,
        phase: MonitorPhase,
        foregroundActive: Bool,
        activityRequired: Bool,
        historyCommitment: String) throws
    {
        let sources = heartbeat.attributedForegroundSourceProcessIdentifiers
        let safeMaximum = UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger)
        let expectedTargetPID = foregroundActive ? evidence.foregroundTarget.processIdentifier : nil
        let expectedTargetWindow = foregroundActive ? evidence.foregroundTarget.windowID : nil
        guard heartbeat.sequence > 0,
              heartbeat.sequence <= safeMaximum,
              heartbeat.monotonicMicroseconds > 0,
              heartbeat.monotonicMicroseconds <= safeMaximum,
              PeekabooBridgeCertificationValidation.isPositiveSafeInteger(heartbeat.wallClockMilliseconds),
              heartbeat.lastCleanSequence == heartbeat.sequence,
              heartbeat.contaminationRetries == 0,
              !heartbeat.contaminationBlocked,
              heartbeat.inputAttributionAvailable,
              heartbeat.allowedProducerRevision == revision,
              heartbeat.phase == phase,
              heartbeat.pendingActivationCount == 0,
              !heartbeat.pendingFocusedWindowChange,
              heartbeat.authorizationEpoch > 0,
              heartbeat.authorizationEpoch <= safeMaximum,
              !heartbeat.transitionAcknowledged,
              heartbeat.foregroundActive == foregroundActive,
              heartbeat.foregroundTargetProcessIdentifier == expectedTargetPID,
              heartbeat.foregroundTargetWindowID == expectedTargetWindow,
              heartbeat.attributedForegroundEventCount >= 0,
              Int64(heartbeat.attributedForegroundEventCount) <=
              PeekabooBridgeCertificationValidation.maximumSafeInteger,
              sources.allSatisfy({ $0 > 0 }),
              sources == sources.sorted(),
              Set(sources).count == sources.count,
              heartbeat.executionNonce == evidence.executionNonce,
              heartbeat.monitorInstanceID == evidence.monitorInstanceID,
              heartbeat.historyCommitmentSHA256 == historyCommitment
        else { throw Self.invalid("stable clean monitor heartbeat") }

        if activityRequired {
            guard heartbeat.attributedForegroundEventCount > 0,
                  sources == [evidence.foregroundController.processIdentifier],
                  heartbeat.foregroundActivityObserved
            else { throw Self.invalid("foreground activity attribution") }
        } else {
            guard heartbeat.attributedForegroundEventCount == 0,
                  sources.isEmpty,
                  !heartbeat.foregroundActivityObserved
            else { throw Self.invalid("inactive monitor fence") }
        }
    }

    private static func validateClockStep(previous: Heartbeat, current: Heartbeat) throws {
        guard current.sequence > previous.sequence,
              current.authorizationEpoch > previous.authorizationEpoch,
              current.monotonicMicroseconds > previous.monotonicMicroseconds,
              current.wallClockMilliseconds >= previous.wallClockMilliseconds
        else { throw self.invalid("monotonic monitor fence order") }
        let monotonicDelta = current.monotonicMicroseconds - previous.monotonicMicroseconds
        let wallDelta = current.wallClockMilliseconds - previous.wallClockMilliseconds
        let (wallMicroseconds, overflow) = wallDelta.multipliedReportingOverflow(by: 1000)
        guard !overflow, wallMicroseconds >= 0 else { throw Self.invalid("monitor clock domain") }
        let wallMagnitude = UInt64(wallMicroseconds)
        let difference = wallMagnitude >= monotonicDelta
            ? wallMagnitude - monotonicDelta
            : monotonicDelta - wallMagnitude
        guard difference <= 2_000_000 else { throw Self.invalid("monitor clock drift") }
    }

    private static func validateSample(_ sample: MonitorSample, sentinel: WindowTarget) throws {
        guard sample.frontmostProcessIdentifier == sentinel.processIdentifier,
              sample.frontmostWindowID == sentinel.windowID,
              PeekabooBridgeCertificationValidation.isNonnegativeSafeInteger(sample.clipboardChangeCount),
              PeekabooBridgeCertificationValidation.isLowerHex(sample.clipboardDigest, count: 64)
        else { throw self.invalid("sentinel sample") }
    }

    private static func validateCrashEvidence(_ crash: CrashEvidence) throws {
        guard crash.schemaVersion == 1,
              crash.scanDomain == .currentUserDiagnosticReports,
              !crash.prefixes.isEmpty,
              crash.prefixes.count <= 32,
              Set(crash.prefixes).count == crash.prefixes.count,
              crash.prefixes.allSatisfy(self.isSafeCrashName),
              crash.baseline == crash.final,
              crash.newReports.isEmpty
        else { throw self.invalid("clean crash evidence") }
        try self.validateCrashEntries(crash.baseline, prefixes: crash.prefixes)
        try self.validateCrashEntries(crash.final, prefixes: crash.prefixes)
    }

    private static func validateCrashEntries(_ entries: [CrashEntry], prefixes: [String]) throws {
        let names = entries.map(\.name)
        let totalBytes = entries.reduce(Int64(0)) { partial, entry in
            let sum = partial.addingReportingOverflow(entry.size)
            return sum.overflow ? Int64.max : sum.partialValue
        }
        guard entries.count <= 256,
              names == names.sorted(),
              Set(names).count == names.count,
              totalBytes <= 256 * 1024 * 1024,
              entries.allSatisfy({ entry in
                  Self.isSafeCrashName(entry.name) &&
                      (0...64 * 1024 * 1024).contains(entry.size) &&
                      PeekabooBridgeCertificationValidation.isPositiveSafeInteger(
                          entry.modifiedAtUnixMilliseconds) &&
                      PeekabooBridgeCertificationValidation.isLowerHex(entry.sha256, count: 64) &&
                      prefixes.contains(where: entry.name.hasPrefix)
              })
        else { throw Self.invalid("crash inventory") }
    }

    private static func validateRestoration(_ restoration: RestorationSummary, evidence: Evidence) throws {
        let slotIDs = restoration.backgroundFinalBoundsSlotIDs
        guard (1...64).contains(slotIDs.count),
              slotIDs == slotIDs.sorted(),
              Set(slotIDs).count == slotIDs.count,
              slotIDs.allSatisfy({ Self.isSafeSlotID($0) && $0.hasSuffix("-final-bounds") }),
              restoration.foregroundRestored,
              restoration.sentinelRestored,
              PeekabooBridgeCertificationValidation.isLowerHex(
                  restoration.foregroundPostconditionSHA256,
                  count: 64),
              PeekabooBridgeCertificationValidation.isLowerHex(restoration.sentinelSampleSHA256, count: 64),
              try restoration.sentinelSampleSHA256 ==
              (Self.aggregateSHA256(domain: "monitor-sample", value: evidence.finalSample))
        else { throw Self.invalid("restoration summary") }
    }

    private struct BaselineProjection: Encodable {
        let executionNonce: String
        let monitorInstanceID: UUID
        let source: Source
        let monitorProcess: ProcessIdentity
        let sentinel: WindowTarget
        let foregroundController: ProcessIdentity
        let foregroundTarget: WindowTarget
        let producerSet: ProducerSet
        let baselineSample: MonitorSample
        let foregroundPlan: ForegroundPlan
        let crashBaseline: CrashBaselineProjection
    }

    private struct CrashBaselineProjection: Encodable {
        let scanDomain: CrashScanDomain
        let prefixes: [String]
        let baseline: [CrashEntry]
    }

    private struct HistoryProjection: Encodable {
        let executionNonce: String
        let monitorInstanceID: UUID
        let source: Source
        let monitorProcess: ProcessIdentity
        let sentinel: WindowTarget
        let foregroundController: ProcessIdentity
        let foregroundTarget: WindowTarget
        let baselineCommitmentSHA256: String
        let producerSets: ProducerSets
        let fences: [HistoryFenceProjection]
        let baselineSample: MonitorSample
        let finalSample: MonitorSample
        let foregroundPlan: ForegroundPlan
        let violationRecords: [ViolationRecord]
        let contaminationRecords: [ContaminationRecord]
        let crashEvidence: CrashEvidence
        let restoration: RestorationSummary
    }

    private struct HistoryFenceProjection: Encodable {
        let name: FenceName
        let heartbeat: HistoryHeartbeatProjection
    }

    private struct HistoryHeartbeatProjection: Encodable {
        let heartbeat: Heartbeat

        private enum CodingKeys: String, CodingKey {
            case sequence
            case monotonicMicroseconds
            case wallClockMilliseconds
            case lastCleanSequence
            case contaminationRetries
            case contaminationBlocked
            case inputAttributionAvailable
            case allowedProducerRevision
            case phase
            case cursorMovementObserved
            case pendingActivationCount
            case pendingFocusedWindowChange
            case authorizationEpoch
            case transitionAcknowledged
            case foregroundActive
            case foregroundTargetProcessIdentifier
            case foregroundTargetWindowID
            case attributedForegroundEventCount
            case attributedForegroundSourceProcessIdentifiers
            case foregroundActivityObserved
            case executionNonce
            case monitorInstanceID
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(self.heartbeat.sequence), forKey: .sequence)
            try container.encode(String(self.heartbeat.monotonicMicroseconds), forKey: .monotonicMicroseconds)
            try container.encode(self.heartbeat.wallClockMilliseconds, forKey: .wallClockMilliseconds)
            try container.encode(String(self.heartbeat.lastCleanSequence), forKey: .lastCleanSequence)
            try container.encode(self.heartbeat.contaminationRetries, forKey: .contaminationRetries)
            try container.encode(self.heartbeat.contaminationBlocked, forKey: .contaminationBlocked)
            try container.encode(self.heartbeat.inputAttributionAvailable, forKey: .inputAttributionAvailable)
            try container.encode(
                String(self.heartbeat.allowedProducerRevision),
                forKey: .allowedProducerRevision)
            try container.encode(self.heartbeat.phase, forKey: .phase)
            try container.encode(self.heartbeat.cursorMovementObserved, forKey: .cursorMovementObserved)
            try container.encode(self.heartbeat.pendingActivationCount, forKey: .pendingActivationCount)
            try container.encode(
                self.heartbeat.pendingFocusedWindowChange,
                forKey: .pendingFocusedWindowChange)
            try container.encode(String(self.heartbeat.authorizationEpoch), forKey: .authorizationEpoch)
            try container.encode(self.heartbeat.transitionAcknowledged, forKey: .transitionAcknowledged)
            try container.encode(self.heartbeat.foregroundActive, forKey: .foregroundActive)
            try container.encode(
                self.heartbeat.foregroundTargetProcessIdentifier,
                forKey: .foregroundTargetProcessIdentifier)
            try container.encode(self.heartbeat.foregroundTargetWindowID, forKey: .foregroundTargetWindowID)
            try container.encode(
                self.heartbeat.attributedForegroundEventCount,
                forKey: .attributedForegroundEventCount)
            try container.encode(
                self.heartbeat.attributedForegroundSourceProcessIdentifiers,
                forKey: .attributedForegroundSourceProcessIdentifiers)
            try container.encode(
                self.heartbeat.foregroundActivityObserved,
                forKey: .foregroundActivityObserved)
            try container.encode(self.heartbeat.executionNonce, forKey: .executionNonce)
            try container.encode(self.heartbeat.monitorInstanceID, forKey: .monitorInstanceID)
        }
    }

    private static func baselineCommitment(for evidence: Evidence) throws -> String {
        try self.aggregateSHA256(
            domain: "monitor-baseline",
            value: BaselineProjection(
                executionNonce: evidence.executionNonce,
                monitorInstanceID: evidence.monitorInstanceID,
                source: evidence.source,
                monitorProcess: evidence.monitorProcess,
                sentinel: evidence.sentinel,
                foregroundController: evidence.foregroundController,
                foregroundTarget: evidence.foregroundTarget,
                producerSet: evidence.producerSets.baseline,
                baselineSample: evidence.baselineSample,
                foregroundPlan: evidence.foregroundPlan,
                crashBaseline: CrashBaselineProjection(
                    scanDomain: evidence.crashEvidence.scanDomain,
                    prefixes: evidence.crashEvidence.prefixes,
                    baseline: evidence.crashEvidence.baseline)))
    }

    private static func historyCommitment(for evidence: Evidence) throws -> String {
        let fences = evidence.fences.map { fence in
            HistoryFenceProjection(
                name: fence.name,
                heartbeat: HistoryHeartbeatProjection(heartbeat: fence.heartbeat))
        }
        return try self.aggregateSHA256(
            domain: "monitor-history",
            value: HistoryProjection(
                executionNonce: evidence.executionNonce,
                monitorInstanceID: evidence.monitorInstanceID,
                source: evidence.source,
                monitorProcess: evidence.monitorProcess,
                sentinel: evidence.sentinel,
                foregroundController: evidence.foregroundController,
                foregroundTarget: evidence.foregroundTarget,
                baselineCommitmentSHA256: evidence.baselineCommitmentSHA256,
                producerSets: evidence.producerSets,
                fences: fences,
                baselineSample: evidence.baselineSample,
                finalSample: evidence.finalSample,
                foregroundPlan: evidence.foregroundPlan,
                violationRecords: evidence.violationRecords,
                contaminationRecords: evidence.contaminationRecords,
                crashEvidence: evidence.crashEvidence,
                restoration: evidence.restoration))
    }

    private static func aggregateSHA256(domain: String, value: some Encodable) throws -> String {
        var data = Data("peekaboo.multi-target-certification.\(domain).v2\0".utf8)
        try data.append(PeekabooBridgeOperationReceiptCoding.canonicalData(value))
        return PeekabooBridgeOperationReceiptCoding.sha256(data)
    }

    static func derivedBaselineCommitmentSHA256(for evidence: Evidence) throws -> String {
        try self.baselineCommitment(for: evidence)
    }

    static func derivedHistoryCommitmentSHA256(for evidence: Evidence) throws -> String {
        try self.historyCommitment(for: evidence)
    }

    static func derivedEvidenceSHA256(for evidence: Evidence) throws -> String {
        try self.aggregateSHA256(domain: "monitor-evidence", value: evidence)
    }

    static func derivedMonitorSampleSHA256(for sample: MonitorSample) throws -> String {
        try self.aggregateSHA256(domain: "monitor-sample", value: sample)
    }

    private static func producerPrecedes(_ lhs: AllowedProducer, _ rhs: AllowedProducer) -> Bool {
        if lhs.processIdentifier != rhs.processIdentifier {
            return lhs.processIdentifier < rhs.processIdentifier
        }
        if lhs.processStartIdentity != rhs.processStartIdentity {
            return lhs.processStartIdentity < rhs.processStartIdentity
        }
        return lhs.role.rawValue < rhs.role.rawValue
    }

    private static func sameGeneration(_ process: ProcessIdentity, _ target: WindowTarget) -> Bool {
        process.processIdentifier == target.processIdentifier &&
            process.processStartIdentity == target.processStartIdentity
    }

    private static func sameGeneration(_ lhs: WindowTarget, _ rhs: WindowTarget) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier &&
            lhs.processStartIdentity == rhs.processStartIdentity
    }

    private static func sameGeneration(_ lhs: ProcessIdentity, _ rhs: ProcessIdentity) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier &&
            lhs.processStartIdentity == rhs.processStartIdentity
    }

    private static func isSafeText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
    }

    private static func isSafeOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        return self.isSafeText(value, maximumBytes: maximumBytes)
    }

    private static func isSafeCrashName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 255 && bytes.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) ||
                (0x30...0x39).contains(byte) || [0x2E, 0x5F, 0x2D].contains(byte)
        }
    }

    private static func isSafeSlotID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 64 && bytes.first != 0x2D && bytes.last != 0x2D &&
            bytes.allSatisfy { byte in
                (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D
            }
    }

    private static func invalid(_ field: String) -> PeekabooBridgeOperationReceiptError {
        .receiptMismatch("certification monitor seal \(field)")
    }
}
