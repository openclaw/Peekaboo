import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

/// One internally coherent application, window, target, and receipt graph for happy-path tests.
///
/// Malformed and compatibility tests should continue constructing their values explicitly so this
/// fixture cannot accidentally repair the contradiction under test.
public struct LinkedDesktopTargetFixture: Sendable {
    public let processIdentity: ApplicationProcessIdentity
    public let application: ServiceApplicationInfo
    public let windowIdentity: WindowMutationIdentity
    public let window: ServiceWindowInfo
    public let processTargetIdentity: DesktopTargetIdentity
    public let windowTargetIdentity: DesktopTargetIdentity
    public let windowContext: WindowContext

    public var processTargetReceipt: DesktopActionTargetReceipt {
        self.processTargetIdentity.actionTargetReceipt
    }

    public var windowTargetReceipt: DesktopActionTargetReceipt {
        self.windowTargetIdentity.actionTargetReceipt
    }
}

extension AutomationTestFixtures {
    public static func linkedDesktopTarget(
        processIdentity: ApplicationProcessIdentity = Self.processIdentity(),
        bundleIdentifier: String? = "com.example.TestApp",
        applicationName: String = "Test App",
        windowID: Int = 201,
        windowTitle: String = "Test Window",
        bounds: CGRect = CGRect(x: 10, y: 20, width: 640, height: 480),
        isMinimized: Bool = false,
        isMainWindow: Bool = true,
        isKeyWindow: Bool? = true,
        isFrontmost: Bool? = false,
        windowIndex: Int = 0,
        focusedElement: FocusedElementIdentity? = nil) -> LinkedDesktopTargetFixture
    {
        precondition(
            processIdentity.processIdentifier > 0 && processIdentity.processStartIdentity > 0,
            "A linked desktop target fixture requires a positive process generation")
        precondition(
            windowID > 0 && UInt64(windowID) <= UInt64(UInt32.max),
            "A linked desktop target fixture requires a WindowServer-compatible window ID")
        precondition(
            !bounds.isEmpty &&
                bounds.origin.x.isFinite &&
                bounds.origin.y.isFinite &&
                bounds.width.isFinite &&
                bounds.height.isFinite,
            "A linked desktop target fixture requires finite nonempty bounds")

        let application = self.application(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: bundleIdentifier,
            name: applicationName,
            windowCount: 1,
            windowIDs: [windowID])
        let window = self.window(
            windowID: windowID,
            title: windowTitle,
            bounds: bounds,
            processIdentity: processIdentity,
            isMinimized: isMinimized,
            isMainWindow: isMainWindow,
            isKeyWindow: isKeyWindow,
            isFrontmost: isFrontmost,
            index: windowIndex)
        guard let windowIdentity = window.mutationIdentity else {
            preconditionFailure("A linked desktop target fixture requires a window mutation identity")
        }

        do {
            let processTargetIdentity = try DesktopTargetIdentity(processIdentity: processIdentity)
            let windowTargetIdentity = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                window: window,
                focusedElement: focusedElement))
            return LinkedDesktopTargetFixture(
                processIdentity: processIdentity,
                application: application,
                windowIdentity: windowIdentity,
                window: window,
                processTargetIdentity: processTargetIdentity,
                windowTargetIdentity: windowTargetIdentity,
                windowContext: self.windowContext(
                    application: application,
                    window: window,
                    focusedElement: focusedElement))
        } catch {
            preconditionFailure("Invalid linked desktop target fixture: \(error.localizedDescription)")
        }
    }

    /// Copies a valid window fixture while overriding the fields relevant to target and state tests.
    ///
    /// The mutation identity is rebuilt from the resolved window ID, process generation, bounds, and
    /// minimized state. Any mutation postcondition evidence is dropped when one of those fields changes.
    public static func window(
        copying source: ServiceWindowInfo,
        windowID: Int? = nil,
        title: String? = nil,
        bounds: CGRect? = nil,
        processIdentity: ApplicationProcessIdentity? = nil,
        isMinimized: Bool? = nil,
        isMainWindow: Bool? = nil,
        isKeyWindow: Bool? = nil,
        isFrontmost: Bool? = nil,
        windowLevel: Int? = nil,
        alpha: CGFloat? = nil,
        index: Int? = nil,
        isOffScreen: Bool? = nil,
        layer: Int? = nil,
        isOnScreen: Bool? = nil) -> ServiceWindowInfo
    {
        let resolvedWindowID = windowID ?? source.windowID
        let resolvedBounds = bounds ?? source.bounds
        let resolvedMinimized = isMinimized ?? source.isMinimized
        let sourceIdentity = source.mutationIdentity
        let resolvedProcessIdentity = processIdentity ?? sourceIdentity?.processIdentity
        let resolvedCapturedBounds = bounds != nil || sourceIdentity == nil
            ? resolvedBounds
            : sourceIdentity?.capturedBounds
        let resolvedIdentityMinimized = isMinimized != nil || sourceIdentity == nil
            ? resolvedMinimized
            : sourceIdentity?.isMinimized
        let resolvedMutationIdentity = resolvedProcessIdentity.map {
            WindowMutationIdentity(
                windowID: resolvedWindowID,
                ownerProcessIdentifier: $0.processIdentifier,
                ownerProcessStartIdentity: $0.processStartIdentity,
                capturedBounds: resolvedCapturedBounds,
                isMinimized: resolvedIdentityMinimized)
        }
        let preservesPostcondition = windowID == nil &&
            bounds == nil &&
            processIdentity == nil &&
            isMinimized == nil &&
            isMainWindow == nil &&
            isKeyWindow == nil &&
            isFrontmost == nil &&
            windowLevel == nil &&
            alpha == nil &&
            isOffScreen == nil &&
            layer == nil &&
            isOnScreen == nil

        return ServiceWindowInfo(
            windowID: resolvedWindowID,
            title: title ?? source.title,
            bounds: resolvedBounds,
            isMinimized: resolvedMinimized,
            isMainWindow: isMainWindow ?? source.isMainWindow,
            isKeyWindow: isKeyWindow ?? source.isKeyWindow,
            isFrontmost: isFrontmost ?? source.isFrontmost,
            subrole: source.subrole,
            windowLevel: windowLevel ?? source.windowLevel,
            alpha: alpha ?? source.alpha,
            index: index ?? source.index,
            spaceID: source.spaceID,
            spaceName: source.spaceName,
            screenIndex: source.screenIndex,
            screenName: source.screenName,
            isOffScreen: isOffScreen ?? source.isOffScreen,
            layer: layer ?? source.layer,
            isOnScreen: isOnScreen ?? source.isOnScreen,
            sharingState: source.sharingState,
            isExcludedFromWindowsMenu: source.isExcludedFromWindowsMenu,
            mutationIdentity: resolvedMutationIdentity,
            mutationPostconditionEvidence: preservesPostcondition ? source.mutationPostconditionEvidence : nil)
    }
}
