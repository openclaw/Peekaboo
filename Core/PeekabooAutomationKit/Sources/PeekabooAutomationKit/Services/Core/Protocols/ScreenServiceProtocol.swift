import Foundation

/// Protocol for screen management services
@MainActor
public protocol ScreenServiceProtocol: Sendable {
    /// List all available screens
    func listScreens() -> [ScreenInfo]

    /// Find which screen contains global CG/Accessibility window bounds.
    func screenContainingWindow(bounds: CGRect) -> ScreenInfo?

    /// Get screen by index
    func screen(at index: Int) -> ScreenInfo?

    /// Get the primary screen (with menu bar)
    var primaryScreen: ScreenInfo? {
        // List all available screens
        get
    }
}
