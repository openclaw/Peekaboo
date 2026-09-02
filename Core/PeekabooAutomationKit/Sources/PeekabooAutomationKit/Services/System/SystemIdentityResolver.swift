import CoreGraphics
import Darwin
import Foundation

public struct SystemWindowIdentity: Sendable, Equatable {
    public let windowID: CGWindowID
    public let ownerProcessIdentifier: pid_t
    public let ownerProcessStartIdentity: UInt64?
    public let title: String
    public let bounds: CGRect
    public let layer: Int
    public let alpha: CGFloat
    public let isOnScreen: Bool
    public let sharingState: WindowSharingState?
    public let applicationName: String?

    public init(
        windowID: CGWindowID,
        ownerProcessIdentifier: pid_t,
        ownerProcessStartIdentity: UInt64? = nil,
        title: String,
        bounds: CGRect,
        layer: Int,
        alpha: CGFloat,
        isOnScreen: Bool,
        sharingState: WindowSharingState?,
        applicationName: String? = nil)
    {
        self.windowID = windowID
        self.ownerProcessIdentifier = ownerProcessIdentifier
        self.ownerProcessStartIdentity = ownerProcessStartIdentity
        self.title = title
        self.bounds = bounds
        self.layer = layer
        self.alpha = alpha
        self.isOnScreen = isOnScreen
        self.sharingState = sharingState
        self.applicationName = applicationName
    }
}

/// Native process/window identity lookups used when a numeric identifier must not silently retarget.
/// PIDs are generation-bound because they are recycled; CGWindowID is Apple's session-scoped
/// WindowServer identifier, with owner generation and bounds retained as fail-closed change evidence.
public enum SystemIdentityResolver {
    enum ProcessStartIdentityObservation: Equatable, Sendable {
        case identity(UInt64)
        case permissionDenied
        case unavailable

        var identity: UInt64? {
            guard case let .identity(identity) = self else { return nil }
            return identity
        }
    }

    struct ProcessCredentials: Equatable, Sendable {
        let processIdentifier: pid_t
        let effectiveUserID: uid_t
    }

    enum ExactWindowCatalogObservation {
        case found([String: Any])
        case absent
        case unreadable
    }

    private struct WindowSafetyFingerprint: Equatable {
        let windowID: CGWindowID
        let ownerProcessIdentifier: pid_t
        let bounds: CGRect
        let layer: Int
        let alpha: CGFloat
        let isOnScreen: Bool
        let sharingState: WindowSharingState?

        init(_ identity: SystemWindowIdentity) {
            self.windowID = identity.windowID
            self.ownerProcessIdentifier = identity.ownerProcessIdentifier
            self.bounds = identity.bounds
            self.layer = identity.layer
            self.alpha = identity.alpha
            self.isOnScreen = identity.isOnScreen
            self.sharingState = identity.sharingState
        }
    }

    struct WindowMutationIdentityProviders {
        let processStartIdentity: (pid_t) -> UInt64?
        let windowIdentity: (CGWindowID) -> SystemWindowIdentity?
        let mutationIdentity: (CGWindowID) -> WindowMutationIdentity?
    }

    struct WindowMutationSnapshot {
        let windowID: CGWindowID
        let ownerProcessIdentifier: pid_t
        let ownerProcessStartIdentity: UInt64
        let bounds: CGRect
        let isMinimized: Bool?
    }

    /// Returns an identity that changes when macOS reuses a numeric process identifier.
    public static func processStartIdentity(_ processIdentifier: pid_t) -> UInt64? {
        self.processStartIdentityObservation(processIdentifier).identity
    }

    static func processStartIdentityObservation(_ processIdentifier: pid_t) -> ProcessStartIdentityObservation {
        guard processIdentifier > 0 else { return .unavailable }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
        errno = 0
        let bytesRead = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            expectedSize)
        let errorCode = errno
        return self.processStartIdentityObservation(info: info, bytesRead: bytesRead, errorCode: errorCode)
    }

    static func processStartIdentityObservation(
        info: proc_bsdinfo,
        bytesRead: Int32,
        errorCode: Int32) -> ProcessStartIdentityObservation
    {
        guard bytesRead == Int32(MemoryLayout<proc_bsdinfo>.stride) else {
            // Only a failed full read with explicit EPERM proves the verified permission-denied path.
            return bytesRead <= 0 && errorCode == EPERM ? .permissionDenied : .unavailable
        }
        let seconds = UInt64(info.pbi_start_tvsec)
        let microseconds = UInt64(info.pbi_start_tvusec)
        return .identity(seconds.multipliedReportingOverflow(by: 1_000_000).partialValue &+ microseconds)
    }

    /// Short BSD supplies credentials only, never a process-generation receipt.
    static func processCredentials(_ processIdentifier: pid_t) -> ProcessCredentials? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdshortinfo()
        let bytesRead = proc_pidinfo(
            processIdentifier,
            PROC_PIDT_SHORTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdshortinfo>.stride))
        return self.processCredentials(processIdentifier, info: info, bytesRead: bytesRead)
    }

    static func processCredentials(
        _ processIdentifier: pid_t,
        info: proc_bsdshortinfo,
        bytesRead: Int32) -> ProcessCredentials?
    {
        guard processIdentifier > 0,
              bytesRead == Int32(MemoryLayout<proc_bsdshortinfo>.stride),
              info.pbsi_pid == UInt32(processIdentifier)
        else { return nil }
        return ProcessCredentials(processIdentifier: processIdentifier, effectiveUserID: info.pbsi_uid)
    }

    /// Resolves one exact window from the current WindowServer catalog without AX traversal.
    public static func windowIdentity(_ windowID: CGWindowID) -> SystemWindowIdentity? {
        guard windowID != kCGNullWindowID else { return nil }
        guard case let .found(window) = self.exactWindowCatalogObservation(
            windowID,
            windowListProvider: { options, relativeToWindow in
                CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]]
            })
        else { return nil }
        return self.windowIdentity(from: window)
    }

    /// Observes one exact WindowServer row without conflating absence with a failed catalog read.
    ///
    /// `optionIncludingWindow` can omit a minimized or off-Space window even while `optionAll`
    /// still carries its exact ID, owner, and frame. The fallback remains ID-only: descriptive
    /// metadata such as title and bounds is never used to select a different entry.
    static func exactWindowCatalogObservation(
        _ windowID: CGWindowID,
        windowListProvider: (CGWindowListOption, CGWindowID) -> [[String: Any]]?)
        -> ExactWindowCatalogObservation
    {
        guard windowID != kCGNullWindowID else { return .absent }

        let exact = windowListProvider([.optionIncludingWindow], windowID)
        if let window = exact.flatMap({ self.exactWindowDictionary(windowID, in: $0) }) {
            return .found(window)
        }

        let all = windowListProvider(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID)
        if let window = all.flatMap({ self.exactWindowDictionary(windowID, in: $0) }) {
            return .found(window)
        }

        return exact != nil && all != nil ? .absent : .unreadable
    }

    /// Captures one generation-bound exact-window identity while allowing descriptive metadata
    /// such as the title or application name to refresh between reads. Those fields do not define
    /// WindowServer identity and must not invalidate a safe capture plan by themselves.
    static func stableWindowIdentity(
        _ windowID: CGWindowID,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity? = SystemIdentityResolver.windowIdentity,
        processStartIdentityProvider: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity)
        -> SystemWindowIdentity?
    {
        guard windowID != kCGNullWindowID,
              let before = windowIdentityProvider(windowID),
              before.windowID == windowID,
              let beforeGeneration = processStartIdentityProvider(before.ownerProcessIdentifier),
              let after = windowIdentityProvider(windowID),
              after.windowID == windowID,
              let afterGeneration = processStartIdentityProvider(after.ownerProcessIdentifier),
              beforeGeneration == afterGeneration,
              WindowSafetyFingerprint(before) == WindowSafetyFingerprint(after)
        else {
            return nil
        }

        return SystemWindowIdentity(
            windowID: after.windowID,
            ownerProcessIdentifier: after.ownerProcessIdentifier,
            ownerProcessStartIdentity: afterGeneration,
            title: after.title,
            bounds: after.bounds,
            layer: after.layer,
            alpha: after.alpha,
            isOnScreen: after.isOnScreen,
            sharingState: after.sharingState,
            applicationName: after.applicationName)
    }

    /// Lists one process's current WindowServer entries in front-to-back order without AX traversal.
    public static func windowIdentities(ownerProcessIdentifier: pid_t) -> [SystemWindowIdentity] {
        guard ownerProcessIdentifier > 0,
              let processStartIdentity = self.processStartIdentity(ownerProcessIdentifier),
              let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
              as? [[String: Any]],
              self.processStartIdentity(ownerProcessIdentifier) == processStartIdentity
        else {
            return []
        }
        return windows.compactMap(self.windowIdentity(from:)).compactMap { identity in
            guard identity.ownerProcessIdentifier == ownerProcessIdentifier else { return nil }
            return SystemWindowIdentity(
                windowID: identity.windowID,
                ownerProcessIdentifier: identity.ownerProcessIdentifier,
                ownerProcessStartIdentity: processStartIdentity,
                title: identity.title,
                bounds: identity.bounds,
                layer: identity.layer,
                alpha: identity.alpha,
                isOnScreen: identity.isOnScreen,
                sharingState: identity.sharingState,
                applicationName: identity.applicationName)
        }
    }

    private static func windowIdentity(from window: [String: Any]) -> SystemWindowIdentity? {
        guard let rawWindowID = intValue(window[kCGWindowNumber as String]),
              let windowID = CGWindowID(exactly: rawWindowID),
              let owner = intValue(window[kCGWindowOwnerPID as String]),
              let processIdentifier = pid_t(exactly: owner),
              processIdentifier > 0,
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
        else {
            return nil
        }
        return SystemWindowIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            title: window[kCGWindowName as String] as? String ?? "",
            bounds: bounds,
            layer: Self.intValue(window[kCGWindowLayer as String]) ?? 0,
            alpha: Self.cgFloatValue(window[kCGWindowAlpha as String]) ?? 1,
            isOnScreen: window[kCGWindowIsOnscreen as String] as? Bool ?? false,
            sharingState: Self.intValue(window[kCGWindowSharingState as String])
                .flatMap(WindowSharingState.init(rawValue:)),
            applicationName: window[kCGWindowOwnerName as String] as? String)
    }

    static func windowIdentity(
        _ windowID: CGWindowID,
        in windows: [[String: Any]]) -> SystemWindowIdentity?
    {
        self.exactWindowDictionary(windowID, in: windows).flatMap(self.windowIdentity(from:))
    }

    private static func exactWindowDictionary(
        _ windowID: CGWindowID,
        in windows: [[String: Any]]) -> [String: Any]?
    {
        windows.first {
            self.intValue($0[kCGWindowNumber as String]) == Int(windowID)
        }
    }

    /// Resolves the current CoreGraphics owner for one exact window identifier.
    /// A missing result means the identifier is not present in the current WindowServer catalog.
    public static func windowOwnerProcessIdentifier(_ windowID: CGWindowID) -> pid_t? {
        self.windowIdentity(windowID)?.ownerProcessIdentifier
    }

    /// Captures one stable exact-window/process-generation receipt.
    public static func windowMutationIdentity(windowID: CGWindowID) -> WindowMutationIdentity? {
        guard let before = self.windowIdentity(windowID),
              let processStartIdentity = self.processStartIdentity(before.ownerProcessIdentifier)
        else {
            return nil
        }
        return self.windowMutationIdentity(
            windowID: windowID,
            expectedOwnerProcessIdentifier: before.ownerProcessIdentifier,
            expectedOwnerProcessStartIdentity: processStartIdentity,
            expectedBounds: before.bounds,
            isMinimized: false)
    }

    /// Creates a receipt only while an earlier local window snapshot still names the live window.
    static func windowMutationIdentity(
        windowID: CGWindowID,
        expectedOwnerProcessIdentifier: pid_t,
        expectedOwnerProcessStartIdentity: UInt64,
        expectedBounds: CGRect,
        isMinimized: Bool?) -> WindowMutationIdentity?
    {
        self.windowMutationIdentity(
            snapshot: WindowMutationSnapshot(
                windowID: windowID,
                ownerProcessIdentifier: expectedOwnerProcessIdentifier,
                ownerProcessStartIdentity: expectedOwnerProcessStartIdentity,
                bounds: expectedBounds,
                isMinimized: isMinimized),
            processStartIdentityProvider: self.processStartIdentity,
            windowIdentityProvider: self.windowIdentity)
    }

    static func windowMutationIdentity(
        snapshot: WindowMutationSnapshot,
        processStartIdentityProvider: (pid_t) -> UInt64?,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?) -> WindowMutationIdentity?
    {
        guard snapshot.windowID != kCGNullWindowID,
              snapshot.ownerProcessIdentifier > 0,
              processStartIdentityProvider(snapshot.ownerProcessIdentifier) == snapshot.ownerProcessStartIdentity,
              let current = windowIdentityProvider(snapshot.windowID),
              current.windowID == snapshot.windowID,
              current.ownerProcessIdentifier == snapshot.ownerProcessIdentifier,
              current.bounds == snapshot.bounds
        else {
            return nil
        }
        return WindowMutationIdentity(
            windowID: Int(snapshot.windowID),
            ownerProcessIdentifier: snapshot.ownerProcessIdentifier,
            ownerProcessStartIdentity: snapshot.ownerProcessStartIdentity,
            capturedBounds: snapshot.bounds,
            isMinimized: snapshot.isMinimized)
    }

    /// Captures an exact AX window receipt when WindowServer omits a minimized entry. If a CG entry
    /// exists it remains authoritative and must match; absence is accepted only for AX-minimized state.
    static func axWindowMutationIdentity(
        snapshot: WindowMutationSnapshot,
        processStartIdentityProvider: (pid_t) -> UInt64?,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?) -> WindowMutationIdentity?
    {
        guard snapshot.windowID != kCGNullWindowID,
              snapshot.ownerProcessIdentifier > 0,
              processStartIdentityProvider(snapshot.ownerProcessIdentifier) == snapshot.ownerProcessStartIdentity
        else {
            return nil
        }
        if let current = windowIdentityProvider(snapshot.windowID) {
            guard current.windowID == snapshot.windowID,
                  current.ownerProcessIdentifier == snapshot.ownerProcessIdentifier,
                  current.bounds == snapshot.bounds
            else {
                return nil
            }
        } else if snapshot.isMinimized != true {
            return nil
        }
        guard processStartIdentityProvider(snapshot.ownerProcessIdentifier) == snapshot.ownerProcessStartIdentity else {
            return nil
        }
        return WindowMutationIdentity(
            windowID: Int(snapshot.windowID),
            ownerProcessIdentifier: snapshot.ownerProcessIdentifier,
            ownerProcessStartIdentity: snapshot.ownerProcessStartIdentity,
            capturedBounds: snapshot.bounds,
            isMinimized: snapshot.isMinimized)
    }

    /// Revalidates only the owner process generation. This is a prerequisite for a bounded AX scan,
    /// not sufficient evidence that a session-scoped window ID still names the captured target because
    /// the public API provides no stronger window-incarnation token.
    public static func validateWindowMutationOwnerGeneration(_ expected: WindowMutationIdentity) -> Bool {
        expected.windowID > 0 &&
            expected.ownerProcessIdentifier > 0 &&
            CGWindowID(exactly: expected.windowID) != nil &&
            self.processStartIdentity(expected.ownerProcessIdentifier) == expected.ownerProcessStartIdentity
    }

    /// Revalidates the exact window owner, owner process generation, and capture-time bounds.
    public static func validateWindowMutationIdentity(_ expected: WindowMutationIdentity) -> Bool {
        guard let capturedBounds = expected.capturedBounds else { return false }
        return self.validateWindowMutationIdentity(expected, expectedBounds: capturedBounds)
    }

    /// Revalidates one capture-time bounds sidecar. Legacy input receipts may still carry the bounds
    /// separately, but when the receipt embeds bounds both sources must agree.
    public static func validateWindowMutationIdentity(
        _ expected: WindowMutationIdentity,
        expectedBounds: CGRect) -> Bool
    {
        guard expected.capturedBounds == nil || expected.capturedBounds == expectedBounds else {
            return false
        }
        return self.validateWindowMutationIdentity(
            expected,
            expectedBounds: expectedBounds,
            processStartIdentityProvider: self.processStartIdentity,
            windowIdentityProvider: self.windowIdentity)
    }

    static func validateWindowMutationIdentity(
        _ expected: WindowMutationIdentity,
        expectedBounds: CGRect,
        processStartIdentityProvider: (pid_t) -> UInt64?,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?) -> Bool
    {
        guard expected.windowID > 0,
              expected.ownerProcessIdentifier > 0,
              let windowID = CGWindowID(exactly: expected.windowID),
              processStartIdentityProvider(expected.ownerProcessIdentifier) == expected.ownerProcessStartIdentity,
              let current = windowIdentityProvider(windowID)
        else {
            return false
        }
        return current.ownerProcessIdentifier == expected.ownerProcessIdentifier && current.bounds == expectedBounds
    }

    /// Repins a completed geometry mutation only when the requested final bounds belong to the
    /// original owner process generation. Callers intentionally discard the old bounds receipt.
    public static func repinWindowMutationIdentity(
        _ expected: WindowMutationIdentity,
        expectedBounds: CGRect,
        tolerance: CGFloat = 1) -> WindowMutationIdentity?
    {
        self.repinWindowMutationIdentity(
            expected,
            expectedBounds: expectedBounds,
            tolerance: tolerance,
            providers: WindowMutationIdentityProviders(
                processStartIdentity: self.processStartIdentity,
                windowIdentity: self.windowIdentity,
                mutationIdentity: self.windowMutationIdentity))
    }

    static func repinWindowMutationIdentity(
        _ expected: WindowMutationIdentity,
        expectedBounds: CGRect,
        tolerance: CGFloat,
        providers: WindowMutationIdentityProviders) -> WindowMutationIdentity?
    {
        guard expected.windowID > 0,
              expected.ownerProcessIdentifier > 0,
              let windowID = CGWindowID(exactly: expected.windowID),
              providers.processStartIdentity(expected.ownerProcessIdentifier) == expected.ownerProcessStartIdentity,
              let current = providers.windowIdentity(windowID),
              current.ownerProcessIdentifier == expected.ownerProcessIdentifier,
              WindowMutationGeometryPostcondition.boundsMatch(
                  current.bounds,
                  expectedBounds,
                  tolerance: tolerance),
              let repinned = providers.mutationIdentity(windowID),
              repinned.ownerProcessIdentifier == expected.ownerProcessIdentifier,
              repinned.ownerProcessStartIdentity == expected.ownerProcessStartIdentity,
              let repinnedBounds = repinned.capturedBounds,
              WindowMutationGeometryPostcondition.boundsMatch(
                  repinnedBounds,
                  expectedBounds,
                  tolerance: tolerance)
        else {
            return nil
        }
        return repinned
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let value as Int:
            value
        case let value as Int32:
            Int(value)
        case let value as NSNumber:
            value.intValue
        default:
            nil
        }
    }

    private static func cgFloatValue(_ value: Any?) -> CGFloat? {
        switch value {
        case let value as CGFloat:
            value
        case let value as Double:
            CGFloat(value)
        case let value as Int:
            CGFloat(value)
        case let value as NSNumber:
            CGFloat(value.doubleValue)
        default:
            nil
        }
    }
}
