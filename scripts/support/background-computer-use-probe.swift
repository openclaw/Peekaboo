import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Security
import Synchronization

// The shell harness compiles this standalone probe directly; its deterministic contracts stay in the same source.
// swiftlint:disable file_length

@_silgen_name("_AXUIElementGetWindow")
private func copyProbeAXWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

private let selfTestExecutionNonce = String(repeating: "a", count: 64)
private let selfTestMonitorInstanceID = "00000000-0000-4000-8000-000000000001"

private func isLowerHex(_ value: String, count: Int) -> Bool {
    value.utf8.count == count && value.utf8.allSatisfy {
        (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
    }
}

private func isCanonicalV4UUID(_ value: String) -> Bool {
    guard value == value.lowercased(), value.count == 36,
          value[value.index(value.startIndex, offsetBy: 14)] == "4",
          "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]),
          let uuid = UUID(uuidString: value)
    else { return false }
    return uuid.uuidString.lowercased() == value
}

private struct Point: Codable, Equatable {
    let x: Double
    let y: Double
}

private struct Rectangle: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

private struct SystemSample: Codable {
    let timestamp: Double
    let frontmostPID: Int32?
    let frontmostBundleIdentifier: String?
    let frontmostWindowID: UInt32?
    let cursor: Point
    let clipboardChangeCount: Int
    let clipboardDigest: String
    let peekabooWindowIDs: [UInt32]
    let visibleScreenFramesTopLeft: [Rectangle]
}

private struct Violation: Codable, Hashable {
    let kind: String
    let expected: String
    let actual: String
}

private struct WatchHeartbeat: Codable, Equatable {
    let sequence: UInt64
    let monotonicMicroseconds: UInt64
    let wallClockMilliseconds: Int64
    let lastCleanSequence: UInt64
    let contaminationRetries: Int
    let contaminationBlocked: Bool
    let inputAttributionAvailable: Bool
    let allowedProducerRevision: UInt64
    let phase: String
    let cursorMovementObserved: Bool
    let pendingActivationCount: Int
    let pendingFocusedWindowChange: Bool
    let authorizationEpoch: UInt64
    let transitionAcknowledged: Bool
    let foregroundActive: Bool
    let foregroundTargetPID: Int32?
    let foregroundTargetWindowID: UInt32?
    let attributedForegroundEventCount: Int
    let attributedForegroundSourcePIDs: [Int32]
    let foregroundActivityObserved: Bool
    let executionNonce: String
    let monitorInstanceID: String
    let historyCommitmentSHA256: String

    private enum CodingKeys: String, CodingKey {
        case sequence, monotonicMicroseconds, wallClockMilliseconds, lastCleanSequence
        case contaminationRetries, contaminationBlocked
        case inputAttributionAvailable, allowedProducerRevision, phase, cursorMovementObserved
        case pendingActivationCount, pendingFocusedWindowChange, authorizationEpoch
        case transitionAcknowledged, foregroundActive, foregroundTargetPID, foregroundTargetWindowID
        case attributedForegroundEventCount, attributedForegroundSourcePIDs, foregroundActivityObserved
        case executionNonce, monitorInstanceID, historyCommitmentSHA256
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.sequence, forKey: .sequence)
        try values.encode(self.monotonicMicroseconds, forKey: .monotonicMicroseconds)
        try values.encode(self.wallClockMilliseconds, forKey: .wallClockMilliseconds)
        try values.encode(self.lastCleanSequence, forKey: .lastCleanSequence)
        try values.encode(self.contaminationRetries, forKey: .contaminationRetries)
        try values.encode(self.contaminationBlocked, forKey: .contaminationBlocked)
        try values.encode(self.inputAttributionAvailable, forKey: .inputAttributionAvailable)
        try values.encode(self.allowedProducerRevision, forKey: .allowedProducerRevision)
        try values.encode(self.phase, forKey: .phase)
        try values.encode(self.cursorMovementObserved, forKey: .cursorMovementObserved)
        try values.encode(self.pendingActivationCount, forKey: .pendingActivationCount)
        try values.encode(self.pendingFocusedWindowChange, forKey: .pendingFocusedWindowChange)
        try values.encode(self.authorizationEpoch, forKey: .authorizationEpoch)
        try values.encode(self.transitionAcknowledged, forKey: .transitionAcknowledged)
        try values.encode(self.foregroundActive, forKey: .foregroundActive)
        if let foregroundTargetPID {
            try values.encode(foregroundTargetPID, forKey: .foregroundTargetPID)
        } else {
            try values.encodeNil(forKey: .foregroundTargetPID)
        }
        if let foregroundTargetWindowID {
            try values.encode(foregroundTargetWindowID, forKey: .foregroundTargetWindowID)
        } else {
            try values.encodeNil(forKey: .foregroundTargetWindowID)
        }
        try values.encode(self.attributedForegroundEventCount, forKey: .attributedForegroundEventCount)
        try values.encode(self.attributedForegroundSourcePIDs, forKey: .attributedForegroundSourcePIDs)
        try values.encode(self.foregroundActivityObserved, forKey: .foregroundActivityObserved)
        try values.encode(self.executionNonce, forKey: .executionNonce)
        try values.encode(self.monitorInstanceID, forKey: .monitorInstanceID)
        try values.encode(self.historyCommitmentSHA256, forKey: .historyCommitmentSHA256)
    }

    func withTransitionAcknowledged(_ acknowledged: Bool) -> WatchHeartbeat {
        WatchHeartbeat(
            sequence: self.sequence,
            monotonicMicroseconds: self.monotonicMicroseconds,
            wallClockMilliseconds: self.wallClockMilliseconds,
            lastCleanSequence: self.lastCleanSequence,
            contaminationRetries: self.contaminationRetries,
            contaminationBlocked: self.contaminationBlocked,
            inputAttributionAvailable: self.inputAttributionAvailable,
            allowedProducerRevision: self.allowedProducerRevision,
            phase: self.phase,
            cursorMovementObserved: self.cursorMovementObserved,
            pendingActivationCount: self.pendingActivationCount,
            pendingFocusedWindowChange: self.pendingFocusedWindowChange,
            authorizationEpoch: self.authorizationEpoch,
            transitionAcknowledged: acknowledged,
            foregroundActive: self.foregroundActive,
            foregroundTargetPID: self.foregroundTargetPID,
            foregroundTargetWindowID: self.foregroundTargetWindowID,
            attributedForegroundEventCount: self.attributedForegroundEventCount,
            attributedForegroundSourcePIDs: self.attributedForegroundSourcePIDs,
            foregroundActivityObserved: self.foregroundActivityObserved,
            executionNonce: self.executionNonce,
            monitorInstanceID: self.monitorInstanceID,
            historyCommitmentSHA256: self.historyCommitmentSHA256)
    }

    func withHistoryCommitmentSHA256(_ digest: String) -> WatchHeartbeat {
        WatchHeartbeat(
            sequence: self.sequence,
            monotonicMicroseconds: self.monotonicMicroseconds,
            wallClockMilliseconds: self.wallClockMilliseconds,
            lastCleanSequence: self.lastCleanSequence,
            contaminationRetries: self.contaminationRetries,
            contaminationBlocked: self.contaminationBlocked,
            inputAttributionAvailable: self.inputAttributionAvailable,
            allowedProducerRevision: self.allowedProducerRevision,
            phase: self.phase,
            cursorMovementObserved: self.cursorMovementObserved,
            pendingActivationCount: self.pendingActivationCount,
            pendingFocusedWindowChange: self.pendingFocusedWindowChange,
            authorizationEpoch: self.authorizationEpoch,
            transitionAcknowledged: self.transitionAcknowledged,
            foregroundActive: self.foregroundActive,
            foregroundTargetPID: self.foregroundTargetPID,
            foregroundTargetWindowID: self.foregroundTargetWindowID,
            attributedForegroundEventCount: self.attributedForegroundEventCount,
            attributedForegroundSourcePIDs: self.attributedForegroundSourcePIDs,
            foregroundActivityObserved: self.foregroundActivityObserved,
            executionNonce: self.executionNonce,
            monitorInstanceID: self.monitorInstanceID,
            historyCommitmentSHA256: digest)
    }
}

private struct ContaminationRecord: Codable, Equatable {
    let state: String
    let retry: Int
    let sequence: UInt64
    let sourcePIDs: [Int32]
    let eventTypes: [UInt32]
}

private struct AppIdentity: Codable {
    let bundleIdentifier: String
    let pid: Int32
    let isActive: Bool
}

private struct ProcessIdentity: Codable {
    let pid: Int32
    let startIdentity: String
}

private struct ProcessExecutable: Codable {
    let pid: Int32
    let startIdentity: String
    let path: String
    let sha256: String
}

private struct ProcessExecutableIdentity: Codable {
    let pid: Int32
    let startIdentity: String
    let path: String
}

private struct ClockSample: Codable {
    let wallTime: Double
    let monotonicSeconds: Double
}

private enum ProbeError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case noMouseEvent
    case inputEventTapUnavailable
    case focusedWindowObserverUnavailable

    var description: String {
        switch self {
        case let .invalidArguments(message): message
        case .noMouseEvent: "Unable to read the physical cursor location"
        case .inputEventTapUnavailable: "Unable to start the input-attribution event tap"
        case .focusedWindowObserverUnavailable: "Unable to observe foreground-window changes"
        }
    }
}

private enum InvariantSlot: Int, CaseIterable {
    case frontmostPID
    case frontmostWindow
    case physicalCursor
    case globalInputEvent
    case clipboardChangeCount
    case peekabooOverlayWindow
}

private let cursorPositionViolationKind = "cursor_position"

private struct InvariantProjection {
    let names: [String]

    init(json: String) throws {
        let decoded = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        guard decoded.count == InvariantSlot.allCases.count,
              decoded.allSatisfy({ !$0.isEmpty }),
              Set(decoded).count == decoded.count
        else {
            throw ProbeError.invalidArguments(
                "--invariant-names must contain exactly \(InvariantSlot.allCases.count) unique nonempty names")
        }
        self.names = decoded
    }

    init(names: [String]) {
        precondition(names.count == InvariantSlot.allCases.count)
        self.names = names
    }

    subscript(_ slot: InvariantSlot) -> String {
        self.names[slot.rawValue]
    }
}

private struct InteractiveBaseline {
    let frontmostPID: Int32
    let processStartIdentity: String
    let frontmostWindowID: UInt32
    let cursor: Point
}

private struct InvariantEvaluationContext {
    let baseline: SystemSample
    let interactiveBaseline: InteractiveBaseline
    let allowClipboardMutation: Bool
    let evaluateInteractiveInvariants: Bool
    let cursorObservational: Bool
    let projection: InvariantProjection
}

private enum AllowedEventProducerRole: String, Codable, Hashable, Sendable {
    case bridge
    case foregroundController = "foreground-controller"
}

private struct AllowedEventProducer: Codable, Hashable, Sendable {
    let pid: Int32
    let startIdentity: String
    let role: AllowedEventProducerRole?

    var effectiveRole: AllowedEventProducerRole {
        self.role ?? .bridge
    }
}

private struct AllowedForegroundTarget: Codable, Equatable, Hashable, Sendable {
    let pid: Int32
    let startIdentity: String
    let windowID: UInt32
}

private struct AllowedForegroundActivity: Codable, Equatable, Hashable, Sendable {
    let active: Bool
    let target: AllowedForegroundTarget?

    private enum CodingKeys: String, CodingKey {
        case active, target
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(self.active, forKey: .active)
        if let target {
            try values.encode(target, forKey: .target)
        } else {
            try values.encodeNil(forKey: .target)
        }
    }
}

private struct AllowedEventProducerSet: Codable, Equatable, Sendable {
    let revision: UInt64
    let executionNonce: String
    let monitorInstanceID: String
    let producers: [AllowedEventProducer]
    let foreground: AllowedForegroundActivity?

    init(
        revision: UInt64,
        executionNonce: String = selfTestExecutionNonce,
        monitorInstanceID: String = selfTestMonitorInstanceID,
        producers: [AllowedEventProducer],
        foreground: AllowedForegroundActivity? = nil)
    {
        self.revision = revision
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.producers = producers
        self.foreground = foreground
    }

    var effectiveForeground: AllowedForegroundActivity {
        self.foreground ?? AllowedForegroundActivity(active: false, target: nil)
    }

    func hasExactlyEquivalentPayload(to other: AllowedEventProducerSet) -> Bool {
        self.executionNonce == other.executionNonce &&
            self.monitorInstanceID == other.monitorInstanceID &&
            self.producers.count == other.producers.count &&
            Set(self.producers) == Set(other.producers) &&
            self.foreground == other.foreground
    }
}

private func decodeAllowedProducerSet(
    _ data: Data,
    executionNonce: String,
    monitorInstanceID: String) throws -> AllowedEventProducerSet
{
    let object = try JSONSerialization.jsonObject(with: data)
    guard let root = object as? [String: Any],
          Set(root.keys) == ["revision", "executionNonce", "monitorInstanceID", "producers", "foreground"],
          let producers = root["producers"] as? [[String: Any]],
          producers.allSatisfy({ producer in
              Set(producer.keys) == ["pid", "startIdentity", "role"] &&
                  producer["role"] is String
          }),
          let foreground = root["foreground"] as? [String: Any],
          Set(foreground.keys) == ["active", "target"],
          foreground["active"] is Bool
    else {
        throw ProbeError.invalidArguments("allowed producer document is not one closed schema")
    }
    if let target = foreground["target"] as? [String: Any] {
        guard Set(target.keys) == ["pid", "startIdentity", "windowID"] else {
            throw ProbeError.invalidArguments("allowed foreground target is not closed")
        }
    } else if !(foreground["target"] is NSNull) {
        throw ProbeError.invalidArguments("allowed foreground target must be one object or null")
    }
    let decoded = try JSONDecoder().decode(AllowedEventProducerSet.self, from: data)
    guard decoded.executionNonce == executionNonce,
          decoded.monitorInstanceID == monitorInstanceID,
          decoded.producers.allSatisfy({ $0.role != nil })
    else {
        throw ProbeError.invalidArguments("allowed producer document is not bound to this monitor run")
    }
    return decoded
}

private struct ProcessGenerationIdentity: Hashable, Sendable {
    let pid: Int32
    let startIdentity: String
}

private struct ProcessWindowEvidence: Equatable, Sendable {
    let pid: Int32
    let startIdentity: String?
    let windowID: UInt32?
}

private struct MonitorAuthorization: Equatable, Sendable {
    let source: AllowedEventProducerSet
    let producersByPID: [Int32: AllowedEventProducer]
    let foreground: AllowedForegroundActivity

    var revision: UInt64 {
        self.source.revision
    }

    var target: AllowedForegroundTarget? {
        self.foreground.active ? self.foreground.target : nil
    }

    func hasExactlyEquivalentPayload(to producerSet: AllowedEventProducerSet) -> Bool {
        self.source.hasExactlyEquivalentPayload(to: producerSet)
    }
}

private enum MonitorEpochPhase: Equatable, Sendable {
    case stable
    case transition(prior: MonitorAuthorization)
    case awaitingAcknowledgement(prior: MonitorAuthorization)

    var priorAuthorization: MonitorAuthorization? {
        switch self {
        case .stable:
            nil
        case let .transition(prior), let .awaitingAcknowledgement(prior):
            prior
        }
    }

    var isStable: Bool {
        if case .stable = self {
            return true
        }
        return false
    }

    var requiresAcknowledgementHeartbeat: Bool {
        if case .transition = self {
            return true
        }
        return false
    }
}

private struct MonitorEpoch: Equatable, Sendable {
    let serial: UInt64
    let authorization: MonitorAuthorization
    let lowerAdmissionCutoff: UInt64
    let phase: MonitorEpochPhase

    var focusAuthorization: MonitorAuthorization {
        self.phase.priorAuthorization ?? self.authorization
    }
}

private struct InputEventEvidence: Equatable, Sendable {
    let type: UInt32
    let source: ProcessWindowEvidence
    let sessionFocus: ProcessWindowEvidence?
}

private struct FocusEventEvidence: Equatable, Sendable {
    let observer: ProcessGenerationIdentity
    let observed: ProcessWindowEvidence
}

private enum MonitorEventKind: Equatable, Sendable {
    case input(InputEventEvidence)
    case activation(ProcessWindowEvidence)
    case focus(FocusEventEvidence)
    case attributionFailure(reason: String, process: ProcessWindowEvidence?)
}

private struct MonitorEvent: Equatable, Sendable {
    let admission: UInt64
    let epoch: MonitorEpoch
    let kind: MonitorEventKind
}

private struct ClosedMonitorEpoch: Equatable, Sendable {
    let epoch: MonitorEpoch
    let upperAdmissionCutoff: UInt64
    let events: [MonitorEvent]
}

private struct MonitorEpochClosure: Sendable {
    let epochs: [ClosedMonitorEpoch]

    var finalEpoch: ClosedMonitorEpoch {
        precondition(!self.epochs.isEmpty)
        return self.epochs[self.epochs.index(before: self.epochs.endIndex)]
    }

    var transitionAcknowledged: Bool {
        self.epochs.contains {
            if case .transition = $0.epoch.phase {
                return true
            }
            return false
        }
    }
}

private enum MonitorPublicationResult: Equatable, Sendable {
    case idempotent
    case published
    case rejected(reason: String)
}

private struct MonitorAdmissionToken: Equatable, Sendable {
    let admission: UInt64
    let epoch: MonitorEpoch
}

private struct MonitorEpochBucket: Sendable {
    let epoch: MonitorEpoch
    var events = [MonitorEvent]()
    var pendingAdmissions = Set<UInt64>()
    var upperAdmissionCutoff: UInt64?
}

private struct MonitorEpochMachineState: Sendable {
    var openBucket: MonitorEpochBucket
    var sealedBuckets = [MonitorEpochBucket]()
    var lastAdmission: UInt64 = 0
    var nextEpochSerial: UInt64 = 2
    var acknowledgementReadyRevision: UInt64?
    var isSealCutoff = false
    var isQuiesced = false
}

/// The one publication/admission authority for input, activation, and focus callbacks.
/// A callback reserves its epoch under this cutoff, samples outside the lock, and
/// cannot be drained until that exact reservation completes.
private final class MonitorEpochMachine: Sendable {
    private let state: Mutex<MonitorEpochMachineState>

    init(initialAuthorization: MonitorAuthorization) {
        self.state = Mutex(MonitorEpochMachineState(
            openBucket: MonitorEpochBucket(epoch: MonitorEpoch(
                serial: 1,
                authorization: initialAuthorization,
                lowerAdmissionCutoff: 0,
                phase: .stable))))
    }

    var currentAuthorization: MonitorAuthorization {
        self.state.withLock { $0.openBucket.epoch.authorization }
    }

    var currentPhase: MonitorEpochPhase {
        self.state.withLock { $0.openBucket.epoch.phase }
    }

    func publish(_ authorization: MonitorAuthorization) -> MonitorPublicationResult {
        self.state.withLock { state in
            let current = state.openBucket.epoch.authorization
            if authorization.revision == current.revision {
                return current.hasExactlyEquivalentPayload(to: authorization.source)
                    ? .idempotent
                    : .rejected(reason: "blocked_producer_revision_replay")
            }
            guard authorization.revision > current.revision else {
                return .rejected(reason: "blocked_producer_revision_replay")
            }
            guard state.openBucket.epoch.phase.isStable else {
                return .rejected(reason: "blocked_producer_revision_before_ack")
            }
            Self.sealOpenBucket(state: &state)
            state.openBucket = MonitorEpochBucket(epoch: MonitorEpoch(
                serial: state.nextEpochSerial,
                authorization: authorization,
                lowerAdmissionCutoff: state.lastAdmission,
                phase: .transition(prior: current)))
            state.nextEpochSerial += 1
            return .published
        }
    }

    func admitInput(
        type: CGEventType,
        evidence: (MonitorAuthorization) -> (source: ProcessWindowEvidence, sessionFocus: ProcessWindowEvidence?))
    {
        let token = self.reserve()
        let sample = evidence(token.epoch.focusAuthorization)
        let kind = MonitorEventKind.input(InputEventEvidence(
            type: type.rawValue,
            source: sample.source,
            sessionFocus: sample.sessionFocus))
        if !self.complete(token, with: kind) {
            self.admitFailure(reason: "blocked_admission_completion")
        }
    }

    func admitActivation(evidence: () -> ProcessWindowEvidence) {
        self.admit { .activation(evidence()) }
    }

    func admitFocus(
        observer: ProcessGenerationIdentity,
        evidence: () -> ProcessWindowEvidence)
    {
        self.admit { .focus(FocusEventEvidence(observer: observer, observed: evidence())) }
    }

    func admitFailure(reason: String, evidence: () -> ProcessWindowEvidence? = { nil }) {
        self.admit { .attributionFailure(reason: reason, process: evidence()) }
    }

    func admitForTesting(_ kind: MonitorEventKind) {
        self.admit { kind }
    }

    func admitForTesting(sample: () -> MonitorEventKind) {
        self.admit(sample)
    }

    func reserveForTesting() -> MonitorAdmissionToken {
        self.reserve()
    }

    func beginSealCutoff() -> Bool {
        self.state.withLock { state in
            guard !state.isQuiesced, !state.isSealCutoff else { return false }
            state.isSealCutoff = true
            return true
        }
    }

    func finishSealCutoff() -> Bool {
        self.state.withLock { state in
            guard state.isSealCutoff,
                  !state.isQuiesced,
                  state.sealedBuckets.isEmpty,
                  state.openBucket.pendingAdmissions.isEmpty,
                  state.openBucket.events.isEmpty,
                  state.openBucket.epoch.phase.isStable,
                  state.acknowledgementReadyRevision == nil
            else { return false }
            state.isQuiesced = true
            return true
        }
    }

    func pendingEvidenceCountForTesting() -> Int {
        self.state.withLock { state in
            state.openBucket.events.count + state.openBucket.pendingAdmissions.count +
                state.sealedBuckets.reduce(0) { partial, bucket in
                    partial + bucket.events.count + bucket.pendingAdmissions.count
                }
        }
    }

    @discardableResult
    func completeForTesting(_ token: MonitorAdmissionToken, with kind: MonitorEventKind) -> Bool {
        self.complete(token, with: kind)
    }

    @discardableResult
    func cancelForTesting(_ token: MonitorAdmissionToken, reason: String) -> Bool {
        self.complete(token, with: .attributionFailure(reason: reason, process: nil))
    }

    func closeForHeartbeat() -> MonitorEpochClosure? {
        self.state.withLock { state in
            let shouldSealOpenBucket = state.sealedBuckets.isEmpty ||
                state.openBucket.epoch.phase.requiresAcknowledgementHeartbeat ||
                !state.openBucket.pendingAdmissions.isEmpty ||
                !state.openBucket.events.isEmpty
            if shouldSealOpenBucket {
                let closedEpoch = state.openBucket.epoch
                Self.sealOpenBucket(state: &state)
                state.openBucket = MonitorEpochBucket(epoch: MonitorEpoch(
                    serial: state.nextEpochSerial,
                    authorization: closedEpoch.authorization,
                    lowerAdmissionCutoff: state.lastAdmission,
                    phase: Self.continuationPhase(after: closedEpoch.phase)))
                state.nextEpochSerial += 1
            }
            return Self.drainCompletedPrefix(state: &state)
        }
    }

    func acknowledge(revision: UInt64) -> MonitorPublicationResult {
        self.acknowledge(revision: revision, preparing: {}, publishing: {})
    }

    func markAcknowledgementReady(revision: UInt64) -> MonitorPublicationResult {
        self.state.withLock { state in
            let openEpoch = state.openBucket.epoch
            guard openEpoch.authorization.revision == revision else {
                return .rejected(reason: "blocked_producer_ack_revision_mismatch")
            }
            guard case .awaitingAcknowledgement = openEpoch.phase else {
                return .rejected(reason: "blocked_producer_ack_without_transition")
            }
            state.acknowledgementReadyRevision = revision
            return .published
        }
    }

    func acknowledge(
        revision: UInt64,
        preparing acknowledgementPreparation: () throws -> Void,
        publishing acknowledgement: () throws -> Void) rethrows -> MonitorPublicationResult
    {
        try self.state.withLock { state in
            let openEpoch = state.openBucket.epoch
            guard openEpoch.authorization.revision == revision else {
                return .rejected(reason: "blocked_producer_ack_revision_mismatch")
            }
            guard case .awaitingAcknowledgement = openEpoch.phase else {
                return .rejected(reason: "blocked_producer_ack_without_transition")
            }
            guard state.acknowledgementReadyRevision == revision else {
                return .rejected(reason: "blocked_producer_ack_before_callback_barrier")
            }
            guard state.sealedBuckets.isEmpty,
                  state.openBucket.pendingAdmissions.isEmpty,
                  state.openBucket.events.isEmpty
            else {
                return .rejected(reason: "blocked_producer_ack_evidence_pending")
            }
            try acknowledgementPreparation()
            try acknowledgement()
            state.openBucket = MonitorEpochBucket(epoch: MonitorEpoch(
                serial: state.nextEpochSerial,
                authorization: openEpoch.authorization,
                lowerAdmissionCutoff: state.lastAdmission,
                phase: .stable))
            state.nextEpochSerial += 1
            state.acknowledgementReadyRevision = nil
            return .published
        }
    }

    private func admit(_ evidence: () -> MonitorEventKind) {
        let token = self.reserve()
        let kind = evidence()
        if !self.complete(token, with: kind) {
            self.admitFailure(reason: "blocked_admission_completion")
        }
    }

    private func reserve() -> MonitorAdmissionToken {
        self.state.withLock { state in
            if state.isQuiesced || state.isSealCutoff {
                return MonitorAdmissionToken(admission: 0, epoch: state.openBucket.epoch)
            }
            state.lastAdmission += 1
            let token = MonitorAdmissionToken(
                admission: state.lastAdmission,
                epoch: state.openBucket.epoch)
            state.openBucket.pendingAdmissions.insert(token.admission)
            return token
        }
    }

    private func complete(_ token: MonitorAdmissionToken, with kind: MonitorEventKind) -> Bool {
        self.state.withLock { state in
            if state.isQuiesced || token.admission == 0 {
                return true
            }
            if state.openBucket.epoch == token.epoch {
                return Self.complete(token, with: kind, in: &state.openBucket)
            }
            guard let index = state.sealedBuckets.firstIndex(where: { $0.epoch == token.epoch }) else {
                return false
            }
            return Self.complete(token, with: kind, in: &state.sealedBuckets[index])
        }
    }

    private static func complete(
        _ token: MonitorAdmissionToken,
        with kind: MonitorEventKind,
        in bucket: inout MonitorEpochBucket) -> Bool
    {
        guard bucket.pendingAdmissions.remove(token.admission) != nil else { return false }
        bucket.events.append(MonitorEvent(
            admission: token.admission,
            epoch: token.epoch,
            kind: kind))
        return true
    }

    private static func sealOpenBucket(state: inout MonitorEpochMachineState) {
        state.openBucket.upperAdmissionCutoff = state.lastAdmission
        state.sealedBuckets.append(state.openBucket)
    }

    private static func continuationPhase(after phase: MonitorEpochPhase) -> MonitorEpochPhase {
        switch phase {
        case .stable:
            .stable
        case let .transition(prior), let .awaitingAcknowledgement(prior):
            .awaitingAcknowledgement(prior: prior)
        }
    }

    private static func drainCompletedPrefix(state: inout MonitorEpochMachineState) -> MonitorEpochClosure? {
        let completedCount = state.sealedBuckets.prefix { $0.pendingAdmissions.isEmpty }.count
        guard completedCount > 0 else { return nil }
        let completed = state.sealedBuckets.prefix(completedCount).map { bucket in
            ClosedMonitorEpoch(
                epoch: bucket.epoch,
                upperAdmissionCutoff: bucket.upperAdmissionCutoff ?? bucket.epoch.lowerAdmissionCutoff,
                events: bucket.events.sorted { $0.admission < $1.admission })
        }
        state.sealedBuckets.removeFirst(completedCount)
        return MonitorEpochClosure(epochs: completed)
    }
}

private struct AttemptContaminationState {
    private(set) var blocked = false

    mutating func observe(externalInput: Bool, attributionFailed: Bool) {
        if externalInput || attributionFailed {
            self.blocked = true
        }
    }

    var permitsInteractiveEvaluation: Bool {
        !self.blocked
    }
}

private final class RunLoopIdleBarrierState: Sendable {
    private let idlePasses = Mutex(0)

    func recordIdlePass() -> Bool {
        self.idlePasses.withLock { passes in
            passes += 1
            return passes >= 2
        }
    }

    func reachedBarrier() -> Bool {
        self.idlePasses.withLock { $0 >= 2 }
    }
}

private func runLoopReachesIdle(timeout: TimeInterval) -> Bool {
    let runLoop = CFRunLoopGetCurrent()
    let state = RunLoopIdleBarrierState()
    guard let observer = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault,
        CFRunLoopActivity.beforeWaiting.rawValue,
        true,
        CFIndex.max,
        { _, _ in
            if state.recordIdlePass() {
                CFRunLoopStop(runLoop)
            } else {
                CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {}
                CFRunLoopWakeUp(runLoop)
            }
        })
    else {
        return false
    }
    CFRunLoopAddObserver(runLoop, observer, .defaultMode)
    defer {
        CFRunLoopRemoveObserver(runLoop, observer, .defaultMode)
        CFRunLoopObserverInvalidate(observer)
    }
    _ = CFRunLoopRunInMode(.defaultMode, timeout, false)
    return state.reachedBarrier()
}

private final class InputEventTracker {
    private static let requiredEventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDown,
        .keyDown,
        .scrollWheel,
        .tabletPointer,
        .tabletProximity,
    ]
    private static let monitoredEventMask = CGEventMask.max &
        ~(CGEventMask(1) << CGEventType.null.rawValue)

    private let machine: MonitorEpochMachine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    init(machine: MonitorEpochMachine) {
        self.machine = machine
    }

    func start() throws {
        guard CGPreflightListenEventAccess() else {
            throw ProbeError.inputEventTapUnavailable
        }
        let priorTapIDs = Set(Self.tapInformation().filter { $0.tappingProcess == getpid() }.map(\.eventTapID))
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: Self.monitoredEventMask,
            callback: inputEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            throw ProbeError.inputEventTapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            throw ProbeError.inputEventTapUnavailable
        }
        self.eventTap = eventTap
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        let currentPID = getpid()
        let currentTaps = Self.tapInformation()
        let installedTap = currentTaps.first { info in
            guard info.tappingProcess == currentPID else { return false }
            guard !priorTapIDs.contains(info.eventTapID) else { return false }
            guard info.tapPoint == .cgSessionEventTap else { return false }
            return info.options == .listenOnly
        }
        guard let installedTap,
              installedTap.enabled,
              installedTap.eventsOfInterest & Self.requiredEventMask == Self.requiredEventMask
        else {
            self.stop()
            throw ProbeError.inputEventTapUnavailable
        }
    }

    func stop() {
        if let runLoopSource = self.runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        if let eventTap = self.eventTap {
            CFMachPortInvalidate(eventTap)
        }
        self.runLoopSource = nil
        self.eventTap = nil
    }

    static func validateMonitoredEventMask() -> Bool {
        let nullBit = CGEventMask(1) << CGEventType.null.rawValue
        return Self.monitoredEventMask & nullBit == 0 && Self.requiredEventTypes.allSatisfy { type in
            Self.monitoredEventMask & (CGEventMask(1) << type.rawValue) != 0
        }
    }

    private static var requiredEventMask: CGEventMask {
        requiredEventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
    }

    private static func tapInformation() -> [CGEventTapInformation] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        var returnedCount = count
        guard CGGetEventTapList(count, &taps, &returnedCount) == .success else { return [] }
        return Array(taps.prefix(Int(returnedCount)))
    }

    func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            self.machine.admitFailure(reason: "blocked_attribution")
            if let eventTap = self.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let sourcePIDValue = event.getIntegerValueField(.eventSourceUnixProcessID)
        let sourcePID = sourcePIDValue > 0 && sourcePIDValue <= Int64(Int32.max)
            ? Int32(sourcePIDValue)
            : 0
        self.machine.admitInput(type: type) { authorization in
            inputEventEvidence(sourcePID: sourcePID, authorization: authorization)
        }
    }
}

private final class ActivationTracker {
    private let machine: MonitorEpochMachine
    private var observer: (any NSObjectProtocol)?

    init(machine: MonitorEpochMachine) {
        self.machine = machine
    }

    func start() {
        let machine = self.machine
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil)
        { notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else {
                return
            }
            let pid = app.processIdentifier
            machine.admitActivation {
                processWindowEvidence(pid: pid) { focusedWindowID(pid: pid) }
            }
        }
    }

    func stop() {
        if let observer = self.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.observer = nil
    }
}

private protocol FocusObserverTracking: AnyObject {
    var identity: ProcessGenerationIdentity { get }
    func start() throws
    func stop() throws
}

private final class FocusedWindowTracker: FocusObserverTracking {
    let identity: ProcessGenerationIdentity
    private let machine: MonitorEpochMachine
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?

    init(identity: ProcessGenerationIdentity, machine: MonitorEpochMachine) {
        self.identity = identity
        self.machine = machine
    }

    func start() throws {
        guard processStartIdentity(pid: self.identity.pid).map(String.init) == self.identity.startIdentity else {
            throw ProbeError.focusedWindowObserverUnavailable
        }
        var observer: AXObserver?
        guard AXObserverCreate(self.identity.pid, focusedWindowObserverCallback, &observer) == .success,
              let observer
        else {
            throw ProbeError.focusedWindowObserverUnavailable
        }
        let applicationElement = AXUIElementCreateApplication(self.identity.pid)
        guard AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()) == .success
        else {
            throw ProbeError.focusedWindowObserverUnavailable
        }
        guard processStartIdentity(pid: self.identity.pid).map(String.init) == self.identity.startIdentity else {
            AXObserverRemoveNotification(
                observer,
                applicationElement,
                kAXFocusedWindowChangedNotification as CFString)
            throw ProbeError.focusedWindowObserverUnavailable
        }
        self.observer = observer
        self.applicationElement = applicationElement
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .commonModes)
    }

    func recordChange() {
        self.machine.admitFocus(observer: self.identity) {
            self.focusedWindowEvidence()
        }
    }

    func stop() throws {
        guard let observer = self.observer, let applicationElement = self.applicationElement else { return }
        guard AXObserverRemoveNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString) == .success
        else {
            throw ProbeError.focusedWindowObserverUnavailable
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .commonModes)
        self.observer = nil
        self.applicationElement = nil
    }

    private func focusedWindowEvidence() -> ProcessWindowEvidence {
        guard let applicationElement = self.applicationElement else {
            return processWindowEvidence(pid: self.identity.pid) { nil }
        }
        return processWindowEvidence(pid: self.identity.pid) {
            focusedWindowID(applicationElement: applicationElement)
        }
    }
}

private final class FocusObserverCoordinator {
    typealias Factory = (ProcessGenerationIdentity) -> any FocusObserverTracking

    private let factory: Factory
    private var baselineObserver: (any FocusObserverTracking)?
    private var grantedObservers: [ProcessGenerationIdentity: any FocusObserverTracking] = [:]

    init(factory: @escaping Factory) {
        self.factory = factory
    }

    func startBaseline(_ identity: ProcessGenerationIdentity) throws {
        let observer = self.factory(identity)
        try observer.start()
        self.baselineObserver = observer
    }

    func prepare(target: AllowedForegroundTarget?) throws {
        guard let target else { return }
        let identity = ProcessGenerationIdentity(pid: target.pid, startIdentity: target.startIdentity)
        if self.baselineObserver?.identity == identity || self.grantedObservers[identity] != nil {
            return
        }
        let observer = self.factory(identity)
        try observer.start()
        self.grantedObservers[identity] = observer
    }

    func reconcile(activeTarget: AllowedForegroundTarget?) throws {
        let retainedIdentity = activeTarget.map {
            ProcessGenerationIdentity(pid: $0.pid, startIdentity: $0.startIdentity)
        }
        for identity in self.grantedObservers.keys where identity != retainedIdentity {
            guard let observer = self.grantedObservers[identity] else { continue }
            try observer.stop()
            self.grantedObservers.removeValue(forKey: identity)
        }
    }

    func stop() throws {
        var firstError: Error?
        for observer in self.grantedObservers.values {
            do {
                try observer.stop()
            } catch {
                firstError = firstError ?? error
            }
        }
        if let baselineObserver = self.baselineObserver {
            do {
                try baselineObserver.stop()
            } catch {
                firstError = firstError ?? error
            }
        }
        self.grantedObservers.removeAll()
        self.baselineObserver = nil
        if let firstError {
            throw firstError
        }
    }

    var observedIdentities: Set<ProcessGenerationIdentity> {
        var identities = Set(self.grantedObservers.keys)
        if let baselineObserver = self.baselineObserver {
            identities.insert(baselineObserver.identity)
        }
        return identities
    }
}

private func focusedWindowObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    _: CFString,
    context: UnsafeMutableRawPointer?)
{
    guard let context else { return }
    Unmanaged<FocusedWindowTracker>.fromOpaque(context).takeUnretainedValue().recordChange()
}

private func inputEventTapCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>?
{
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tracker = Unmanaged<InputEventTracker>.fromOpaque(userInfo).takeUnretainedValue()
    tracker.handle(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func windowInfo() -> [[String: Any]] {
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    return CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
}

private func frontmostWindowID(pid: Int32?, windows: [[String: Any]]) -> UInt32? {
    guard let pid else { return nil }

    return windows.first { window in
        guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              ownerPID == pid,
              let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue,
              layer == 0
        else {
            return false
        }

        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        return alpha > 0
    }.flatMap { window in
        (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
}

private func topWindowPID(windows: [[String: Any]]) -> Int32? {
    windows.first { window in
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        return layer == 0 && alpha > 0
    }.flatMap { window in
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }
}

private func sampleProcessWindowEvidence(
    pid: Int32,
    processIdentity: () -> UInt64?,
    windowID: () -> UInt32?) -> ProcessWindowEvidence
{
    let identityBefore = processIdentity()
    let sampledWindowID = windowID()
    let identityAfter = processIdentity()
    guard identityBefore == identityAfter, let identityBefore else {
        return ProcessWindowEvidence(pid: pid, startIdentity: nil, windowID: nil)
    }
    return ProcessWindowEvidence(pid: pid, startIdentity: String(identityBefore), windowID: sampledWindowID)
}

private func processWindowEvidence(pid: Int32, windowID: () -> UInt32?) -> ProcessWindowEvidence {
    sampleProcessWindowEvidence(
        pid: pid,
        processIdentity: { processStartIdentity(pid: pid) },
        windowID: windowID)
}

private func focusedWindowID(pid: Int32) -> UInt32? {
    guard pid > 0 else { return nil }
    return focusedWindowID(applicationElement: AXUIElementCreateApplication(pid))
}

private func focusedWindowID(applicationElement: AXUIElement) -> UInt32? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        applicationElement,
        kAXFocusedWindowAttribute as CFString,
        &value) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
        return nil
    }
    let window = unsafeDowncast(value, to: AXUIElement.self)
    var windowID: CGWindowID = 0
    return copyProbeAXWindowID(window, &windowID) == .success ? windowID : nil
}

private func inputEventEvidence(
    sourcePID: Int32,
    authorization: MonitorAuthorization) -> (source: ProcessWindowEvidence, sessionFocus: ProcessWindowEvidence?)
{
    let source = processWindowEvidence(pid: sourcePID) { nil }
    guard authorization.producersByPID[sourcePID]?.effectiveRole == .foregroundController,
          authorization.target != nil
    else {
        return (source: source, sessionFocus: nil)
    }
    let sessionFocus = NSWorkspace.shared.frontmostApplication.map { app in
        let pid = app.processIdentifier
        return processWindowEvidence(pid: pid) { focusedWindowID(pid: pid) }
    }
    return (source: source, sessionFocus: sessionFocus)
}

private func peekabooWindowIDs(windows: [[String: Any]]) -> [UInt32] {
    let pids = Set(NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
        guard let bundleIdentifier = app.bundleIdentifier?.lowercased(),
              bundleIdentifier.contains("peekaboo"),
              !bundleIdentifier.contains("playground")
        else {
            return nil
        }
        return app.processIdentifier
    })

    return windows.compactMap { window in
        guard let ownerPID = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              pids.contains(ownerPID),
              let number = window[kCGWindowNumber as String] as? NSNumber
        else {
            return nil
        }
        let alpha = window[kCGWindowAlpha as String] as? Double ?? 1
        guard alpha > 0 else { return nil }
        return number.uint32Value
    }.sorted()
}

private func clipboardDigest(_ pasteboard: NSPasteboard) -> String {
    var hasher = SHA256()
    for item in pasteboard.pasteboardItems ?? [] {
        let types = item.types.sorted { $0.rawValue < $1.rawValue }
        for type in types {
            let typeData = Data(type.rawValue.utf8)
            hasher.update(data: withLengthPrefix(typeData))
            hasher.update(data: withLengthPrefix(item.data(forType: type) ?? Data()))
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func withLengthPrefix(_ data: Data) -> Data {
    var length = UInt64(data.count).bigEndian
    var result = Data(bytes: &length, count: MemoryLayout<UInt64>.size)
    result.append(data)
    return result
}

private func sample(includeClipboardDigest: Bool = true) throws -> SystemSample {
    guard let event = CGEvent(source: nil) else { throw ProbeError.noMouseEvent }
    let windows = windowInfo()
    let workspace = NSWorkspace.shared
    let windowOwnerPID = topWindowPID(windows: windows)
    let frontmost = windowOwnerPID.flatMap { pid in
        workspace.runningApplications.first { $0.processIdentifier == pid }
    } ?? workspace.frontmostApplication
    let frontmostPID = windowOwnerPID ?? frontmost?.processIdentifier
    let pasteboard = NSPasteboard.general
    let primaryDisplayHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
        ?? NSScreen.main)?.frame.height ?? 0
    let visibleScreenFramesTopLeft = NSScreen.screens.map { screen in
        let frame = screen.visibleFrame
        return Rectangle(
            x: frame.origin.x,
            y: primaryDisplayHeight - frame.maxY,
            width: frame.width,
            height: frame.height)
    }

    return SystemSample(
        timestamp: Date().timeIntervalSince1970,
        frontmostPID: frontmostPID,
        frontmostBundleIdentifier: frontmost?.bundleIdentifier,
        frontmostWindowID: frontmostWindowID(pid: frontmostPID, windows: windows),
        cursor: Point(x: event.location.x, y: event.location.y),
        clipboardChangeCount: pasteboard.changeCount,
        clipboardDigest: includeClipboardDigest ? clipboardDigest(pasteboard) : "",
        peekabooWindowIDs: peekabooWindowIDs(windows: windows),
        visibleScreenFramesTopLeft: visibleScreenFramesTopLeft)
}

private func processStartIdentity(pid: Int32) -> UInt64? {
    guard pid > 0 else { return nil }
    var info = proc_bsdinfo()
    let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize) == expectedSize else {
        return nil
    }
    let seconds = UInt64(info.pbi_start_tvsec)
    let microseconds = UInt64(info.pbi_start_tvusec)
    return seconds.multipliedReportingOverflow(by: 1_000_000).partialValue &+ microseconds
}

private func monotonicMicroseconds() -> UInt64 {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = mach_continuous_time()
    let denominator = UInt64(timebase.denom)
    let numerator = UInt64(timebase.numer)
    let whole = (ticks / denominator) * numerator
    let remainder = (ticks % denominator) * numerator / denominator
    return (whole + remainder) / 1000
}

private func violations(current: SystemSample, context: InvariantEvaluationContext) -> Set<Violation> {
    var result = Set<Violation>()

    if context.evaluateInteractiveInvariants {
        if current.frontmostPID != context.interactiveBaseline.frontmostPID {
            result.insert(Violation(
                kind: context.projection[.frontmostPID],
                expected: String(context.interactiveBaseline.frontmostPID),
                actual: current.frontmostPID.map(String.init) ?? "null"))
        }
        if current.frontmostWindowID != context.interactiveBaseline.frontmostWindowID {
            result.insert(Violation(
                kind: context.projection[.frontmostWindow],
                expected: String(context.interactiveBaseline.frontmostWindowID),
                actual: current.frontmostWindowID.map(String.init) ?? "null"))
        }

        let cursorMoved = abs(current.cursor.x - context.interactiveBaseline.cursor.x) > 0.5 ||
            abs(current.cursor.y - context.interactiveBaseline.cursor.y) > 0.5
        if cursorMoved, !context.cursorObservational {
            result.insert(Violation(
                kind: cursorPositionViolationKind,
                expected: "\(context.interactiveBaseline.cursor.x),\(context.interactiveBaseline.cursor.y)",
                actual: "\(current.cursor.x),\(current.cursor.y)"))
        }
    }

    if !context.allowClipboardMutation,
       current.clipboardChangeCount != context.baseline.clipboardChangeCount
    {
        result.insert(Violation(
            kind: context.projection[.clipboardChangeCount],
            expected: String(context.baseline.clipboardChangeCount),
            actual: String(current.clipboardChangeCount)))
    }

    let addedWindows = Set(current.peekabooWindowIDs).subtracting(context.baseline.peekabooWindowIDs)
    if !addedWindows.isEmpty {
        result.insert(Violation(
            kind: context.projection[.peekabooOverlayWindow],
            expected: "none added",
            actual: addedWindows.sorted().map(String.init).joined(separator: ",")))
    }

    return result
}

private func foregroundControllerCardinalityIsValid(
    producers: [AllowedEventProducer],
    foreground: AllowedForegroundActivity) -> Bool
{
    let controllerCount = producers.count { $0.effectiveRole == .foregroundController }
    return foreground.active ? controllerCount == 1 && foreground.target != nil
        : controllerCount == 0 && foreground.target == nil
}

private func foregroundTargetIsLive(
    _ target: AllowedForegroundTarget,
    processIdentity: () -> UInt64?,
    windowMatches: () -> Bool) -> Bool
{
    guard target.pid > 0,
          target.windowID > 0,
          processIdentity().map(String.init) == target.startIdentity,
          windowMatches(),
          processIdentity().map(String.init) == target.startIdentity
    else {
        return false
    }
    return true
}

private func foregroundTargetIsLive(_ target: AllowedForegroundTarget) -> Bool {
    foregroundTargetIsLive(
        target,
        processIdentity: { processStartIdentity(pid: target.pid) },
        windowMatches: {
            let windows = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow, .excludeDesktopElements],
                target.windowID) as? [[String: Any]] ?? []
            return windows.contains { window in
                (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid &&
                    (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID
            }
        })
}

private func makeMonitorAuthorization(
    _ producerSet: AllowedEventProducerSet,
    processIdentity: (Int32) -> UInt64? = processStartIdentity(pid:),
    targetValidator: (AllowedForegroundTarget) -> Bool = foregroundTargetIsLive) throws -> MonitorAuthorization
{
    let producerPIDs = producerSet.producers.map(\.pid)
    guard Set(producerPIDs).count == producerPIDs.count,
          Set(producerSet.producers).count == producerSet.producers.count,
          producerSet.producers.allSatisfy({ producer in
              processIdentity(producer.pid).map(String.init) == producer.startIdentity
          }),
          producerSet.producers.isEmpty || producerSet.producers.contains(where: {
              $0.effectiveRole == .bridge
          })
    else {
        throw ProbeError.invalidArguments("blocked_producer_identity")
    }
    let foreground = producerSet.effectiveForeground
    guard foregroundControllerCardinalityIsValid(
        producers: producerSet.producers,
        foreground: foreground),
        !foreground.active || foreground.target.map(targetValidator) == true
    else {
        throw ProbeError.invalidArguments("blocked_foreground_contract")
    }
    return MonitorAuthorization(
        source: producerSet,
        producersByPID: Dictionary(uniqueKeysWithValues: producerSet.producers.map { ($0.pid, $0) }),
        foreground: foreground)
}

private func applyMonitorAuthorization(
    _ producerSet: AllowedEventProducerSet,
    to machine: MonitorEpochMachine,
    observers: FocusObserverCoordinator,
    processIdentity: (Int32) -> UInt64? = processStartIdentity(pid:),
    targetValidator: (AllowedForegroundTarget) -> Bool = foregroundTargetIsLive)
{
    let current = machine.currentAuthorization
    if producerSet.revision == current.revision {
        // Exact rereads are required while this revision waits for its acknowledgement barrier.
        if !current.hasExactlyEquivalentPayload(to: producerSet) {
            machine.admitFailure(reason: "blocked_producer_revision_replay")
        }
        return
    }
    guard producerSet.revision > current.revision else {
        machine.admitFailure(reason: "blocked_producer_revision_replay")
        return
    }
    guard machine.currentPhase.isStable else {
        machine.admitFailure(reason: "blocked_producer_revision_before_ack")
        return
    }
    let authorization: MonitorAuthorization
    do {
        authorization = try makeMonitorAuthorization(
            producerSet,
            processIdentity: processIdentity,
            targetValidator: targetValidator)
    } catch {
        machine.admitFailure(reason: String(describing: error))
        return
    }
    do {
        try observers.prepare(target: authorization.target)
    } catch {
        machine.admitFailure(reason: "blocked_focus_observer_install")
        return
    }
    if case let .rejected(reason) = machine.publish(authorization) {
        machine.admitFailure(reason: reason)
    }
}

private enum MonitorAcknowledgementPreparationError: Error {
    case liveness
    case observerRemoval

    var reason: String {
        switch self {
        case .liveness:
            "blocked_foreground_ack_liveness"
        case .observerRemoval:
            "blocked_focus_observer_removal"
        }
    }
}

private func recordMonitorAcknowledgementPreparationFailure(
    _ error: MonitorAcknowledgementPreparationError,
    machine: MonitorEpochMachine)
{
    machine.admitFailure(reason: error.reason)
}

private func publishMonitorTransitionAcknowledgement(
    revision: UInt64,
    machine: MonitorEpochMachine,
    observers: FocusObserverCoordinator,
    processIdentity: @escaping (Int32) -> UInt64? = processStartIdentity(pid:),
    targetValidator: @escaping (AllowedForegroundTarget) -> Bool = foregroundTargetIsLive,
    publish: () throws -> Void = {}) throws -> MonitorPublicationResult
{
    let authorization = machine.currentAuthorization
    let priorAuthorization = machine.currentPhase.priorAuthorization
    guard authorization.revision == revision else {
        return .rejected(reason: "blocked_producer_ack_revision_mismatch")
    }
    let authorizations = [authorization] + (priorAuthorization.map { [$0] } ?? [])
    func authorizationsAreLive() -> Bool {
        authorizations.allSatisfy { candidate in
            candidate.source.producers.filter {
                $0.effectiveRole == .foregroundController
            }.allSatisfy { producer in
                processIdentity(producer.pid).map(String.init) == producer.startIdentity
            } && candidate.target.map(targetValidator) != false
        }
    }
    return try machine.acknowledge(
        revision: revision,
        preparing: {
            guard authorizationsAreLive() else {
                throw MonitorAcknowledgementPreparationError.liveness
            }
            do {
                try observers.reconcile(activeTarget: authorization.target)
            } catch {
                throw MonitorAcknowledgementPreparationError.observerRemoval
            }
            guard authorizationsAreLive() else {
                throw MonitorAcknowledgementPreparationError.liveness
            }
        },
        publishing: publish)
}

private struct MonitorAcknowledgementGate {
    private(set) var pendingRevision: UInt64?
    private(set) var readyRevision: UInt64?

    mutating func record(_ closure: MonitorEpochClosure) {
        guard closure.transitionAcknowledged else { return }
        self.pendingRevision = closure.finalEpoch.epoch.authorization.revision
        self.readyRevision = nil
    }

    mutating func completeCallbackBarrier(machine: MonitorEpochMachine) throws {
        guard let pendingRevision = self.pendingRevision else { return }
        guard machine.markAcknowledgementReady(revision: pendingRevision) == .published else {
            throw ProbeError.invalidArguments("blocked_producer_ack_callback_barrier")
        }
        self.readyRevision = pendingRevision
    }

    mutating func didPublish(revision: UInt64) {
        precondition(self.pendingRevision == revision && self.readyRevision == revision)
        self.pendingRevision = nil
        self.readyRevision = nil
    }
}

private func monitorRequiresIdleBarrier(
    pendingAcknowledgementRevision: UInt64?,
    currentRevision: UInt64,
    proposedRevision: UInt64) -> Bool
{
    pendingAcknowledgementRevision != nil || proposedRevision > currentRevision
}

private func evidenceMatches(
    _ evidence: ProcessWindowEvidence,
    pid: Int32,
    startIdentity: String,
    windowID: UInt32) -> Bool
{
    evidence.pid == pid && evidence.startIdentity == startIdentity && evidence.windowID == windowID
}

private func focusEvidenceViolations(
    _ evidence: ProcessWindowEvidence,
    authorization: MonitorAuthorization,
    baseline: InteractiveBaseline,
    projection: InvariantProjection) -> Set<Violation>
{
    var allowed = [ProcessWindowEvidence(
        pid: baseline.frontmostPID,
        startIdentity: baseline.processStartIdentity,
        windowID: baseline.frontmostWindowID)]
    if let target = authorization.target {
        allowed.append(ProcessWindowEvidence(
            pid: target.pid,
            startIdentity: target.startIdentity,
            windowID: target.windowID))
    }
    guard !allowed.contains(evidence) else { return [] }
    var result = Set<Violation>()
    if !allowed.contains(where: { $0.pid == evidence.pid }) {
        result.insert(Violation(
            kind: projection[.frontmostPID],
            expected: allowed.map { String($0.pid) }.joined(separator: " or "),
            actual: String(evidence.pid)))
    }
    result.insert(Violation(
        kind: projection[.frontmostWindow],
        expected: allowed.compactMap(\.windowID).map(String.init).joined(separator: " or "),
        actual: evidence.windowID.map(String.init) ?? "unresolved"))
    return result
}

private func currentFocusViolations(
    current: SystemSample,
    closure: MonitorEpochClosure,
    baseline: InteractiveBaseline,
    projection: InvariantProjection) -> Set<Violation>
{
    var allowed = Set(["\(baseline.frontmostPID):\(baseline.frontmostWindowID)"])
    if let target = closure.finalEpoch.epoch.focusAuthorization.target {
        allowed.insert("\(target.pid):\(target.windowID)")
    }
    let currentKey = current.frontmostPID.flatMap { pid in
        current.frontmostWindowID.map { "\(pid):\($0)" }
    }
    guard let currentKey, allowed.contains(currentKey) else {
        return [
            Violation(
                kind: projection[.frontmostPID],
                expected: "authorized epoch focus",
                actual: current.frontmostPID.map(String.init) ?? "null"),
            Violation(
                kind: projection[.frontmostWindow],
                expected: "authorized epoch window",
                actual: current.frontmostWindowID.map(String.init) ?? "null"),
        ]
    }
    return []
}

private struct ClosedEpochEventClassification {
    var externalInputs = [InputEventEvidence]()
    var focusEvents = [ProcessWindowEvidence]()
    var bridgeSources = Set<Int32>()
    var bridgeTypes = Set<UInt32>()
    var bridgePointerSources = Set<Int32>()
    var bridgePointerTypes = Set<UInt32>()
    var activationCount = 0
    var focusCount = 0
}

private let sharedPointerEventTypes = Set([
    CGEventType.leftMouseDown.rawValue,
    CGEventType.leftMouseUp.rawValue,
    CGEventType.rightMouseDown.rawValue,
    CGEventType.rightMouseUp.rawValue,
    CGEventType.mouseMoved.rawValue,
    CGEventType.leftMouseDragged.rawValue,
    CGEventType.rightMouseDragged.rawValue,
    CGEventType.otherMouseDown.rawValue,
    CGEventType.otherMouseUp.rawValue,
    CGEventType.otherMouseDragged.rawValue,
    CGEventType.scrollWheel.rawValue,
    CGEventType.tabletPointer.rawValue,
    CGEventType.tabletProximity.rawValue,
])

private struct ClosedEpochEvaluation {
    let violations: Set<Violation>
    let permitsInteractiveEvaluation: Bool
    let activationCount: Int
    let focusCount: Int
}

private struct ForegroundActivitySummary {
    var eventCount = 0
    var sourcePIDs = Set<Int32>()
}

private struct WatchState {
    let baseline: SystemSample
    let interactiveBaseline: InteractiveBaseline
    let executionNonce: String
    let monitorInstanceID: String
    var historyCommitmentSHA256: String
    let allowClipboardMutation: Bool
    let physicalInputObservational: Bool
    let cursorObservational: Bool
    let projection: InvariantProjection
    let outputPath: String
    let contaminationOutputPath: String
    let evidenceLedger: MonitorPublicationLedger?
    private var recorded = Set<Violation>()
    private var sequence: UInt64 = 0
    private var lastCleanSequence: UInt64 = 0
    private var contaminationRetries = 0
    private var contaminationState = AttemptContaminationState()
    private var inputAttributionAvailable = true
    private var cursorMovementObserved = false
    private var foregroundActivityByRevision = [UInt64: ForegroundActivitySummary]()

    mutating func observe(
        current: SystemSample,
        phase: String,
        closure: MonitorEpochClosure,
        processIdentity: (Int32) -> UInt64? = processStartIdentity(pid:),
        targetValidator: (AllowedForegroundTarget) -> Bool = foregroundTargetIsLive) throws -> WatchHeartbeat
    {
        if abs(current.cursor.x - self.interactiveBaseline.cursor.x) > 0.5 ||
            abs(current.cursor.y - self.interactiveBaseline.cursor.y) > 0.5
        {
            self.cursorMovementObserved = true
        }
        var currentViolations = Set<Violation>()
        var totalActivationCount = 0
        var totalFocusCount = 0
        var allEpochsPermitInteractiveEvaluation = true

        if processIdentity(self.interactiveBaseline.frontmostPID).map(String.init) !=
            self.interactiveBaseline.processStartIdentity
        {
            try self.block(
                reason: "blocked_baseline_generation_drift",
                sourcePIDs: [self.interactiveBaseline.frontmostPID],
                eventTypes: [],
                attributionFailed: true,
                countsRetry: false)
        }

        for closedEpoch in closure.epochs {
            let evaluation = try self.evaluate(
                closedEpoch: closedEpoch,
                phase: phase,
                processIdentity: processIdentity,
                targetValidator: targetValidator)
            currentViolations.formUnion(evaluation.violations)
            totalActivationCount += evaluation.activationCount
            totalFocusCount += evaluation.focusCount
            allEpochsPermitInteractiveEvaluation = allEpochsPermitInteractiveEvaluation &&
                evaluation.permitsInteractiveEvaluation
        }

        let evaluateInteractive = allEpochsPermitInteractiveEvaluation && self.inputAttributionAvailable &&
            self.contaminationState.permitsInteractiveEvaluation
        let finalEpoch = closure.finalEpoch.epoch
        let focusAuthorization = finalEpoch.focusAuthorization
        let context = InvariantEvaluationContext(
            baseline: self.baseline,
            interactiveBaseline: self.interactiveBaseline,
            allowClipboardMutation: self.allowClipboardMutation,
            evaluateInteractiveInvariants: evaluateInteractive && !focusAuthorization.foreground.active,
            cursorObservational: self.cursorObservational,
            projection: self.projection)
        currentViolations.formUnion(violations(current: current, context: context))
        if evaluateInteractive, focusAuthorization.foreground.active {
            currentViolations.formUnion(currentFocusViolations(
                current: current,
                closure: closure,
                baseline: self.interactiveBaseline,
                projection: self.projection))
            let cursorMoved = abs(current.cursor.x - self.interactiveBaseline.cursor.x) > 0.5 ||
                abs(current.cursor.y - self.interactiveBaseline.cursor.y) > 0.5
            if cursorMoved, !self.cursorObservational {
                currentViolations.insert(Violation(
                    kind: cursorPositionViolationKind,
                    expected: "\(self.interactiveBaseline.cursor.x),\(self.interactiveBaseline.cursor.y)",
                    actual: "\(current.cursor.x),\(current.cursor.y)"))
            }
        }
        for violation in currentViolations.subtracting(self.recorded) {
            try appendJSONLine(violation, to: self.outputPath)
            self.evidenceLedger?.record(violation: violation)
            self.recorded.insert(violation)
        }

        self.sequence += 1
        if evaluateInteractive, finalEpoch.phase.isStable, currentViolations.isEmpty {
            self.lastCleanSequence = self.sequence
        }
        let finalAuthorization = closure.finalEpoch.epoch.authorization
        let finalActivity = self.foregroundActivityByRevision[finalAuthorization.revision] ??
            ForegroundActivitySummary()
        return WatchHeartbeat(
            sequence: self.sequence,
            monotonicMicroseconds: monotonicMicroseconds(),
            wallClockMilliseconds: Int64((current.timestamp * 1000).rounded(.down)),
            lastCleanSequence: self.lastCleanSequence,
            contaminationRetries: self.contaminationRetries,
            contaminationBlocked: self.contaminationState.blocked,
            inputAttributionAvailable: self.inputAttributionAvailable,
            allowedProducerRevision: finalAuthorization.revision,
            phase: phase,
            cursorMovementObserved: self.cursorMovementObserved,
            pendingActivationCount: totalActivationCount,
            pendingFocusedWindowChange: totalFocusCount > 0,
            authorizationEpoch: closure.finalEpoch.epoch.serial,
            transitionAcknowledged: closure.transitionAcknowledged,
            foregroundActive: finalAuthorization.foreground.active,
            foregroundTargetPID: finalAuthorization.target?.pid,
            foregroundTargetWindowID: finalAuthorization.target?.windowID,
            attributedForegroundEventCount: finalActivity.eventCount,
            attributedForegroundSourcePIDs: finalActivity.sourcePIDs.sorted(),
            foregroundActivityObserved: finalActivity.eventCount > 0,
            executionNonce: self.executionNonce,
            monitorInstanceID: self.monitorInstanceID,
            historyCommitmentSHA256: self.historyCommitmentSHA256)
    }

    private mutating func evaluate(
        closedEpoch: ClosedMonitorEpoch,
        phase: String,
        processIdentity: (Int32) -> UInt64?,
        targetValidator: (AllowedForegroundTarget) -> Bool) throws -> ClosedEpochEvaluation
    {
        let authorization = closedEpoch.epoch.authorization
        let producers = Set(
            (authorization.source.producers + closedEpoch.epoch.focusAuthorization.source.producers).filter {
                $0.effectiveRole == .foregroundController
            })
        for producer in producers
            where processIdentity(producer.pid).map(String.init) != producer.startIdentity
        {
            try self.block(
                reason: "blocked_producer_generation_drift",
                sourcePIDs: [producer.pid],
                eventTypes: [],
                attributionFailed: true,
                countsRetry: false)
        }
        let targets = Set([authorization.target, closedEpoch.epoch.focusAuthorization.target].compactMap(\.self))
        for target in targets where !targetValidator(target) {
            try self.block(
                reason: "blocked_foreground_target_drift",
                sourcePIDs: [target.pid],
                eventTypes: [],
                attributionFailed: true,
                countsRetry: false)
        }
        let classification = try self.classify(
            events: closedEpoch.events,
            epoch: closedEpoch.epoch)
        var epochViolations = Set<Violation>()
        if !classification.bridgeSources.isEmpty {
            epochViolations.insert(Violation(
                kind: self.projection[.globalInputEvent],
                expected: "no session-global input events",
                actual: "pids=\(classification.bridgeSources.sorted().map(String.init).joined(separator: ",")); " +
                    "types=\(classification.bridgeTypes.sorted().map(String.init).joined(separator: ","))"))
        }
        if !classification.bridgePointerSources.isEmpty {
            epochViolations.insert(Violation(
                kind: self.projection[.physicalCursor],
                expected: "no producer-attributed shared-pointer events",
                actual: "pids=\(classification.bridgePointerSources.sorted().map(String.init).joined(separator: ",")); " +
                    "types=\(classification.bridgePointerTypes.sorted().map(String.init).joined(separator: ","))"))
        }

        let physicalInputIsObservational = self.physicalInputObservational &&
            !classification.externalInputs.isEmpty && classification.externalInputs.allSatisfy { input in
                input.source.pid == 0 && input.source.startIdentity == nil &&
                    input.type == CGEventType.mouseMoved.rawValue
            }
        let permitsInteractiveEvaluation = classification.externalInputs.isEmpty || physicalInputIsObservational
        if !permitsInteractiveEvaluation {
            try self.block(
                reason: phase == "setup" ? "blocked_setup_attempt" : "blocked_active_attempt",
                sourcePIDs: Set(classification.externalInputs.map(\.source.pid)).sorted(),
                eventTypes: Set(classification.externalInputs.map(\.type)).sorted(),
                attributionFailed: false,
                countsRetry: true)
        } else {
            try epochViolations.formUnion(self.focusViolations(
                classification.focusEvents,
                authorization: closedEpoch.epoch.focusAuthorization))
        }
        return ClosedEpochEvaluation(
            violations: epochViolations,
            permitsInteractiveEvaluation: permitsInteractiveEvaluation,
            activationCount: classification.activationCount,
            focusCount: classification.focusCount)
    }

    private mutating func classify(
        events: [MonitorEvent],
        epoch: MonitorEpoch) throws -> ClosedEpochEventClassification
    {
        var classification = ClosedEpochEventClassification()
        for event in events {
            switch event.kind {
            case let .attributionFailure(reason, process):
                try self.block(
                    reason: reason,
                    sourcePIDs: process.map { [$0.pid] } ?? [],
                    eventTypes: [],
                    attributionFailed: true,
                    countsRetry: false)
            case let .input(input):
                try self.classify(
                    input: input,
                    epoch: epoch,
                    into: &classification)
            case let .activation(evidence):
                classification.activationCount += 1
                classification.focusEvents.append(evidence)
            case let .focus(focus):
                classification.focusCount += 1
                if focus.observer.pid != focus.observed.pid ||
                    focus.observer.startIdentity != focus.observed.startIdentity
                {
                    try self.block(
                        reason: "blocked_focus_observer_generation_drift",
                        sourcePIDs: [focus.observer.pid],
                        eventTypes: [],
                        attributionFailed: true,
                        countsRetry: false)
                }
                classification.focusEvents.append(focus.observed)
            }
        }
        return classification
    }

    private mutating func classify(
        input: InputEventEvidence,
        epoch: MonitorEpoch,
        into classification: inout ClosedEpochEventClassification) throws
    {
        let authorization = epoch.focusAuthorization
        if !epoch.phase.isStable,
           authorization.producersByPID[input.source.pid] == nil,
           epoch.authorization.producersByPID[input.source.pid]?.effectiveRole == .foregroundController
        {
            try self.block(
                reason: "blocked_foreground_input_before_transition_ack",
                sourcePIDs: [input.source.pid],
                eventTypes: [input.type],
                attributionFailed: true,
                countsRetry: false)
            return
        }
        guard let producer = authorization.producersByPID[input.source.pid] else {
            classification.externalInputs.append(input)
            return
        }
        guard input.source.startIdentity == producer.startIdentity else {
            try self.block(
                reason: "blocked_producer_generation_drift",
                sourcePIDs: [input.source.pid],
                eventTypes: [input.type],
                attributionFailed: true,
                countsRetry: false)
            return
        }
        switch producer.effectiveRole {
        case .bridge:
            classification.bridgeSources.insert(input.source.pid)
            classification.bridgeTypes.insert(input.type)
            if sharedPointerEventTypes.contains(input.type) {
                classification.bridgePointerSources.insert(input.source.pid)
                classification.bridgePointerTypes.insert(input.type)
            }
        case .foregroundController:
            guard let target = authorization.target,
                  input.sessionFocus.map({ evidenceMatches(
                      $0,
                      pid: target.pid,
                      startIdentity: target.startIdentity,
                      windowID: target.windowID)
                  }) == true
            else {
                try self.block(
                    reason: "blocked_foreground_target_drift",
                    sourcePIDs: [input.source.pid],
                    eventTypes: [input.type],
                    attributionFailed: true,
                    countsRetry: false)
                return
            }
            var activity = self.foregroundActivityByRevision[authorization.revision] ??
                ForegroundActivitySummary()
            activity.eventCount += 1
            activity.sourcePIDs.insert(input.source.pid)
            self.foregroundActivityByRevision[authorization.revision] = activity
        }
    }

    func foregroundActivity(for revision: UInt64) -> ForegroundActivitySummary {
        self.foregroundActivityByRevision[revision] ?? ForegroundActivitySummary()
    }

    private mutating func focusViolations(
        _ evidence: [ProcessWindowEvidence],
        authorization: MonitorAuthorization) throws -> Set<Violation>
    {
        let allowedGenerations = [ProcessWindowEvidence(
            pid: self.interactiveBaseline.frontmostPID,
            startIdentity: self.interactiveBaseline.processStartIdentity,
            windowID: self.interactiveBaseline.frontmostWindowID)] +
            (authorization.target.map {
                [ProcessWindowEvidence(
                    pid: $0.pid,
                    startIdentity: $0.startIdentity,
                    windowID: $0.windowID)]
            } ?? [])
        var result = Set<Violation>()
        for eventEvidence in evidence {
            if allowedGenerations.contains(where: {
                $0.pid == eventEvidence.pid && $0.startIdentity != eventEvidence.startIdentity
            }) {
                try self.block(
                    reason: "blocked_focus_generation_drift",
                    sourcePIDs: [eventEvidence.pid],
                    eventTypes: [],
                    attributionFailed: true,
                    countsRetry: false)
            }
            result.formUnion(focusEvidenceViolations(
                eventEvidence,
                authorization: authorization,
                baseline: self.interactiveBaseline,
                projection: self.projection))
        }
        return result
    }

    private mutating func block(
        reason: String,
        sourcePIDs: [Int32],
        eventTypes: [UInt32],
        attributionFailed: Bool,
        countsRetry: Bool) throws
    {
        if attributionFailed {
            self.inputAttributionAvailable = false
        }
        guard !self.contaminationState.blocked else { return }
        if countsRetry {
            self.contaminationRetries += 1
        }
        let record = ContaminationRecord(
            state: reason,
            retry: self.contaminationRetries,
            sequence: self.sequence + 1,
            sourcePIDs: sourcePIDs,
            eventTypes: eventTypes)
        try appendJSONLine(record, to: self.contaminationOutputPath)
        self.evidenceLedger?.record(contamination: record)
        self.contaminationState.observe(
            externalInput: !attributionFailed,
            attributionFailed: attributionFailed)
    }
}

private func writeJSON(_ value: some Encodable, to path: String?) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    if let path {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        guard chmod(path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private final class PreparedJSONPublication {
    private let temporaryURL: URL
    private let destinationURL: URL
    private var committed = false

    init(_ value: some Encodable, destinationPath: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(value)
        data.append(Data("\n".utf8))
        let destinationURL = URL(fileURLWithPath: destinationPath)
        let temporaryURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp")
        self.destinationURL = destinationURL
        self.temporaryURL = temporaryURL
        try data.write(to: temporaryURL)
        guard chmod(temporaryURL.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    deinit {
        if !self.committed {
            try? FileManager.default.removeItem(at: self.temporaryURL)
        }
    }

    func commit() throws {
        guard !self.committed else {
            throw ProbeError.invalidArguments("prepared JSON publication was already committed")
        }
        guard rename(self.temporaryURL.path, self.destinationURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.committed = true
    }
}

private struct MonitorProcessReceipt: Codable, Equatable {
    let pid: Int32
    let startIdentity: String
    let codeSignatureHash: String

    private enum CodingKeys: String, CodingKey {
        case pid
        case startIdentity = "start_identity"
        case codeSignatureHash = "code_signature_hash"
    }
}

private struct MonitorAttestationRequest: Codable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let challenge: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case challenge
    }
}

private struct MonitorAttestationResponse: Codable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let challenge: String
    let monitor: MonitorProcessReceipt
    let monitorEvidenceSHA256: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case challenge
        case monitor
        case monitorEvidenceSHA256 = "monitor_evidence_sha256"
    }
}

private struct MonitorSealRequest: Codable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let phase: String
    let draftPath: String
    let sealedPath: String
    let historyCommitmentSHA256: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case phase
        case draftPath = "draft_path"
        case sealedPath = "sealed_path"
        case historyCommitmentSHA256 = "history_commitment_sha256"
    }
}

private struct MonitorSealReceipt: Codable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let phase: String
    let monitorEvidenceSHA256: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case phase
        case monitorEvidenceSHA256 = "monitor_evidence_sha256"
    }
}

private func currentCodeSignatureHash() -> String? {
    var dynamicCode: SecCode?
    guard SecCodeCopySelf([], &dynamicCode) == errSecSuccess, let dynamicCode else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var information: CFDictionary?
    let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
    guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
          let values = information as? [String: Any],
          let data = values[kSecCodeInfoUnique as String] as? Data,
          data.count == 20
    else { return nil }
    return data.map { String(format: "%02x", $0) }.joined()
}

private func currentMonitorProcessReceipt() throws -> MonitorProcessReceipt {
    let pid = getpid()
    guard let startIdentity = processStartIdentity(pid: pid).map(String.init),
          let codeSignatureHash = currentCodeSignatureHash(),
          isLowerHex(codeSignatureHash, count: 40)
    else {
        throw ProbeError.invalidArguments("monitor cannot bind its live process generation and code signature")
    }
    return MonitorProcessReceipt(
        pid: pid,
        startIdentity: startIdentity,
        codeSignatureHash: codeSignatureHash)
}

private func requireOwnerPrivateParent(of path: String) throws {
    guard path.hasPrefix("/"), !path.contains("\0") else {
        throw ProbeError.invalidArguments("monitor path must be absolute")
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path
    var info = stat()
    guard lstat(parent, &info) == 0,
          (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == geteuid(),
          (info.st_mode & 0o077) == 0
    else {
        throw ProbeError.invalidArguments("monitor artifact parent must be owner private")
    }
}

private func readOwnerPrivateFile(
    _ path: String,
    maximumBytes: Int = 16 * 1024 * 1024,
    afterOpen: (() throws -> Void)? = nil) throws -> Data
{
    func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec && lhs.st_nlink == rhs.st_nlink
    }
    func valid(_ info: stat) -> Bool {
        (info.st_mode & S_IFMT) == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1 &&
            (info.st_mode & 0o077) == 0 && info.st_size >= 0 && info.st_size <= maximumBytes
    }

    var pathBefore = stat()
    guard lstat(path, &pathBefore) == 0, valid(pathBefore) else {
        throw ProbeError.invalidArguments("monitor input must be one bounded owner-private regular file")
    }
    let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw ProbeError.invalidArguments("monitor input cannot be opened safely") }
    defer { close(descriptor) }
    var descriptorBefore = stat()
    guard fstat(descriptor, &descriptorBefore) == 0,
          valid(descriptorBefore),
          sameFile(pathBefore, descriptorBefore)
    else {
        throw ProbeError.invalidArguments("monitor input changed while it was opened")
    }
    try afterOpen?()
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
    while data.count <= maximumBytes {
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
            data.append(contentsOf: buffer.prefix(count))
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    var descriptorAfter = stat()
    var pathAfter = stat()
    guard data.count <= maximumBytes,
          data.count == descriptorBefore.st_size,
          fstat(descriptor, &descriptorAfter) == 0,
          lstat(path, &pathAfter) == 0,
          sameFile(descriptorBefore, descriptorAfter),
          sameFile(descriptorAfter, pathAfter)
    else {
        throw ProbeError.invalidArguments("monitor input changed while it was read")
    }
    return data
}

private func readStableOwnerPrivateFile(_ path: String, maximumBytes: Int = 16 * 1024 * 1024) throws -> Data {
    var lastError: Error?
    for _ in 0..<3 {
        do {
            return try readOwnerPrivateFile(path, maximumBytes: maximumBytes)
        } catch {
            lastError = error
            usleep(1000)
        }
    }
    throw lastError ?? ProbeError.invalidArguments("monitor input could not be read stably")
}

private func writeOwnerPrivateJSON(_ value: some Encodable, to path: String) throws {
    try requireOwnerPrivateParent(of: path)
    var existing = stat()
    guard lstat(path, &existing) != 0, errno == ENOENT else {
        throw ProbeError.invalidArguments("monitor output path already exists")
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func canonicalJSONObjectData(_ object: Any) throws -> Data {
    func validate(_ value: Any) throws {
        if value is NSNull || value is String || value is Bool {
            return
        }
        if let number = value as? NSNumber {
            let double = number.doubleValue
            guard double.isFinite,
                  !(double == 0 && double.sign == .minus)
            else {
                throw ProbeError.invalidArguments("canonical monitor JSON contains an invalid number")
            }
            if floor(double) == double {
                guard abs(double) <= 9_007_199_254_740_991 else {
                    throw ProbeError.invalidArguments("canonical monitor JSON contains a lossy integer")
                }
            }
            return
        }
        if let array = value as? [Any] {
            for entry in array {
                try validate(entry)
            }
            return
        }
        if let dictionary = value as? [String: Any] {
            for entry in dictionary.values {
                try validate(entry)
            }
            return
        }
        throw ProbeError.invalidArguments("canonical monitor JSON contains a non-JSON value")
    }
    try validate(object)
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys, .withoutEscapingSlashes])
}

extension Array {
    fileprivate subscript(safe index: Index) -> Element? {
        self.indices.contains(index) ? self[index] : nil
    }
}

private struct RawCanonicalJSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ data: Data) {
        self.bytes = Array(data)
    }

    mutating func parse() throws -> Data {
        let value = try self.parseValue()
        self.skipWhitespace()
        guard self.index == self.bytes.count else { throw self.invalid() }
        return value
    }

    private mutating func parseValue() throws -> Data {
        self.skipWhitespace()
        guard let byte = self.bytes[safe: self.index] else { throw self.invalid() }
        return switch byte {
        case 0x7B: try self.parseObject()
        case 0x5B: try self.parseArray()
        case 0x22: try self.parseString().encoded
        case 0x74: try self.parseLiteral("true")
        case 0x66: try self.parseLiteral("false")
        case 0x6E: try self.parseLiteral("null")
        case 0x2D, 0x30...0x39: try self.parseNumber()
        default: throw self.invalid()
        }
    }

    private mutating func parseObject() throws -> Data {
        self.index += 1
        self.skipWhitespace()
        var entries = [(key: String, encodedKey: Data, value: Data)]()
        if self.consume(0x7D) {
            return Data("{}".utf8)
        }
        while true {
            self.skipWhitespace()
            let key = try self.parseString()
            self.skipWhitespace()
            guard self.consume(0x3A) else { throw self.invalid() }
            try entries.append((key.value, key.encoded, self.parseValue()))
            self.skipWhitespace()
            if self.consume(0x7D) {
                break
            }
            guard self.consume(0x2C) else { throw self.invalid() }
        }
        guard Set(entries.map(\.key)).count == entries.count else { throw self.invalid() }
        entries.sort {
            Array($0.key.utf16).lexicographicallyPrecedes(Array($1.key.utf16))
        }
        var output = Data("{".utf8)
        for (offset, entry) in entries.enumerated() {
            if offset > 0 {
                output.append(0x2C)
            }
            output.append(entry.encodedKey)
            output.append(0x3A)
            output.append(entry.value)
        }
        output.append(0x7D)
        return output
    }

    private mutating func parseArray() throws -> Data {
        self.index += 1
        self.skipWhitespace()
        var values = [Data]()
        if self.consume(0x5D) {
            return Data("[]".utf8)
        }
        while true {
            try values.append(self.parseValue())
            self.skipWhitespace()
            if self.consume(0x5D) {
                break
            }
            guard self.consume(0x2C) else { throw self.invalid() }
        }
        var output = Data("[".utf8)
        for (offset, value) in values.enumerated() {
            if offset > 0 {
                output.append(0x2C)
            }
            output.append(value)
        }
        output.append(0x5D)
        return output
    }

    private mutating func parseString() throws -> (value: String, encoded: Data) {
        let start = self.index
        guard self.consume(0x22) else { throw self.invalid() }
        var escaped = false
        while let byte = self.bytes[safe: self.index] {
            self.index += 1
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == 0x22 {
                let token = Data(self.bytes[start..<self.index])
                guard let value = try JSONSerialization.jsonObject(
                    with: token,
                    options: .fragmentsAllowed) as? String
                else { throw self.invalid() }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.withoutEscapingSlashes]
                return try (value, encoder.encode(value))
            } else if byte < 0x20 {
                throw self.invalid()
            }
        }
        throw self.invalid()
    }

    private mutating func parseNumber() throws -> Data {
        let start = self.index
        _ = self.consume(0x2D)
        guard let first = self.bytes[safe: self.index] else { throw self.invalid() }
        if first == 0x30 {
            self.index += 1
            if let next = self.bytes[safe: self.index], (0x30...0x39).contains(next) {
                throw self.invalid()
            }
        } else if (0x31...0x39).contains(first) {
            self.index += 1
            while let next = self.bytes[safe: self.index], (0x30...0x39).contains(next) {
                self.index += 1
            }
        } else {
            throw self.invalid()
        }
        if let suffix = self.bytes[safe: self.index], suffix == 0x2E || suffix == 0x65 || suffix == 0x45 {
            throw self.invalid()
        }
        let token = Data(self.bytes[start..<self.index])
        guard let text = String(data: token, encoding: .utf8),
              let number = Double(text), number.isFinite,
              !(number == 0 && number.sign == .minus)
        else { throw self.invalid() }
        guard let integer = Int64(text),
              integer >= -9_007_199_254_740_991,
              integer <= 9_007_199_254_740_991
        else { throw self.invalid() }
        return token
    }

    private mutating func parseLiteral(_ literal: String) throws -> Data {
        let literalBytes = Array(literal.utf8)
        guard self.bytes[self.index...].starts(with: literalBytes) else { throw self.invalid() }
        self.index += literalBytes.count
        return Data(literalBytes)
    }

    private mutating func skipWhitespace() {
        while let byte = self.bytes[safe: self.index], [0x20, 0x09, 0x0A, 0x0D].contains(byte) {
            self.index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard self.bytes[safe: self.index] == byte else { return false }
        self.index += 1
        return true
    }

    private func invalid() -> ProbeError {
        .invalidArguments("monitor evidence is not canonicalizable JSON")
    }
}

private func monitorAggregateSHA256(domain: String, jsonData: Data) throws -> String {
    var parser = RawCanonicalJSONParser(jsonData)
    var bytes = Data("peekaboo.multi-target-certification.\(domain).v2\0".utf8)
    try bytes.append(parser.parse())
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
}

private func monitorAggregateSHA256(domain: String, object: Any) throws -> String {
    try monitorAggregateSHA256(domain: domain, jsonData: canonicalJSONObjectData(object))
}

private final class MonitorPublicationLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var publishedHeartbeats = [WatchHeartbeat]()
    private var producerSets = [UInt64: AllowedEventProducerSet]()
    private var violations = [Violation]()
    private var contaminations = [ContaminationRecord]()
    private var evidenceSHA256: String?

    func record(_ heartbeat: WatchHeartbeat) {
        self.lock.withLock { self.publishedHeartbeats.append(heartbeat) }
    }

    func heartbeats() -> [WatchHeartbeat] {
        self.lock.withLock { self.publishedHeartbeats }
    }

    func recordProducerSet(_ producerSet: AllowedEventProducerSet) throws {
        try self.lock.withLock {
            if let prior = self.producerSets[producerSet.revision] {
                guard prior.hasExactlyEquivalentPayload(to: producerSet) else {
                    throw ProbeError.invalidArguments("monitor producer revision was replayed with different semantics")
                }
                return
            }
            self.producerSets[producerSet.revision] = producerSet
        }
    }

    func producerSet(revision: UInt64) -> AllowedEventProducerSet? {
        self.lock.withLock { self.producerSets[revision] }
    }

    func record(violation: Violation) {
        self.lock.withLock { self.violations.append(violation) }
    }

    func record(contamination: ContaminationRecord) {
        self.lock.withLock { self.contaminations.append(contamination) }
    }

    func evidenceRecords() -> (violations: [Violation], contaminations: [ContaminationRecord]) {
        self.lock.withLock { (self.violations, self.contaminations) }
    }

    func seal(digest: String) throws {
        try self.lock.withLock {
            guard self.evidenceSHA256 == nil else {
                throw ProbeError.invalidArguments("monitor evidence was already sealed")
            }
            self.evidenceSHA256 = digest
        }
    }

    func sealedDigest() -> String? {
        self.lock.withLock { self.evidenceSHA256 }
    }
}

private func unixSocketAddress(path: String) throws -> sockaddr_un {
    let bytes = Array(path.utf8) + [0]
    var address = sockaddr_un()
    let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
          offset + bytes.count <= Int(UInt8.max)
    else {
        throw ProbeError.invalidArguments("monitor attestation socket path is too long")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(offset + bytes.count)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

private func readSocketJSONLine(
    _ descriptor: Int32,
    maximumBytes: Int,
    timeoutMilliseconds: Int = 2000) throws -> Data
{
    var data = Data()
    var byte = UInt8.zero
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    while data.count < maximumBytes {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            throw ProbeError.invalidArguments("monitor attestation request exceeded its whole-message deadline")
        }
        let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
        var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&event, 1, Int32(clamping: remainingMilliseconds))
        if ready == 0 {
            throw ProbeError.invalidArguments("monitor attestation request exceeded its whole-message deadline")
        }
        if ready < 0 {
            if errno == EINTR {
                continue
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let count = Darwin.read(descriptor, &byte, 1)
        if count == 1 {
            if byte == 0x0A {
                return data
            }
            data.append(byte)
        } else if count < 0, errno == EINTR {
            continue
        } else if count == 0 {
            throw ProbeError.invalidArguments("monitor attestation request ended before its newline delimiter")
        } else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    throw ProbeError.invalidArguments("monitor attestation request exceeds its bound")
}

private func writeSocketJSON(_ value: some Encodable, descriptor: Int32) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw ProbeError.invalidArguments("monitor attestation response could not be written")
            }
        }
    }
}

private final class MonitorAttestationServer: @unchecked Sendable {
    private let socketPath: String
    private let executionNonce: String
    private let monitorInstanceID: String
    private let monitor: MonitorProcessReceipt
    private let ledger: MonitorPublicationLedger
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var activeClient: Int32 = -1

    init(
        socketPath: String,
        executionNonce: String,
        monitorInstanceID: String,
        monitor: MonitorProcessReceipt,
        ledger: MonitorPublicationLedger) throws
    {
        try requireOwnerPrivateParent(of: socketPath)
        var existing = stat()
        guard lstat(socketPath, &existing) != 0, errno == ENOENT else {
            throw ProbeError.invalidArguments("monitor attestation socket path already exists")
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            var address = try unixSocketAddress(path: socketPath)
            let length = socklen_t(address.sun_len)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard bound == 0,
                  chmod(socketPath, S_IRUSR | S_IWUSR) == 0,
                  listen(descriptor, 8) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            close(descriptor)
            unlink(socketPath)
            throw error
        }
        self.socketPath = socketPath
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.monitor = monitor
        self.ledger = ledger
        self.listener = descriptor
    }

    func start() {
        DispatchQueue(label: "boo.peekaboo.certification.monitor-attestation").async { self.serve() }
    }

    func stop() {
        let descriptor = self.lock.withLock { () -> Int32 in
            let current = self.listener
            self.listener = -1
            if self.activeClient >= 0 {
                shutdown(self.activeClient, SHUT_RDWR)
            }
            return current
        }
        if descriptor >= 0 {
            close(descriptor)
            unlink(self.socketPath)
        }
    }

    func hasActiveClient() -> Bool {
        self.lock.withLock { self.activeClient >= 0 }
    }

    private func serve() {
        while true {
            let client = self.lock.withLock { () -> Int32 in
                guard self.listener >= 0 else { return -2 }
                return accept(self.listener, nil, nil)
            }
            if client == -2 {
                return
            }
            if client >= 0 {
                self.lock.withLock { self.activeClient = client }
                do {
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    var noSignal: Int32 = 1
                    let size = socklen_t(MemoryLayout<timeval>.size)
                    guard setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
                          setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0,
                          setsockopt(
                              client,
                              SOL_SOCKET,
                              SO_NOSIGPIPE,
                              &noSignal,
                              socklen_t(MemoryLayout<Int32>.size)) == 0
                    else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    try self.handle(client)
                } catch {
                    // A malformed, early, cross-user, or stalled challenge is refused by closing it.
                }
                self.lock.withLock {
                    if self.activeClient == client {
                        self.activeClient = -1
                        close(client)
                    }
                }
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                return
            }
            usleep(10000)
        }
    }

    private func handle(_ descriptor: Int32) throws {
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0, peerUID == geteuid(),
              let digest = self.ledger.sealedDigest()
        else {
            throw ProbeError.invalidArguments("monitor attestation peer or sealed corpus is unavailable")
        }
        let data = try readSocketJSONLine(descriptor, maximumBytes: 64 * 1024)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["version", "execution_nonce", "monitor_instance_id", "challenge"]
        else {
            throw ProbeError.invalidArguments("monitor attestation request keys are not closed")
        }
        let request = try JSONDecoder().decode(MonitorAttestationRequest.self, from: data)
        guard request.version == 1,
              request.executionNonce == self.executionNonce,
              request.monitorInstanceID == self.monitorInstanceID,
              isLowerHex(request.challenge, count: 64)
        else {
            throw ProbeError.invalidArguments("monitor attestation request is not run bound")
        }
        try writeSocketJSON(
            MonitorAttestationResponse(
                version: 1,
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                challenge: request.challenge,
                monitor: self.monitor,
                monitorEvidenceSHA256: digest),
            descriptor: descriptor)
    }
}

private struct MonitorSealConfiguration {
    let executionNonce: String
    let monitorInstanceID: String
    let requestPath: String
    let sealedEvidencePath: String
    let attestationEvidencePath: String
    let receiptPath: String
    let attestationSocketPath: String
    let heartbeatPath: String
    let violationsPath: String
    let contaminationPath: String
    let baseline: SystemSample
    let initialCommitmentSHA256: String
    let monitor: MonitorProcessReceipt
}

private func writeOwnerPrivateData(_ data: Data, to path: String) throws {
    try requireOwnerPrivateParent(of: path)
    let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { close(descriptor) }
    try data.withUnsafeBytes { bytes in
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
    guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func sameJSONObject(_ lhs: Any, _ rhs: Any) -> Bool {
    (try? canonicalJSONObjectData(lhs)) == (try? canonicalJSONObjectData(rhs))
}

private func monitorSampleProjection(_ sample: SystemSample) -> [String: Any] {
    [
        "frontmost_pid": sample.frontmostPID.map(NSNumber.init(value:)) ?? NSNull(),
        "frontmost_window_id": sample.frontmostWindowID.map(NSNumber.init(value:)) ?? NSNull(),
        "clipboard_change_count": sample.clipboardChangeCount,
        "clipboard_digest": sample.clipboardDigest,
    ]
}

private func decodeHeartbeat(_ object: Any) throws -> WatchHeartbeat {
    guard let dictionary = object as? [String: Any], Set(dictionary.keys) == [
        "sequence", "monotonicMicroseconds", "wallClockMilliseconds", "lastCleanSequence", "contaminationRetries",
        "contaminationBlocked", "inputAttributionAvailable", "allowedProducerRevision",
        "phase", "cursorMovementObserved", "pendingActivationCount",
        "pendingFocusedWindowChange", "authorizationEpoch", "transitionAcknowledged",
        "foregroundActive", "foregroundTargetPID", "foregroundTargetWindowID",
        "attributedForegroundEventCount", "attributedForegroundSourcePIDs",
        "foregroundActivityObserved", "executionNonce", "monitorInstanceID",
        "historyCommitmentSHA256",
    ] else {
        throw ProbeError.invalidArguments("sealed monitor heartbeat keys are not closed")
    }
    let data = try JSONSerialization.data(withJSONObject: dictionary)
    let heartbeat = try JSONDecoder().decode(WatchHeartbeat.self, from: data)
    guard heartbeat.monotonicMicroseconds > 0,
          heartbeat.monotonicMicroseconds <= 9_007_199_254_740_991,
          heartbeat.wallClockMilliseconds > 0,
          heartbeat.wallClockMilliseconds <= 9_007_199_254_740_991
    else {
        throw ProbeError.invalidArguments("monitor heartbeat clocks are outside the exact safe-integer domain")
    }
    return heartbeat
}

private func monitorClockStepIsConsistent(
    previous: WatchHeartbeat,
    current: WatchHeartbeat,
    toleranceMicroseconds: UInt64 = 2_000_000) -> Bool
{
    guard previous.monotonicMicroseconds <= 9_007_199_254_740_991,
          current.monotonicMicroseconds <= 9_007_199_254_740_991,
          previous.wallClockMilliseconds > 0,
          current.wallClockMilliseconds > 0,
          previous.wallClockMilliseconds <= 9_007_199_254_740_991,
          current.wallClockMilliseconds <= 9_007_199_254_740_991,
          current.monotonicMicroseconds > previous.monotonicMicroseconds,
          current.wallClockMilliseconds >= previous.wallClockMilliseconds
    else { return false }
    let monotonicDelta = current.monotonicMicroseconds - previous.monotonicMicroseconds
    let (wallDelta, subtractionOverflow) = current.wallClockMilliseconds.subtractingReportingOverflow(
        previous.wallClockMilliseconds)
    guard !subtractionOverflow, wallDelta >= 0 else { return false }
    let (wallMicroseconds, multiplicationOverflow) = wallDelta.multipliedReportingOverflow(by: 1000)
    guard !multiplicationOverflow else { return false }
    let wallMagnitude = UInt64(wallMicroseconds)
    let difference = wallMagnitude >= monotonicDelta
        ? wallMagnitude - monotonicDelta
        : monotonicDelta - wallMagnitude
    return difference <= toleranceMicroseconds
}

private func sealMonitorEvidenceIfRequested(
    configuration: MonitorSealConfiguration,
    ledger: MonitorPublicationLedger,
    prepareForSeal: () throws -> Void = {},
    finalSampleProvider: () throws -> SystemSample = { try sample(includeClipboardDigest: true) }) throws -> Bool
{
    if ledger.sealedDigest() != nil {
        return true
    }
    var requestInfo = stat()
    guard lstat(configuration.requestPath, &requestInfo) == 0 else {
        if errno == ENOENT {
            return false
        }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    let requestData = try readOwnerPrivateFile(configuration.requestPath, maximumBytes: 64 * 1024)
    let requestObject = try JSONSerialization.jsonObject(with: requestData)
    guard let requestDictionary = requestObject as? [String: Any],
          Set(requestDictionary.keys) == [
              "version", "execution_nonce", "monitor_instance_id", "phase", "draft_path",
              "sealed_path", "history_commitment_sha256",
          ]
    else {
        throw ProbeError.invalidArguments("monitor seal request keys are not closed")
    }
    let request = try JSONDecoder().decode(MonitorSealRequest.self, from: requestData)
    guard request.version == 1,
          request.executionNonce == configuration.executionNonce,
          request.monitorInstanceID == configuration.monitorInstanceID,
          request.phase == "seal",
          request.sealedPath == configuration.sealedEvidencePath,
          configuration.attestationEvidencePath == configuration.sealedEvidencePath,
          isLowerHex(request.historyCommitmentSHA256, count: 64),
          URL(fileURLWithPath: request.draftPath).deletingLastPathComponent().standardizedFileURL.path ==
          URL(fileURLWithPath: configuration.sealedEvidencePath)
          .deletingLastPathComponent().standardizedFileURL.path,
          request.draftPath != configuration.sealedEvidencePath
    else {
        throw ProbeError.invalidArguments("monitor seal request is not bound to this run and output")
    }

    let draftData = try readOwnerPrivateFile(request.draftPath)
    let draftObject = try JSONSerialization.jsonObject(with: draftData)
    let evidenceKeys: Set = [
        "version", "execution_nonce", "monitor_instance_id", "monitor_source_sha256",
        "coordinator_source_sha256", "monitor_process", "monitor_attestation_socket_path", "sentinel",
        "foreground_controller", "foreground_target", "producer_sets", "fences",
        "baseline_sample", "final_sample", "foreground_plan", "violation_records",
        "contamination_records", "baseline_commitment_sha256", "history_commitment_sha256",
        "crash_evidence", "restoration",
    ]
    guard let evidence = draftObject as? [String: Any],
          Set(evidence.keys) == evidenceKeys,
          (evidence["version"] as? NSNumber)?.intValue == 1,
          evidence["execution_nonce"] as? String == configuration.executionNonce,
          evidence["monitor_instance_id"] as? String == configuration.monitorInstanceID,
          evidence["monitor_attestation_socket_path"] as? String == configuration.attestationSocketPath,
          evidence["baseline_commitment_sha256"] as? String == configuration.initialCommitmentSHA256,
          evidence["history_commitment_sha256"] as? String == request.historyCommitmentSHA256,
          let monitorProcess = evidence["monitor_process"] as? [String: Any],
          (monitorProcess["pid"] as? NSNumber)?.int32Value == configuration.monitor.pid,
          monitorProcess["start_identity"] as? String == configuration.monitor.startIdentity,
          monitorProcess["code_signature_hash"] as? String == configuration.monitor.codeSignatureHash,
          let baselineSample = evidence["baseline_sample"],
          sameJSONObject(baselineSample, monitorSampleProjection(configuration.baseline)),
          let violationRecords = evidence["violation_records"] as? [[String: Any]],
          violationRecords.allSatisfy({ Set($0.keys) == ["kind", "expected", "actual"] }),
          let contaminationRecords = evidence["contamination_records"] as? [[String: Any]],
          contaminationRecords.allSatisfy({
              Set($0.keys) == ["state", "retry", "sequence", "sourcePIDs", "eventTypes"]
          }),
          let producerSets = evidence["producer_sets"] as? [String: Any],
          Set(producerSets.keys) == ["baseline", "grant", "revoke"],
          let fenceRows = evidence["fences"] as? [[String: Any]]
    else {
        throw ProbeError.invalidArguments("monitor evidence draft is not the exact clean run-bound corpus")
    }
    let draftViolations = try JSONDecoder().decode(
        [Violation].self,
        from: JSONSerialization.data(withJSONObject: violationRecords))
    let draftContaminations = try JSONDecoder().decode(
        [ContaminationRecord].self,
        from: JSONSerialization.data(withJSONObject: contaminationRecords))
    try prepareForSeal()
    let recordedEvidence = ledger.evidenceRecords()
    guard draftViolations == recordedEvidence.violations,
          draftContaminations == recordedEvidence.contaminations,
          draftViolations.isEmpty,
          draftContaminations.isEmpty
    else {
        throw ProbeError.invalidArguments("sealed cleanliness differs from the monitor-owned in-memory evidence")
    }
    for (label, revision) in [("baseline", UInt64(1)), ("grant", UInt64(2)), ("revoke", UInt64(3))] {
        guard let producerSetObject = producerSets[label],
              JSONSerialization.isValidJSONObject(producerSetObject)
        else { throw ProbeError.invalidArguments("monitor producer set is not JSON") }
        let producerSet = try decodeAllowedProducerSet(
            JSONSerialization.data(withJSONObject: producerSetObject),
            executionNonce: configuration.executionNonce,
            monitorInstanceID: configuration.monitorInstanceID)
        guard producerSet.revision == revision,
              ledger.producerSet(revision: revision)?.hasExactlyEquivalentPayload(to: producerSet) == true
        else {
            throw ProbeError.invalidArguments("sealed producer set differs from monitor authorization history")
        }
    }
    let currentFinalSample = try finalSampleProvider()
    guard let finalSample = evidence["final_sample"],
          sameJSONObject(finalSample, monitorSampleProjection(currentFinalSample))
    else {
        throw ProbeError.invalidArguments("monitor evidence final sample differs from the live desktop")
    }

    let names = [
        "baseline-stable", "grant-stable", "operations-start",
        "operations-complete", "revoke-stable", "final-stable",
    ]
    guard fenceRows.count == names.count else {
        throw ProbeError.invalidArguments("monitor evidence draft does not contain the six required fences")
    }
    let published = ledger.heartbeats()
    var sealedHeartbeats = [WatchHeartbeat]()
    for (index, row) in fenceRows.enumerated() {
        guard Set(row.keys) == ["name", "heartbeat"], row["name"] as? String == names[index],
              let heartbeatObject = row["heartbeat"]
        else {
            throw ProbeError.invalidArguments("monitor evidence fences are not closed and ordered")
        }
        let heartbeat = try decodeHeartbeat(heartbeatObject)
        let emittedCandidate = index == names.indices.last
            ? heartbeat.withHistoryCommitmentSHA256(configuration.initialCommitmentSHA256)
            : heartbeat
        guard heartbeat.executionNonce == configuration.executionNonce,
              heartbeat.monitorInstanceID == configuration.monitorInstanceID,
              published.contains(emittedCandidate),
              index == names.indices.last
              ? heartbeat.historyCommitmentSHA256 == request.historyCommitmentSHA256
              : heartbeat.historyCommitmentSHA256 == configuration.initialCommitmentSHA256
        else {
            throw ProbeError.invalidArguments("monitor evidence fence was not emitted by this live monitor")
        }
        sealedHeartbeats.append(heartbeat)
    }
    guard sealedHeartbeats.enumerated().dropFirst().allSatisfy({ index, heartbeat in
        let previous = sealedHeartbeats[index - 1]
        return heartbeat.sequence > previous.sequence &&
            monitorClockStepIsConsistent(previous: previous, current: heartbeat) &&
            heartbeat.authorizationEpoch > previous.authorizationEpoch
    }) else {
        throw ProbeError.invalidArguments(
            "monitor fence sequence, integer clocks, and authorization epochs must increase without a clock jump")
    }

    let digest = try monitorAggregateSHA256(domain: "monitor-evidence", jsonData: draftData)
    try writeOwnerPrivateData(draftData, to: configuration.sealedEvidencePath)
    let finalHeartbeat = sealedHeartbeats[sealedHeartbeats.index(before: sealedHeartbeats.endIndex)]
    try writeJSON(finalHeartbeat, to: configuration.heartbeatPath)
    ledger.record(finalHeartbeat)
    try writeOwnerPrivateJSON(
        MonitorSealReceipt(
            version: 1,
            executionNonce: configuration.executionNonce,
            monitorInstanceID: configuration.monitorInstanceID,
            phase: "sealed",
            monitorEvidenceSHA256: digest),
        to: configuration.receiptPath)
    try ledger.seal(digest: digest)
    return true
}

private func appendJSONLine(_ value: some Encodable, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value) + Data("\n".utf8)
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(
            atPath: path,
            contents: nil,
            attributes: [.posixPermissions: 0o600])
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private func argument(_ name: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

private func readHexCommitment(path: String) throws -> String {
    guard let contents = try String(data: readStableOwnerPrivateFile(path, maximumBytes: 1024), encoding: .utf8)
    else { throw ProbeError.invalidArguments("monitor commitment is not UTF-8") }
    let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    guard isLowerHex(value, count: 64) else {
        throw ProbeError.invalidArguments("monitor commitment must contain one lowercase SHA-256")
    }
    return value
}

private func runWatch(arguments: [String]) throws -> Never {
    guard let baselinePath = argument("--baseline", in: arguments),
          let outputPath = argument("--output", in: arguments),
          let contaminationOutputPath = argument("--contamination-output", in: arguments),
          let readyPath = argument("--ready", in: arguments),
          let heartbeatPath = argument("--heartbeat", in: arguments),
          let phasePath = argument("--phase", in: arguments),
          let allowedProducersPath = argument("--allowed-producers", in: arguments),
          let invariantNamesJSON = argument("--invariant-names", in: arguments),
          let executionNonce = argument("--execution-nonce", in: arguments),
          let monitorInstanceID = argument("--monitor-instance-id", in: arguments),
          let historyCommitmentPath = argument("--history-commitment", in: arguments),
          isLowerHex(executionNonce, count: 64),
          isCanonicalV4UUID(monitorInstanceID)
    else {
        throw ProbeError.invalidArguments(
            "watch requires baseline/output paths, run identity, phase, producers, heartbeat, and commitments")
    }

    let intervalMilliseconds = Int(argument("--interval-ms", in: arguments) ?? "20") ?? 20
    guard intervalMilliseconds > 0 else {
        throw ProbeError.invalidArguments("watch interval must be valid")
    }
    let allowClipboardMutation = arguments.contains("--allow-clipboard-mutation")
    let physicalInputObservational = arguments.contains("--physical-input-observational")
    let cursorObservational = arguments.contains("--cursor-observational")
    let invariantProjection = try InvariantProjection(json: invariantNamesJSON)
    let baselineData = try readStableOwnerPrivateFile(baselinePath)
    let baseline = try JSONDecoder().decode(SystemSample.self, from: baselineData)
    guard let baselinePID = baseline.frontmostPID,
          let baselineWindowID = baseline.frontmostWindowID,
          let baselineStartIdentity = processStartIdentity(pid: baselinePID).map(String.init)
    else {
        throw ProbeError.focusedWindowObserverUnavailable
    }
    let initialProducerData = try readStableOwnerPrivateFile(allowedProducersPath)
    let initialProducerSet = try decodeAllowedProducerSet(
        initialProducerData,
        executionNonce: executionNonce,
        monitorInstanceID: monitorInstanceID)
    let initialAuthorization = try makeMonitorAuthorization(initialProducerSet)
    let historyCommitmentSHA256 = try readHexCommitment(path: historyCommitmentPath)
    FileManager.default.createFile(
        atPath: outputPath,
        contents: nil,
        attributes: [.posixPermissions: 0o600])
    FileManager.default.createFile(
        atPath: contaminationOutputPath,
        contents: nil,
        attributes: [.posixPermissions: 0o600])

    let ledger = MonitorPublicationLedger()
    try ledger.recordProducerSet(initialProducerSet)
    let attestationArguments = [
        argument("--attestation-socket", in: arguments),
        argument("--attestation-evidence", in: arguments),
        argument("--seal-request", in: arguments),
        argument("--sealed-evidence", in: arguments),
        argument("--seal-receipt", in: arguments),
    ]
    let usesLiveSeal = attestationArguments.contains(where: { $0 != nil })
    guard !usesLiveSeal || attestationArguments.allSatisfy({ $0 != nil }) else {
        throw ProbeError.invalidArguments("live monitor attestation and seal paths must be supplied together")
    }
    let monitorReceipt = usesLiveSeal ? try currentMonitorProcessReceipt() : nil
    let attestationServer: MonitorAttestationServer? = if usesLiveSeal {
        try MonitorAttestationServer(
            socketPath: attestationArguments[0]!,
            executionNonce: executionNonce,
            monitorInstanceID: monitorInstanceID,
            monitor: monitorReceipt!,
            ledger: ledger)
    } else {
        nil
    }
    attestationServer?.start()
    defer { attestationServer?.stop() }
    let sealConfiguration: MonitorSealConfiguration? = if usesLiveSeal {
        MonitorSealConfiguration(
            executionNonce: executionNonce,
            monitorInstanceID: monitorInstanceID,
            requestPath: attestationArguments[2]!,
            sealedEvidencePath: attestationArguments[3]!,
            attestationEvidencePath: attestationArguments[1]!,
            receiptPath: attestationArguments[4]!,
            attestationSocketPath: attestationArguments[0]!,
            heartbeatPath: heartbeatPath,
            violationsPath: outputPath,
            contaminationPath: contaminationOutputPath,
            baseline: baseline,
            initialCommitmentSHA256: historyCommitmentSHA256,
            monitor: monitorReceipt!)
    } else {
        nil
    }

    let machine = MonitorEpochMachine(initialAuthorization: initialAuthorization)
    let inputTracker = InputEventTracker(machine: machine)
    try inputTracker.start()
    let activationTracker = ActivationTracker(machine: machine)
    activationTracker.start()
    let focusObservers = FocusObserverCoordinator { identity in
        FocusedWindowTracker(identity: identity, machine: machine)
    }
    try focusObservers.startBaseline(ProcessGenerationIdentity(
        pid: baselinePID,
        startIdentity: baselineStartIdentity))
    try focusObservers.prepare(target: initialAuthorization.target)
    var monitoringQuiesced = false
    defer {
        if !monitoringQuiesced {
            try? focusObservers.stop()
            activationTracker.stop()
            inputTracker.stop()
        }
    }

    var watchState = WatchState(
        baseline: baseline,
        interactiveBaseline: InteractiveBaseline(
            frontmostPID: baselinePID,
            processStartIdentity: baselineStartIdentity,
            frontmostWindowID: baselineWindowID,
            cursor: baseline.cursor),
        executionNonce: executionNonce,
        monitorInstanceID: monitorInstanceID,
        historyCommitmentSHA256: historyCommitmentSHA256,
        allowClipboardMutation: allowClipboardMutation,
        physicalInputObservational: physicalInputObservational,
        cursorObservational: cursorObservational,
        projection: invariantProjection,
        outputPath: outputPath,
        contaminationOutputPath: contaminationOutputPath,
        evidenceLedger: ledger)
    var firstSample = true
    var acknowledgementGate = MonitorAcknowledgementGate()
    func publishHeartbeat(_ heartbeat: WatchHeartbeat) throws {
        try writeJSON(heartbeat, to: heartbeatPath)
        ledger.record(heartbeat)
    }
    while true {
        CFRunLoopRunInMode(
            .defaultMode,
            Double(intervalMilliseconds) / 1000,
            false)
        if ledger.sealedDigest() != nil {
            continue
        }
        let producerData = try readStableOwnerPrivateFile(allowedProducersPath)
        let allowedProducerSet = try decodeAllowedProducerSet(
            producerData,
            executionNonce: executionNonce,
            monitorInstanceID: monitorInstanceID)
        watchState.historyCommitmentSHA256 = try readHexCommitment(path: historyCommitmentPath)
        let publishingHigherRevision = allowedProducerSet.revision > machine.currentAuthorization.revision
        let requiresIdleBarrier = monitorRequiresIdleBarrier(
            pendingAcknowledgementRevision: acknowledgementGate.pendingRevision,
            currentRevision: machine.currentAuthorization.revision,
            proposedRevision: allowedProducerSet.revision)
        let reachedIdleBarrier = !requiresIdleBarrier ||
            runLoopReachesIdle(timeout: max(Double(intervalMilliseconds) / 1000, 0.1))
        if reachedIdleBarrier {
            try acknowledgementGate.completeCallbackBarrier(machine: machine)
        }
        if !publishingHigherRevision || reachedIdleBarrier {
            applyMonitorAuthorization(allowedProducerSet, to: machine, observers: focusObservers)
            if machine.currentAuthorization.source == allowedProducerSet {
                try ledger.recordProducerSet(allowedProducerSet)
            }
        }
        let current = try sample(includeClipboardDigest: false)
        guard runLoopReachesIdle(timeout: max(Double(intervalMilliseconds) / 1000, 0.1)),
              let closure = machine.closeForHeartbeat()
        else {
            continue
        }
        guard let phaseContents = try String(
            data: readStableOwnerPrivateFile(phasePath, maximumBytes: 1024),
            encoding: .utf8)
        else { throw ProbeError.invalidArguments("watch phase must be UTF-8") }
        let phase = phaseContents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["setup", "running", "complete"].contains(phase) else {
            throw ProbeError.invalidArguments("watch phase must be setup, running, or complete")
        }
        let heartbeat = try watchState.observe(
            current: current,
            phase: phase,
            closure: closure)
        acknowledgementGate.record(closure)
        var publishedHeartbeat = false
        if let revision = acknowledgementGate.pendingRevision {
            if heartbeat.contaminationBlocked || !heartbeat.inputAttributionAvailable {
                try publishHeartbeat(heartbeat.withTransitionAcknowledged(false))
                publishedHeartbeat = true
            } else if acknowledgementGate.readyRevision == revision {
                let preparedHeartbeat = try PreparedJSONPublication(
                    heartbeat.withTransitionAcknowledged(true),
                    destinationPath: heartbeatPath)
                if runLoopReachesIdle(timeout: max(Double(intervalMilliseconds) / 1000, 0.1)) {
                    do {
                        let result = try publishMonitorTransitionAcknowledgement(
                            revision: revision,
                            machine: machine,
                            observers: focusObservers,
                            publish: { try preparedHeartbeat.commit() })
                        switch result {
                        case .published:
                            acknowledgementGate.didPublish(revision: revision)
                            ledger.record(heartbeat.withTransitionAcknowledged(true))
                            publishedHeartbeat = true
                        case .rejected(reason: "blocked_producer_ack_evidence_pending"):
                            try publishHeartbeat(heartbeat.withTransitionAcknowledged(false))
                            publishedHeartbeat = true
                        case .idempotent, .rejected:
                            throw ProbeError.invalidArguments("blocked_producer_ack_publication")
                        }
                    } catch let error as MonitorAcknowledgementPreparationError {
                        recordMonitorAcknowledgementPreparationFailure(error, machine: machine)
                        try publishHeartbeat(heartbeat.withTransitionAcknowledged(false))
                        publishedHeartbeat = true
                    }
                } else {
                    try publishHeartbeat(heartbeat.withTransitionAcknowledged(false))
                    publishedHeartbeat = true
                }
            } else {
                try publishHeartbeat(heartbeat.withTransitionAcknowledged(false))
                publishedHeartbeat = true
            }
        } else {
            try publishHeartbeat(heartbeat.withTransitionAcknowledged(false))
            publishedHeartbeat = true
        }
        if firstSample, publishedHeartbeat {
            try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
            firstSample = false
        }
        if let sealConfiguration {
            let sealed = try sealMonitorEvidenceIfRequested(
                configuration: sealConfiguration,
                ledger: ledger,
                prepareForSeal: {
                    guard !monitoringQuiesced else { return }
                    guard acknowledgementGate.pendingRevision == nil,
                          machine.beginSealCutoff()
                    else {
                        throw ProbeError.invalidArguments(
                            "monitor terminal seal cutoff requires a fully acknowledged stable epoch")
                    }
                    inputTracker.stop()
                    activationTracker.stop()
                    try focusObservers.stop()
                    let timeout = max(Double(intervalMilliseconds) / 1000, 0.1)
                    let cutoffDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
                    while true {
                        guard runLoopReachesIdle(timeout: timeout) else {
                            throw ProbeError.invalidArguments(
                                "monitor could not drain its run loop at the terminal seal cutoff")
                        }
                        if let cutoffClosure = machine.closeForHeartbeat() {
                            _ = try watchState.observe(
                                current: sample(includeClipboardDigest: true),
                                phase: "complete",
                                closure: cutoffClosure)
                        }
                        if machine.finishSealCutoff() {
                            break
                        }
                        guard DispatchTime.now().uptimeNanoseconds < cutoffDeadline else {
                            throw ProbeError.invalidArguments(
                                "monitor retained a pre-cutoff callback past its terminal drain deadline")
                        }
                    }
                    monitoringQuiesced = true
                })
            guard !sealed || monitoringQuiesced else {
                throw ProbeError.invalidArguments("monitor sealed evidence before establishing its callback cutoff")
            }
        }
    }
}

private func producerReceiptSchemaIsLossless() -> Bool {
    let data = Data(
        #"{"revision":1,"executionNonce":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","monitorInstanceID":"00000000-0000-4000-8000-000000000001","producers":[{"pid":42,"startIdentity":"987654321","role":"bridge"}],"foreground":{"active":false,"target":null}}"#
            .utf8)
    guard let decoded = try? decodeAllowedProducerSet(
        data,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID)
    else { return false }
    return decoded.revision == 1 &&
        decoded.executionNonce == selfTestExecutionNonce &&
        decoded.monitorInstanceID == selfTestMonitorInstanceID &&
        decoded.producers.first?.pid == 42 &&
        decoded.producers.first?.startIdentity == "987654321" &&
        decoded.producers.first?.effectiveRole == .bridge &&
        decoded.effectiveForeground == AllowedForegroundActivity(active: false, target: nil)
}

private func foregroundAuthorizationSchemaIsStrict() -> Bool {
    let data = Data(
        #"""
        {
          "revision": 2,
          "executionNonce": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "monitorInstanceID": "00000000-0000-4000-8000-000000000001",
          "producers": [
            {"pid": 20, "startIdentity": "2000", "role": "bridge"},
            {"pid": 30, "startIdentity": "3000", "role": "foreground-controller"}
          ],
          "foreground": {
            "active": true,
            "target": {"pid": 40, "startIdentity": "4000", "windowID": 401}
          }
        }
        """#
            .utf8)
    guard let decoded = try? decodeAllowedProducerSet(
        data,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID),
        let authorization = try? makeMonitorAuthorization(
            decoded,
            processIdentity: { [20: 2000, 30: 3000][$0] },
            targetValidator: { $0.pid == 40 && $0.startIdentity == "4000" && $0.windowID == 401 }),
        authorization.target?.windowID == 401
    else {
        return false
    }
    let invalidInactive = testProducerSet(
        revision: 3,
        producers: [testProducer(20, "2000"), testProducer(30, "3000", role: .foregroundController)],
        foreground: AllowedForegroundActivity(active: false, target: nil))
    let invalidTarget = testProducerSet(
        revision: 3,
        producers: [testProducer(20, "2000"), testProducer(30, "3000", role: .foregroundController)],
        foreground: AllowedForegroundActivity(
            active: true,
            target: AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)))
    return (try? makeMonitorAuthorization(
        invalidInactive,
        processIdentity: { [20: 2000, 30: 3000][$0] },
        targetValidator: { _ in true })) == nil &&
        (try? makeMonitorAuthorization(
            invalidTarget,
            processIdentity: { [20: 2000, 30: 3000][$0] },
            targetValidator: { _ in false })) == nil
}

private func testProducer(
    _ pid: Int32,
    _ startIdentity: String,
    role: AllowedEventProducerRole? = nil) -> AllowedEventProducer
{
    AllowedEventProducer(pid: pid, startIdentity: startIdentity, role: role)
}

private func testProducerSet(
    revision: UInt64,
    producers: [AllowedEventProducer],
    foreground: AllowedForegroundActivity? = nil) -> AllowedEventProducerSet
{
    AllowedEventProducerSet(revision: revision, producers: producers, foreground: foreground)
}

private func testAuthorization(_ producerSet: AllowedEventProducerSet) -> MonitorAuthorization {
    MonitorAuthorization(
        source: producerSet,
        producersByPID: Dictionary(uniqueKeysWithValues: producerSet.producers.map { ($0.pid, $0) }),
        foreground: producerSet.effectiveForeground)
}

private func testEvidence(_ pid: Int32, _ startIdentity: String?, _ windowID: UInt32?) -> ProcessWindowEvidence {
    ProcessWindowEvidence(pid: pid, startIdentity: startIdentity, windowID: windowID)
}

private func acknowledgeForTesting(_ machine: MonitorEpochMachine, revision: UInt64) -> Bool {
    machine.markAcknowledgementReady(revision: revision) == .published &&
        machine.acknowledge(revision: revision) == .published
}

private func selfTestDesktop() -> (sample: SystemSample, baseline: InteractiveBaseline) {
    let sample = SystemSample(
        timestamp: 1,
        frontmostPID: 10,
        frontmostBundleIdentifier: "com.apple.calculator",
        frontmostWindowID: 100,
        cursor: Point(x: 50, y: 60),
        clipboardChangeCount: 3,
        clipboardDigest: "digest",
        peekabooWindowIDs: [301],
        visibleScreenFramesTopLeft: [Rectangle(x: 0, y: 0, width: 800, height: 600)])
    return (
        sample,
        InteractiveBaseline(
            frontmostPID: 10,
            processStartIdentity: "1000",
            frontmostWindowID: 100,
            cursor: sample.cursor))
}

private final class MonitorClosureCapture: Sendable {
    private let closures = Mutex<[MonitorEpochClosure]>([])

    func append(_ closure: MonitorEpochClosure) {
        self.closures.withLock { $0.append(closure) }
    }

    func load() -> [MonitorEpochClosure] {
        self.closures.withLock { $0 }
    }
}

private struct MonitorAdmissionLatencyResult: Sendable {
    let publication: MonitorPublicationResult
    let heartbeatDeferred: Bool
}

private final class MonitorAdmissionLatencyCapture: Sendable {
    private let result = Mutex<MonitorAdmissionLatencyResult?>(nil)

    func store(_ value: MonitorAdmissionLatencyResult) {
        self.result.withLock { $0 = value }
    }

    func load() -> MonitorAdmissionLatencyResult? {
        self.result.withLock { $0 }
    }
}

private func suspendedSamplingDoesNotHoldPublicationLock() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    let samplingStarted = DispatchSemaphore(value: 0)
    let releaseSampling = DispatchSemaphore(value: 0)
    let samplingFinished = DispatchSemaphore(value: 0)
    let publicationFinished = DispatchSemaphore(value: 0)
    let capture = MonitorAdmissionLatencyCapture()

    DispatchQueue.global(qos: .userInitiated).async {
        machine.admitForTesting {
            samplingStarted.signal()
            releaseSampling.wait()
            return .activation(testEvidence(10, "1000", 100))
        }
        samplingFinished.signal()
    }
    guard samplingStarted.wait(timeout: .now() + .seconds(1)) == .success else { return false }

    DispatchQueue.global(qos: .userInitiated).async {
        let publication = machine.publish(second)
        let heartbeatDeferred = machine.closeForHeartbeat() == nil
        capture.store(MonitorAdmissionLatencyResult(
            publication: publication,
            heartbeatDeferred: heartbeatDeferred))
        publicationFinished.signal()
    }
    let completedBeforeRelease = publicationFinished.wait(timeout: .now() + .seconds(1)) == .success
    releaseSampling.signal()
    guard samplingFinished.wait(timeout: .now() + .seconds(1)) == .success else { return false }
    if !completedBeforeRelease {
        _ = publicationFinished.wait(timeout: .now() + .seconds(1))
        return false
    }
    guard let result = capture.load(),
          result.publication == .published,
          result.heartbeatDeferred,
          let closure = machine.closeForHeartbeat()
    else {
        return false
    }
    let events = closure.epochs.flatMap(\.events)
    return events.count == 1 && events[0].epoch.authorization.revision == 1 &&
        closure.epochs.contains(where: { $0.epoch.authorization.revision == 2 })
}

private func reservedAdmissionsCloseOnlyAfterCompletion() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    let canceledOld = machine.reserveForTesting()
    let completedOld = machine.reserveForTesting()
    guard machine.publish(second) == .published else { return false }
    let completedNew = machine.reserveForTesting()
    guard machine.closeForHeartbeat() == nil else { return false }

    guard machine.completeForTesting(
        completedOld,
        with: .activation(testEvidence(10, "1000", 100))),
        machine.completeForTesting(
            completedNew,
            with: .activation(testEvidence(40, "4000", 401))),
        machine.closeForHeartbeat() == nil,
        machine.cancelForTesting(canceledOld, reason: "blocked_evidence_sampling"),
        !machine.completeForTesting(
            completedOld,
            with: .activation(testEvidence(99, "9900", 991))),
        let closure = machine.closeForHeartbeat()
    else {
        return false
    }
    let events = closure.epochs.flatMap(\.events)
    guard events.map(\.admission) == [1, 2, 3],
          events.map(\.epoch.authorization.revision) == [1, 1, 2],
          closure.transitionAcknowledged
    else {
        return false
    }
    if case .attributionFailure(reason: "blocked_evidence_sampling", process: nil) = events[0].kind {
        return true
    }
    return false
}

private func recordPublishDrainIsLinearizable() -> Bool {
    let bridge = testProducer(20, "2000")
    let first = testAuthorization(testProducerSet(revision: 1, producers: [bridge]))
    let second = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))
    for _ in 0..<100 {
        let machine = MonitorEpochMachine(initialAuthorization: first)
        let capture = MonitorClosureCapture()
        DispatchQueue.concurrentPerform(iterations: 3) { index in
            switch index {
            case 0:
                machine.admitForTesting(.activation(testEvidence(10, "1000", 100)))
            case 1:
                _ = machine.publish(second)
            default:
                if let closure = machine.closeForHeartbeat() {
                    capture.append(closure)
                }
            }
        }
        if let closure = machine.closeForHeartbeat() {
            capture.append(closure)
        }
        let epochs = capture.load().flatMap(\.epochs)
        let events = epochs.flatMap(\.events)
        guard events.count == 1,
              let event = events.first,
              [UInt64(1), UInt64(2)].contains(event.epoch.authorization.revision),
              epochs.contains(where: { closed in
                  closed.events.contains(event) &&
                      event.admission > closed.epoch.lowerAdmissionCutoff &&
                      event.admission <= closed.upperAdmissionCutoff
              }),
              epochs.contains(where: {
                  $0.epoch.authorization.revision == 2 &&
                      $0.epoch.phase.requiresAcknowledgementHeartbeat
              })
        else {
            return false
        }
    }
    return true
}

private func exactPublicationCutoffIsClosed() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    machine.admitForTesting(.activation(testEvidence(10, "1000", 100)))
    guard machine.publish(second) == .published else { return false }
    machine.admitForTesting(.activation(testEvidence(10, "1000", 100)))
    guard let closure = machine.closeForHeartbeat(), closure.epochs.count == 2 else { return false }
    let old = closure.epochs[0]
    let new = closure.epochs[1]
    guard old.epoch.authorization.revision == 1, old.upperAdmissionCutoff == 1,
          old.events.map(\.admission) == [1], old.epoch.phase.isStable,
          new.epoch.authorization.revision == 2, new.epoch.focusAuthorization.revision == 1,
          new.epoch.lowerAdmissionCutoff == 1, new.upperAdmissionCutoff == 2,
          new.events.map(\.admission) == [2], closure.transitionAcknowledged,
          acknowledgeForTesting(machine, revision: second.revision)
    else {
        return false
    }
    machine.admitForTesting(.activation(testEvidence(10, "1000", 100)))
    guard let stableClosure = machine.closeForHeartbeat(),
          let stableEvent = stableClosure.epochs.flatMap(\.events).first
    else {
        return false
    }
    return stableEvent.epoch.authorization.revision == 2 && stableEvent.epoch.phase.isStable
}

private enum MonitorAcknowledgementTestError: Error {
    case requestedFailure
}

private func acknowledgementWriteOwnsAdmissionCutoff() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    guard machine.publish(second) == .published,
          machine.acknowledge(revision: second.revision) ==
          .rejected(reason: "blocked_producer_ack_without_transition"),
          let closure = machine.closeForHeartbeat(),
          closure.transitionAcknowledged,
          machine.acknowledge(revision: second.revision + 1) ==
          .rejected(reason: "blocked_producer_ack_revision_mismatch"),
          machine.acknowledge(revision: second.revision) ==
          .rejected(reason: "blocked_producer_ack_before_callback_barrier"),
          machine.markAcknowledgementReady(revision: second.revision) == .published
    else {
        return false
    }
    do {
        _ = try machine.acknowledge(revision: second.revision, preparing: {}, publishing: {
            throw MonitorAcknowledgementTestError.requestedFailure
        })
        return false
    } catch MonitorAcknowledgementTestError.requestedFailure {
        guard !machine.currentPhase.isStable else { return false }
    } catch {
        return false
    }

    let reservationStarted = DispatchSemaphore(value: 0)
    let reservationFinished = DispatchSemaphore(value: 0)
    let capturedToken = Mutex<MonitorAdmissionToken?>(nil)
    var reservationCompletedDuringWrite = false
    let result: MonitorPublicationResult
    do {
        result = try machine.acknowledge(revision: second.revision, preparing: {}, publishing: {
            DispatchQueue.global(qos: .userInitiated).async {
                reservationStarted.signal()
                let token = machine.reserveForTesting()
                capturedToken.withLock { $0 = token }
                reservationFinished.signal()
            }
            guard reservationStarted.wait(timeout: .now() + .seconds(1)) == .success else {
                throw MonitorAcknowledgementTestError.requestedFailure
            }
            reservationCompletedDuringWrite =
                reservationFinished.wait(timeout: .now() + .milliseconds(100)) == .success
        })
    } catch {
        return false
    }
    guard result == .published, !reservationCompletedDuringWrite,
          reservationFinished.wait(timeout: .now() + .seconds(1)) == .success,
          let token = capturedToken.withLock({ $0 }), token.epoch.phase.isStable,
          token.epoch.authorization.revision == second.revision,
          machine.cancelForTesting(token, reason: "test_cleanup"),
          machine.acknowledge(revision: second.revision) ==
          .rejected(reason: "blocked_producer_ack_without_transition")
    else {
        return false
    }
    return true
}

private func sealedPreAcknowledgementBucketsBlockPublication() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    guard machine.publish(second) == .published,
          machine.closeForHeartbeat()?.transitionAcknowledged == true,
          machine.markAcknowledgementReady(revision: second.revision) == .published
    else {
        return false
    }
    let firstPending = machine.reserveForTesting()
    guard machine.closeForHeartbeat() == nil else { return false }
    let secondPending = machine.reserveForTesting()
    guard machine.closeForHeartbeat() == nil,
          machine.completeForTesting(
              firstPending,
              with: .activation(testEvidence(10, "1000", 100))),
          machine.closeForHeartbeat() != nil,
          machine.acknowledge(revision: second.revision) ==
          .rejected(reason: "blocked_producer_ack_evidence_pending"),
          machine.completeForTesting(
              secondPending,
              with: .activation(testEvidence(10, "1000", 100))),
          machine.closeForHeartbeat() != nil,
          machine.acknowledge(revision: second.revision) == .published
    else {
        return false
    }
    return machine.currentPhase.isStable
}

private func acknowledgementGateRequiresNextCallbackTurn() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    guard machine.publish(second) == .published,
          let closure = machine.closeForHeartbeat(),
          closure.transitionAcknowledged
    else {
        return false
    }
    var gate = MonitorAcknowledgementGate()
    gate.record(closure)
    guard gate.pendingRevision == second.revision, gate.readyRevision == nil,
          machine.acknowledge(revision: second.revision) ==
          .rejected(reason: "blocked_producer_ack_before_callback_barrier")
    else {
        return false
    }
    do {
        try gate.completeCallbackBarrier(machine: machine)
    } catch {
        return false
    }
    guard gate.readyRevision == second.revision,
          machine.acknowledge(revision: second.revision) == .published
    else {
        return false
    }
    gate.didPublish(revision: second.revision)
    return gate.pendingRevision == nil && gate.readyRevision == nil && machine.currentPhase.isStable
}

private func stableMonitoringDoesNotRequireIdleBarrier() -> Bool {
    !monitorRequiresIdleBarrier(
        pendingAcknowledgementRevision: nil,
        currentRevision: 7,
        proposedRevision: 7) &&
        !monitorRequiresIdleBarrier(
            pendingAcknowledgementRevision: nil,
            currentRevision: 7,
            proposedRevision: 6) &&
        monitorRequiresIdleBarrier(
            pendingAcknowledgementRevision: nil,
            currentRevision: 7,
            proposedRevision: 8) &&
        monitorRequiresIdleBarrier(
            pendingAcknowledgementRevision: 7,
            currentRevision: 7,
            proposedRevision: 7)
}

private func finalIdleBarrierDefersQueuedEvidence() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    guard machine.publish(second) == .published,
          machine.closeForHeartbeat()?.transitionAcknowledged == true,
          machine.markAcknowledgementReady(revision: second.revision) == .published
    else {
        return false
    }
    let runLoop = CFRunLoopGetCurrent()
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        machine.admitActivation { testEvidence(10, "1000", 100) }
    }
    CFRunLoopWakeUp(runLoop)
    guard runLoopReachesIdle(timeout: 1),
          machine.acknowledge(revision: second.revision) ==
          .rejected(reason: "blocked_producer_ack_evidence_pending"),
          let closure = machine.closeForHeartbeat()
    else {
        return false
    }
    return closure.epochs.flatMap(\.events).count == 1 && !machine.currentPhase.isStable
}

private func transitionHeartbeatRetainsPendingEvidence(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let firstProducer = testProducer(20, "2000")
    let secondProducer = testProducer(21, "2100")
    let first = testAuthorization(testProducerSet(revision: 1, producers: [firstProducer]))
    let second = testAuthorization(testProducerSet(revision: 2, producers: [firstProducer, secondProducer]))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    guard machine.publish(second) == .published else { return false }
    machine.admitActivation { testEvidence(10, "1000", 100) }
    guard let closure = machine.closeForHeartbeat() else { return false }
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/transition-summary-violations.jsonl",
        contaminationPath: "\(directory)/transition-summary-contamination.jsonl")
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 21: 2100][$0] },
        targetValidator: { _ in true })
    let unpublished = heartbeat.withTransitionAcknowledged(false)
    return heartbeat.transitionAcknowledged && unpublished.pendingActivationCount == 1 &&
        unpublished.pendingFocusedWindowChange == heartbeat.pendingFocusedWindowChange &&
        !unpublished.transitionAcknowledged && unpublished.sequence == heartbeat.sequence &&
        unpublished.allowedProducerRevision == heartbeat.allowedProducerRevision
}

private func acknowledgementPreparationFailureRemainsObservable() -> Bool {
    for error in [MonitorAcknowledgementPreparationError.liveness, .observerRemoval] {
        let first = testAuthorization(testProducerSet(revision: 1, producers: []))
        let second = testAuthorization(testProducerSet(revision: 2, producers: []))
        let machine = MonitorEpochMachine(initialAuthorization: first)
        guard machine.publish(second) == .published,
              machine.closeForHeartbeat()?.transitionAcknowledged == true,
              machine.markAcknowledgementReady(revision: second.revision) == .published
        else {
            return false
        }
        recordMonitorAcknowledgementPreparationFailure(error, machine: machine)
        guard let closure = machine.closeForHeartbeat(), !machine.currentPhase.isStable,
              closure.epochs.flatMap(\.events).contains(where: {
                  if case let .attributionFailure(reason, process: nil) = $0.kind {
                      return reason == error.reason
                  }
                  return false
              })
        else {
            return false
        }
    }
    return true
}

private func notificationEvidenceIsCapturedAtAdmission() -> Bool {
    let authorization = testAuthorization(testProducerSet(revision: 1, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    var activationEvidence = testEvidence(40, "4000", 401)
    machine.admitActivation { activationEvidence }
    activationEvidence = testEvidence(40, "4001", 402)
    let observer = ProcessGenerationIdentity(pid: 40, startIdentity: "4000")
    var focusEvidence = testEvidence(40, "4000", 401)
    machine.admitFocus(observer: observer) { focusEvidence }
    focusEvidence = testEvidence(40, "4001", 402)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let events = closure.epochs.flatMap(\.events)
    guard events.count == 2 else { return false }
    guard case let .activation(capturedActivation) = events[0].kind,
          case let .focus(capturedFocus) = events[1].kind
    else {
        return false
    }
    return capturedActivation == testEvidence(40, "4000", 401) &&
        capturedFocus == FocusEventEvidence(observer: observer, observed: testEvidence(40, "4000", 401))
}

private func processWindowEvidenceRejectsGenerationABA() -> Bool {
    var identities = [UInt64(4000), UInt64(4001)].makeIterator()
    let driftedEvidence = sampleProcessWindowEvidence(
        pid: 40,
        processIdentity: { identities.next() },
        windowID: { 401 })
    guard driftedEvidence == testEvidence(40, nil, nil) else { return false }

    let stableEvidence = sampleProcessWindowEvidence(
        pid: 40,
        processIdentity: { 4000 },
        windowID: { 401 })
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    var targetIdentities = [UInt64(4000), UInt64(4001)].makeIterator()
    let driftedTargetAccepted = foregroundTargetIsLive(
        target,
        processIdentity: { targetIdentities.next() },
        windowMatches: { true })
    let stableTargetAccepted = foregroundTargetIsLive(
        target,
        processIdentity: { 4000 },
        windowMatches: { true })
    return stableEvidence == testEvidence(40, "4000", 401) &&
        !driftedTargetAccepted && stableTargetAccepted
}

private func idleBarrierDrainsQueuedCallbacksBeforePublication() -> Bool {
    let first = testAuthorization(testProducerSet(revision: 1, producers: []))
    let second = testAuthorization(testProducerSet(revision: 2, producers: []))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    let callbacks = Mutex<[Int]>([])
    let runLoop = CFRunLoopGetCurrent()
    guard let lateObserver = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault,
        CFRunLoopActivity.beforeWaiting.rawValue,
        false,
        0,
        { _, _ in
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
                callbacks.withLock { $0.append(3) }
                machine.admitActivation { testEvidence(10, "1000", 100) }
            }
            CFRunLoopWakeUp(runLoop)
        })
    else {
        return false
    }
    CFRunLoopAddObserver(runLoop, lateObserver, .defaultMode)
    defer {
        CFRunLoopRemoveObserver(runLoop, lateObserver, .defaultMode)
        CFRunLoopObserverInvalidate(lateObserver)
    }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        callbacks.withLock { $0.append(1) }
    }
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        callbacks.withLock { $0.append(2) }
        machine.admitActivation { testEvidence(10, "1000", 100) }
    }
    CFRunLoopWakeUp(runLoop)
    guard runLoopReachesIdle(timeout: 1), callbacks.withLock({ $0 }) == [1, 2, 3],
          machine.publish(second) == .published,
          let closure = machine.closeForHeartbeat(),
          closure.epochs.flatMap(\.events).count == 2
    else {
        return false
    }
    return closure.epochs.flatMap(\.events).allSatisfy { $0.epoch.authorization.revision == first.revision } &&
        closure.finalEpoch.epoch.authorization.revision == second.revision
}

private func sampleDrainCloseRetainsCallbackEvidence(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [])))
    let runLoop = CFRunLoopGetCurrent()
    let current = desktop.sample
    CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
        machine.admitActivation { testEvidence(99, "9900", 991) }
    }
    CFRunLoopWakeUp(runLoop)
    guard runLoopReachesIdle(timeout: 1), let closure = machine.closeForHeartbeat() else { return false }
    let output = "\(directory)/sample-cutoff-violations.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: "\(directory)/sample-cutoff-contamination.jsonl")
    let heartbeat = try watch.observe(
        current: current,
        phase: "running",
        closure: closure,
        processIdentity: { $0 == 10 ? 1000 : nil },
        targetValidator: { _ in true })
    let kinds = Set(decodeJSONLines(Violation.self, at: output).map(\.kind))
    return heartbeat.pendingActivationCount == 1 &&
        kinds == Set([projection[.frontmostPID], projection[.frontmostWindow]])
}

private func revisionsRequireAcknowledgement() -> Bool {
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let targetA = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let targetB = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 402)
    let targetC = AllowedForegroundTarget(pid: 40, startIdentity: "4001", windowID: 402)
    let inactive = AllowedForegroundActivity(active: false, target: nil)
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge],
        foreground: inactive)))
    let revisions = [
        testProducerSet(
            revision: 2,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: targetA)),
        testProducerSet(
            revision: 3,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: targetB)),
        testProducerSet(
            revision: 4,
            producers: [bridge, testProducer(30, "3001", role: .foregroundController)],
            foreground: AllowedForegroundActivity(active: true, target: targetC)),
        testProducerSet(revision: 5, producers: [bridge], foreground: inactive),
    ]
    var acknowledgedRevisions = [UInt64]()
    for producerSet in revisions {
        let authorization = testAuthorization(producerSet)
        guard machine.publish(authorization) == .published else { return false }
        if producerSet.revision == 2 {
            let next = testAuthorization(revisions[1])
            guard case .rejected(reason: "blocked_producer_revision_before_ack") = machine.publish(next) else {
                return false
            }
        }
        guard let closure = machine.closeForHeartbeat(),
              closure.transitionAcknowledged,
              closure.finalEpoch.epoch.authorization.revision == producerSet.revision,
              acknowledgeForTesting(machine, revision: producerSet.revision)
        else {
            return false
        }
        acknowledgedRevisions.append(producerSet.revision)
    }
    return acknowledgedRevisions == [2, 3, 4, 5] && machine.currentAuthorization.target == nil
}

private func equalRevisionRequiresExactPayload() -> Bool {
    let a = testProducer(20, "2000")
    let b = testProducer(21, "2100")
    let source = testProducerSet(revision: 7, producers: [a, b])
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(source))
    let reordered = testAuthorization(testProducerSet(revision: 7, producers: [b, a]))
    let mutated = testAuthorization(testProducerSet(
        revision: 7,
        producers: [a, b],
        foreground: AllowedForegroundActivity(active: false, target: nil)))
    guard machine.publish(reordered) == .idempotent else { return false }
    guard case .rejected(reason: "blocked_producer_revision_replay") = machine.publish(mutated) else {
        return false
    }
    return true
}

private func queuedGrantEraEventsRetainAuthorization() -> Bool {
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let targetA = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let targetB = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 402)
    let inactive = AllowedForegroundActivity(active: false, target: nil)
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge],
        foreground: inactive)))
    let grant = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: targetA)))
    let retarget = testAuthorization(testProducerSet(
        revision: 3,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: targetB)))
    let revoke = testAuthorization(testProducerSet(revision: 4, producers: [bridge], foreground: inactive))
    guard machine.publish(grant) == .published,
          let grantClosure = machine.closeForHeartbeat(),
          grantClosure.transitionAcknowledged,
          acknowledgeForTesting(machine, revision: grant.revision)
    else {
        return false
    }
    let queuedGrantInput = machine.reserveForTesting()
    guard machine.publish(retarget) == .published,
          machine.completeForTesting(queuedGrantInput, with: .input(InputEventEvidence(
              type: CGEventType.keyDown.rawValue,
              source: testEvidence(30, "3000", nil),
              sessionFocus: testEvidence(40, "4000", 401)))),
          let retargetClosure = machine.closeForHeartbeat(),
          retargetClosure.transitionAcknowledged,
          acknowledgeForTesting(machine, revision: retarget.revision)
    else {
        return false
    }
    let queuedRetargetFocus = machine.reserveForTesting()
    guard machine.publish(revoke) == .published,
          machine.completeForTesting(queuedRetargetFocus, with: .focus(FocusEventEvidence(
              observer: ProcessGenerationIdentity(pid: 40, startIdentity: "4000"),
              observed: testEvidence(40, "4000", 402))))
    else {
        return false
    }
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3000", nil),
        sessionFocus: testEvidence(40, "4000", 402))))
    guard let revokeClosure = machine.closeForHeartbeat(), revokeClosure.transitionAcknowledged else { return false }
    let events = retargetClosure.epochs.flatMap(\.events) + revokeClosure.epochs.flatMap(\.events)
    return events.count == 3 && events.map(\.epoch.authorization.revision) == [2, 3, 4] &&
        events[0].epoch.phase.isStable && events[1].epoch.phase.isStable &&
        events[2].epoch.phase.requiresAcknowledgementHeartbeat
}

private enum FakeFocusObserverError: Error {
    case requestedFailure
}

private final class FakeFocusObserverStore {
    var failStart = Set<ProcessGenerationIdentity>()
    var failStop = Set<ProcessGenerationIdentity>()
    var starts = [ProcessGenerationIdentity]()
    var stops = [ProcessGenerationIdentity]()
    var onStop: ((ProcessGenerationIdentity) -> Void)?
}

private final class FakeFocusObserver: FocusObserverTracking {
    let identity: ProcessGenerationIdentity
    private let store: FakeFocusObserverStore

    init(identity: ProcessGenerationIdentity, store: FakeFocusObserverStore) {
        self.identity = identity
        self.store = store
    }

    func start() throws {
        if self.store.failStart.contains(self.identity) {
            throw FakeFocusObserverError.requestedFailure
        }
        self.store.starts.append(self.identity)
    }

    func stop() throws {
        self.store.onStop?(self.identity)
        if self.store.failStop.contains(self.identity) {
            throw FakeFocusObserverError.requestedFailure
        }
        self.store.stops.append(self.identity)
    }
}

private func observerLifecycleIsBarrierBound() -> Bool {
    let baseline = ProcessGenerationIdentity(pid: 10, startIdentity: "1000")
    let first = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let sameProcessWindow = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 402)
    let second = AllowedForegroundTarget(pid: 41, startIdentity: "4100", windowID: 411)
    let failedInstall = AllowedForegroundTarget(pid: 42, startIdentity: "4200", windowID: 421)
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let inactive = AllowedForegroundActivity(active: false, target: nil)
    let store = FakeFocusObserverStore()
    let coordinator = FocusObserverCoordinator { FakeFocusObserver(identity: $0, store: store) }
    do {
        try coordinator.startBaseline(baseline)
    } catch {
        return false
    }
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge],
        foreground: inactive)))
    let identities: (Int32) -> UInt64? = {
        [10: 1000, 20: 2000, 30: 3000, 40: 4000, 41: 4100, 42: 4200][$0]
    }
    let targetValidator: (AllowedForegroundTarget) -> Bool = { _ in true }
    func closeAndAcknowledge() -> MonitorEpochClosure? {
        guard let closure = machine.closeForHeartbeat(), closure.transitionAcknowledged else { return nil }
        do {
            guard machine.markAcknowledgementReady(
                revision: closure.finalEpoch.epoch.authorization.revision) == .published
            else {
                return nil
            }
            let result = try publishMonitorTransitionAcknowledgement(
                revision: closure.finalEpoch.epoch.authorization.revision,
                machine: machine,
                observers: coordinator,
                processIdentity: identities,
                targetValidator: targetValidator)
            guard result == .published else { return nil }
        } catch {
            return nil
        }
        return closure
    }

    applyMonitorAuthorization(
        testProducerSet(
            revision: 2,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: first)),
        to: machine,
        observers: coordinator,
        processIdentity: identities,
        targetValidator: targetValidator)
    let firstIdentity = ProcessGenerationIdentity(pid: 40, startIdentity: "4000")
    let secondIdentity = ProcessGenerationIdentity(pid: 41, startIdentity: "4100")
    guard coordinator.observedIdentities == Set([baseline, firstIdentity]),
          closeAndAcknowledge() != nil
    else {
        return false
    }

    applyMonitorAuthorization(
        testProducerSet(
            revision: 3,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: sameProcessWindow)),
        to: machine,
        observers: coordinator,
        processIdentity: identities,
        targetValidator: targetValidator)
    guard coordinator.observedIdentities == Set([baseline, firstIdentity]),
          closeAndAcknowledge() != nil
    else {
        return false
    }

    applyMonitorAuthorization(
        testProducerSet(
            revision: 4,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: second)),
        to: machine,
        observers: coordinator,
        processIdentity: identities,
        targetValidator: targetValidator)
    guard coordinator.observedIdentities == Set([baseline, firstIdentity, secondIdentity]) else {
        return false
    }
    guard let retargetAcknowledgement = closeAndAcknowledge() else { return false }
    guard retargetAcknowledgement.transitionAcknowledged,
          coordinator.observedIdentities == Set([baseline, secondIdentity]),
          store.stops == [firstIdentity]
    else {
        return false
    }

    let failedInstallIdentity = ProcessGenerationIdentity(pid: 42, startIdentity: "4200")
    store.failStart.insert(failedInstallIdentity)
    applyMonitorAuthorization(
        testProducerSet(
            revision: 5,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: failedInstall)),
        to: machine,
        observers: coordinator,
        processIdentity: identities,
        targetValidator: targetValidator)
    guard let failedInstallClosure = machine.closeForHeartbeat() else { return false }
    guard machine.currentAuthorization.revision == 4,
          !coordinator.observedIdentities.contains(failedInstallIdentity),
          failedInstallClosure.epochs.flatMap(\.events).contains(where: {
              if case .attributionFailure(reason: "blocked_focus_observer_install", process: nil) = $0.kind {
                  return true
              }
              return false
          })
    else {
        return false
    }

    store.failStop.insert(secondIdentity)
    applyMonitorAuthorization(
        testProducerSet(revision: 6, producers: [bridge], foreground: inactive),
        to: machine,
        observers: coordinator,
        processIdentity: identities,
        targetValidator: targetValidator)
    guard let failedRemovalAcknowledgement = machine.closeForHeartbeat(),
          failedRemovalAcknowledgement.transitionAcknowledged
    else {
        return false
    }
    var acknowledgementPublished = false
    do {
        guard machine.markAcknowledgementReady(
            revision: failedRemovalAcknowledgement.finalEpoch.epoch.authorization.revision) == .published
        else {
            return false
        }
        _ = try publishMonitorTransitionAcknowledgement(
            revision: failedRemovalAcknowledgement.finalEpoch.epoch.authorization.revision,
            machine: machine,
            observers: coordinator,
            processIdentity: identities,
            targetValidator: targetValidator)
        {
            acknowledgementPublished = true
        }
        return false
    } catch {
        return machine.currentAuthorization.revision == 6 && !machine.currentPhase.isStable &&
            !acknowledgementPublished && coordinator.observedIdentities.contains(secondIdentity)
    }
}

private func productionRevisionReplayFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let first = testProducer(20, "2000")
    let second = testProducer(21, "2100")
    let source = testProducerSet(revision: 7, producers: [first, second])
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(source))
    let store = FakeFocusObserverStore()
    let observers = FocusObserverCoordinator { FakeFocusObserver(identity: $0, store: store) }
    applyMonitorAuthorization(
        testProducerSet(
            revision: 7,
            producers: [first, second],
            foreground: AllowedForegroundActivity(active: false, target: nil)),
        to: machine,
        observers: observers,
        processIdentity: { [20: 2000, 21: 2100][$0] },
        targetValidator: { _ in true })
    guard let closure = machine.closeForHeartbeat() else { return false }
    let contamination = "\(directory)/revision-replay-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/revision-replay-violations.jsonl",
        contaminationPath: contamination)
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 21: 2100][$0] },
        targetValidator: { _ in true })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return machine.currentAuthorization.source == source && store.starts.isEmpty && store.stops.isEmpty &&
        heartbeat.contaminationBlocked && !heartbeat.inputAttributionAvailable &&
        states == Set(["blocked_producer_revision_replay"])
}

private func productionRevisionBeforeAckDoesNotPrepareObserver() -> Bool {
    let baseline = ProcessGenerationIdentity(pid: 10, startIdentity: "1000")
    let firstTarget = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let secondTarget = AllowedForegroundTarget(pid: 41, startIdentity: "4100", windowID: 411)
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let store = FakeFocusObserverStore()
    let observers = FocusObserverCoordinator { FakeFocusObserver(identity: $0, store: store) }
    do {
        try observers.startBaseline(baseline)
    } catch {
        return false
    }
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge])))
    let identities: (Int32) -> UInt64? = {
        [10: 1000, 20: 2000, 30: 3000, 40: 4000, 41: 4100][$0]
    }
    applyMonitorAuthorization(
        testProducerSet(
            revision: 2,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: firstTarget)),
        to: machine,
        observers: observers,
        processIdentity: identities,
        targetValidator: { _ in true })
    let firstIdentity = ProcessGenerationIdentity(pid: 40, startIdentity: "4000")
    let secondIdentity = ProcessGenerationIdentity(pid: 41, startIdentity: "4100")
    guard observers.observedIdentities == Set([baseline, firstIdentity]) else { return false }
    applyMonitorAuthorization(
        testProducerSet(
            revision: 3,
            producers: [bridge, controller],
            foreground: AllowedForegroundActivity(active: true, target: secondTarget)),
        to: machine,
        observers: observers,
        processIdentity: identities,
        targetValidator: { _ in true })
    guard let closure = machine.closeForHeartbeat() else { return false }
    return machine.currentAuthorization.revision == 2 && !machine.currentPhase.isStable &&
        observers.observedIdentities == Set([baseline, firstIdentity]) &&
        !observers.observedIdentities.contains(secondIdentity) &&
        closure.epochs.flatMap(\.events).contains(where: {
            if case .attributionFailure(reason: "blocked_producer_revision_before_ack", process: nil) = $0.kind {
                return true
            }
            return false
        })
}

private func productionIdempotentRevisionIsAllowedBeforeAck() -> Bool {
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let initial = testProducerSet(revision: 1, producers: [bridge])
    let grant = testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target))
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(initial))
    let observers = FocusObserverCoordinator { identity in
        FakeFocusObserver(identity: identity, store: FakeFocusObserverStore())
    }
    let identities: (Int32) -> UInt64? = { [20: 2000, 30: 3000, 40: 4000][$0] }
    applyMonitorAuthorization(
        grant,
        to: machine,
        observers: observers,
        processIdentity: identities,
        targetValidator: { $0 == target })
    guard machine.currentAuthorization.revision == 2, !machine.currentPhase.isStable else { return false }
    applyMonitorAuthorization(
        grant,
        to: machine,
        observers: observers,
        processIdentity: identities,
        targetValidator: { $0 == target })
    guard let closure = machine.closeForHeartbeat() else { return false }
    return closure.transitionAcknowledged && closure.epochs.flatMap(\.events).isEmpty &&
        machine.currentAuthorization.revision == 2
}

private func acknowledgementRevalidatesControllerAndTargetLiveness() -> Bool {
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let active = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let revoked = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))

    func blocks(
        processIdentity: @escaping (Int32) -> UInt64?,
        targetValidator: @escaping (AllowedForegroundTarget) -> Bool) -> Bool
    {
        let machine = MonitorEpochMachine(initialAuthorization: active)
        let observers = FocusObserverCoordinator { identity in
            FakeFocusObserver(identity: identity, store: FakeFocusObserverStore())
        }
        guard machine.publish(revoked) == .published,
              machine.closeForHeartbeat()?.transitionAcknowledged == true,
              machine.markAcknowledgementReady(revision: revoked.revision) == .published
        else {
            return false
        }
        var published = false
        do {
            _ = try publishMonitorTransitionAcknowledgement(
                revision: revoked.revision,
                machine: machine,
                observers: observers,
                processIdentity: processIdentity,
                targetValidator: targetValidator)
            {
                published = true
            }
            return false
        } catch {
            return !published && !machine.currentPhase.isStable
        }
    }

    let controllerDriftBlocked = blocks(
        processIdentity: { [20: 2000, 30: 3001, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let targetDriftBlocked = blocks(
        processIdentity: { [20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { _ in false })
    return controllerDriftBlocked && targetDriftBlocked
}

private func acknowledgementRevalidatesAfterObserverReconciliation() -> Bool {
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let active = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let revoked = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))
    let machine = MonitorEpochMachine(initialAuthorization: active)
    let store = FakeFocusObserverStore()
    let observers = FocusObserverCoordinator { FakeFocusObserver(identity: $0, store: store) }
    do {
        try observers.prepare(target: target)
    } catch {
        return false
    }
    let controllerLive = Mutex(true)
    store.onStop = { _ in controllerLive.withLock { $0 = false } }
    guard machine.publish(revoked) == .published,
          machine.closeForHeartbeat()?.transitionAcknowledged == true,
          machine.markAcknowledgementReady(revision: revoked.revision) == .published
    else {
        return false
    }
    var published = false
    do {
        _ = try publishMonitorTransitionAcknowledgement(
            revision: revoked.revision,
            machine: machine,
            observers: observers,
            processIdentity: { pid in
                [20: 2000, 30: controllerLive.withLock { $0 ? 3000 : 3001 }, 40: 4000][pid]
            },
            targetValidator: { $0 == target })
        {
            published = true
        }
        return false
    } catch MonitorAcknowledgementPreparationError.liveness {
        return !published && !machine.currentPhase.isStable && !controllerLive.withLock { $0 }
    } catch {
        return false
    }
}

private func pendingAcknowledgementEvidenceDrainsBeforePublication(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let active = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let revoked = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))
    let machine = MonitorEpochMachine(initialAuthorization: active)
    let observers = FocusObserverCoordinator { identity in
        FakeFocusObserver(identity: identity, store: FakeFocusObserverStore())
    }
    guard machine.publish(revoked) == .published,
          let transitionClosure = machine.closeForHeartbeat(),
          transitionClosure.transitionAcknowledged
    else {
        return false
    }
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/pending-ack-violations.jsonl",
        contaminationPath: "\(directory)/pending-ack-contamination.jsonl")
    let identities: (Int32) -> UInt64? = { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] }
    _ = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: transitionClosure,
        processIdentity: identities,
        targetValidator: { $0 == target })
    guard machine.markAcknowledgementReady(revision: revoked.revision) == .published else { return false }
    let pending = machine.reserveForTesting()
    var acknowledgementPublished = false
    let deferred = try publishMonitorTransitionAcknowledgement(
        revision: revoked.revision,
        machine: machine,
        observers: observers,
        processIdentity: identities,
        targetValidator: { $0 == target })
    {
        acknowledgementPublished = true
    }
    guard deferred == .rejected(reason: "blocked_producer_ack_evidence_pending"),
          !acknowledgementPublished,
          machine.completeForTesting(pending, with: .input(InputEventEvidence(
              type: CGEventType.keyDown.rawValue,
              source: testEvidence(30, "3000", nil),
              sessionFocus: testEvidence(40, "4000", 401)))),
          let evidenceClosure = machine.closeForHeartbeat()
    else {
        return false
    }
    let evidenceHeartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: evidenceClosure,
        processIdentity: identities,
        targetValidator: { $0 == target })
    let published = try publishMonitorTransitionAcknowledgement(
        revision: revoked.revision,
        machine: machine,
        observers: observers,
        processIdentity: identities,
        targetValidator: { $0 == target })
    {
        acknowledgementPublished = true
    }
    let priorActivity = watch.foregroundActivity(for: active.revision)
    return published == .published && acknowledgementPublished && machine.currentPhase.isStable &&
        !evidenceHeartbeat.contaminationBlocked && evidenceHeartbeat.inputAttributionAvailable &&
        priorActivity.eventCount == 1 && priorActivity.sourcePIDs == Set([30])
}

private func decodeJSONLines<T: Decodable>(_ type: T.Type, at path: String) -> [T] {
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return contents.split(separator: "\n").compactMap {
        try? JSONDecoder().decode(type, from: Data($0.utf8))
    }
}

private func makeSelfTestWatchState(
    desktop: (sample: SystemSample, baseline: InteractiveBaseline),
    projection: InvariantProjection,
    outputPath: String,
    contaminationPath: String,
    physicalInputObservational: Bool = true,
    cursorObservational: Bool = true,
    evidenceLedger: MonitorPublicationLedger? = nil) -> WatchState
{
    WatchState(
        baseline: desktop.sample,
        interactiveBaseline: desktop.baseline,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        historyCommitmentSHA256: String(repeating: "b", count: 64),
        allowClipboardMutation: false,
        physicalInputObservational: physicalInputObservational,
        cursorObservational: cursorObservational,
        projection: projection,
        outputPath: outputPath,
        contaminationOutputPath: contaminationPath,
        evidenceLedger: evidenceLedger)
}

private func transitionAcknowledgementNeverAdvancesClean(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridgeA = testProducer(20, "2000")
    let bridgeB = testProducer(21, "2100")
    let first = testAuthorization(testProducerSet(revision: 1, producers: [bridgeA]))
    let second = testAuthorization(testProducerSet(revision: 2, producers: [bridgeA, bridgeB]))
    let machine = MonitorEpochMachine(initialAuthorization: first)
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/ack-violations.jsonl",
        contaminationPath: "\(directory)/ack-contamination.jsonl")
    let identities: (Int32) -> UInt64? = { [10: 1000, 20: 2000, 21: 2100][$0] }
    guard let firstClosure = machine.closeForHeartbeat() else { return false }
    let firstHeartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: firstClosure,
        processIdentity: identities,
        targetValidator: { _ in true })
    guard machine.publish(second) == .published else { return false }
    guard let acknowledgementClosure = machine.closeForHeartbeat() else { return false }
    let acknowledgement = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: acknowledgementClosure,
        processIdentity: identities,
        targetValidator: { _ in true })
    guard acknowledgeForTesting(machine, revision: second.revision) else { return false }
    guard let settledClosure = machine.closeForHeartbeat() else { return false }
    let settled = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: settledClosure,
        processIdentity: identities,
        targetValidator: { _ in true })
    return firstHeartbeat.lastCleanSequence == 1 &&
        acknowledgement.allowedProducerRevision == 2 && acknowledgement.transitionAcknowledged &&
        acknowledgement.lastCleanSequence == 1 &&
        settled.allowedProducerRevision == 2 && !settled.transitionAcknowledged &&
        settled.lastCleanSequence == settled.sequence
}

private func preAcknowledgementForegroundActivityFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let initial = testAuthorization(testProducerSet(revision: 1, producers: [bridge]))
    let granted = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: initial)
    guard machine.publish(granted) == .published else { return false }
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3000", nil),
        sessionFocus: testEvidence(40, "4000", 401))))
    machine.admitForTesting(.activation(testEvidence(40, "4000", 401)))
    let output = "\(directory)/pre-ack-violations.jsonl"
    let contamination = "\(directory)/pre-ack-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: contamination)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    let kinds = Set(decodeJSONLines(Violation.self, at: output).map(\.kind))
    return heartbeat.transitionAcknowledged && heartbeat.lastCleanSequence == 0 &&
        heartbeat.attributedForegroundEventCount == 0 && heartbeat.contaminationBlocked &&
        states == Set(["blocked_foreground_input_before_transition_ack"]) &&
        kinds == Set([projection[.frontmostPID], projection[.frontmostWindow]])
}

private func acknowledgementPublicationCutoffIsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let initial = testAuthorization(testProducerSet(revision: 1, producers: [bridge]))
    let granted = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: initial)
    guard machine.publish(granted) == .published,
          let acknowledgementClosure = machine.closeForHeartbeat(),
          acknowledgementClosure.transitionAcknowledged
    else {
        return false
    }
    let admission = machine.reserveForTesting()
    var acknowledgementPublished = false
    guard machine.markAcknowledgementReady(revision: granted.revision) == .published,
          machine.acknowledge(revision: granted.revision, preparing: {}, publishing: {
              acknowledgementPublished = true
          }) == .rejected(reason: "blocked_producer_ack_evidence_pending"),
          !acknowledgementPublished,
          machine.completeForTesting(admission, with: .input(InputEventEvidence(
              type: CGEventType.keyDown.rawValue,
              source: testEvidence(30, "3000", nil),
              sessionFocus: testEvidence(40, "4000", 401)))),
          let preAcknowledgementClosure = machine.closeForHeartbeat()
    else {
        return false
    }
    let contamination = "\(directory)/ack-cutoff-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/ack-cutoff-violations.jsonl",
        contaminationPath: contamination)
    _ = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: acknowledgementClosure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: preAcknowledgementClosure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return !machine.currentPhase.isStable && !preAcknowledgementClosure.transitionAcknowledged &&
        heartbeat.contaminationBlocked &&
        heartbeat.attributedForegroundEventCount == 0 &&
        states == Set(["blocked_foreground_input_before_transition_ack"])
}

private func transitionSamplingUsesAcknowledgedAuthorization() -> Bool {
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let active = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let revoked = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))
    let revokeMachine = MonitorEpochMachine(initialAuthorization: active)
    var transitionSample: MonitorAuthorization?
    guard revokeMachine.publish(revoked) == .published else { return false }
    revokeMachine.admitInput(type: .keyDown) { authorization in
        transitionSample = authorization
        return (
            source: testEvidence(30, "3000", nil),
            sessionFocus: authorization.target.map {
                testEvidence($0.pid, $0.startIdentity, $0.windowID)
            })
    }
    guard let transitionClosure = revokeMachine.closeForHeartbeat(),
          transitionSample == active,
          let transitionInput = transitionClosure.epochs.flatMap(\.events).compactMap({ event -> InputEventEvidence? in
              if case let .input(input) = event.kind {
                  return input
              }
              return nil
          }).first,
          transitionInput.sessionFocus == testEvidence(40, "4000", 401)
    else {
        return false
    }

    var awaitingSample: MonitorAuthorization?
    revokeMachine.admitInput(type: .keyDown) { authorization in
        awaitingSample = authorization
        return (
            source: testEvidence(30, "3000", nil),
            sessionFocus: authorization.target.map {
                testEvidence($0.pid, $0.startIdentity, $0.windowID)
            })
    }
    guard let awaitingClosure = revokeMachine.closeForHeartbeat(), awaitingSample == active,
          awaitingClosure.epochs.flatMap(\.events).contains(where: {
              if case let .input(input) = $0.kind {
                  return input.sessionFocus == testEvidence(40, "4000", 401)
              }
              return false
          })
    else {
        return false
    }

    let inactive = testAuthorization(testProducerSet(revision: 1, producers: [bridge]))
    let granted = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let grantMachine = MonitorEpochMachine(initialAuthorization: inactive)
    var grantSample: MonitorAuthorization?
    guard grantMachine.publish(granted) == .published else { return false }
    grantMachine.admitInput(type: .keyDown) { authorization in
        grantSample = authorization
        return (source: testEvidence(30, "3000", nil), sessionFocus: nil)
    }
    return grantSample == inactive
}

private func queuedGrantEraEvidenceIsNeitherDroppedNorRelabeled(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let active = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let revoked = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))
    let machine = MonitorEpochMachine(initialAuthorization: active)
    let queuedInput = machine.reserveForTesting()
    let queuedActivation = machine.reserveForTesting()
    guard machine.publish(revoked) == .published,
          machine.completeForTesting(queuedInput, with: .input(InputEventEvidence(
              type: CGEventType.keyDown.rawValue,
              source: testEvidence(30, "3000", nil),
              sessionFocus: testEvidence(40, "4000", 401)))),
          machine.completeForTesting(queuedActivation, with: .activation(testEvidence(99, "9900", 991))),
          let closure = machine.closeForHeartbeat()
    else {
        return false
    }
    let output = "\(directory)/queued-grant-violations.jsonl"
    let contamination = "\(directory)/queued-grant-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: contamination)
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000, 99: 9900][$0] },
        targetValidator: { $0 == target })
    let kinds = Set(decodeJSONLines(Violation.self, at: output).map(\.kind))
    let grantActivity = watch.foregroundActivity(for: active.revision)
    return heartbeat.transitionAcknowledged && grantActivity.eventCount == 1 &&
        grantActivity.sourcePIDs == Set([30]) && heartbeat.attributedForegroundEventCount == 0 &&
        heartbeat.attributedForegroundSourcePIDs.isEmpty && !heartbeat.foregroundActivityObserved &&
        !heartbeat.contaminationBlocked && decodeJSONLines(ContaminationRecord.self, at: contamination).isEmpty &&
        kinds == Set([projection[.frontmostPID], projection[.frontmostWindow]])
}

private func foregroundActivityIsRevisionScoped(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let firstController = testProducer(30, "3000", role: .foregroundController)
    let secondController = testProducer(31, "3100", role: .foregroundController)
    let firstTarget = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let secondTarget = AllowedForegroundTarget(pid: 41, startIdentity: "4100", windowID: 411)
    let firstGrant = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, firstController],
        foreground: AllowedForegroundActivity(active: true, target: firstTarget)))
    let revoke = testAuthorization(testProducerSet(revision: 2, producers: [bridge]))
    let secondGrant = testAuthorization(testProducerSet(
        revision: 3,
        producers: [bridge, secondController],
        foreground: AllowedForegroundActivity(active: true, target: secondTarget)))
    let machine = MonitorEpochMachine(initialAuthorization: firstGrant)
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3000", nil),
        sessionFocus: testEvidence(40, "4000", 401))))
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/activity-scope-violations.jsonl",
        contaminationPath: "\(directory)/activity-scope-contamination.jsonl")
    let identities: (Int32) -> UInt64? = {
        [10: 1000, 20: 2000, 30: 3000, 31: 3100, 40: 4000, 41: 4100][$0]
    }
    guard let firstClosure = machine.closeForHeartbeat() else { return false }
    let firstHeartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: firstClosure,
        processIdentity: identities,
        targetValidator: { $0 == firstTarget || $0 == secondTarget })
    guard machine.publish(revoke) == .published,
          let revokeClosure = machine.closeForHeartbeat()
    else {
        return false
    }
    let revokeHeartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: revokeClosure,
        processIdentity: identities,
        targetValidator: { $0 == firstTarget || $0 == secondTarget })
    guard acknowledgeForTesting(machine, revision: revoke.revision),
          machine.publish(secondGrant) == .published,
          let secondGrantClosure = machine.closeForHeartbeat()
    else {
        return false
    }
    let secondGrantHeartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: secondGrantClosure,
        processIdentity: identities,
        targetValidator: { $0 == firstTarget || $0 == secondTarget })
    return firstHeartbeat.attributedForegroundEventCount == 1 &&
        firstHeartbeat.attributedForegroundSourcePIDs == [30] && firstHeartbeat.foregroundActivityObserved &&
        revokeHeartbeat.attributedForegroundEventCount == 0 &&
        revokeHeartbeat.attributedForegroundSourcePIDs.isEmpty && !revokeHeartbeat.foregroundActivityObserved &&
        secondGrantHeartbeat.attributedForegroundEventCount == 0 &&
        secondGrantHeartbeat.attributedForegroundSourcePIDs.isEmpty &&
        !secondGrantHeartbeat.foregroundActivityObserved
}

private func wrongWindowThenTargetStillViolates(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let authorization = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    let observer = ProcessGenerationIdentity(pid: 40, startIdentity: "4000")
    machine.admitForTesting(.focus(FocusEventEvidence(
        observer: observer,
        observed: testEvidence(40, "4000", 499))))
    machine.admitForTesting(.focus(FocusEventEvidence(
        observer: observer,
        observed: testEvidence(40, "4000", 401))))
    let output = "\(directory)/wrong-window-violations.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: "\(directory)/wrong-window-contamination.jsonl")
    let current = SystemSample(
        timestamp: 2,
        frontmostPID: 40,
        frontmostBundleIdentifier: nil,
        frontmostWindowID: 401,
        cursor: desktop.sample.cursor,
        clipboardChangeCount: desktop.sample.clipboardChangeCount,
        clipboardDigest: "",
        peekabooWindowIDs: desktop.sample.peekabooWindowIDs,
        visibleScreenFramesTopLeft: desktop.sample.visibleScreenFramesTopLeft)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: current,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let kinds = Set(decodeJSONLines(Violation.self, at: output).map(\.kind))
    return kinds.contains(projection[.frontmostWindow]) && !heartbeat.contaminationBlocked
}

private func authorizedForegroundEvidenceIsClean(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let authorization = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3000", nil),
        sessionFocus: testEvidence(40, "4000", 401))))
    machine.admitForTesting(.activation(testEvidence(40, "4000", 401)))
    machine.admitForTesting(.focus(FocusEventEvidence(
        observer: ProcessGenerationIdentity(pid: 40, startIdentity: "4000"),
        observed: testEvidence(40, "4000", 401))))
    let output = "\(directory)/authorized-foreground-violations.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: "\(directory)/authorized-foreground-contamination.jsonl")
    let current = SystemSample(
        timestamp: 2,
        frontmostPID: 40,
        frontmostBundleIdentifier: nil,
        frontmostWindowID: 401,
        cursor: desktop.sample.cursor,
        clipboardChangeCount: desktop.sample.clipboardChangeCount,
        clipboardDigest: "",
        peekabooWindowIDs: desktop.sample.peekabooWindowIDs,
        visibleScreenFramesTopLeft: desktop.sample.visibleScreenFramesTopLeft)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: current,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { $0 == target })
    return heartbeat.lastCleanSequence == heartbeat.sequence &&
        heartbeat.attributedForegroundEventCount == 1 &&
        heartbeat.attributedForegroundSourcePIDs == [30] &&
        heartbeat.foregroundActivityObserved && !heartbeat.contaminationBlocked &&
        decodeJSONLines(Violation.self, at: output).isEmpty
}

private func currentTargetDriftFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let authorization = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    let contamination = "\(directory)/current-target-drift-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/current-target-drift-violations.jsonl",
        contaminationPath: contamination)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000][$0] },
        targetValidator: { _ in false })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return heartbeat.contaminationBlocked && !heartbeat.inputAttributionAvailable &&
        states == Set(["blocked_foreground_target_drift"])
}

private func controllerGenerationDriftFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let authorization = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3001", nil),
        sessionFocus: testEvidence(40, "4000", 401))))
    let contamination = "\(directory)/controller-drift-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/controller-drift-violations.jsonl",
        contaminationPath: contamination)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3001, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return heartbeat.contaminationBlocked && !heartbeat.inputAttributionAvailable &&
        states == Set(["blocked_producer_generation_drift"])
}

private func idleProducerGenerationDriftFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let authorization = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    let contamination = "\(directory)/idle-controller-drift-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/idle-controller-drift-violations.jsonl",
        contaminationPath: contamination)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3001, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return heartbeat.contaminationBlocked && !heartbeat.inputAttributionAvailable &&
        heartbeat.lastCleanSequence == 0 && states == Set(["blocked_producer_generation_drift"])
}

private func focusNotificationGenerationDriftFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let authorization = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let machine = MonitorEpochMachine(initialAuthorization: authorization)
    machine.admitForTesting(.focus(FocusEventEvidence(
        observer: ProcessGenerationIdentity(pid: 40, startIdentity: "4000"),
        observed: testEvidence(40, "4001", 401))))
    let contamination = "\(directory)/focus-generation-drift-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/focus-generation-drift-violations.jsonl",
        contaminationPath: contamination)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4000][$0] },
        targetValidator: { $0 == target })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return heartbeat.contaminationBlocked && !heartbeat.inputAttributionAvailable &&
        states == Set(["blocked_focus_observer_generation_drift"])
}

private func deferredTargetDriftFailsClosed(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let controller = testProducer(30, "3000", role: .foregroundController)
    let target = AllowedForegroundTarget(pid: 40, startIdentity: "4000", windowID: 401)
    let active = testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge, controller],
        foreground: AllowedForegroundActivity(active: true, target: target)))
    let revoked = testAuthorization(testProducerSet(
        revision: 2,
        producers: [bridge],
        foreground: AllowedForegroundActivity(active: false, target: nil)))
    let machine = MonitorEpochMachine(initialAuthorization: active)
    guard machine.publish(revoked) == .published else { return false }
    let contamination = "\(directory)/deferred-target-drift-contamination.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/deferred-target-drift-violations.jsonl",
        contaminationPath: contamination)
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000, 30: 3000, 40: 4001][$0] },
        targetValidator: { _ in false })
    let states = Set(decodeJSONLines(ContaminationRecord.self, at: contamination).map(\.state))
    return heartbeat.transitionAcknowledged && heartbeat.contaminationBlocked &&
        states == Set(["blocked_foreground_target_drift"])
}

private func physicalCursorIsObservationalButOtherInputContaminates(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let authorization = testAuthorization(testProducerSet(revision: 1, producers: []))
    let physicalMachine = MonitorEpochMachine(initialAuthorization: authorization)
    physicalMachine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.mouseMoved.rawValue,
        source: testEvidence(0, nil, nil),
        sessionFocus: testEvidence(10, "1000", 100))))
    var physicalWatch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/physical-violations.jsonl",
        contaminationPath: "\(directory)/physical-contamination.jsonl")
    let moved = SystemSample(
        timestamp: 2,
        frontmostPID: 10,
        frontmostBundleIdentifier: desktop.sample.frontmostBundleIdentifier,
        frontmostWindowID: 100,
        cursor: Point(x: 80, y: 90),
        clipboardChangeCount: desktop.sample.clipboardChangeCount,
        clipboardDigest: "",
        peekabooWindowIDs: desktop.sample.peekabooWindowIDs,
        visibleScreenFramesTopLeft: desktop.sample.visibleScreenFramesTopLeft)
    guard let physicalClosure = physicalMachine.closeForHeartbeat() else { return false }
    let physicalHeartbeat = try physicalWatch.observe(
        current: moved,
        phase: "running",
        closure: physicalClosure,
        processIdentity: { $0 == 10 ? 1000 : nil },
        targetValidator: { _ in true })

    let keyMachine = MonitorEpochMachine(initialAuthorization: authorization)
    keyMachine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(0, nil, nil),
        sessionFocus: testEvidence(10, "1000", 100))))
    var keyWatch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: "\(directory)/key-violations.jsonl",
        contaminationPath: "\(directory)/key-contamination.jsonl")
    guard let keyClosure = keyMachine.closeForHeartbeat() else { return false }
    let keyHeartbeat = try keyWatch.observe(
        current: desktop.sample,
        phase: "running",
        closure: keyClosure,
        processIdentity: { $0 == 10 ? 1000 : nil },
        targetValidator: { _ in true })
    return physicalHeartbeat.cursorMovementObserved && !physicalHeartbeat.contaminationBlocked &&
        keyHeartbeat.contaminationBlocked
}

private func bridgePointerEventViolatesBothInputSlots(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let bridge = testProducer(20, "2000")
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge])))
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.mouseMoved.rawValue,
        source: testEvidence(20, "2000", nil),
        sessionFocus: nil)))
    let output = "\(directory)/bridge-pointer-violations.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: "\(directory)/bridge-pointer-contamination.jsonl")
    guard let closure = machine.closeForHeartbeat() else { return false }
    let heartbeat = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { [10: 1000, 20: 2000][$0] },
        targetValidator: { _ in true })
    let kinds = Set(decodeJSONLines(Violation.self, at: output).map(\.kind))
    let keyMachine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [bridge])))
    keyMachine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(20, "2000", nil),
        sessionFocus: nil)))
    let keyOutput = "\(directory)/bridge-key-violations.jsonl"
    var keyWatch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: keyOutput,
        contaminationPath: "\(directory)/bridge-key-contamination.jsonl")
    guard let keyClosure = keyMachine.closeForHeartbeat() else { return false }
    let keyHeartbeat = try keyWatch.observe(
        current: desktop.sample,
        phase: "running",
        closure: keyClosure,
        processIdentity: { [10: 1000, 20: 2000][$0] },
        targetValidator: { _ in true })
    let keyKinds = Set(decodeJSONLines(Violation.self, at: keyOutput).map(\.kind))
    return !heartbeat.contaminationBlocked && !keyHeartbeat.contaminationBlocked &&
        kinds == Set([projection[.physicalCursor], projection[.globalInputEvent]]) &&
        keyKinds == Set([projection[.globalInputEvent]])
}

private func cursorPositionAndProducerPointerRemainDistinct(
    projection: InvariantProjection) -> Bool
{
    let desktop = selfTestDesktop()
    let moved = SystemSample(
        timestamp: desktop.sample.timestamp + 1,
        frontmostPID: desktop.sample.frontmostPID,
        frontmostBundleIdentifier: desktop.sample.frontmostBundleIdentifier,
        frontmostWindowID: desktop.sample.frontmostWindowID,
        cursor: Point(x: desktop.sample.cursor.x + 10, y: desktop.sample.cursor.y),
        clipboardChangeCount: desktop.sample.clipboardChangeCount,
        clipboardDigest: desktop.sample.clipboardDigest,
        peekabooWindowIDs: desktop.sample.peekabooWindowIDs,
        visibleScreenFramesTopLeft: desktop.sample.visibleScreenFramesTopLeft)
    let kinds = Set(violations(
        current: moved,
        context: InvariantEvaluationContext(
            baseline: desktop.sample,
            interactiveBaseline: desktop.baseline,
            allowClipboardMutation: false,
            evaluateInteractiveInvariants: true,
            cursorObservational: false,
            projection: projection)).map(\.kind))
    return kinds == Set([cursorPositionViolationKind]) &&
        !kinds.contains(projection[.physicalCursor])
}

private func unexpectedActivationViolatesFocus(
    directory: String,
    projection: InvariantProjection) throws -> Bool
{
    let desktop = selfTestDesktop()
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [])))
    machine.admitForTesting(.activation(testEvidence(99, "9900", 991)))
    let output = "\(directory)/activation-violations.jsonl"
    var watch = makeSelfTestWatchState(
        desktop: desktop,
        projection: projection,
        outputPath: output,
        contaminationPath: "\(directory)/activation-contamination.jsonl")
    guard let closure = machine.closeForHeartbeat() else { return false }
    _ = try watch.observe(
        current: desktop.sample,
        phase: "running",
        closure: closure,
        processIdentity: { $0 == 10 ? 1000 : nil },
        targetValidator: { _ in true })
    let kinds = Set(decodeJSONLines(Violation.self, at: output).map(\.kind))
    return kinds == Set([projection[.frontmostPID], projection[.frontmostWindow]])
}

private func monitorDigestMatchesNodeContract() -> Bool {
    let object: [String: Any] = [
        "z": [3, ["b": true, "a": NSNull()]],
        "a": "x",
        "n": 1_786_870_761_474,
    ]
    return (try? monitorAggregateSHA256(domain: "monitor-evidence", object: object)) ==
        "69412ce746d97a2445185fddaa4c56f6e33708c904d8ffc012d5982a81839999"
}

private func canonicalBooleanValuesRemainBooleans() -> Bool {
    guard let data = try? canonicalJSONObjectData(["true": true, "false": false]) else { return false }
    return String(data: data, encoding: .utf8) == #"{"false":false,"true":true}"#
}

private func producerLedgerPreservesEquivalentReorder() -> Bool {
    let first = AllowedEventProducerSet(
        revision: 7,
        producers: [testProducer(20, "2000", role: .bridge), testProducer(21, "2100", role: .bridge)],
        foreground: AllowedForegroundActivity(active: false, target: nil))
    let reordered = AllowedEventProducerSet(
        revision: 7,
        producers: Array(first.producers.reversed()),
        foreground: AllowedForegroundActivity(active: false, target: nil))
    let mutated = AllowedEventProducerSet(
        revision: 7,
        producers: [testProducer(20, "2001", role: .bridge), testProducer(21, "2100", role: .bridge)],
        foreground: AllowedForegroundActivity(active: false, target: nil))
    let ledger = MonitorPublicationLedger()
    do {
        try ledger.recordProducerSet(first)
        try ledger.recordProducerSet(reordered)
    } catch {
        return false
    }
    do {
        try ledger.recordProducerSet(mutated)
        return false
    } catch {
        return ledger.producerSet(revision: 7) == first
    }
}

private func sealCutoffDrainsPreCutoffAdmissions() -> Bool {
    let machine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [])))
    let pending = machine.reserveForTesting()
    guard machine.beginSealCutoff(), !machine.finishSealCutoff() else { return false }
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(20, "2000", nil),
        sessionFocus: nil)))
    guard machine.pendingEvidenceCountForTesting() == 1 else { return false }
    guard machine.completeForTesting(
        pending,
        with: .activation(testEvidence(10, "1000", 100)))
    else { return false }
    guard let closure = machine.closeForHeartbeat(),
          closure.epochs.flatMap(\.events).count == 1,
          machine.finishSealCutoff()
    else { return false }
    for _ in 0..<100 {
        machine.admitForTesting(.input(InputEventEvidence(
            type: CGEventType.keyDown.rawValue,
            source: testEvidence(20, "2000", nil),
            sessionFocus: nil)))
    }
    return machine.pendingEvidenceCountForTesting() == 0
}

private func ownerPrivateReadRejectsLinksAndPathSwap() throws -> Bool {
    let directory = "\(NSTemporaryDirectory())pbr-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let original = "\(directory)/original"
    let hardlink = "\(directory)/hardlink"
    let symlinkPath = "\(directory)/symlink"
    try writeOwnerPrivateData(Data("original".utf8), to: original)
    guard link(original, hardlink) == 0 else { return false }
    let hardlinkRefused: Bool
    do {
        _ = try readOwnerPrivateFile(original)
        hardlinkRefused = false
    } catch {
        hardlinkRefused = true
    }
    unlink(hardlink)
    guard symlink(original, symlinkPath) == 0 else { return false }
    let symlinkRefused: Bool
    do {
        _ = try readOwnerPrivateFile(symlinkPath)
        symlinkRefused = false
    } catch {
        symlinkRefused = true
    }
    let replacement = "\(directory)/replacement"
    try writeOwnerPrivateData(Data("replacement".utf8), to: replacement)
    let swapRefused: Bool
    do {
        _ = try readOwnerPrivateFile(original, afterOpen: {
            guard rename(replacement, original) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        })
        swapRefused = false
    } catch {
        swapRefused = true
    }
    return hardlinkRefused && symlinkRefused && swapRefused
}

private func testHeartbeat(
    sequence: UInt64,
    authorizationEpoch: UInt64,
    revision: UInt64,
    commitment: String,
    monotonic: UInt64? = nil,
    wall: Int64? = nil) -> WatchHeartbeat
{
    WatchHeartbeat(
        sequence: sequence,
        monotonicMicroseconds: monotonic ?? sequence * 10000,
        wallClockMilliseconds: wall ?? 1_786_870_761_000 + Int64(sequence * 10),
        lastCleanSequence: sequence,
        contaminationRetries: 0,
        contaminationBlocked: false,
        inputAttributionAvailable: true,
        allowedProducerRevision: revision,
        phase: sequence < 3 ? "setup" : (sequence < 6 ? "running" : "complete"),
        cursorMovementObserved: false,
        pendingActivationCount: 0,
        pendingFocusedWindowChange: false,
        authorizationEpoch: authorizationEpoch,
        transitionAcknowledged: false,
        foregroundActive: false,
        foregroundTargetPID: nil,
        foregroundTargetWindowID: nil,
        attributedForegroundEventCount: 0,
        attributedForegroundSourcePIDs: [],
        foregroundActivityObserved: false,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        historyCommitmentSHA256: commitment)
}

private func integerClockExtremesFailClosed() -> Bool {
    let commitment = String(repeating: "b", count: 64)
    let baseline = testHeartbeat(sequence: 1, authorizationEpoch: 1, revision: 1, commitment: commitment)
    let unsafe = testHeartbeat(
        sequence: 2,
        authorizationEpoch: 2,
        revision: 1,
        commitment: commitment,
        monotonic: UInt64.max,
        wall: Int64.max)
    let backward = testHeartbeat(
        sequence: 2,
        authorizationEpoch: 2,
        revision: 1,
        commitment: commitment,
        monotonic: baseline.monotonicMicroseconds - 1,
        wall: baseline.wallClockMilliseconds)
    return !monitorClockStepIsConsistent(previous: baseline, current: unsafe) &&
        !monitorClockStepIsConsistent(previous: baseline, current: backward)
}

private func monitorSealIsRunBoundAndOwned() throws -> Bool {
    let directory = "\(NSTemporaryDirectory())pbs-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let baseline = selfTestDesktop().sample
    let initialCommitment = String(repeating: "b", count: 64)
    let historyCommitment = String(repeating: "e", count: 64)
    let monitor = try currentMonitorProcessReceipt()
    let producerSets = (1...3).map { revision in
        AllowedEventProducerSet(
            revision: UInt64(revision),
            producers: [testProducer(20, "2000", role: .bridge)],
            foreground: AllowedForegroundActivity(active: false, target: nil))
    }
    let baseHeartbeats = (1...6).map { value in
        testHeartbeat(
            sequence: UInt64(value),
            authorizationEpoch: UInt64(value),
            revision: value < 2 ? 1 : (value < 5 ? 2 : 3),
            commitment: initialCommitment)
    }
    func populatedLedger() throws -> MonitorPublicationLedger {
        let value = MonitorPublicationLedger()
        for producerSet in producerSets {
            try value.recordProducerSet(producerSet)
        }
        for heartbeat in baseHeartbeats {
            value.record(heartbeat)
        }
        return value
    }
    let ledger = try populatedLedger()
    let names = [
        "baseline-stable", "grant-stable", "operations-start",
        "operations-complete", "revoke-stable", "final-stable",
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let fenceRows: [[String: Any]] = try zip(names, baseHeartbeats).enumerated().map { index, entry in
        let heartbeat = index == names.indices.last
            ? entry.1.withHistoryCommitmentSHA256(historyCommitment)
            : entry.1
        let object = try JSONSerialization.jsonObject(with: encoder.encode(heartbeat))
        return ["name": entry.0, "heartbeat": object]
    }
    let socketPath = "\(directory)/attestation.sock"
    let evidence: [String: Any] = try [
        "version": 1,
        "execution_nonce": selfTestExecutionNonce,
        "monitor_instance_id": selfTestMonitorInstanceID,
        "monitor_source_sha256": String(repeating: "1", count: 64),
        "coordinator_source_sha256": String(repeating: "2", count: 64),
        "monitor_process": [
            "pid": monitor.pid,
            "start_identity": monitor.startIdentity,
            "code_signature_hash": monitor.codeSignatureHash,
        ],
        "monitor_attestation_socket_path": socketPath,
        "sentinel": ["pid": 10, "start_identity": "1000", "window_id": 100],
        "foreground_controller": [
            "pid": 30,
            "start_identity": "3000",
            "code_signature_hash": String(repeating: "3", count: 40),
        ],
        "foreground_target": ["pid": 40, "start_identity": "4000", "window_id": 400],
        "producer_sets": [
            "baseline": JSONSerialization.jsonObject(with: encoder.encode(producerSets[0])),
            "grant": JSONSerialization.jsonObject(with: encoder.encode(producerSets[1])),
            "revoke": JSONSerialization.jsonObject(with: encoder.encode(producerSets[2])),
        ],
        "fences": fenceRows,
        "baseline_sample": monitorSampleProjection(baseline),
        "final_sample": monitorSampleProjection(baseline),
        "foreground_plan": [:],
        "violation_records": [],
        "contamination_records": [],
        "baseline_commitment_sha256": initialCommitment,
        "history_commitment_sha256": historyCommitment,
        "crash_evidence": [:],
        "restoration": [:],
    ]
    let draftPath = "\(directory)/draft.json"
    let sealedPath = "\(directory)/sealed.json"
    let requestPath = "\(directory)/request.json"
    let receiptPath = "\(directory)/receipt.json"
    let heartbeatPath = "\(directory)/heartbeat.json"
    let violationsPath = "\(directory)/violations.jsonl"
    let contaminationPath = "\(directory)/contamination.jsonl"
    try writeOwnerPrivateData(Data(), to: violationsPath)
    try writeOwnerPrivateData(Data(), to: contaminationPath)
    try writeOwnerPrivateData(
        JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
        to: draftPath)
    let request = MonitorSealRequest(
        version: 1,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        phase: "seal",
        draftPath: draftPath,
        sealedPath: sealedPath,
        historyCommitmentSHA256: historyCommitment)
    try writeOwnerPrivateData(encoder.encode(request), to: requestPath)
    let blockedSealedPath = "\(directory)/blocked-sealed.json"
    let blockedRequestPath = "\(directory)/blocked-request.json"
    let blockedReceiptPath = "\(directory)/blocked-receipt.json"
    let blockedHeartbeatPath = "\(directory)/blocked-heartbeat.json"
    try writeOwnerPrivateData(Data("occupied".utf8), to: blockedSealedPath)
    let blockedRequest = MonitorSealRequest(
        version: 1,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        phase: "seal",
        draftPath: draftPath,
        sealedPath: blockedSealedPath,
        historyCommitmentSHA256: historyCommitment)
    try writeOwnerPrivateData(encoder.encode(blockedRequest), to: blockedRequestPath)
    let blockedLedger = try populatedLedger()
    let blockedConfiguration = MonitorSealConfiguration(
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        requestPath: blockedRequestPath,
        sealedEvidencePath: blockedSealedPath,
        attestationEvidencePath: blockedSealedPath,
        receiptPath: blockedReceiptPath,
        attestationSocketPath: socketPath,
        heartbeatPath: blockedHeartbeatPath,
        violationsPath: violationsPath,
        contaminationPath: contaminationPath,
        baseline: baseline,
        initialCommitmentSHA256: initialCommitment,
        monitor: monitor)
    var blockedAttempts = 0
    for _ in 0..<2 {
        do {
            _ = try sealMonitorEvidenceIfRequested(
                configuration: blockedConfiguration,
                ledger: blockedLedger,
                finalSampleProvider: { baseline })
        } catch {
            blockedAttempts += 1
        }
    }
    guard blockedAttempts == 2,
          blockedLedger.sealedDigest() == nil,
          try readOwnerPrivateFile(blockedSealedPath) == Data("occupied".utf8)
    else { return false }
    let lateSealedPath = "\(directory)/late-sealed.json"
    let lateRequestPath = "\(directory)/late-request.json"
    let lateReceiptPath = "\(directory)/late-receipt.json"
    let lateHeartbeatPath = "\(directory)/late-heartbeat.json"
    let lateRequest = MonitorSealRequest(
        version: 1,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        phase: "seal",
        draftPath: draftPath,
        sealedPath: lateSealedPath,
        historyCommitmentSHA256: historyCommitment)
    try writeOwnerPrivateData(encoder.encode(lateRequest), to: lateRequestPath)
    let lateLedger = try populatedLedger()
    let lateMachine = MonitorEpochMachine(initialAuthorization: testAuthorization(testProducerSet(
        revision: 1,
        producers: [])))
    let latePending = lateMachine.reserveForTesting()
    let lateDesktop = selfTestDesktop()
    let lateProjection = InvariantProjection(names: InvariantSlot.allCases.map { "late-\($0.rawValue)" })
    var lateWatch = makeSelfTestWatchState(
        desktop: lateDesktop,
        projection: lateProjection,
        outputPath: "\(directory)/late-violations.jsonl",
        contaminationPath: "\(directory)/late-contamination.jsonl",
        physicalInputObservational: false,
        evidenceLedger: lateLedger)
    let lateConfiguration = MonitorSealConfiguration(
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        requestPath: lateRequestPath,
        sealedEvidencePath: lateSealedPath,
        attestationEvidencePath: lateSealedPath,
        receiptPath: lateReceiptPath,
        attestationSocketPath: socketPath,
        heartbeatPath: lateHeartbeatPath,
        violationsPath: violationsPath,
        contaminationPath: contaminationPath,
        baseline: baseline,
        initialCommitmentSHA256: initialCommitment,
        monitor: monitor)
    var cutoffCalls = 0
    var cutoffDrained = false
    do {
        _ = try sealMonitorEvidenceIfRequested(
            configuration: lateConfiguration,
            ledger: lateLedger,
            prepareForSeal: {
                cutoffCalls += 1
                guard lateMachine.beginSealCutoff(),
                      !lateMachine.finishSealCutoff(),
                      lateMachine.pendingEvidenceCountForTesting() == 1
                else {
                    throw ProbeError.invalidArguments("seal cutoff did not retain its pre-cutoff admission")
                }
                lateMachine.admitForTesting(.input(InputEventEvidence(
                    type: CGEventType.keyDown.rawValue,
                    source: testEvidence(98, "9800", nil),
                    sessionFocus: nil)))
                guard lateMachine.pendingEvidenceCountForTesting() == 1,
                      lateMachine.completeForTesting(
                          latePending,
                          with: .input(InputEventEvidence(
                              type: CGEventType.keyDown.rawValue,
                              source: testEvidence(99, "9900", nil),
                              sessionFocus: nil))),
                      let closure = lateMachine.closeForHeartbeat()
                else {
                    throw ProbeError.invalidArguments("seal cutoff lost its pre-cutoff callback")
                }
                _ = try lateWatch.observe(
                    current: lateDesktop.sample,
                    phase: "complete",
                    closure: closure,
                    processIdentity: { [10: 1000, 99: 9900][$0] },
                    targetValidator: { _ in true })
                guard lateMachine.finishSealCutoff() else {
                    throw ProbeError.invalidArguments("seal cutoff did not finish after draining callback evidence")
                }
                cutoffDrained = true
            },
            finalSampleProvider: { baseline })
        return false
    } catch {
        // The late callback must invalidate the seal before any output is published.
    }
    let lateRecords = lateLedger.evidenceRecords()
    guard cutoffCalls == 1,
          cutoffDrained,
          lateRecords.violations.isEmpty,
          lateRecords.contaminations.count == 1,
          lateLedger.sealedDigest() == nil,
          !FileManager.default.fileExists(atPath: lateSealedPath),
          !FileManager.default.fileExists(atPath: lateReceiptPath)
    else { return false }
    let configuration = MonitorSealConfiguration(
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        requestPath: requestPath,
        sealedEvidencePath: sealedPath,
        attestationEvidencePath: sealedPath,
        receiptPath: receiptPath,
        attestationSocketPath: socketPath,
        heartbeatPath: heartbeatPath,
        violationsPath: violationsPath,
        contaminationPath: contaminationPath,
        baseline: baseline,
        initialCommitmentSHA256: initialCommitment,
        monitor: monitor)
    guard try sealMonitorEvidenceIfRequested(
        configuration: configuration,
        ledger: ledger,
        finalSampleProvider: { baseline })
    else { return false }
    let sealedData = try readOwnerPrivateFile(sealedPath)
    let sealedObject = try JSONSerialization.jsonObject(with: sealedData)
    let receipt = try JSONDecoder().decode(
        MonitorSealReceipt.self,
        from: readOwnerPrivateFile(receiptPath))
    let finalHeartbeat = try JSONDecoder().decode(
        WatchHeartbeat.self,
        from: readOwnerPrivateFile(heartbeatPath))
    let expectedDigest = try monitorAggregateSHA256(domain: "monitor-evidence", object: evidence)
    return sameJSONObject(sealedObject, evidence) &&
        receipt.monitorEvidenceSHA256 == expectedDigest &&
        finalHeartbeat == baseHeartbeats[5].withHistoryCommitmentSHA256(historyCommitment) &&
        ledger.sealedDigest() == receipt.monitorEvidenceSHA256
}

private func monitorAttestationServerIsPeerPIDCompatible() throws -> Bool {
    let socketDirectory = "\(NSTemporaryDirectory())pba-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: socketDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: socketDirectory) }
    let socketPath = "\(socketDirectory)/a.sock"
    let ledger = MonitorPublicationLedger()
    let digest = String(repeating: "c", count: 64)
    try ledger.seal(digest: digest)
    let monitor = try currentMonitorProcessReceipt()
    let server = try MonitorAttestationServer(
        socketPath: socketPath,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        monitor: monitor,
        ledger: ledger)
    server.start()
    defer { server.stop() }
    for _ in 0..<100 {
        var info = stat()
        if lstat(socketPath, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK {
            break
        }
        usleep(1000)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = try unixSocketAddress(path: socketPath)
    let addressLength = socklen_t(address.sun_len)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, addressLength)
        }
    }
    guard connected == 0 else { return false }
    var peerPID = pid_t()
    var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
    guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0,
          peerPID == getpid()
    else { return false }
    let challenge = String(repeating: "d", count: 64)
    try writeSocketJSON(
        MonitorAttestationRequest(
            version: 1,
            executionNonce: selfTestExecutionNonce,
            monitorInstanceID: selfTestMonitorInstanceID,
            challenge: challenge),
        descriptor: descriptor)
    let responseData = try readSocketJSONLine(descriptor, maximumBytes: 64 * 1024)
    let object = try JSONSerialization.jsonObject(with: responseData)
    guard let dictionary = object as? [String: Any], Set(dictionary.keys) == [
        "version", "execution_nonce", "monitor_instance_id", "challenge", "monitor",
        "monitor_evidence_sha256",
    ] else { return false }
    let response = try JSONDecoder().decode(MonitorAttestationResponse.self, from: responseData)
    return response.version == 1 &&
        response.executionNonce == selfTestExecutionNonce &&
        response.monitorInstanceID == selfTestMonitorInstanceID &&
        response.challenge == challenge &&
        response.monitor == monitor &&
        response.monitorEvidenceSHA256 == digest
}

private func socketReadDeadlineIsWholeMessage() -> Bool {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { return false }
    let reader = descriptors[0]
    let writer = descriptors[1]
    var noSignal: Int32 = 1
    _ = setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        for byte in Array("{\"slow\":true}".utf8) {
            var value = byte
            if Darwin.write(writer, &value, 1) != 1 {
                break
            }
            usleep(20000)
        }
        close(writer)
        finished.signal()
    }
    let started = DispatchTime.now().uptimeNanoseconds
    let refused: Bool
    do {
        _ = try readSocketJSONLine(reader, maximumBytes: 1024, timeoutMilliseconds: 60)
        refused = false
    } catch {
        refused = true
    }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    close(reader)
    _ = finished.wait(timeout: .now() + .seconds(1))

    var unterminated = [Int32](repeating: -1, count: 2)
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &unterminated) == 0 else { return false }
    var byte = UInt8(ascii: "{")
    _ = Darwin.write(unterminated[1], &byte, 1)
    shutdown(unterminated[1], SHUT_WR)
    let eofRefused: Bool
    do {
        _ = try readSocketJSONLine(unterminated[0], maximumBytes: 1024, timeoutMilliseconds: 100)
        eofRefused = false
    } catch {
        eofRefused = true
    }
    close(unterminated[0])
    close(unterminated[1])
    return refused && elapsed < 200_000_000 && eofRefused
}

private func stoppingServerTerminatesActiveClient() throws -> Bool {
    let directory = "\(NSTemporaryDirectory())pbstop-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let ledger = MonitorPublicationLedger()
    try ledger.seal(digest: String(repeating: "f", count: 64))
    let server = try MonitorAttestationServer(
        socketPath: "\(directory)/a.sock",
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        monitor: currentMonitorProcessReceipt(),
        ledger: ledger)
    server.start()
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = try unixSocketAddress(path: "\(directory)/a.sock")
    let addressLength = socklen_t(address.sun_len)
    let connected = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(descriptor, $0, addressLength)
        }
    }
    guard connected == 0 else {
        server.stop()
        return false
    }
    for _ in 0..<100 where !server.hasActiveClient() {
        usleep(1000)
    }
    guard server.hasActiveClient() else {
        server.stop()
        return false
    }
    server.stop()
    var event = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
    return poll(&event, 1, 500) > 0
}

private func attestationServerSurvivesEarlyClientClose() throws -> Bool {
    let directory = "\(NSTemporaryDirectory())pbclose-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: directory) }
    let socketPath = "\(directory)/a.sock"
    let ledger = MonitorPublicationLedger()
    let digest = String(repeating: "f", count: 64)
    try ledger.seal(digest: digest)
    let server = try MonitorAttestationServer(
        socketPath: socketPath,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        monitor: currentMonitorProcessReceipt(),
        ledger: ledger)
    server.start()
    defer { server.stop() }
    func connectClient() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var address = try unixSocketAddress(path: socketPath)
        let length = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
    let request = MonitorAttestationRequest(
        version: 1,
        executionNonce: selfTestExecutionNonce,
        monitorInstanceID: selfTestMonitorInstanceID,
        challenge: String(repeating: "a", count: 64))
    let early = try connectClient()
    try writeSocketJSON(request, descriptor: early)
    var resetLinger = linger(l_onoff: 1, l_linger: 0)
    _ = setsockopt(early, SOL_SOCKET, SO_LINGER, &resetLinger, socklen_t(MemoryLayout<linger>.size))
    close(early)
    for _ in 0..<200 where server.hasActiveClient() {
        usleep(1000)
    }

    let retry = try connectClient()
    defer { close(retry) }
    try writeSocketJSON(request, descriptor: retry)
    let responseData = try readSocketJSONLine(retry, maximumBytes: 64 * 1024)
    let response = try JSONDecoder().decode(MonitorAttestationResponse.self, from: responseData)
    return response.challenge == request.challenge && response.monitorEvidenceSHA256 == digest
}

private func runSelfTest() throws {
    let projection = InvariantProjection(names: InvariantSlot.allCases.map { "slot-\($0.rawValue)" })
    let desktop = selfTestDesktop()
    let testDirectory = "\(NSTemporaryDirectory())peekaboo-monitor-epoch-\(UUID().uuidString)"
    try FileManager.default.createDirectory(
        atPath: testDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: testDirectory) }

    let baselineContext = InvariantEvaluationContext(
        baseline: desktop.sample,
        interactiveBaseline: desktop.baseline,
        allowClipboardMutation: false,
        evaluateInteractiveInvariants: true,
        cursorObservational: false,
        projection: projection)
    guard violations(current: desktop.sample, context: baselineContext).isEmpty else {
        throw ProbeError.invalidArguments("equal samples must not produce violations")
    }
    guard InputEventTracker.validateMonitoredEventMask() else {
        throw ProbeError.invalidArguments("input event mask does not cover the complete public input family")
    }
    guard producerReceiptSchemaIsLossless() else {
        throw ProbeError.invalidArguments("producer receipt schema lost default roles or decimal identities")
    }
    guard monitorDigestMatchesNodeContract() else {
        throw ProbeError.invalidArguments("monitor evidence digest differs from the Node canonical contract")
    }
    guard canonicalBooleanValuesRemainBooleans() else {
        throw ProbeError.invalidArguments("canonical JSON reclassified Boolean values as numbers")
    }
    guard producerLedgerPreservesEquivalentReorder() else {
        throw ProbeError.invalidArguments("producer ledger rejected an idempotent reorder or accepted drift")
    }
    guard sealCutoffDrainsPreCutoffAdmissions() else {
        throw ProbeError.invalidArguments("terminal seal cutoff lost or admitted callback evidence")
    }
    guard integerClockExtremesFailClosed() else {
        throw ProbeError.invalidArguments("monitor clock arithmetic accepted an unsafe or backward step")
    }
    guard try ownerPrivateReadRejectsLinksAndPathSwap() else {
        throw ProbeError.invalidArguments("owner-private monitor reads accepted a link or path swap")
    }
    guard try monitorSealIsRunBoundAndOwned() else {
        throw ProbeError.invalidArguments("monitor did not seal its exact in-memory run corpus")
    }
    guard try monitorAttestationServerIsPeerPIDCompatible() else {
        throw ProbeError.invalidArguments("monitor attestation is not kernel peer-PID compatible")
    }
    guard socketReadDeadlineIsWholeMessage() else {
        throw ProbeError.invalidArguments("attestation slow-drip or unterminated input did not fail closed")
    }
    guard try stoppingServerTerminatesActiveClient() else {
        throw ProbeError.invalidArguments("stopping the attestation server left an active client blocked")
    }
    guard try attestationServerSurvivesEarlyClientClose() else {
        throw ProbeError.invalidArguments("an early-closing attestation client terminated the server")
    }
    guard foregroundAuthorizationSchemaIsStrict() else {
        throw ProbeError.invalidArguments("foreground authorization schema accepted an invalid role or target")
    }
    guard recordPublishDrainIsLinearizable() else {
        throw ProbeError.invalidArguments("concurrent record, publish, and drain lost or relabeled evidence")
    }
    guard suspendedSamplingDoesNotHoldPublicationLock() else {
        throw ProbeError.invalidArguments("slow evidence sampling held the publication or heartbeat lock")
    }
    guard reservedAdmissionsCloseOnlyAfterCompletion() else {
        throw ProbeError.invalidArguments("reserved evidence was lost, emitted early, or relabeled after publication")
    }
    guard exactPublicationCutoffIsClosed() else {
        throw ProbeError.invalidArguments("events at the publication cutoff did not retain exact epochs")
    }
    guard acknowledgementWriteOwnsAdmissionCutoff() else {
        throw ProbeError.invalidArguments("acknowledgement publication did not own the admission cutoff")
    }
    guard sealedPreAcknowledgementBucketsBlockPublication() else {
        throw ProbeError.invalidArguments("sealed pre-acknowledgement evidence did not block publication")
    }
    guard acknowledgementGateRequiresNextCallbackTurn() else {
        throw ProbeError.invalidArguments("acknowledgement did not wait for the next callback turn")
    }
    guard stableMonitoringDoesNotRequireIdleBarrier() else {
        throw ProbeError.invalidArguments("stable monitoring incorrectly required a callback idle barrier")
    }
    guard finalIdleBarrierDefersQueuedEvidence() else {
        throw ProbeError.invalidArguments("final idle barrier did not defer queued callback evidence")
    }
    guard try transitionHeartbeatRetainsPendingEvidence(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("pending transition heartbeat evidence was discarded")
    }
    guard acknowledgementPreparationFailureRemainsObservable() else {
        throw ProbeError.invalidArguments("acknowledgement preparation failure terminated observability")
    }
    guard notificationEvidenceIsCapturedAtAdmission() else {
        throw ProbeError.invalidArguments("notification evidence was resampled after callback admission")
    }
    guard processWindowEvidenceRejectsGenerationABA() else {
        throw ProbeError.invalidArguments("process/window evidence accepted generation ABA")
    }
    guard idleBarrierDrainsQueuedCallbacksBeforePublication() else {
        throw ProbeError.invalidArguments("run-loop idle barrier relabeled a queued callback")
    }
    guard try sampleDrainCloseRetainsCallbackEvidence(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("system sample callback evidence crossed the epoch cutoff")
    }
    guard revisionsRequireAcknowledgement() else {
        throw ProbeError.invalidArguments("authorization revisions bypassed acknowledgement gating")
    }
    guard equalRevisionRequiresExactPayload() else {
        throw ProbeError.invalidArguments("equal revision reorder/mutation semantics were not fail-closed")
    }
    guard queuedGrantEraEventsRetainAuthorization() else {
        throw ProbeError.invalidArguments("grant-era evidence was relabeled after retarget or revoke")
    }
    guard observerLifecycleIsBarrierBound() else {
        throw ProbeError.invalidArguments("focus observer install/remove barrier contract failed")
    }
    guard try transitionAcknowledgementNeverAdvancesClean(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("transition acknowledgement advanced the clean sequence")
    }
    guard try preAcknowledgementForegroundActivityFailsClosed(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("foreground activity was credited before grant acknowledgement")
    }
    guard try acknowledgementPublicationCutoffIsClosed(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("pending evidence crossed the acknowledgement publication cutoff")
    }
    guard transitionSamplingUsesAcknowledgedAuthorization() else {
        throw ProbeError.invalidArguments("transition sampling used an unacknowledged authorization")
    }
    guard try queuedGrantEraEvidenceIsNeitherDroppedNorRelabeled(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("queued grant-era focus or controller evidence was lost or relabeled")
    }
    guard try foregroundActivityIsRevisionScoped(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("foreground activity leaked into a later authorization revision")
    }
    guard try productionRevisionReplayFailsClosed(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("production revision replay handling did not fail closed")
    }
    guard productionRevisionBeforeAckDoesNotPrepareObserver() else {
        throw ProbeError.invalidArguments("unacknowledged revision prepared an unaccepted focus observer")
    }
    guard productionIdempotentRevisionIsAllowedBeforeAck() else {
        throw ProbeError.invalidArguments("idempotent current revision was rejected before acknowledgement")
    }
    guard acknowledgementRevalidatesControllerAndTargetLiveness() else {
        throw ProbeError.invalidArguments("acknowledgement accepted stale controller or target liveness")
    }
    guard acknowledgementRevalidatesAfterObserverReconciliation() else {
        throw ProbeError.invalidArguments("post-reconciliation liveness drift was acknowledged")
    }
    guard try pendingAcknowledgementEvidenceDrainsBeforePublication(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("pending acknowledgement evidence did not drain before publication")
    }
    guard try wrongWindowThenTargetStillViolates(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("wrong-window callback collapsed into a later target callback")
    }
    guard try authorizedForegroundEvidenceIsClean(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("exact foreground controller/focus evidence was not credited")
    }
    guard try currentTargetDriftFailsClosed(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("current target generation/window drift did not fail closed")
    }
    guard try controllerGenerationDriftFailsClosed(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("recycled foreground controller did not fail closed")
    }
    guard try idleProducerGenerationDriftFailsClosed(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("idle producer generation drift advanced a clean heartbeat")
    }
    guard try focusNotificationGenerationDriftFailsClosed(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("focus notification generation drift did not fail closed")
    }
    guard try deferredTargetDriftFailsClosed(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("deferred target generation/window drift did not fail closed")
    }
    guard try physicalCursorIsObservationalButOtherInputContaminates(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("physical cursor and unrelated input policies were conflated")
    }
    guard try bridgePointerEventViolatesBothInputSlots(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("producer pointer input did not violate its dedicated invariant")
    }
    guard cursorPositionAndProducerPointerRemainDistinct(projection: projection) else {
        throw ProbeError.invalidArguments("cursor position drift was conflated with producer pointer input")
    }
    guard try unexpectedActivationViolatesFocus(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("unexpected activation did not retain callback-time focus evidence")
    }

    try writeJSON(SelfTestResult(success: true, tests: 57), to: nil)
}

private func findApp(arguments: [String]) throws {
    guard let bundleIdentifier = argument("--bundle-id", in: arguments) else {
        throw ProbeError.invalidArguments("find-app requires --bundle-id")
    }
    guard let app = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == bundleIdentifier && !$0.isTerminated
    }) else {
        throw ProbeError.invalidArguments("controlled app is not running: \(bundleIdentifier)")
    }
    try writeJSON(
        AppIdentity(
            bundleIdentifier: bundleIdentifier,
            pid: app.processIdentifier,
            isActive: app.isActive),
        to: argument("--output", in: arguments))
}

private func writeProcessIdentity(arguments: [String]) throws {
    guard let value = argument("--pid", in: arguments),
          let pid = Int32(value),
          let startIdentity = processStartIdentity(pid: pid)
    else {
        throw ProbeError.invalidArguments("process-identity requires a live positive --pid")
    }
    try writeJSON(
        ProcessIdentity(pid: pid, startIdentity: String(startIdentity)),
        to: argument("--output", in: arguments))
}

private func writeProcessExecutable(arguments: [String]) throws {
    guard let value = argument("--pid", in: arguments),
          let pid = Int32(value),
          let startIdentity = processStartIdentity(pid: pid)
    else {
        throw ProbeError.invalidArguments("process-executable requires a live positive --pid")
    }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else {
        throw ProbeError.invalidArguments("process-executable could not resolve the executable path")
    }
    let executablePath = String(cString: buffer)
    let executableData = try Data(contentsOf: URL(fileURLWithPath: executablePath), options: .mappedIfSafe)
    let digest = SHA256.hash(data: executableData).map { String(format: "%02x", $0) }.joined()
    guard processStartIdentity(pid: pid) == startIdentity else {
        throw ProbeError.invalidArguments("process-executable generation changed while hashing")
    }
    try writeJSON(
        ProcessExecutable(
            pid: pid,
            startIdentity: String(startIdentity),
            path: executablePath,
            sha256: digest),
        to: argument("--output", in: arguments))
}

private func writeProcessExecutableIdentity(arguments: [String]) throws {
    guard let value = argument("--pid", in: arguments),
          let pid = Int32(value),
          let startIdentity = processStartIdentity(pid: pid)
    else {
        throw ProbeError.invalidArguments("process-executable-identity requires a live positive --pid")
    }
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0,
          processStartIdentity(pid: pid) == startIdentity
    else {
        throw ProbeError.invalidArguments("process-executable-identity generation changed while resolving")
    }
    try writeJSON(
        ProcessExecutableIdentity(
            pid: pid,
            startIdentity: String(startIdentity),
            path: String(cString: buffer)),
        to: argument("--output", in: arguments))
}

private func clockSample() -> ClockSample {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = mach_continuous_time()
    let nanoseconds = Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    return ClockSample(
        wallTime: Date().timeIntervalSince1970,
        monotonicSeconds: nanoseconds / 1_000_000_000)
}

private func runIgnoringTermination() -> Never {
    signal(SIGTERM, SIG_IGN)
    while true {
        pause()
    }
}

private struct SelfTestResult: Encodable {
    let success: Bool
    let tests: Int
}

private struct MonitorDigestResult: Encodable {
    let monitorEvidenceSHA256: String

    private enum CodingKeys: String, CodingKey {
        case monitorEvidenceSHA256 = "monitor_evidence_sha256"
    }
}

private func writeMonitorEvidenceV2Digest(arguments: [String]) throws {
    guard let inputPath = argument("--input", in: arguments) else {
        throw ProbeError.invalidArguments("monitor-evidence-v2-digest requires one integer-only --input corpus")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: inputPath), options: .mappedIfSafe)
    let digest = try monitorAggregateSHA256(domain: "monitor-evidence", jsonData: data)
    try writeJSON(MonitorDigestResult(monitorEvidenceSHA256: digest), to: argument("--output", in: arguments))
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else {
        throw ProbeError.invalidArguments(
            "expected sample, clock, watch, find-app, process-identity, process-executable, " +
                "process-executable-identity, monitor-evidence-v2-digest, ignore-term, or self-test")
    }
    switch mode {
    case "sample":
        try writeJSON(
            sample(includeClipboardDigest: !arguments.contains("--no-clipboard-digest")),
            to: argument("--output", in: arguments))
    case "clock":
        try writeJSON(clockSample(), to: argument("--output", in: arguments))
    case "watch":
        try runWatch(arguments: arguments)
    case "find-app":
        try findApp(arguments: arguments)
    case "process-identity":
        try writeProcessIdentity(arguments: arguments)
    case "process-executable":
        try writeProcessExecutable(arguments: arguments)
    case "process-executable-identity":
        try writeProcessExecutableIdentity(arguments: arguments)
    case "monitor-evidence-v2-digest":
        try writeMonitorEvidenceV2Digest(arguments: arguments)
    case "ignore-term":
        runIgnoringTermination()
    case "self-test":
        try runSelfTest()
    default:
        throw ProbeError.invalidArguments("unknown mode: \(mode)")
    }
} catch {
    FileHandle.standardError.write(Data("background-computer-use-probe: \(error)\n".utf8))
    exit(2)
}
