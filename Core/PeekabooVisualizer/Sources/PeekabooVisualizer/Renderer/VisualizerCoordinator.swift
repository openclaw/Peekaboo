//
//  VisualizerCoordinator.swift
//  Peekaboo
//
//  Created by Peekaboo on 2025-01-30.
//

import CoreGraphics
import Foundation
import IOKit.ps
import Observation
import os
import PeekabooFoundation
import PeekabooProtocols
import SwiftUI

/// Coordinates all visual feedback animations for a host app.
/// This follows modern SwiftUI patterns and focuses on simplicity
@MainActor
@Observable
public final class VisualizerCoordinator {
    // MARK: - Properties

    /// Logger for debugging
    let logger = Logger(subsystem: "boo.peekaboo.visualizer", category: "VisualizerCoordinator")

    /// Overlay manager for displaying animations
    let overlayManager = AnimationOverlayManager()

    /// Optimized animation queue with batching and priorities
    let animationQueue = OptimizedAnimationQueue()
    static let animationSlowdownFactor: Double = 3.0
    static let defaultVisualizerAnimationSpeed: Double = 1.0
    var previewDurationOverride: TimeInterval?

    /// Settings reference
    weak var settings: (any VisualizerSettingsProviding)?

    enum AnimationBaseline {
        static let screenshotFlash: TimeInterval = 0.35
        static let clickRipple: TimeInterval = 0.45
        static let typingOverlay: TimeInterval = 1.2
        static let scrollIndicator: TimeInterval = 0.6
        static let mouseTrail: TimeInterval = 0.75
        static let swipePath: TimeInterval = 0.9
        static let hotkeyOverlay: TimeInterval = 1.2
        static let windowOperation: TimeInterval = 0.85
        static let appLaunch: TimeInterval = 1.8
        static let appQuit: TimeInterval = 1.5
        static let menuNavigation: TimeInterval = 1.0
        static let dialogInteraction: TimeInterval = 1.0
        static let annotatedScreenshot: TimeInterval = 1.2
        static let elementHighlight: TimeInterval = 1.0
        static let spaceTransition: TimeInterval = 1.0
    }

    /// Minimum gaps between repeats of the same feedback kind. Agents fire
    /// actions in rapid bursts; without throttling every capture and scroll
    /// spawns its own overlay and the screen turns into a slideshow.
    enum FeedbackThrottle {
        static let screenshotFlash: TimeInterval = 1.2
        static let scroll: TimeInterval = 0.3
        static let mouseTrail: TimeInterval = 0.4
        static let elementDetection: TimeInterval = 1.0
        /// Mouse moves shorter than this aren't worth a comet.
        static let minimumTrailDistance: CGFloat = 80
    }

    /// Replace-keys for overlays that should exist at most once: a new event
    /// of the same kind crossfades into the previous one instead of stacking.
    enum OverlaySlot {
        static let typing = "typing"
        static let hotkey = "hotkey"
        static let menu = "menu"
        static let space = "space"
        static let appLifecycle = "appLifecycle"
        static let watchHUD = "watchHUD"
        static let annotatedScreenshot = "annotatedScreenshot"
        static let elementSheetPrefix = "elements-screen-"

        static func elementSheet(screenIndex: Int) -> String {
            "\(self.elementSheetPrefix)\(screenIndex)"
        }
    }

    enum OverlayPadding {
        static let watchHUD: CGFloat = 16
        static let click: CGFloat = 32
        static let typing: CGFloat = 32
        static let scroll: CGFloat = 24
        static let mouseTrail: CGFloat = 16
        static let swipe: CGFloat = 24
        static let hotkeyGlow: CGFloat = 96
        static let appLifecycle: CGFloat = 48
        static let windowOperation: CGFloat = 48
        static let menuGlow: CGFloat = 64
        static let dialog: CGFloat = 80
        static let elementHighlight: CGFloat = 32
        static let annotatedScreenshot: CGFloat = 64
    }

    static func paddedRect(_ rect: CGRect, padding: CGFloat) -> CGRect {
        guard padding > 0 else { return rect }
        return rect.insetBy(dx: -padding, dy: -padding)
    }

    /// Overlay window rect (AppKit screen coordinates) covering a travel path.
    static func travelWindowRect(from: CGPoint, to: CGPoint, padding: CGFloat) -> CGRect {
        CGRect(
            x: min(from.x, to.x) - padding,
            y: min(from.y, to.y) - padding,
            width: abs(to.x - from.x) + padding * 2,
            height: abs(to.y - from.y) + padding * 2)
    }

    /// Converts an AppKit screen point (bottom-left origin) into a window-local
    /// SwiftUI point (top-left origin) for an overlay shown at `windowRect`.
    static func windowLocalPoint(_ point: CGPoint, in windowRect: CGRect) -> CGPoint {
        CGPoint(
            x: point.x - windowRect.minX,
            y: windowRect.maxY - point.y)
    }

    /// Converts an AppKit screen rect into a window-local SwiftUI rect
    /// (top-left origin) for an overlay shown at `windowRect`.
    static func windowLocalRect(_ rect: CGRect, in windowRect: CGRect) -> CGRect {
        VisualizerScreenGeometry.windowLocalRect(rect, in: windowRect)
    }

    /// Keeps element highlights readable: drops degenerate and screen-filling
    /// rects (window/group containers) and caps the count, preferring the
    /// smallest rects — those are the actual controls.
    static func filteredElementOverlays(
        _ elements: [String: CGRect],
        screenArea: CGFloat,
        limit: Int = 120) -> [String: CGRect]
    {
        let usable = elements.filter { _, rect in
            rect.width >= 4 && rect.height >= 4 &&
                (rect.width * rect.height) <= screenArea * 0.5
        }
        guard usable.count > limit else { return usable }
        let smallest = usable
            .sorted { ($0.value.width * $0.value.height) < ($1.value.width * $1.value.height) }
            .prefix(limit)
        return Dictionary(uniqueKeysWithValues: Array(smallest))
    }

    private static func keyWidthForHotkeyOverlay(_ key: String) -> CGFloat {
        switch key.lowercased() {
        case "space":
            120
        case "shift", "return", "enter", "delete", "backspace":
            80
        case "cmd", "command", "ctrl", "control", "option", "alt":
            60
        default:
            40
        }
    }

    static func estimatedHotkeyOverlaySize(for keys: [String]) -> CGSize {
        let keyWidths = keys.map { self.keyWidthForHotkeyOverlay($0) }
        let keysWidth = keyWidths.reduce(0, +) + CGFloat(max(0, keys.count - 1)) * 8
        // Key container: internal padding(.horizontal: 20) + border/glow breathing room.
        let baseWidth = keysWidth + 40
        let width = max(400, min(960, baseWidth + self.OverlayPadding.hotkeyGlow * 2))
        // Key height: 40 + padding(.vertical: 20) + glow breathing room.
        let baseHeight: CGFloat = 80
        let height = max(160, min(420, baseHeight + self.OverlayPadding.hotkeyGlow * 2))
        return CGSize(width: width, height: height)
    }

    static func estimatedMenuOverlaySize(for menuPath: [String]) -> CGSize {
        // Rough heuristic: each segment needs room for title + padding + arrows.
        let segmentWidth: CGFloat = 220
        let baseWidth = max(600, CGFloat(menuPath.count) * segmentWidth)
        let width = min(1100, baseWidth + self.OverlayPadding.menuGlow * 2)
        let height: CGFloat = 140 + self.OverlayPadding.menuGlow * 2
        return CGSize(width: width, height: height)
    }

    var animationSpeedScale: Double {
        max(0.1, min(2.0, self.settings?.visualizerAnimationSpeed ?? Self.defaultVisualizerAnimationSpeed))
    }

    var durationScaledAnimationSpeed: Double {
        self.animationSpeedScale * Self.animationSlowdownFactor
    }

    /// Screenshot counter for easter egg (persisted)
    var screenshotCount: Int {
        get { UserDefaults.standard.integer(forKey: "PeekabooScreenshotCount") }
        set { UserDefaults.standard.set(newValue, forKey: "PeekabooScreenshotCount") }
    }

    var lastWatchHUDDate = Date.distantPast
    var watchHUDSequence = 0
    var lastScreenshotFlashDate = Date.distantPast
    var lastScrollDate = Date.distantPast
    var lastMouseTrailDate = Date.distantPast
    var lastElementDetectionDate = Date.distantPast

    // MARK: - Initialization

    public init() {
        // Overlay manager is created internally
    }

    // MARK: - Helpers

    func scaledDuration(_ baseline: TimeInterval, applySlowdown: Bool = true) -> TimeInterval {
        let slowdown = applySlowdown ? Self.animationSlowdownFactor : 1.0
        let duration = baseline * self.animationSpeedScale * slowdown
        return self.previewDurationOverride.map { min($0, duration) } ?? duration
    }

    func scaledDuration(
        for requested: TimeInterval,
        minimum baseline: TimeInterval,
        applySlowdown: Bool = true) -> TimeInterval
    {
        let slowdown = applySlowdown ? Self.animationSlowdownFactor : 1.0
        let duration = max(requested, baseline) * self.animationSpeedScale * slowdown
        return self.previewDurationOverride.map { min($0, duration) } ?? duration
    }

    /// Run a preview with capped animation duration (used by Settings play buttons).
    public func runPreview<T>(_ body: () async -> T) async -> T {
        self.previewDurationOverride = 1.0
        defer { self.previewDurationOverride = nil }
        return await body()
    }

    // MARK: - Settings

    /// Connect to a host settings source.
    public func connectSettings(_ settings: any VisualizerSettingsProviding) {
        self.settings = settings
        self.logger.info("Visualizer connected to settings")
    }

    /// Check if visualizer is enabled
    public func isEnabled() -> Bool {
        self.settings?.visualizerEnabled ?? true
    }

    /// Check if running on battery power
    private func isOnBatteryPower() -> Bool {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as Array

        for source in sources {
            if let sourceInfo = IOPSGetPowerSourceDescription(snapshot, source)
                .takeUnretainedValue() as? [String: Any],
                let powerSourceState = sourceInfo[kIOPSPowerSourceStateKey] as? String
            {
                return powerSourceState == kIOPSBatteryPowerValue
            }
        }

        return false
    }

    /// Get the appropriate screen for displaying visualizations based on context
    /// For point-based operations, use the screen containing that point
    /// For general operations, use the screen containing the mouse cursor
    func getTargetScreen(for point: CGPoint? = nil) -> NSScreen {
        if let point {
            NSScreen.screen(containing: point)
        } else {
            NSScreen.mouseScreen
        }
    }
}
