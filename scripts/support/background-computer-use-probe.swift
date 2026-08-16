import AppKit
import ApplicationServices
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

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
    var frontmostPID: Int32?
    var frontmostWindowID: UInt32?
    var cursor: Point
}

private struct InvariantEvaluationContext {
    let baseline: SystemSample
    let interactiveBaseline: InteractiveBaseline
    let allowClipboardMutation: Bool
    let evaluateInteractiveInvariants: Bool
    let cursorObservational: Bool
    let projection: InvariantProjection
}

private struct InputEventBatch {
    let producerEventCount: Int
    let producerSourcePIDs: [Int32]
    let producerEventTypes: [UInt32]
    let externalEventCount: Int
    let externalSourcePIDs: [Int32]
    let externalEventTypes: [UInt32]
    let attributionFailed: Bool
}

private func physicalInputIsObservational(_ batch: InputEventBatch, enabled: Bool) -> Bool {
    enabled && batch.externalEventCount > 0 && batch.externalSourcePIDs == [0] &&
        batch.externalEventTypes == [CGEventType.mouseMoved.rawValue]
}

private struct AllowedEventProducer: Codable, Hashable {
    let pid: Int32
    let startIdentity: String
}

private struct AllowedEventProducerSet: Codable {
    let revision: UInt64
    let producers: [AllowedEventProducer]
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

    private let lock = NSLock()
    private var allowedProducerPIDs = Set<Int32>()
    private var producerEventCount = 0
    private var producerSourcePIDs = Set<Int32>()
    private var producerEventTypes = Set<UInt32>()
    private var externalEventCount = 0
    private var externalSourcePIDs = Set<Int32>()
    private var externalEventTypes = Set<UInt32>()
    private var attributionFailed = false
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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
            self.lock.lock()
            self.attributionFailed = true
            self.lock.unlock()
            if let eventTap = self.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return
        }

        let sourcePIDValue = event.getIntegerValueField(.eventSourceUnixProcessID)
        let sourcePID = sourcePIDValue > 0 && sourcePIDValue <= Int64(Int32.max)
            ? Int32(sourcePIDValue)
            : 0
        self.lock.lock()
        if self.allowedProducerPIDs.contains(sourcePID) {
            self.producerEventCount += 1
            self.producerSourcePIDs.insert(sourcePID)
            self.producerEventTypes.insert(type.rawValue)
            self.lock.unlock()
            return
        }
        if self.externalSourcePIDs.count >= 128, !self.externalSourcePIDs.contains(sourcePID) {
            self.attributionFailed = true
            self.lock.unlock()
            return
        }
        self.externalEventCount += 1
        self.externalSourcePIDs.insert(sourcePID)
        self.externalEventTypes.insert(type.rawValue)
        self.lock.unlock()
    }

    func updateAllowedProducerPIDs(_ pids: Set<Int32>) {
        self.lock.lock()
        self.allowedProducerPIDs = pids
        self.lock.unlock()
    }

    func drain() -> InputEventBatch {
        self.lock.lock()
        let producerEventCount = self.producerEventCount
        let producerSourcePIDs = self.producerSourcePIDs.sorted()
        let producerEventTypes = self.producerEventTypes.sorted()
        let externalEventCount = self.externalEventCount
        let externalSourcePIDs = self.externalSourcePIDs.sorted()
        let externalEventTypes = self.externalEventTypes.sorted()
        let attributionFailed = self.attributionFailed
        self.producerEventCount = 0
        self.producerSourcePIDs.removeAll(keepingCapacity: true)
        self.producerEventTypes.removeAll(keepingCapacity: true)
        self.externalEventCount = 0
        self.externalSourcePIDs.removeAll(keepingCapacity: true)
        self.externalEventTypes.removeAll(keepingCapacity: true)
        self.attributionFailed = false
        self.lock.unlock()
        return InputEventBatch(
            producerEventCount: producerEventCount,
            producerSourcePIDs: producerSourcePIDs,
            producerEventTypes: producerEventTypes,
            externalEventCount: externalEventCount,
            externalSourcePIDs: externalSourcePIDs,
            externalEventTypes: externalEventTypes,
            attributionFailed: attributionFailed)
    }
}

private final class ActivationTracker {
    private let baselinePID: Int32?
    private let lock = NSLock()
    private var activatedPIDs = Set<Int32>()
    private var observer: (any NSObjectProtocol)?

    init(baselinePID: Int32?) {
        self.baselinePID = baselinePID
    }

    func start() {
        self.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil)
        { [weak self] notification in
            guard let self,
                  let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != self.baselinePID
            else {
                return
            }
            self.lock.lock()
            self.activatedPIDs.insert(app.processIdentifier)
            self.lock.unlock()
        }
    }

    func drain() -> [Int32] {
        self.lock.lock()
        defer { self.lock.unlock() }
        let pids = self.activatedPIDs.sorted()
        self.activatedPIDs.removeAll(keepingCapacity: true)
        return pids
    }

    func stop() {
        if let observer = self.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        self.observer = nil
    }
}

private final class FocusedWindowTracker {
    private let pid: Int32
    private let lock = NSLock()
    private var changed = false
    private var observer: AXObserver?
    private var applicationElement: AXUIElement?

    init(pid: Int32) {
        self.pid = pid
    }

    func start() throws {
        var observer: AXObserver?
        guard AXObserverCreate(self.pid, focusedWindowObserverCallback, &observer) == .success,
              let observer
        else {
            throw ProbeError.focusedWindowObserverUnavailable
        }
        let applicationElement = AXUIElementCreateApplication(self.pid)
        guard AXObserverAddNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()) == .success
        else {
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
        self.lock.lock()
        self.changed = true
        self.lock.unlock()
    }

    func drain() -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        let changed = self.changed
        self.changed = false
        return changed
    }

    func stop() {
        guard let observer = self.observer, let applicationElement = self.applicationElement else { return }
        AXObserverRemoveNotification(
            observer,
            applicationElement,
            kAXFocusedWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .commonModes)
        self.observer = nil
        self.applicationElement = nil
    }
}

private let focusedWindowObserverCallback: AXObserverCallback = { _, _, _, context in
    guard let context else { return }
    Unmanaged<FocusedWindowTracker>.fromOpaque(context).takeUnretainedValue().recordChange()
}

private let inputEventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
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
                expected: context.interactiveBaseline.frontmostPID.map(String.init) ?? "null",
                actual: current.frontmostPID.map(String.init) ?? "null"))
        }
        if current.frontmostWindowID != context.interactiveBaseline.frontmostWindowID {
            result.insert(Violation(
                kind: context.projection[.frontmostWindow],
                expected: context.interactiveBaseline.frontmostWindowID.map(String.init) ?? "null",
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

private func producerInputViolation(
    batch: InputEventBatch,
    projection: InvariantProjection) -> Violation?
{
    guard batch.producerEventCount > 0 else { return nil }
    let sources = batch.producerSourcePIDs.map(String.init).joined(separator: ",")
    let types = batch.producerEventTypes.map(String.init).joined(separator: ",")
    return Violation(
        kind: projection[.globalInputEvent],
        expected: "no session-global input events",
        actual: "pids=\(sources); types=\(types)")
}

private func producerEventsMatchReceipts(
    batch: InputEventBatch,
    receipts: [Int32: String],
    processIdentity: (Int32) -> UInt64?) -> Bool
{
    batch.producerSourcePIDs.allSatisfy { pid in
        guard let expected = receipts[pid], let current = processIdentity(pid) else { return false }
        return expected == String(current)
    }
}

private func transientFocusViolations(
    externalEventCount: Int,
    unexpectedActivations: [Int32],
    focusedWindowChanged: Bool,
    baseline: InteractiveBaseline,
    projection: InvariantProjection) -> Set<Violation>
{
    guard externalEventCount == 0 else { return [] }
    var result = Set<Violation>()
    if !unexpectedActivations.isEmpty {
        result.insert(Violation(
            kind: projection[.frontmostPID],
            expected: baseline.frontmostPID.map(String.init) ?? "null",
            actual: "transient activations: \(unexpectedActivations.map(String.init).joined(separator: ","))"))
    }
    if focusedWindowChanged {
        result.insert(Violation(
            kind: projection[.frontmostWindow],
            expected: baseline.frontmostWindowID.map(String.init) ?? "null",
            actual: "transient focused-window change"))
    }
    return result
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
    private var allowedProducerRevision: UInt64?
    private var allowedProducerReceipts: [Int32: String] = [:]
    private var pendingActivations: [Int32] = []
    private var pendingFocusedWindowChange = false
    private var cursorMovementObserved = false

    mutating func applyProducerSet(
        _ producerSet: AllowedEventProducerSet,
        to tracker: InputEventTracker) throws
    {
        guard self.allowedProducerRevision != producerSet.revision else { return }
        let producerPIDs = producerSet.producers.map(\.pid)
        let validatedPIDs = Set(producerSet.producers.compactMap { producer -> Int32? in
            guard let currentStartIdentity = processStartIdentity(pid: producer.pid),
                  producer.startIdentity == String(currentStartIdentity)
            else {
                return nil
            }
            return producer.pid
        })
        guard validatedPIDs.count == producerSet.producers.count,
              Set(producerPIDs).count == producerPIDs.count
        else {
            try self.block(
                reason: "blocked_producer_identity",
                sourcePIDs: producerSet.producers.map(\.pid).sorted(),
                eventTypes: [],
                attributionFailed: true,
                countsRetry: false)
            return
        }
        tracker.updateAllowedProducerPIDs(validatedPIDs)
        self.allowedProducerReceipts = Dictionary(uniqueKeysWithValues: producerSet.producers.map {
            ($0.pid, $0.startIdentity)
        })
        self.allowedProducerRevision = producerSet.revision
    }

    mutating func observe(
        current: SystemSample,
        phase: String,
        inputBatch: InputEventBatch,
        unexpectedActivations: [Int32],
        focusedWindowChanged: Bool) throws -> WatchHeartbeat
    {
        if abs(current.cursor.x - self.interactiveBaseline.cursor.x) > 0.5 ||
            abs(current.cursor.y - self.interactiveBaseline.cursor.y) > 0.5
        {
            self.cursorMovementObserved = true
        }
        let deferredActivations = self.pendingActivations
        let deferredFocusedWindowChange = self.pendingFocusedWindowChange
        self.pendingActivations = unexpectedActivations
        self.pendingFocusedWindowChange = focusedWindowChanged

        if inputBatch.attributionFailed {
            try self.block(
                reason: "blocked_attribution",
                sourcePIDs: [],
                eventTypes: [],
                attributionFailed: true,
                countsRetry: false)
        }
        let producerEventsValid = producerEventsMatchReceipts(
            batch: inputBatch,
            receipts: self.allowedProducerReceipts,
            processIdentity: processStartIdentity(pid:))
        if !producerEventsValid {
            try self.block(
                reason: "blocked_producer_generation_drift",
                sourcePIDs: inputBatch.producerSourcePIDs,
                eventTypes: inputBatch.producerEventTypes,
                attributionFailed: true,
                countsRetry: false)
        }
        let observesPhysicalInput = physicalInputIsObservational(
            inputBatch,
            enabled: self.physicalInputObservational)
        if inputBatch.externalEventCount > 0, !observesPhysicalInput {
            try self.block(
                reason: phase == "setup" ? "blocked_setup_attempt" : "blocked_active_attempt",
                sourcePIDs: inputBatch.externalSourcePIDs,
                eventTypes: inputBatch.externalEventTypes,
                attributionFailed: false,
                countsRetry: true)
        }
        let externalInputPermitsEvaluation = observesPhysicalInput || inputBatch.externalEventCount == 0
        let evaluateInteractive = externalInputPermitsEvaluation &&
            unexpectedActivations.isEmpty && !focusedWindowChanged && self.inputAttributionAvailable &&
            self.contaminationState.permitsInteractiveEvaluation
        let context = InvariantEvaluationContext(
            baseline: self.baseline,
            interactiveBaseline: self.interactiveBaseline,
            allowClipboardMutation: self.allowClipboardMutation,
            evaluateInteractiveInvariants: evaluateInteractive,
            cursorObservational: self.cursorObservational,
            projection: self.projection)
        var currentViolations = violations(current: current, context: context)
        if self.contaminationState.permitsInteractiveEvaluation {
            currentViolations.formUnion(transientFocusViolations(
                externalEventCount: observesPhysicalInput ? 0 : inputBatch.externalEventCount,
                unexpectedActivations: deferredActivations,
                focusedWindowChanged: deferredFocusedWindowChange,
                baseline: self.interactiveBaseline,
                projection: self.projection))
        }
        if producerEventsValid,
           let inputViolation = producerInputViolation(batch: inputBatch, projection: self.projection)
        {
            currentViolations.insert(inputViolation)
        }
        for violation in currentViolations.subtracting(self.recorded) {
            try appendJSONLine(violation, to: self.outputPath)
            self.recorded.insert(violation)
        }

        self.sequence += 1
        if evaluateInteractive {
            self.lastCleanSequence = self.sequence
        }
        return WatchHeartbeat(
            sequence: self.sequence,
            timestamp: current.timestamp,
            lastCleanSequence: self.lastCleanSequence,
            contaminationRetries: self.contaminationRetries,
            contaminationBlocked: self.contaminationState.blocked,
            inputAttributionAvailable: self.inputAttributionAvailable,
            allowedProducerRevision: self.allowedProducerRevision ?? 0,
            phase: phase,
            cursorMovementObserved: self.cursorMovementObserved,
            pendingActivationCount: self.pendingActivations.count,
            pendingFocusedWindowChange: self.pendingFocusedWindowChange)
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
    FileManager.default.createFile(atPath: outputPath, contents: nil)
    FileManager.default.createFile(atPath: contaminationOutputPath, contents: nil)

    let inputTracker = InputEventTracker()
    try inputTracker.start()
    let activationTracker = ActivationTracker(baselinePID: baseline.frontmostPID)
    activationTracker.start()
    guard let baselinePID = baseline.frontmostPID else {
        throw ProbeError.focusedWindowObserverUnavailable
    }
    let focusedWindowTracker = FocusedWindowTracker(pid: baselinePID)
    try focusedWindowTracker.start()
    defer {
        focusedWindowTracker.stop()
        activationTracker.stop()
        inputTracker.stop()
    }

    var watchState = WatchState(
        baseline: baseline,
        interactiveBaseline: InteractiveBaseline(
            frontmostPID: baseline.frontmostPID,
            frontmostWindowID: baseline.frontmostWindowID,
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
        let current = try sample(includeClipboardDigest: false)
        let producerData = try Data(contentsOf: URL(fileURLWithPath: allowedProducersPath))
        let allowedProducerSet = try JSONDecoder().decode(AllowedEventProducerSet.self, from: producerData)
        try watchState.applyProducerSet(allowedProducerSet, to: inputTracker)
        let phase = try String(contentsOfFile: phasePath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["setup", "running", "complete"].contains(phase) else {
            throw ProbeError.invalidArguments("watch phase must be setup, running, or complete")
        }
        let inputBatch = inputTracker.drain()
        let unexpectedActivations = activationTracker.drain()
        let heartbeat = try watchState.observe(
            current: current,
            phase: phase,
            inputBatch: inputBatch,
            unexpectedActivations: unexpectedActivations,
            focusedWindowChanged: focusedWindowTracker.drain())
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
        decoded.producers.first?.startIdentity == "987654321"
}

private func physicalInputPolicyIsSafe() -> Bool {
    let physicalBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 1,
        externalSourcePIDs: [0],
        externalEventTypes: [CGEventType.mouseMoved.rawValue],
        attributionFailed: false)
    let processBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 1,
        externalSourcePIDs: [4242],
        externalEventTypes: [CGEventType.keyDown.rawValue],
        attributionFailed: false)
    let physicalKeyBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 1,
        externalSourcePIDs: [0],
        externalEventTypes: [CGEventType.keyDown.rawValue],
        attributionFailed: false)
    let physicalClickBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 1,
        externalSourcePIDs: [0],
        externalEventTypes: [CGEventType.leftMouseDown.rawValue],
        attributionFailed: false)
    let physicalScrollBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 1,
        externalSourcePIDs: [0],
        externalEventTypes: [CGEventType.scrollWheel.rawValue],
        attributionFailed: false)
    let mixedPhysicalBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 2,
        externalSourcePIDs: [0],
        externalEventTypes: [CGEventType.mouseMoved.rawValue, CGEventType.keyDown.rawValue],
        attributionFailed: false)
    let unattributedBatch = InputEventBatch(
        producerEventCount: 0,
        producerSourcePIDs: [],
        producerEventTypes: [],
        externalEventCount: 1,
        externalSourcePIDs: [],
        externalEventTypes: [CGEventType.keyDown.rawValue],
        attributionFailed: false)
    return physicalInputIsObservational(physicalBatch, enabled: true) &&
        !physicalInputIsObservational(physicalKeyBatch, enabled: true) &&
        !physicalInputIsObservational(physicalClickBatch, enabled: true) &&
        !physicalInputIsObservational(physicalScrollBatch, enabled: true) &&
        !physicalInputIsObservational(mixedPhysicalBatch, enabled: true) &&
        !physicalInputIsObservational(processBatch, enabled: true) &&
        !physicalInputIsObservational(unattributedBatch, enabled: true) &&
        !physicalInputIsObservational(physicalBatch, enabled: false)
}

private func runSelfTest() throws {
    let projection = InvariantProjection(names: InvariantSlot.allCases.map { "slot-\($0.rawValue)" })
    let baseline = SystemSample(
        timestamp: 1,
        frontmostPID: 101,
        frontmostBundleIdentifier: "com.apple.calculator",
        frontmostWindowID: 201,
        cursor: Point(x: 50, y: 60),
        clipboardChangeCount: 3,
        clipboardDigest: "digest",
        peekabooWindowIDs: [301],
        visibleScreenFramesTopLeft: [Rectangle(x: 0, y: 0, width: 800, height: 600)])

    let interactiveBaseline = InteractiveBaseline(
        frontmostPID: baseline.frontmostPID,
        frontmostWindowID: baseline.frontmostWindowID,
        cursor: baseline.cursor)
    let baselineContext = InvariantEvaluationContext(
        baseline: baseline,
        interactiveBaseline: interactiveBaseline,
        allowClipboardMutation: false,
        evaluateInteractiveInvariants: true,
        cursorObservational: false,
        projection: projection)
    guard violations(current: baseline, context: baselineContext).isEmpty
    else {
        throw ProbeError.invalidArguments("equal samples must not produce violations")
    }

    let changed = SystemSample(
        timestamp: 2,
        frontmostPID: 102,
        frontmostBundleIdentifier: nil,
        frontmostWindowID: 202,
        cursor: Point(x: 51, y: 60),
        clipboardChangeCount: 4,
        clipboardDigest: "different",
        peekabooWindowIDs: [301, 302],
        visibleScreenFramesTopLeft: baseline.visibleScreenFramesTopLeft)
    let kinds = Set(violations(
        current: changed,
        context: InvariantEvaluationContext(
            baseline: baseline,
            interactiveBaseline: interactiveBaseline,
            allowClipboardMutation: false,
            evaluateInteractiveInvariants: true,
            cursorObservational: false,
            projection: projection)).map(\.kind))
    let expected = Set(projection.names).subtracting([projection[.globalInputEvent]])
    guard kinds == expected else {
        throw ProbeError.invalidArguments("self-test violation mismatch: \(kinds)")
    }
    let allowedKinds = Set(violations(
        current: changed,
        context: InvariantEvaluationContext(
            baseline: baseline,
            interactiveBaseline: interactiveBaseline,
            allowClipboardMutation: true,
            evaluateInteractiveInvariants: true,
            cursorObservational: false,
            projection: projection)).map(\.kind))
    guard !allowedKinds.contains(projection[.clipboardChangeCount]) else {
        throw ProbeError.invalidArguments("clipboard mutation allowance was ignored")
    }

    let contaminatedKinds = Set(violations(
        current: changed,
        context: InvariantEvaluationContext(
            baseline: baseline,
            interactiveBaseline: interactiveBaseline,
            allowClipboardMutation: false,
            evaluateInteractiveInvariants: false,
            cursorObservational: false,
            projection: projection)).map(\.kind))
    guard !contaminatedKinds.contains(projection[.frontmostPID]),
          !contaminatedKinds.contains(projection[.frontmostWindow]),
          !contaminatedKinds.contains(projection[.physicalCursor]),
          contaminatedKinds.contains(projection[.clipboardChangeCount]),
          contaminatedKinds.contains(projection[.peekabooOverlayWindow])
    else {
        throw ProbeError.invalidArguments("contaminated samples weakened fixed desktop invariants")
    }

    var contaminationState = AttemptContaminationState()
    contaminationState.observe(externalInput: true, attributionFailed: false)
    contaminationState.observe(externalInput: false, attributionFailed: false)
    guard contaminationState.blocked, !contaminationState.permitsInteractiveEvaluation else {
        throw ProbeError.invalidArguments("contamination did not remain sticky for the attempt")
    }

    let producerBatch = InputEventBatch(
        producerEventCount: 1,
        producerSourcePIDs: [getpid()],
        producerEventTypes: [CGEventType.mouseMoved.rawValue],
        externalEventCount: 0,
        externalSourcePIDs: [],
        externalEventTypes: [],
        attributionFailed: false)
    guard producerInputViolation(batch: producerBatch, projection: projection)?.kind ==
        projection[.globalInputEvent]
    else {
        throw ProbeError.invalidArguments("global producer input was not retained as an invariant violation")
    }
    guard physicalInputPolicyIsSafe() else {
        throw ProbeError.invalidArguments("only hardware-origin cursor motion may be observational")
    }
    guard let selfIdentity = processStartIdentity(pid: getpid()),
          producerEventsMatchReceipts(
              batch: producerBatch,
              receipts: [getpid(): String(selfIdentity)],
              processIdentity: processStartIdentity(pid:)),
          !producerEventsMatchReceipts(
              batch: producerBatch,
              receipts: [getpid(): String(selfIdentity &+ 1)],
              processIdentity: processStartIdentity(pid:))
    else {
        throw ProbeError.invalidArguments("producer event generation receipts did not fail closed")
    }
    guard InputEventTracker.validateMonitoredEventMask() else {
        throw ProbeError.invalidArguments("input event mask does not cover the complete public input family")
    }
    guard producerReceiptSchemaIsLossless() else {
        throw ProbeError.invalidArguments("producer start identities must decode as lossless decimal strings")
    }
    let transientKinds = Set(transientFocusViolations(
        externalEventCount: 0,
        unexpectedActivations: [102],
        focusedWindowChanged: true,
        baseline: interactiveBaseline,
        projection: projection).map(\.kind))
    guard transientKinds == Set([projection[.frontmostPID], projection[.frontmostWindow]]),
          transientFocusViolations(
              externalEventCount: 1,
              unexpectedActivations: [102],
              focusedWindowChanged: true,
              baseline: interactiveBaseline,
              projection: projection).isEmpty
    else {
        throw ProbeError.invalidArguments("transient focus attribution did not distinguish external input")
    }

    let cursorObservationalKinds = Set(violations(
        current: changed,
        context: InvariantEvaluationContext(
            baseline: baseline,
            interactiveBaseline: interactiveBaseline,
            allowClipboardMutation: false,
            evaluateInteractiveInvariants: true,
            cursorObservational: true,
            projection: projection)).map(\.kind))
    guard !cursorObservationalKinds.contains(projection[.physicalCursor]),
          cursorObservationalKinds.contains(projection[.frontmostPID]),
          cursorObservationalKinds.contains(projection[.frontmostWindow])
    else {
        throw ProbeError.invalidArguments("observational cursor mode weakened focus invariants")
    }

    try writeJSON(SelfTestResult(success: true, tests: 14), to: nil)
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
