import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Dispatch
import Foundation
import Synchronization

// The shell harness compiles this standalone probe directly; its deterministic contracts stay in the same source.
// swiftlint:disable file_length

@_silgen_name("_AXUIElementGetWindow")
private func copyProbeAXWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

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

private struct WatchHeartbeat: Codable {
    let sequence: UInt64
    let timestamp: Double
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
}

private struct ContaminationRecord: Codable {
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
}

private struct AllowedEventProducerSet: Codable, Equatable, Sendable {
    let revision: UInt64
    let producers: [AllowedEventProducer]
    let foreground: AllowedForegroundActivity?

    var effectiveForeground: AllowedForegroundActivity {
        self.foreground ?? AllowedForegroundActivity(active: false, target: nil)
    }

    func hasExactlyEquivalentPayload(to other: AllowedEventProducerSet) -> Bool {
        self.producers.count == other.producers.count &&
            Set(self.producers) == Set(other.producers) &&
            self.foreground == other.foreground
    }
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

private struct MonitorEpoch: Equatable, Sendable {
    let serial: UInt64
    let authorization: MonitorAuthorization
    let lowerAdmissionCutoff: UInt64
    let transitionBarrier: Bool
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
        self.epochs.contains { $0.epoch.transitionBarrier }
    }

    func appending(_ other: MonitorEpochClosure) -> MonitorEpochClosure {
        MonitorEpochClosure(epochs: self.epochs + other.epochs)
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
}

/// The one publication/admission authority for input, activation, and focus callbacks.
/// A callback samples evidence while holding this cutoff, so it can only land wholly
/// before or wholly after a policy publication.
private final class MonitorEpochMachine: Sendable {
    private let state: Mutex<MonitorEpochMachineState>

    init(initialAuthorization: MonitorAuthorization) {
        self.state = Mutex(MonitorEpochMachineState(
            openBucket: MonitorEpochBucket(epoch: MonitorEpoch(
                serial: 1,
                authorization: initialAuthorization,
                lowerAdmissionCutoff: 0,
                transitionBarrier: false))))
    }

    var currentAuthorization: MonitorAuthorization {
        self.state.withLock { $0.openBucket.epoch.authorization }
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
            Self.sealOpenBucket(state: &state)
            state.openBucket = MonitorEpochBucket(epoch: MonitorEpoch(
                serial: state.nextEpochSerial,
                authorization: authorization,
                lowerAdmissionCutoff: state.lastAdmission,
                transitionBarrier: true))
            state.nextEpochSerial += 1
            return .published
        }
    }

    func admitInput(
        type: CGEventType,
        evidence: (MonitorAuthorization) -> (source: ProcessWindowEvidence, sessionFocus: ProcessWindowEvidence?))
    {
        let token = self.reserve()
        let sample = evidence(token.epoch.authorization)
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
                state.openBucket.epoch.transitionBarrier ||
                !state.openBucket.pendingAdmissions.isEmpty ||
                !state.openBucket.events.isEmpty
            if shouldSealOpenBucket {
                Self.sealOpenBucket(state: &state)
                state.openBucket = MonitorEpochBucket(epoch: MonitorEpoch(
                    serial: state.nextEpochSerial,
                    authorization: state.openBucket.epoch.authorization,
                    lowerAdmissionCutoff: state.lastAdmission,
                    transitionBarrier: false))
                state.nextEpochSerial += 1
            }
            return Self.drainCompletedPrefix(state: &state)
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
                processWindowEvidence(
                    pid: pid,
                    windowID: focusedWindowID(pid: pid))
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
            return processWindowEvidence(pid: self.identity.pid, windowID: nil)
        }
        return processWindowEvidence(
            pid: self.identity.pid,
            windowID: focusedWindowID(applicationElement: applicationElement))
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

    func stop() {
        for observer in self.grantedObservers.values {
            try? observer.stop()
        }
        if let baselineObserver = self.baselineObserver {
            try? baselineObserver.stop()
        }
        self.grantedObservers.removeAll()
        self.baselineObserver = nil
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

private func processWindowEvidence(pid: Int32, windowID: UInt32?) -> ProcessWindowEvidence {
    ProcessWindowEvidence(
        pid: pid,
        startIdentity: processStartIdentity(pid: pid).map(String.init),
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
    let source = processWindowEvidence(pid: sourcePID, windowID: nil)
    guard authorization.producersByPID[sourcePID]?.effectiveRole == .foregroundController,
          authorization.target != nil
    else {
        return (source: source, sessionFocus: nil)
    }
    let sessionFocus = NSWorkspace.shared.frontmostApplication.map { app in
        let pid = app.processIdentifier
        return processWindowEvidence(pid: pid, windowID: focusedWindowID(pid: pid))
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
                kind: context.projection[.physicalCursor],
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

private func foregroundTargetIsLive(_ target: AllowedForegroundTarget) -> Bool {
    guard target.pid > 0,
          target.windowID > 0,
          processStartIdentity(pid: target.pid).map(String.init) == target.startIdentity
    else {
        return false
    }
    let windows = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow, .excludeDesktopElements],
        target.windowID) as? [[String: Any]] ?? []
    return windows.contains { window in
        (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == target.pid &&
            (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == target.windowID
    }
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
        if !current.hasExactlyEquivalentPayload(to: producerSet) {
            machine.admitFailure(reason: "blocked_producer_revision_replay")
        }
        return
    }
    guard producerSet.revision > current.revision else {
        machine.admitFailure(reason: "blocked_producer_revision_replay")
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

private func closeMonitorEpoch(
    _ machine: MonitorEpochMachine,
    observers: FocusObserverCoordinator) -> MonitorEpochClosure?
{
    guard var closure = machine.closeForHeartbeat() else { return nil }
    if closure.transitionAcknowledged,
       closure.finalEpoch.epoch.authorization.revision == machine.currentAuthorization.revision
    {
        do {
            try observers.reconcile(activeTarget: closure.finalEpoch.epoch.authorization.target)
        } catch {
            machine.admitFailure(reason: "blocked_focus_observer_removal")
            if let failureClosure = machine.closeForHeartbeat() {
                closure = closure.appending(failureClosure)
            }
        }
    }
    return closure
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
    let authorizations = closure.transitionAcknowledged
        ? closure.epochs.map(\.epoch.authorization)
        : [closure.finalEpoch.epoch.authorization]
    for authorization in authorizations {
        if let target = authorization.target {
            allowed.insert("\(target.pid):\(target.windowID)")
        }
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
    var activationCount = 0
    var focusCount = 0
}

private struct ClosedEpochEvaluation {
    let violations: Set<Violation>
    let permitsInteractiveEvaluation: Bool
    let activationCount: Int
    let focusCount: Int
}

private struct WatchState {
    let baseline: SystemSample
    let interactiveBaseline: InteractiveBaseline
    let allowClipboardMutation: Bool
    let physicalInputObservational: Bool
    let cursorObservational: Bool
    let projection: InvariantProjection
    let outputPath: String
    let contaminationOutputPath: String
    private var recorded = Set<Violation>()
    private var sequence: UInt64 = 0
    private var lastCleanSequence: UInt64 = 0
    private var contaminationRetries = 0
    private var contaminationState = AttemptContaminationState()
    private var inputAttributionAvailable = true
    private var cursorMovementObserved = false
    private var attributedForegroundEventCount = 0
    private var attributedForegroundSourcePIDs = Set<Int32>()
    private var foregroundActivityObserved = false

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
                targetValidator: targetValidator)
            currentViolations.formUnion(evaluation.violations)
            totalActivationCount += evaluation.activationCount
            totalFocusCount += evaluation.focusCount
            allEpochsPermitInteractiveEvaluation = allEpochsPermitInteractiveEvaluation &&
                evaluation.permitsInteractiveEvaluation
        }

        let evaluateInteractive = allEpochsPermitInteractiveEvaluation && self.inputAttributionAvailable &&
            self.contaminationState.permitsInteractiveEvaluation
        let context = InvariantEvaluationContext(
            baseline: self.baseline,
            interactiveBaseline: self.interactiveBaseline,
            allowClipboardMutation: self.allowClipboardMutation,
            evaluateInteractiveInvariants: evaluateInteractive &&
                !closure.finalEpoch.epoch.authorization.foreground.active &&
                !closure.transitionAcknowledged,
            cursorObservational: self.cursorObservational,
            projection: self.projection)
        currentViolations.formUnion(violations(current: current, context: context))
        if evaluateInteractive,
           closure.finalEpoch.epoch.authorization.foreground.active || closure.transitionAcknowledged
        {
            currentViolations.formUnion(currentFocusViolations(
                current: current,
                closure: closure,
                baseline: self.interactiveBaseline,
                projection: self.projection))
            let cursorMoved = abs(current.cursor.x - self.interactiveBaseline.cursor.x) > 0.5 ||
                abs(current.cursor.y - self.interactiveBaseline.cursor.y) > 0.5
            if cursorMoved, !self.cursorObservational {
                currentViolations.insert(Violation(
                    kind: self.projection[.physicalCursor],
                    expected: "\(self.interactiveBaseline.cursor.x),\(self.interactiveBaseline.cursor.y)",
                    actual: "\(current.cursor.x),\(current.cursor.y)"))
            }
        }
        for violation in currentViolations.subtracting(self.recorded) {
            try appendJSONLine(violation, to: self.outputPath)
            self.recorded.insert(violation)
        }

        self.sequence += 1
        if evaluateInteractive, !closure.transitionAcknowledged, currentViolations.isEmpty {
            self.lastCleanSequence = self.sequence
        }
        let finalAuthorization = closure.finalEpoch.epoch.authorization
        return WatchHeartbeat(
            sequence: self.sequence,
            timestamp: current.timestamp,
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
            attributedForegroundEventCount: self.attributedForegroundEventCount,
            attributedForegroundSourcePIDs: self.attributedForegroundSourcePIDs.sorted(),
            foregroundActivityObserved: self.foregroundActivityObserved)
    }

    private mutating func evaluate(
        closedEpoch: ClosedMonitorEpoch,
        phase: String,
        targetValidator: (AllowedForegroundTarget) -> Bool) throws -> ClosedEpochEvaluation
    {
        let authorization = closedEpoch.epoch.authorization
        if let target = authorization.target, !targetValidator(target) {
            try self.block(
                reason: "blocked_foreground_target_drift",
                sourcePIDs: [target.pid],
                eventTypes: [],
                attributionFailed: true,
                countsRetry: false)
        }
        let classification = try self.classify(
            events: closedEpoch.events,
            authorization: authorization)
        var epochViolations = Set<Violation>()
        if !classification.bridgeSources.isEmpty {
            epochViolations.insert(Violation(
                kind: self.projection[.globalInputEvent],
                expected: "no session-global input events",
                actual: "pids=\(classification.bridgeSources.sorted().map(String.init).joined(separator: ",")); " +
                    "types=\(classification.bridgeTypes.sorted().map(String.init).joined(separator: ","))"))
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
                authorization: authorization))
        }
        return ClosedEpochEvaluation(
            violations: epochViolations,
            permitsInteractiveEvaluation: permitsInteractiveEvaluation,
            activationCount: classification.activationCount,
            focusCount: classification.focusCount)
    }

    private mutating func classify(
        events: [MonitorEvent],
        authorization: MonitorAuthorization) throws -> ClosedEpochEventClassification
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
                    authorization: authorization,
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
        authorization: MonitorAuthorization,
        into classification: inout ClosedEpochEventClassification) throws
    {
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
            self.attributedForegroundEventCount += 1
            self.attributedForegroundSourcePIDs.insert(input.source.pid)
            self.foregroundActivityObserved = true
        }
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
        try appendJSONLine(
            ContaminationRecord(
                state: reason,
                retry: self.contaminationRetries,
                sequence: self.sequence + 1,
                sourcePIDs: sourcePIDs,
                eventTypes: eventTypes),
            to: self.contaminationOutputPath)
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
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

private func appendJSONLine(_ value: some Encodable, to path: String) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value) + Data("\n".utf8)
    let url = URL(fileURLWithPath: path)
    if !FileManager.default.fileExists(atPath: path) {
        FileManager.default.createFile(atPath: path, contents: nil)
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

private func runWatch(arguments: [String]) throws -> Never {
    guard let baselinePath = argument("--baseline", in: arguments),
          let outputPath = argument("--output", in: arguments),
          let contaminationOutputPath = argument("--contamination-output", in: arguments),
          let readyPath = argument("--ready", in: arguments),
          let heartbeatPath = argument("--heartbeat", in: arguments),
          let phasePath = argument("--phase", in: arguments),
          let allowedProducersPath = argument("--allowed-producers", in: arguments),
          let invariantNamesJSON = argument("--invariant-names", in: arguments)
    else {
        throw ProbeError.invalidArguments(
            "watch requires baseline/output paths, phase, allowed producers, heartbeat, and invariant names")
    }

    let intervalMilliseconds = Int(argument("--interval-ms", in: arguments) ?? "20") ?? 20
    guard intervalMilliseconds > 0 else {
        throw ProbeError.invalidArguments("watch interval must be valid")
    }
    let allowClipboardMutation = arguments.contains("--allow-clipboard-mutation")
    let physicalInputObservational = arguments.contains("--physical-input-observational")
    let cursorObservational = arguments.contains("--cursor-observational")
    let invariantProjection = try InvariantProjection(json: invariantNamesJSON)
    let baselineData = try Data(contentsOf: URL(fileURLWithPath: baselinePath))
    let baseline = try JSONDecoder().decode(SystemSample.self, from: baselineData)
    guard let baselinePID = baseline.frontmostPID,
          let baselineWindowID = baseline.frontmostWindowID,
          let baselineStartIdentity = processStartIdentity(pid: baselinePID).map(String.init)
    else {
        throw ProbeError.focusedWindowObserverUnavailable
    }
    let initialProducerData = try Data(contentsOf: URL(fileURLWithPath: allowedProducersPath))
    let initialProducerSet = try JSONDecoder().decode(AllowedEventProducerSet.self, from: initialProducerData)
    let initialAuthorization = try makeMonitorAuthorization(initialProducerSet)
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    FileManager.default.createFile(atPath: contaminationOutputPath, contents: nil)

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
    defer {
        focusObservers.stop()
        activationTracker.stop()
        inputTracker.stop()
    }

    var watchState = WatchState(
        baseline: baseline,
        interactiveBaseline: InteractiveBaseline(
            frontmostPID: baselinePID,
            processStartIdentity: baselineStartIdentity,
            frontmostWindowID: baselineWindowID,
            cursor: baseline.cursor),
        allowClipboardMutation: allowClipboardMutation,
        physicalInputObservational: physicalInputObservational,
        cursorObservational: cursorObservational,
        projection: invariantProjection,
        outputPath: outputPath,
        contaminationOutputPath: contaminationOutputPath)
    var firstSample = true
    while true {
        CFRunLoopRunInMode(
            .defaultMode,
            Double(intervalMilliseconds) / 1000,
            true)
        let producerData = try Data(contentsOf: URL(fileURLWithPath: allowedProducersPath))
        let allowedProducerSet = try JSONDecoder().decode(AllowedEventProducerSet.self, from: producerData)
        applyMonitorAuthorization(allowedProducerSet, to: machine, observers: focusObservers)
        guard let closure = closeMonitorEpoch(machine, observers: focusObservers) else {
            continue
        }
        let current = try sample(includeClipboardDigest: false)
        let phase = try String(contentsOfFile: phasePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["setup", "running", "complete"].contains(phase) else {
            throw ProbeError.invalidArguments("watch phase must be setup, running, or complete")
        }
        let heartbeat = try watchState.observe(
            current: current,
            phase: phase,
            closure: closure)
        try writeJSON(
            heartbeat,
            to: heartbeatPath)
        if firstSample {
            try Data("ready\n".utf8).write(to: URL(fileURLWithPath: readyPath), options: .atomic)
            firstSample = false
        }
    }
}

private func producerReceiptSchemaIsLossless() -> Bool {
    let data = Data(#"{"revision":1,"producers":[{"pid":42,"startIdentity":"987654321"}]}"#.utf8)
    guard let decoded = try? JSONDecoder().decode(AllowedEventProducerSet.self, from: data) else { return false }
    return decoded.revision == 1 &&
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
    guard let decoded = try? JSONDecoder().decode(AllowedEventProducerSet.self, from: data),
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
    let elapsed: Duration
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
        let clock = ContinuousClock()
        let start = clock.now
        let publication = machine.publish(second)
        let heartbeatDeferred = machine.closeForHeartbeat() == nil
        capture.store(MonitorAdmissionLatencyResult(
            publication: publication,
            heartbeatDeferred: heartbeatDeferred,
            elapsed: start.duration(to: clock.now)))
        publicationFinished.signal()
    }
    let completedBeforeRelease = publicationFinished.wait(timeout: .now() + .milliseconds(100)) == .success
    releaseSampling.signal()
    guard samplingFinished.wait(timeout: .now() + .seconds(1)) == .success else { return false }
    if !completedBeforeRelease {
        _ = publicationFinished.wait(timeout: .now() + .seconds(1))
        return false
    }
    guard let result = capture.load(),
          result.publication == .published,
          result.heartbeatDeferred,
          result.elapsed < .milliseconds(50),
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
                  $0.epoch.authorization.revision == 2 && $0.epoch.transitionBarrier
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
    return old.epoch.authorization.revision == 1 && old.upperAdmissionCutoff == 1 &&
        old.events.map(\.admission) == [1] &&
        new.epoch.authorization.revision == 2 && new.epoch.lowerAdmissionCutoff == 1 &&
        new.upperAdmissionCutoff == 2 && new.events.map(\.admission) == [2] &&
        closure.transitionAcknowledged
}

private func queuedRevisionsRemainDistinct() -> Bool {
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
    for producerSet in revisions {
        guard machine.publish(testAuthorization(producerSet)) == .published else { return false }
    }
    guard let closure = machine.closeForHeartbeat() else { return false }
    return closure.epochs.map(\.epoch.authorization.revision) == [1, 2, 3, 4, 5] &&
        closure.epochs.dropFirst().allSatisfy(\.epoch.transitionBarrier) &&
        closure.finalEpoch.epoch.authorization.target == nil
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

private func grantRetargetRevokeRetainsEventEpochs() -> Bool {
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
    guard machine.publish(grant) == .published else { return false }
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3000", nil),
        sessionFocus: testEvidence(40, "4000", 401))))
    guard machine.publish(retarget) == .published else { return false }
    machine.admitForTesting(.focus(FocusEventEvidence(
        observer: ProcessGenerationIdentity(pid: 40, startIdentity: "4000"),
        observed: testEvidence(40, "4000", 401))))
    guard machine.publish(revoke) == .published else { return false }
    machine.admitForTesting(.input(InputEventEvidence(
        type: CGEventType.keyDown.rawValue,
        source: testEvidence(30, "3000", nil),
        sessionFocus: testEvidence(40, "4000", 402))))
    guard let closure = machine.closeForHeartbeat() else { return false }
    let events = closure.epochs.flatMap(\.events)
    return events.count == 3 && events.map(\.epoch.authorization.revision) == [2, 3, 4]
}

private enum FakeFocusObserverError: Error {
    case requestedFailure
}

private final class FakeFocusObserverStore {
    var failStart = Set<ProcessGenerationIdentity>()
    var failStop = Set<ProcessGenerationIdentity>()
    var starts = [ProcessGenerationIdentity]()
    var stops = [ProcessGenerationIdentity]()
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
          closeMonitorEpoch(machine, observers: coordinator)?.transitionAcknowledged == true
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
          closeMonitorEpoch(machine, observers: coordinator)?.transitionAcknowledged == true
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
    guard let retargetAcknowledgement = closeMonitorEpoch(machine, observers: coordinator) else { return false }
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
    guard let failedInstallClosure = closeMonitorEpoch(machine, observers: coordinator) else { return false }
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
    guard let failedRemovalClosure = closeMonitorEpoch(machine, observers: coordinator) else { return false }
    return machine.currentAuthorization.revision == 6 && failedRemovalClosure.transitionAcknowledged &&
        coordinator.observedIdentities.contains(secondIdentity) &&
        failedRemovalClosure.epochs.flatMap(\.events).contains(where: {
            if case .attributionFailure(reason: "blocked_focus_observer_removal", process: nil) = $0.kind {
                return true
            }
            return false
        })
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
    cursorObservational: Bool = true) -> WatchState
{
    WatchState(
        baseline: desktop.sample,
        interactiveBaseline: desktop.baseline,
        allowClipboardMutation: false,
        physicalInputObservational: physicalInputObservational,
        cursorObservational: cursorObservational,
        projection: projection,
        outputPath: outputPath,
        contaminationOutputPath: contaminationPath)
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
    guard queuedRevisionsRemainDistinct() else {
        throw ProbeError.invalidArguments("grant, retarget, generation change, or revoke epochs collapsed")
    }
    guard equalRevisionRequiresExactPayload() else {
        throw ProbeError.invalidArguments("equal revision reorder/mutation semantics were not fail-closed")
    }
    guard grantRetargetRevokeRetainsEventEpochs() else {
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
    guard try deferredTargetDriftFailsClosed(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("deferred target generation/window drift did not fail closed")
    }
    guard try physicalCursorIsObservationalButOtherInputContaminates(
        directory: testDirectory,
        projection: projection)
    else {
        throw ProbeError.invalidArguments("physical cursor and unrelated input policies were conflated")
    }
    guard try unexpectedActivationViolatesFocus(directory: testDirectory, projection: projection) else {
        throw ProbeError.invalidArguments("unexpected activation did not retain callback-time focus evidence")
    }

    try writeJSON(SelfTestResult(success: true, tests: 20), to: nil)
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

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard let mode = arguments.first else {
        throw ProbeError.invalidArguments(
            "expected sample, clock, watch, find-app, process-identity, process-executable, " +
                "process-executable-identity, ignore-term, or self-test")
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
