import CoreGraphics
import Foundation

@_spi(Testing) public enum ScreenCapturePlanner {
    public enum FrameSourcePolicy: Sendable {
        case fastStream
        case singleShot
    }

    /// Convert a global desktop-space rectangle to a display-local `sourceRect`.
    ///
    /// ScreenCaptureKit expects `SCStreamConfiguration.sourceRect` in display-local logical coordinates.
    ///
    /// `SCWindow.frame` and `SCDisplay.frame` returned from `SCShareableContent` are in global desktop
    /// coordinates, matching `NSScreen.frame`, including non-zero / negative origins for secondary displays.
    ///
    /// When using a display-bound filter (`SCContentFilter(display:...)`), passing a global rect directly can
    /// crop the wrong region or fail with an invalid parameter error on non-primary displays.
    public static func displayLocalSourceRect(globalRect: CGRect, displayFrame: CGRect) -> CGRect {
        globalRect.offsetBy(dx: -displayFrame.origin.x, dy: -displayFrame.origin.y)
    }

    /// Resolve the one-based display number expected by `/usr/sbin/screencapture -D`.
    public static func systemScreencaptureDisplayNumber(
        displayID: CGDirectDisplayID,
        activeDisplayIDs: [CGDirectDisplayID],
        mirroredDisplayOwners: [CGDirectDisplayID: CGDirectDisplayID] = [:]) -> Int?
    {
        let captureDisplayID = mirroredDisplayOwners[displayID] ?? displayID
        let captureDisplayIDs = activeDisplayIDs.filter { mirroredDisplayOwners[$0] == nil }
        return captureDisplayIDs.firstIndex(of: captureDisplayID).map { $0 + 1 }
    }

    public static func capturePixelSize(
        for frame: CGRect,
        fallbackFrame: CGRect? = nil,
        scale: CGFloat) -> (width: Int, height: Int)
    {
        let sourceFrame = self.captureSizeSourceFrame(frame, fallbackFrame: fallbackFrame)
        return (
            width: self.capturePixelDimension(sourceFrame.width, scale: scale),
            height: self.capturePixelDimension(sourceFrame.height, scale: scale))
    }

    private static func captureSizeSourceFrame(_ frame: CGRect, fallbackFrame: CGRect?) -> CGRect {
        if self.isUsableCaptureSizeFrame(frame) {
            return frame
        }
        if let fallbackFrame, self.isUsableCaptureSizeFrame(fallbackFrame) {
            return fallbackFrame
        }
        return .zero
    }

    private static func isUsableCaptureSizeFrame(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isEmpty && frame.width.isFinite && frame.height.isFinite
    }

    private static func capturePixelDimension(_ logicalLength: CGFloat, scale: CGFloat) -> Int {
        let scaledLength = logicalLength * scale
        guard scaledLength.isFinite, scaledLength > 0 else { return 1 }
        return max(Int(scaledLength), 1)
    }

    /// Result of attempting to map a window to an available display.
    public enum WindowDisplayMatch: Equatable, Sendable {
        /// The window cleanly maps to the display at the given index. Capture can use a
        /// `SCContentFilter(display:including:)` filter with a display-local source rect.
        case mapped(displayIndex: Int)
        /// No display contains or overlaps the window's geometry, but at least one display exists.
        /// Callers should use a display-independent filter (`SCContentFilter(desktopIndependentWindow:)`).
        /// `fallbackDisplayIndex` is a best-effort display to read scale and metadata from.
        case unmapped(fallbackDisplayIndex: Int)
        /// No displays were enumerated at all. Capture cannot proceed.
        case noDisplays
    }

    /// Map a window's global desktop rectangle to one of the supplied display rectangles.
    ///
    /// Strategy, in order:
    /// 1. Display containing the window's geometric center.
    /// 2. Display with the largest intersection area with the window.
    /// 3. If the window is degenerate (null / zero size) or sits entirely outside every display,
    ///    return `.unmapped` so the caller can fall back to a desktop-independent capture filter.
    ///    The chosen fallback prefers the display whose origin is `(0, 0)` (typically the primary)
    ///    and otherwise the first enumerated display.
    ///
    /// The current `frame.intersects(window.frame)` check used by the live capture path is
    /// insufficient under three real-world conditions reported by users:
    /// - The window has a degenerate frame (e.g. `.zero`) on certain multi-display setups,
    ///   which makes `CGRectIntersectsRect` return false for every display.
    /// - `SCShareableContent.displays` enumeration is incomplete (e.g. dormant secondary displays,
    ///   permission scoping, virtual / DisplayLink adapters) so the display the window actually
    ///   lives on is absent from the list.
    /// - The window straddles two displays and a deterministic primary choice is desirable.
    public static func matchDisplay(
        windowFrame: CGRect,
        displayFrames: [CGRect]) -> WindowDisplayMatch
    {
        guard !displayFrames.isEmpty else { return .noDisplays }

        let windowIsUsable = !windowFrame.isNull && !windowFrame.isEmpty

        if windowIsUsable {
            let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
            if let centerIndex = displayFrames.firstIndex(where: { $0.contains(center) }) {
                return .mapped(displayIndex: centerIndex)
            }

            var bestIndex: Int?
            var bestArea: CGFloat = 0
            for (index, frame) in displayFrames.enumerated() {
                let intersection = frame.intersection(windowFrame)
                guard !intersection.isNull, !intersection.isEmpty else { continue }
                let area = intersection.width * intersection.height
                if area > bestArea {
                    bestArea = area
                    bestIndex = index
                }
            }
            if let bestIndex {
                return .mapped(displayIndex: bestIndex)
            }
        }

        let fallback = displayFrames.firstIndex(where: { $0.origin == .zero }) ?? 0
        return .unmapped(fallbackDisplayIndex: fallback)
    }

    public static func frameSourcePolicy(
        for mode: CaptureMode,
        windowID: CGWindowID?) -> FrameSourcePolicy
    {
        if windowID != nil {
            return .singleShot
        }

        switch mode {
        case .screen, .multi:
            return .fastStream
        case .area:
            return .singleShot
        case .window, .frontmost:
            return .singleShot
        }
    }
}
