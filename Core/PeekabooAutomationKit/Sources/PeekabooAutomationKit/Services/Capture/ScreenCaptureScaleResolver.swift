import AppKit
import CoreGraphics

@_spi(Testing) public enum ScreenCaptureScaleResolver {
    public enum ScaleSource: String, Sendable, Equatable {
        case screenBackingScaleFactor
        case displayPixelRatio
        case fallback1x
    }

    public struct Plan: Sendable, Equatable {
        public let preference: CaptureScalePreference
        public let nativeScale: CGFloat
        public let outputScale: CGFloat
        public let source: ScaleSource

        public init(
            preference: CaptureScalePreference,
            nativeScale: CGFloat,
            outputScale: CGFloat,
            source: ScaleSource)
        {
            self.preference = preference
            self.nativeScale = nativeScale
            self.outputScale = outputScale
            self.source = source
        }
    }

    public static func plan(
        preference: CaptureScalePreference,
        displayID: CGDirectDisplayID,
        fallbackPixelWidth: Int,
        frameWidth: CGFloat,
        screens: [NSScreen] = NSScreen.screens) -> Plan
    {
        self.plan(
            preference: preference,
            screenBackingScaleFactor: self.screenBackingScaleFactor(displayID: displayID, screens: screens),
            fallbackPixelWidth: fallbackPixelWidth,
            frameWidth: frameWidth)
    }

    public static func plan(
        preference: CaptureScalePreference,
        screenBackingScaleFactor: CGFloat?,
        fallbackPixelWidth: Int,
        frameWidth: CGFloat) -> Plan
    {
        let native = self.nativeScaleWithSource(
            screenBackingScaleFactor: screenBackingScaleFactor,
            fallbackPixelWidth: fallbackPixelWidth,
            frameWidth: frameWidth)
        let outputScale: CGFloat = switch preference {
        case .native: native.scale
        case .logical1x: 1.0
        }

        return Plan(
            preference: preference,
            nativeScale: native.scale,
            outputScale: outputScale,
            source: native.source)
    }

    public static func nativeScale(
        displayID: CGDirectDisplayID,
        fallbackPixelWidth: Int,
        frameWidth: CGFloat,
        screens: [NSScreen] = NSScreen.screens) -> CGFloat
    {
        self.plan(
            preference: .native,
            displayID: displayID,
            fallbackPixelWidth: fallbackPixelWidth,
            frameWidth: frameWidth,
            screens: screens).nativeScale
    }

    public static func nativeScale(
        screenBackingScaleFactor: CGFloat?,
        fallbackPixelWidth: Int,
        frameWidth: CGFloat) -> CGFloat
    {
        self.nativeScaleWithSource(
            screenBackingScaleFactor: screenBackingScaleFactor,
            fallbackPixelWidth: fallbackPixelWidth,
            frameWidth: frameWidth).scale
    }

    static func diagnostics(
        plan: Plan,
        finalPixelSize: CGSize,
        engine: ScreenCaptureAPI? = nil,
        fallbackReason: String? = nil,
        windowPlanCacheStatus: CaptureWindowPlanCacheStatus? = nil,
        windowPlanCacheGeneration: UInt64? = nil) -> CaptureDiagnostics
    {
        CaptureDiagnostics(
            requestedScale: plan.preference,
            nativeScale: plan.nativeScale,
            outputScale: plan.outputScale,
            scaleSource: plan.source.rawValue,
            finalPixelSize: finalPixelSize,
            engine: engine?.description,
            fallbackReason: fallbackReason,
            windowPlanCacheStatus: windowPlanCacheStatus,
            windowPlanCacheGeneration: windowPlanCacheGeneration)
    }

    private static func nativeScaleWithSource(
        screenBackingScaleFactor: CGFloat?,
        fallbackPixelWidth: Int,
        frameWidth: CGFloat) -> (scale: CGFloat, source: ScaleSource)
    {
        if let screenScale = screenBackingScaleFactor, screenScale > 0 {
            return (screenScale, .screenBackingScaleFactor)
        }

        guard frameWidth > 0 else { return (1.0, .fallback1x) }
        let scale = CGFloat(fallbackPixelWidth) / frameWidth
        return scale > 0 ? (scale, .displayPixelRatio) : (1.0, .fallback1x)
    }

    private static func screenBackingScaleFactor(displayID: CGDirectDisplayID, screens: [NSScreen]) -> CGFloat? {
        let targetID = NSNumber(value: displayID)
        guard let screen = screens.first(where: { screen in
            screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber == targetID
        }) else {
            return nil
        }

        return screen.backingScaleFactor > 0 ? screen.backingScaleFactor : nil
    }
}
