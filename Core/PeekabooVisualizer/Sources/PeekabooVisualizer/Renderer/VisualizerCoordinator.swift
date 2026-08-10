//
//  VisualizerCoordinator.swift
//  Peekaboo
//
//  Created by Peekaboo on 2025-01-30.
//

import CoreGraphics
import Foundation
import Observation
import os
import PeekabooFoundation
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
    private let visibleTargetResolver: (VisualizerTargetWindow) -> VisualizerTargetWindow?

    enum AnimationBaseline {
        static let agentCursor: TimeInterval = 0.12
        static let inputHUD: TimeInterval = 0.8
        static let annotatedScreenshot: TimeInterval = 1.2
        static let elementHighlight: TimeInterval = 1.0
    }

    /// Minimum gaps between repeats of the same feedback kind. Agents fire
    /// actions in rapid bursts; without throttling every capture and scroll
    /// spawns its own overlay and the screen turns into a slideshow.
    enum FeedbackThrottle {
        static let screenshotFlash: TimeInterval = 1.2
        static let scroll: TimeInterval = 0.3
        static let agentCursor: TimeInterval = 0.06
        static let elementDetection: TimeInterval = 1.0
        /// Instant pointer hops should not be replayed as a delayed animation.
        static let minimumPointerDuration: TimeInterval = 0.05
        /// Tiny cursor moves are indistinguishable from pointer jitter.
        static let minimumCursorDistance: CGFloat = 3
    }

    /// Replace-keys for overlays that should exist at most once: a new event
    /// of the same kind crossfades into the previous one instead of stacking.
    enum OverlaySlot {
        static let inputHUD = "inputHUD"
        static let watchHUD = "watchHUD"
        static let pointer = "pointer"
        static let click = "click"
        static let annotatedScreenshot = "annotatedScreenshot"
        static let elementSheetPrefix = "elements-screen-"

        static func elementSheet(screenIndex: Int) -> String {
            "\(self.elementSheetPrefix)\(screenIndex)"
        }
    }

    enum OverlayPadding {
        static let watchHUD: CGFloat = 16
        // Must cover the cursor path's maximum curve excursion (bend/2 = 27pt,
        // see AgentCursorPath) plus the glyph+halo envelope (~24pt from hotspot).
        static let agentCursor: CGFloat = 56
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

    var animationSpeedScale: Double {
        max(0.1, min(2.0, self.settings?.visualizerAnimationSpeed ?? Self.defaultVisualizerAnimationSpeed))
    }

    var lastWatchHUDDate = Date.distantPast
    var watchHUDSequence = 0
    var lastScreenshotFlashDate = Date.distantPast
    var lastScrollDate = Date.distantPast
    var lastAgentCursorDate = Date.distantPast
    var lastElementDetectionDate = Date.distantPast

    // MARK: - Initialization

    public init() {
        self.visibleTargetResolver = TargetWindowVisibilityEvaluator.visibleTarget
    }

    init(targetWindowVisibility: @escaping (VisualizerTargetWindow) -> Bool) {
        self.visibleTargetResolver = { target in
            targetWindowVisibility(target) ? target : nil
        }
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

    func visibleTargetWindow(_ target: VisualizerTargetWindow) -> VisualizerTargetWindow? {
        self.visibleTargetResolver(target)
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
