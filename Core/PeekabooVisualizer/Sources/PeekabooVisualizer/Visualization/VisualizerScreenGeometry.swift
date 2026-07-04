import CoreGraphics
import PeekabooFoundation

/// Coordinate conversions at the visualizer boundary.
///
/// Automation and Core Graphics use global display coordinates whose origin is
/// the upper-left of the primary display. AppKit overlay windows use global
/// screen coordinates whose origin is the lower-left of that same display.
/// Both spaces use logical points, so Retina scale factors are not involved.
public enum VisualizerScreenGeometry {
    public static func appKitPoint(
        fromGlobalDisplay point: CGPoint,
        primaryScreenFrame: CGRect?) -> CGPoint
    {
        GlobalScreenCoordinateGeometry.appKitPoint(
            fromGlobalDisplay: point,
            primaryScreenFrame: primaryScreenFrame)
    }

    public static func appKitRect(
        fromGlobalDisplay rect: CGRect,
        primaryScreenFrame: CGRect?) -> CGRect
    {
        GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: rect,
            primaryScreenFrame: primaryScreenFrame)
    }

    /// Convert a global AppKit rect into a SwiftUI rect local to an overlay window.
    public static func windowLocalRect(_ rect: CGRect, in windowRect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - windowRect.minX,
            y: windowRect.maxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }
}
