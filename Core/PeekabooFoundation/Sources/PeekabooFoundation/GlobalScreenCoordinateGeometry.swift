import CoreGraphics

/// Converts between Core Graphics/Accessibility global display coordinates
/// and AppKit global screen coordinates.
///
/// Both spaces use logical points. Their x axes match, but Core Graphics and
/// Accessibility place the origin at the upper-left of the primary display,
/// while AppKit places it at the lower-left. The same flip works in either
/// direction and remains valid for displays above or below the primary one.
public enum GlobalScreenCoordinateGeometry {
    public static func appKitPoint(
        fromGlobalDisplay point: CGPoint,
        primaryScreenFrame: CGRect?) -> CGPoint
    {
        guard let primaryScreenFrame else { return point }
        return CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }

    public static func appKitRect(
        fromGlobalDisplay rect: CGRect,
        primaryScreenFrame: CGRect?) -> CGRect
    {
        self.flippedRect(rect, primaryScreenFrame: primaryScreenFrame)
    }

    public static func globalDisplayRect(
        fromAppKit rect: CGRect,
        primaryScreenFrame: CGRect?) -> CGRect
    {
        self.flippedRect(rect, primaryScreenFrame: primaryScreenFrame)
    }

    private static func flippedRect(_ rect: CGRect, primaryScreenFrame: CGRect?) -> CGRect {
        guard let primaryScreenFrame, !rect.isNull, !rect.isInfinite else { return rect }
        return CGRect(
            x: rect.minX,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height)
    }
}
