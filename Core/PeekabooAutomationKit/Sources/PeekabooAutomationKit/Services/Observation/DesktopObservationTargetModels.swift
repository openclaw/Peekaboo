import CoreGraphics
import Foundation

public enum CaptureEnginePreference: String, Codable, Sendable, Equatable {
    case auto
    case modern
    case legacy
}

public enum WindowSelection: Sendable, Codable, Equatable {
    case automatic
    case index(Int)
    case title(String)
    case id(CGWindowID)
}

public enum DesktopObservationTargetRequest: Sendable, Codable, Equatable {
    case screen(index: Int?)
    case allScreens
    case frontmost
    case app(identifier: String, window: WindowSelection?)
    case pid(Int32, window: WindowSelection?)
    case windowID(CGWindowID)
    case area(CGRect)
    case menubar
    case menubarPopover(hints: [String], openIfNeeded: MenuBarPopoverOpenOptions? = nil)
}

public struct MenuBarPopoverOpenOptions: Sendable, Codable, Equatable {
    public var clickHint: String?
    public var settleDelayNanoseconds: UInt64
    public var useClickLocationAreaFallback: Bool

    public init(
        clickHint: String? = nil,
        settleDelayNanoseconds: UInt64 = 350_000_000,
        useClickLocationAreaFallback: Bool = true)
    {
        self.clickHint = clickHint
        self.settleDelayNanoseconds = settleDelayNanoseconds
        self.useClickLocationAreaFallback = useClickLocationAreaFallback
    }
}

public enum ResolvedObservationKind: Sendable, Codable, Equatable {
    case screen(index: Int?)
    case frontmost
    case appWindow
    case windowID(CGWindowID)
    case area(CGRect)
    case menubar
    case menubarPopover
}

public struct ApplicationIdentity: Sendable, Codable, Equatable {
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64?
    public let bundleIdentifier: String?
    public let name: String
    public let bundlePath: String?
    public let executablePath: String?
    public let activationPolicy: ServiceApplicationActivationPolicy?
    public let selectorResolutionProofs: [SelectorResolutionProof]?

    public init(
        processIdentifier: Int32,
        processStartIdentity: UInt64? = nil,
        bundleIdentifier: String?,
        name: String,
        bundlePath: String? = nil,
        executablePath: String? = nil,
        activationPolicy: ServiceApplicationActivationPolicy? = nil,
        selectorResolutionProofs: [SelectorResolutionProof]? = nil)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.bundlePath = bundlePath
        self.executablePath = executablePath
        self.activationPolicy = activationPolicy
        self.selectorResolutionProofs = selectorResolutionProofs
    }

    init(_ app: ServiceApplicationInfo) {
        self.init(
            processIdentifier: app.processIdentifier,
            processStartIdentity: app.processStartIdentity,
            bundleIdentifier: app.bundleIdentifier,
            name: app.name,
            bundlePath: app.bundlePath,
            executablePath: app.executablePath,
            activationPolicy: app.activationPolicy,
            selectorResolutionProofs: app.selectorResolutionProofs)
    }

    func withSelectorResolutionProofs(_ proofs: [SelectorResolutionProof]?) -> Self {
        Self(
            processIdentifier: self.processIdentifier,
            processStartIdentity: self.processStartIdentity,
            bundleIdentifier: self.bundleIdentifier,
            name: self.name,
            bundlePath: self.bundlePath,
            executablePath: self.executablePath,
            activationPolicy: self.activationPolicy,
            selectorResolutionProofs: proofs)
    }
}

public struct WindowIdentity: Sendable, Codable, Equatable {
    public let windowID: Int
    public let title: String
    public let bounds: CGRect
    public let index: Int

    public init(windowID: Int, title: String, bounds: CGRect, index: Int) {
        self.windowID = windowID
        self.title = title
        self.bounds = bounds
        self.index = index
    }

    init(_ window: ServiceWindowInfo) {
        self.init(
            windowID: window.windowID,
            title: window.title,
            bounds: window.bounds,
            index: window.index)
    }
}

public struct DisplayIdentity: Sendable, Codable, Equatable {
    public let index: Int
    public let name: String?
    public let bounds: CGRect
    public let scaleFactor: CGFloat?

    public init(index: Int, name: String?, bounds: CGRect, scaleFactor: CGFloat? = nil) {
        self.index = index
        self.name = name
        self.bounds = bounds
        self.scaleFactor = scaleFactor
    }
}

public struct DesktopStateSnapshot: Sendable, Codable, Equatable {
    public let capturedAt: Date
    public let displays: [DisplayIdentity]
    public let runningApplications: [ApplicationIdentity]
    public let windows: [WindowIdentity]
    public let frontmostApplication: ApplicationIdentity?
    public let frontmostWindow: WindowIdentity?

    public init(
        capturedAt: Date = Date(),
        displays: [DisplayIdentity] = [],
        runningApplications: [ApplicationIdentity] = [],
        windows: [WindowIdentity] = [],
        frontmostApplication: ApplicationIdentity? = nil,
        frontmostWindow: WindowIdentity? = nil)
    {
        self.capturedAt = capturedAt
        self.displays = displays
        self.runningApplications = runningApplications
        self.windows = windows
        self.frontmostApplication = frontmostApplication
        self.frontmostWindow = frontmostWindow
    }
}

public struct DesktopStateSnapshotSummary: Sendable, Codable, Equatable {
    public let capturedAt: Date
    public let displayCount: Int
    public let runningApplicationCount: Int
    public let windowCount: Int
    public let frontmostApplication: ApplicationIdentity?
    public let frontmostWindow: WindowIdentity?

    public init(_ snapshot: DesktopStateSnapshot) {
        self.capturedAt = snapshot.capturedAt
        self.displayCount = snapshot.displays.count
        self.runningApplicationCount = snapshot.runningApplications.count
        self.windowCount = snapshot.windows.count
        self.frontmostApplication = snapshot.frontmostApplication
        self.frontmostWindow = snapshot.frontmostWindow
    }
}

/// Codable projection of the exact owner mutated while resolving an observation target.
public struct DesktopObservationMutationTargetIdentity: Sendable, Codable, Equatable {
    public let processIdentity: ApplicationProcessIdentity
    public let windowIdentity: WindowMutationIdentity?
    public let windowBounds: CGRect?

    public init(_ target: DesktopTargetIdentity) {
        self.processIdentity = target.processIdentity
        self.windowIdentity = target.exactWindow?.identity
        self.windowBounds = target.exactWindow?.bounds
    }
}

public struct ResolvedObservationTarget: Sendable, Codable, Equatable {
    public let kind: ResolvedObservationKind
    public let app: ApplicationIdentity?
    public let window: WindowIdentity?
    public let bounds: CGRect?
    public let detectionContext: WindowContext?
    public let captureScaleHint: CGFloat?
    public let selectorResolutionProofs: [SelectorResolutionProof]?
    /// Exact owner of a conditional mutation performed while resolving this observation target.
    ///
    /// This is intentionally separate from `app` and `window`: opening a menu-bar popover mutates
    /// the status item's window, then captures a different popover window or screen area.
    public let mutationTargetIdentity: DesktopObservationMutationTargetIdentity?

    public init(
        kind: ResolvedObservationKind,
        app: ApplicationIdentity? = nil,
        window: WindowIdentity? = nil,
        bounds: CGRect? = nil,
        detectionContext: WindowContext? = nil,
        captureScaleHint: CGFloat? = nil,
        selectorResolutionProofs: [SelectorResolutionProof]? = nil,
        mutationTargetIdentity: DesktopObservationMutationTargetIdentity? = nil)
    {
        self.kind = kind
        self.app = app
        self.window = window
        self.bounds = bounds
        self.detectionContext = detectionContext
        self.captureScaleHint = captureScaleHint
        self.selectorResolutionProofs = selectorResolutionProofs ?? app?.selectorResolutionProofs?.map {
            $0.selecting(windowIdentity: detectionContext?.windowMutationIdentity)
        }
        self.mutationTargetIdentity = mutationTargetIdentity
    }

    public static func == (lhs: ResolvedObservationTarget, rhs: ResolvedObservationTarget) -> Bool {
        lhs.kind == rhs.kind
            && lhs.app == rhs.app
            && lhs.window == rhs.window
            && lhs.bounds == rhs.bounds
            && lhs.captureScaleHint == rhs.captureScaleHint
            && lhs.selectorResolutionProofs == rhs.selectorResolutionProofs
            && lhs.mutationTargetIdentity == rhs.mutationTargetIdentity
            && lhs.detectionContext?.applicationName == rhs.detectionContext?.applicationName
            && lhs.detectionContext?.applicationBundleId == rhs.detectionContext?.applicationBundleId
            && lhs.detectionContext?.applicationProcessId == rhs.detectionContext?.applicationProcessId
            && lhs.detectionContext?.windowTitle == rhs.detectionContext?.windowTitle
            && lhs.detectionContext?.windowID == rhs.detectionContext?.windowID
            && lhs.detectionContext?.windowBounds == rhs.detectionContext?.windowBounds
            && lhs.detectionContext?.windowMutationIdentity == rhs.detectionContext?.windowMutationIdentity
            && lhs.detectionContext?.shouldFocusWebContent == rhs.detectionContext?.shouldFocusWebContent
    }
}
