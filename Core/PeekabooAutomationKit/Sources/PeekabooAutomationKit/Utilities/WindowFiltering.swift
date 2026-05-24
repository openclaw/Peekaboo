import CoreGraphics
import Foundation

public enum WindowFiltering {
    public struct Thresholds: Sendable {
        public let minWidth: CGFloat
        public let minHeight: CGFloat
        public let minAlpha: CGFloat

        public static let `default` = Thresholds(minWidth: 80, minHeight: 40, minAlpha: 0.01)
    }

    public enum Mode {
        case capture
        case list

        var thresholds: Thresholds {
            switch self {
            case .capture:
                .default
            case .list:
                Thresholds(minWidth: 60, minHeight: 60, minAlpha: 0.0)
            }
        }

        var requireShareable: Bool {
            switch self {
            case .capture:
                true
            case .list:
                false
            }
        }

        var requireOnScreen: Bool {
            switch self {
            case .capture:
                true
            case .list:
                false
            }
        }
    }

    public static func isRenderable(
        _ window: ServiceWindowInfo,
        mode: Mode = .capture) -> Bool
    {
        self.disqualificationReason(for: window, mode: mode) == nil
    }

    public static func disqualificationReason(
        for window: ServiceWindowInfo,
        mode: Mode = .capture) -> String?
    {
        let thresholds = mode.thresholds
        if mode.requireOnScreen, window.isMinimized {
            return "window minimized"
        }

        if window.layer != 0 {
            return "layer != 0"
        }

        if window.alpha <= thresholds.minAlpha {
            return "alpha too low"
        }

        if mode.requireShareable, !window.isShareableWindow {
            return "window marked non-shareable"
        }

        if mode.requireOnScreen && (!window.isOnScreen || window.isOffScreen) {
            return "window off-screen"
        }

        if window.bounds.width < thresholds.minWidth || window.bounds.height < thresholds.minHeight {
            return "window too small"
        }

        if window.isExcludedFromWindowsMenu {
            return "window excluded from Windows menu"
        }

        return nil
    }
}
