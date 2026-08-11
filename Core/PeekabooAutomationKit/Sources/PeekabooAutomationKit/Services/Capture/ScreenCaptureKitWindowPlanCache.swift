import CoreGraphics
import Foundation
import PeekabooFoundation

/// Short-lived process-local cache for ScreenCaptureKit window capture plans.
///
/// Values contain capture filters/configuration, never captured pixels. Every caller must independently
/// revalidate its exact window receipt and display topology before and after using a cached value.
@MainActor
final class ScreenCaptureKitWindowPlanCache<Value: AnyObject> {
    struct Key: Hashable {
        let windowID: CGWindowID
        let usesNativeScale: Bool
    }

    private struct Entry {
        let value: Value
        let insertedAt: ContinuousClock.Instant
        let sequence: UInt64
    }

    private let timeToLive: Duration
    private let capacity: Int
    private var entries: [Key: Entry] = [:]
    private var nextSequence: UInt64 = 0

    init(timeToLive: Duration = .seconds(2), capacity: Int = 32) {
        self.timeToLive = timeToLive
        self.capacity = max(capacity, 0)
    }

    var count: Int {
        self.entries.count
    }

    var isEmpty: Bool {
        self.entries.isEmpty
    }

    func value(for key: Key, now: ContinuousClock.Instant = .now) -> Value? {
        guard let entry = self.entries[key] else { return nil }
        guard !self.isExpired(entry, now: now) else {
            self.entries.removeValue(forKey: key)
            return nil
        }
        return entry.value
    }

    func insert(_ value: Value, for key: Key, now: ContinuousClock.Instant = .now) {
        guard self.capacity > 0 else { return }
        self.removeExpired(now: now)

        if self.entries[key] == nil, self.entries.count >= self.capacity,
           let oldestKey = self.entries.min(by: { $0.value.sequence < $1.value.sequence })?.key
        {
            self.entries.removeValue(forKey: oldestKey)
        }

        let sequence = self.nextSequence
        self.entries[key] = Entry(
            value: value,
            insertedAt: now,
            sequence: sequence)
        self.nextSequence &+= 1
        self.scheduleExpiration(for: key, sequence: sequence)
    }

    @discardableResult
    func removeValue(for key: Key, ifSameAs expected: Value? = nil) -> Bool {
        guard let stored = self.entries[key] else { return false }
        if let expected, stored.value !== expected {
            return false
        }
        self.entries.removeValue(forKey: key)
        return true
    }

    private func removeExpired(now: ContinuousClock.Instant) {
        self.entries = self.entries.filter { !self.isExpired($0.value, now: now) }
    }

    private func isExpired(_ entry: Entry, now: ContinuousClock.Instant) -> Bool {
        let age = entry.insertedAt.duration(to: now)
        return age >= .zero && age >= self.timeToLive
    }

    private func scheduleExpiration(for key: Key, sequence: UInt64) {
        let timeToLive = self.timeToLive
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeToLive)
            guard let self, self.entries[key]?.sequence == sequence else { return }
            self.entries.removeValue(forKey: key)
        }
    }
}

struct ScreenCaptureDisplayTopology: Equatable {
    struct Display: Equatable {
        let displayID: CGDirectDisplayID
        let bounds: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let rotation: Double
        let isMain: Bool
        let mirrorOwnerDisplayID: CGDirectDisplayID?

        init(
            displayID: CGDirectDisplayID,
            bounds: CGRect,
            pixelWidth: Int,
            pixelHeight: Int,
            rotation: Double,
            isMain: Bool = false,
            mirrorOwnerDisplayID: CGDirectDisplayID? = nil)
        {
            self.displayID = displayID
            self.bounds = bounds
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
            self.rotation = rotation
            self.isMain = isMain
            self.mirrorOwnerDisplayID = mirrorOwnerDisplayID
        }
    }

    let displays: [Display]

    static func current() -> ScreenCaptureDisplayTopology? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return nil
        }
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displayIDs, &count) == .success else {
            return nil
        }

        let displays = displayIDs.prefix(Int(count)).map { displayID in
            let mirroredDisplayID = CGDisplayMirrorsDisplay(displayID)
            return Display(
                displayID: displayID,
                bounds: CGDisplayBounds(displayID),
                pixelWidth: CGDisplayPixelsWide(displayID),
                pixelHeight: CGDisplayPixelsHigh(displayID),
                rotation: CGDisplayRotation(displayID),
                isMain: CGDisplayIsMain(displayID) != 0,
                mirrorOwnerDisplayID: mirroredDisplayID == kCGNullDirectDisplay ? nil : mirroredDisplayID)
        }
        return ScreenCaptureDisplayTopology(displays: displays)
    }

    /// ScreenCaptureKit exposes `SCDisplay.frame` in logical points. Physical pixel dimensions remain
    /// part of the topology fingerprint, but must never be compared with `SCDisplay.width/height`, which
    /// are also point dimensions on current SDKs.
    func containsScreenCaptureKitDisplay(
        displayID: CGDirectDisplayID,
        bounds: CGRect,
        width: Int,
        height: Int) -> Bool
    {
        self.displays.contains {
            $0.displayID == displayID &&
                $0.bounds == bounds &&
                $0.bounds.width == CGFloat(width) &&
                $0.bounds.height == CGFloat(height)
        }
    }

    func display(withID displayID: CGDirectDisplayID) -> Display? {
        self.displays.first { $0.displayID == displayID }
    }
}

struct ScreenCaptureWindowPlanReceipt: Equatable {
    let windowID: CGWindowID
    let ownerProcessIdentifier: pid_t
    let ownerProcessStartIdentity: UInt64
    let bounds: CGRect
    let layer: Int
    let alpha: CGFloat
    let isOnScreen: Bool
    let sharingState: Int?

    /// Bracket a WindowServer row with process-generation reads so a recycled PID cannot be combined
    /// with the earlier process's window fingerprint. CGWindowID has no public incarnation token; same-ID,
    /// same-owner-generation, identical-fingerprint reuse remains the documented platform residual.
    static func current(
        windowID: CGWindowID,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity? = SystemIdentityResolver.windowIdentity,
        processStartIdentityProvider: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity)
        -> ScreenCaptureWindowPlanReceipt?
    {
        SystemIdentityResolver.stableWindowIdentity(
            windowID,
            windowIdentityProvider: windowIdentityProvider,
            processStartIdentityProvider: processStartIdentityProvider).flatMap { self.make(identity: $0) }
    }

    var mutationIdentity: WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: Int(self.windowID),
            ownerProcessIdentifier: self.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.ownerProcessStartIdentity,
            capturedBounds: self.bounds,
            isMinimized: !self.isOnScreen)
    }

    static func make(identity: SystemWindowIdentity) -> ScreenCaptureWindowPlanReceipt? {
        guard let processStartIdentity = identity.ownerProcessStartIdentity else { return nil }
        return ScreenCaptureWindowPlanReceipt(
            windowID: identity.windowID,
            ownerProcessIdentifier: identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            bounds: identity.bounds,
            layer: identity.layer,
            alpha: identity.alpha,
            isOnScreen: identity.isOnScreen,
            sharingState: identity.sharingState?.rawValue)
    }
}

enum ScreenCaptureWindowPlanValidation {
    enum Result: Equatable {
        case matched
        case changed
        case unavailable
    }

    static func result(
        expectedReceipt: ScreenCaptureWindowPlanReceipt,
        expectedTopology: ScreenCaptureDisplayTopology,
        currentReceipt: ScreenCaptureWindowPlanReceipt?,
        currentTopology: ScreenCaptureDisplayTopology?,
        expectedScalePlan: ScreenCaptureScaleResolver.Plan? = nil,
        currentScalePlan: ScreenCaptureScaleResolver.Plan? = nil) -> Result
    {
        guard let currentReceipt, let currentTopology else { return .unavailable }
        guard currentReceipt == expectedReceipt, currentTopology == expectedTopology else { return .changed }
        if let expectedScalePlan {
            guard let currentScalePlan else { return .unavailable }
            guard currentScalePlan == expectedScalePlan else { return .changed }
        }
        return .matched
    }
}

struct ScreenCaptureWindowPlanCacheUnavailableError: Error {}

struct RetrySafeStaleWindowPlanError: Error {
    let terminalError: PeekabooError
}

@MainActor
enum ScreenCaptureWindowPlanExecutor {
    /// Owns the exact plan's one shared recovery budget across cache lookup, construction, and capture.
    /// Cancellation, timeout, permission, quarantine, and raw framework errors are evicted and rethrown
    /// unchanged so the outer capture policy remains their sole retry/fallback owner.
    static func execute<Plan: AnyObject, Output>(
        cachedPlan: () -> Plan?,
        buildPlan: () async throws -> Plan,
        capture: (Plan, CaptureWindowPlanCacheStatus) async throws -> Output,
        validation: (Plan) -> ScreenCaptureWindowPlanValidation.Result,
        evict: (Plan) -> Void) async throws
        -> (output: Output, plan: Plan, cacheStatus: CaptureWindowPlanCacheStatus)
    {
        var candidate = cachedPlan()
        var candidateIsCached = candidate != nil
        var recoveredCachedPlan = false
        var recoveryConsumed = false

        while true {
            let selectedPlan: Plan
            let selectedPlanIsCached: Bool
            do {
                if let candidate {
                    selectedPlan = candidate
                    selectedPlanIsCached = candidateIsCached
                } else {
                    selectedPlan = try await buildPlan()
                    selectedPlanIsCached = false
                }
            } catch let error as RetrySafeStaleWindowPlanError {
                guard !recoveryConsumed else { throw error.terminalError }
                recoveryConsumed = true
                candidate = nil
                candidateIsCached = false
                continue
            }
            candidate = nil
            candidateIsCached = false

            switch validation(selectedPlan) {
            case .matched:
                break
            case .unavailable:
                evict(selectedPlan)
                throw ScreenCaptureWindowPlanCacheUnavailableError()
            case .changed:
                evict(selectedPlan)
                guard !recoveryConsumed else { throw self.repeatedDriftError }
                recoveredCachedPlan = selectedPlanIsCached
                recoveryConsumed = true
                continue
            }

            let cacheStatus: CaptureWindowPlanCacheStatus = if selectedPlanIsCached {
                .hit
            } else if recoveredCachedPlan {
                .rebuilt
            } else {
                .miss
            }
            let output: Output
            do {
                output = try await capture(selectedPlan, cacheStatus)
                try Task.checkCancellation()
            } catch let error as RetrySafeStaleWindowPlanError {
                evict(selectedPlan)
                guard !recoveryConsumed else { throw error.terminalError }
                recoveredCachedPlan = selectedPlanIsCached
                recoveryConsumed = true
                continue
            } catch {
                evict(selectedPlan)
                throw error
            }

            switch validation(selectedPlan) {
            case .matched:
                return (output, selectedPlan, cacheStatus)
            case .unavailable:
                evict(selectedPlan)
                throw ScreenCaptureWindowPlanCacheUnavailableError()
            case .changed:
                evict(selectedPlan)
                guard !recoveryConsumed else { throw self.repeatedDriftError }
                recoveredCachedPlan = selectedPlanIsCached
                recoveryConsumed = true
            }
        }
    }

    private static var repeatedDriftError: PeekabooError {
        .captureFailed("Window or display topology changed repeatedly during exact-window capture")
    }
}
