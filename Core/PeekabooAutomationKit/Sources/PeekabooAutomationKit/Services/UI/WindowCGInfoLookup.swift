import CoreGraphics
import Foundation

@MainActor
struct WindowCGInfoLookup {
    typealias WindowListProvider = (CGWindowListOption, CGWindowID) -> [[String: Any]]?

    private let windowListProvider: WindowListProvider
    private let processStartIdentityProvider: (pid_t) -> UInt64?
    private let currentWindowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?
    private let isMainWindowProvider: (CGWindowID) -> Bool

    init(
        windowIdentityService: WindowIdentityService = WindowIdentityService(),
        windowListProvider: @escaping WindowListProvider = { options, relativeToWindow in
            CGWindowListCopyWindowInfo(options, relativeToWindow) as? [[String: Any]]
        },
        processStartIdentityProvider: @escaping (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        currentWindowIdentityProvider: @escaping (CGWindowID) -> SystemWindowIdentity? =
            SystemIdentityResolver.windowIdentity,
        isMainWindowProvider: ((CGWindowID) -> Bool)? = nil)
    {
        self.windowListProvider = windowListProvider
        self.processStartIdentityProvider = processStartIdentityProvider
        self.currentWindowIdentityProvider = currentWindowIdentityProvider
        self.isMainWindowProvider = isMainWindowProvider ?? windowIdentityService.isTopmostRenderableWindow
    }

    func serviceWindowInfo(windowID: Int) -> ServiceWindowInfo? {
        // Exact ID refreshes happen after mutations and snapshot focus; keep them on the CG fast path
        // instead of walking every app's AX window list.
        guard let cgWindowID = CGWindowID(exactly: windowID),
              case let .found(window) = SystemIdentityResolver.exactWindowCatalogObservation(
                  cgWindowID,
                  windowListProvider: self.windowListProvider)
        else {
            return nil
        }

        return Self.serviceWindowInfo(
            windowID: windowID,
            windowList: [window],
            isMainWindowProvider: self.isMainWindowProvider,
            processStartIdentityProvider: self.processStartIdentityProvider,
            currentWindowIdentityProvider: self.currentWindowIdentityProvider)
    }

    static func serviceWindowInfo(
        windowID: Int,
        windowList: [[String: Any]],
        isMainWindowProvider: (CGWindowID) -> Bool,
        processStartIdentityProvider: (pid_t) -> UInt64?,
        currentWindowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?) -> ServiceWindowInfo?
    {
        guard let cgWindowID = CGWindowID(exactly: windowID),
              let windowInfo = windowList.first(where: { Self.intValue($0[kCGWindowNumber as String]) == windowID }),
              let bounds = Self.bounds(from: windowInfo),
              let ownerValue = intValue(windowInfo[kCGWindowOwnerPID as String]),
              let ownerProcessIdentifier = pid_t(exactly: ownerValue),
              ownerProcessIdentifier > 0,
              let ownerProcessStartIdentity = processStartIdentityProvider(ownerProcessIdentifier)
        else {
            return nil
        }

        let layer = Self.intValue(windowInfo[kCGWindowLayer as String]) ?? 0
        let alpha = Self.cgFloatValue(windowInfo[kCGWindowAlpha as String]) ?? 1.0
        let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? false
        let sharingRaw = Self.intValue(windowInfo[kCGWindowSharingState as String])
        let sharingState = sharingRaw.flatMap { WindowSharingState(rawValue: $0) }
        let isMainWindow = isMainWindowProvider(cgWindowID)

        // Bind the receipt to this exact session-scoped WindowServer entry. The public API exposes no
        // stronger incarnation token, so a changed owner generation or frame rejects the stale entry.
        guard let mutationIdentity = SystemIdentityResolver.windowMutationIdentity(
            snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                windowID: cgWindowID,
                ownerProcessIdentifier: ownerProcessIdentifier,
                ownerProcessStartIdentity: ownerProcessStartIdentity,
                bounds: bounds,
                isMinimized: bounds.origin.x < -10000 || bounds.origin.y < -10000),
            processStartIdentityProvider: processStartIdentityProvider,
            windowIdentityProvider: currentWindowIdentityProvider)
        else {
            return nil
        }

        return ServiceWindowInfo(
            windowID: windowID,
            title: (windowInfo[kCGWindowName as String] as? String) ?? "",
            bounds: bounds,
            isMinimized: bounds.origin.x < -10000 || bounds.origin.y < -10000,
            isMainWindow: isMainWindow,
            windowLevel: layer,
            alpha: alpha,
            index: 0,
            isOffScreen: !isOnScreen,
            layer: layer,
            isOnScreen: isOnScreen,
            sharingState: sharingState,
            mutationIdentity: mutationIdentity)
    }

    private nonisolated static func bounds(from windowInfo: [String: Any]) -> CGRect? {
        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = cgFloatValue(boundsDict["X"]),
              let y = cgFloatValue(boundsDict["Y"]),
              let width = cgFloatValue(boundsDict["Width"]),
              let height = cgFloatValue(boundsDict["Height"])
        else {
            return nil
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    private nonisolated static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let int32Value = value as? Int32 {
            return Int(int32Value)
        }
        if let int64Value = value as? Int64 {
            return Int(int64Value)
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        if let numberValue = value as? NSNumber {
            return numberValue.intValue
        }
        return nil
    }

    private nonisolated static func cgFloatValue(_ value: Any?) -> CGFloat? {
        if let cgFloatValue = value as? CGFloat {
            return cgFloatValue
        }
        if let doubleValue = value as? Double {
            return CGFloat(doubleValue)
        }
        if let intValue = value as? Int {
            return CGFloat(intValue)
        }
        if let numberValue = value as? NSNumber {
            return CGFloat(truncating: numberValue)
        }
        return nil
    }
}
