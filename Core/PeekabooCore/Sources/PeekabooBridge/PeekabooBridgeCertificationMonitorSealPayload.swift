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
}
