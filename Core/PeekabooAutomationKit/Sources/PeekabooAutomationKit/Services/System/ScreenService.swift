import Algorithms
import AppKit
import Foundation
import os
import PeekabooFoundation

/// Information about a display screen
public struct ScreenInfo: Codable, Sendable {
    public let index: Int
    public let name: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let isPrimary: Bool
    public let scaleFactor: CGFloat
    public let displayID: CGDirectDisplayID

    public init(
        index: Int,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect,
        isPrimary: Bool,
        scaleFactor: CGFloat,
        displayID: CGDirectDisplayID)
    {
        self.index = index
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
        self.scaleFactor = scaleFactor
        self.displayID = displayID
    }
}

/// Service for managing and querying display screens
@MainActor
public final class ScreenService: ScreenServiceProtocol {
    private static let logger = Logger(subsystem: "boo.peekaboo.core", category: "ScreenService")

    public init() {}

    /// List all available screens
    public func listScreens() -> [ScreenInfo] {
        // List all available screens
        let screens = NSScreen.screens

        return screens.indexed().map { index, screen in
            let displayID = screen.displayID
            let name = screen.localizedName

            return ScreenInfo(
                index: index,
                name: name,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                // AppKit guarantees screens[0] is the menu-bar display at
                // (0, 0). NSScreen.main instead follows keyboard focus.
                isPrimary: index == 0,
                scaleFactor: screen.backingScaleFactor,
                displayID: displayID)
        }
    }

    /// Find which screen contains global CG/AX window bounds.
    public func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        let screens = self.listScreens()
        guard let index = Self.screenIndex(
            containingGlobalDisplayBounds: bounds,
            appKitScreenFrames: screens.map(\.frame),
            primaryScreenFrame: screens.first(where: \.isPrimary)?.frame)
        else {
            return nil
        }
        return screens[index]
    }

    static func screenIndex(
        containingGlobalDisplayBounds bounds: CGRect,
        appKitScreenFrames: [CGRect],
        primaryScreenFrame: CGRect?) -> Int?
    {
        let appKitBounds = GlobalScreenCoordinateGeometry.appKitRect(
            fromGlobalDisplay: bounds,
            primaryScreenFrame: primaryScreenFrame)

        // Find the screen that contains the center of the window
        let windowCenter = CGPoint(x: appKitBounds.midX, y: appKitBounds.midY)

        // First, try to find a screen that contains the window center
        if let index = appKitScreenFrames.firstIndex(where: { $0.contains(windowCenter) }) {
            return index
        }

        // If center is not on any screen, find the screen with the most overlap
        var bestIndex: Int?
        var maxOverlap: CGFloat = 0

        for (index, frame) in appKitScreenFrames.enumerated() {
            let intersection = frame.intersection(appKitBounds)
            let overlapArea = intersection.width * intersection.height

            if overlapArea > maxOverlap {
                maxOverlap = overlapArea
                bestIndex = index
            }
        }

        return bestIndex
    }

    /// Get screen by index
    public func screen(at index: Int) -> ScreenInfo? {
        // Get screen by index
        let screens = self.listScreens()
        guard index >= 0, index < screens.count else { return nil }
        return screens[index]
    }

    /// Get the primary screen (with menu bar)
    public var primaryScreen: ScreenInfo? {
        self.listScreens().first { $0.isPrimary }
    }
}

// MARK: - NSScreen Extensions

extension NSScreen {
    /// Get a human-readable name for this screen
    var localizedName: String {
        // Try to get the display name from Core Graphics
        var name = "Display"

        let displayID = self.displayID
        if displayID != 0 {
            // Check if it's the built-in display
            if CGDisplayIsBuiltin(displayID) != 0 {
                name = "Built-in Display"
            } else {
                // Try to get manufacturer info
                if let info = getDisplayInfo(for: displayID) {
                    name = info
                } else {
                    // Fallback to generic external display
                    name = "External Display"
                }
            }
        }

        return name
    }

    private func getDisplayInfo(for displayID: CGDirectDisplayID) -> String? {
        // Get display info dictionary
        guard let info = CGDisplayCopyDisplayMode(displayID) else { return nil }

        // Try to extract meaningful information
        let width = info.pixelWidth
        let height = info.pixelHeight

        // Return resolution-based name
        return "\(width)×\(height) Display"
    }
}
