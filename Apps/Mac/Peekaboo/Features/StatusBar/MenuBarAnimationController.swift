import AppKit
import Combine
import Foundation
import os.log
import PeekabooCore
import SwiftUI

/// Cache key for storing rendered ghost images.
struct GhostIconCacheKey: Hashable {
    let isAnimating: Bool
    let verticalOffset: Int
    let horizontalOffset: Int
    let scale: Int
    let opacity: Int
    let isDarkMode: Bool
}

/// Manages animation timing and rendering for the menu bar ghost icon.
///
/// This controller handles adaptive timing, icon caching, and state management
/// for smooth ghost animations while minimizing CPU usage.
@MainActor
final class MenuBarAnimationController: ObservableObject {
    private struct IconFrameState {
        let isDarkMode: Bool
        let verticalOffset: CGFloat
        let horizontalOffset: CGFloat
        let scale: CGFloat
        let opacity: CGFloat
        let cacheKey: GhostIconCacheKey
    }

    // MARK: - Properties

    /// Current animation state
    @Published private(set) var isAnimating: Bool = false

    /// Animation timer
    @ObservationIgnored
    private var animationTimer: Timer?

    /// Cache for rendered icons
    private var iconCache: [GhostIconCacheKey: NSImage] = [:]
    private let maxCacheSize = 30

    /// Last rendered frame info for optimization
    private var lastRenderedFrame: (vOffset: CGFloat, hOffset: CGFloat, scale: CGFloat, opacity: Double) = (0, 0, 1, 1)
    private var framesSinceLastChange: Int = 0

    /// Logger for debugging
    private let logger = Logger(subsystem: "boo.peekaboo.mac", category: "MenuBarAnimation")

    /// Callback when icon needs updating
    var onIconUpdateNeeded: ((NSImage) -> Void)?

    /// Reference to the agent to track its processing state
    private weak var agent: PeekabooAgent?

    // MARK: - Initialization

    init() {
        self.logger.info("MenuBarAnimationController initialized")
    }

    // MARK: - Public Methods

    /// Sets the agent to observe
    func setAgent(_ agent: PeekabooAgent) {
        self.agent = agent
    }

    /// Starts or stops animation based on agent status
    func updateAnimationState() {
        let shouldAnimate = self.agent?.isProcessing ?? false

        if shouldAnimate != self.isAnimating {
            if shouldAnimate {
                self.startAnimation()
            } else {
                self.stopAnimation()
            }
        }
    }

    /// Forces a render of the current state
    func forceRender() {
        self.renderCurrentFrame()
    }

    /// Clears the icon cache
    func clearCache() {
        self.iconCache.removeAll()
        self.logger.debug("Icon cache cleared")
    }

    // MARK: - Private Methods

    private func startAnimation() {
        guard !self.isAnimating else { return }

        self.logger.info("Starting ghost animation")
        self.isAnimating = true

        // Start with fast updates for smooth animation
        self.startAdaptiveTimer(interval: 0.0167) // 60 fps initially

        // Render initial frame
        self.renderCurrentFrame()
    }

    private func stopAnimation() {
        guard self.isAnimating else { return }

        self.logger.info("Stopping ghost animation")
        self.isAnimating = false

        // Stop timer - invalidate on main queue since Timer is main queue bound
        let timer = self.animationTimer
        self.animationTimer = nil
        timer?.invalidate()

        // Render final static frame
        self.renderCurrentFrame()
    }

    private func startAdaptiveTimer(interval: TimeInterval) {
        self.animationTimer?.invalidate()

        self.animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                self.renderCurrentFrame()

                // Adaptive timing based on animation needs
                let currentInterval = interval
                let targetInterval: TimeInterval = if self.isAnimating {
                    // Active animation
                    if self.framesSinceLastChange < 5 {
                        0.0167 // 60 fps for smooth animation
                    } else {
                        0.033 // 30 fps when movement is subtle
                    }
                } else {
                    0.5 // Very slow when static
                }

                // Only restart timer if interval needs significant change
                if abs(currentInterval - targetInterval) > 0.005 {
                    self.startAdaptiveTimer(interval: targetInterval)
                }
            }
        }
    }

    private func renderCurrentFrame() {
        let state = self.makeIconFrameState()
        self.updateFrameTracking(with: state)

        if let cachedIcon = iconCache[state.cacheKey] {
            self.onIconUpdateNeeded?(cachedIcon)
            return
        }

        let icon = self.createGhostIcon(for: state)
        self.iconCache[state.cacheKey] = icon
        self.trimCacheIfNeeded()
        self.onIconUpdateNeeded?(icon)
    }

    private func makeIconFrameState() -> IconFrameState {
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let animationTime = Date().timeIntervalSinceReferenceDate
        let animationPhase = self.isAnimating ? animationTime.truncatingRemainder(dividingBy: 3.0) / 3.0 : 0

        let verticalOffset = self.isAnimating ? sin(animationPhase * .pi * 2) * 2.0 : 0
        let horizontalOffset = self.isAnimating ? cos(animationPhase * .pi * 2 * 1.2) * 1.0 : 0
        let scale = self.isAnimating ? 1.0 + sin(animationPhase * .pi * 2 * 0.8) * 0.1 : 1.0
        let opacity = self.isAnimating ? 0.8 + sin(animationPhase * .pi * 2 * 0.9) * 0.2 : 1.0

        let cacheKey = GhostIconCacheKey(
            isAnimating: self.isAnimating,
            verticalOffset: Int(round(verticalOffset)),
            horizontalOffset: Int(round(horizontalOffset)),
            scale: Int(round(scale * 10)),
            opacity: Int(round(opacity * 10)),
            isDarkMode: isDarkMode)

        return IconFrameState(
            isDarkMode: isDarkMode,
            verticalOffset: CGFloat(verticalOffset),
            horizontalOffset: CGFloat(horizontalOffset),
            scale: CGFloat(scale),
            opacity: CGFloat(opacity),
            cacheKey: cacheKey)
    }

    private func updateFrameTracking(with state: IconFrameState) {
        let frameChanged = abs(Double(state.verticalOffset) - self.lastRenderedFrame.vOffset) > 0.25 ||
            abs(Double(state.horizontalOffset) - self.lastRenderedFrame.hOffset) > 0.25 ||
            abs(Double(state.scale) - self.lastRenderedFrame.scale) > 0.02 ||
            abs(Double(state.opacity) - self.lastRenderedFrame.opacity) > 0.03

        if frameChanged {
            self.framesSinceLastChange = 0
            self.lastRenderedFrame = (
                Double(state.verticalOffset),
                Double(state.horizontalOffset),
                Double(state.scale),
                Double(state.opacity))
        } else {
            self.framesSinceLastChange += 1
        }
    }

    private func createGhostIcon(for state: IconFrameState) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let context = NSGraphicsContext.current!.cgContext
            context.saveGState()

            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: state.scale, y: state.scale)
            context.translateBy(x: state.horizontalOffset, y: state.verticalOffset)
            context.translateBy(x: -rect.midX, y: -rect.midY)
            context.setAlpha(state.opacity)

            if let menuIcon = NSImage(named: "MenuIcon") {
                self.draw(menuIcon: menuIcon, in: rect)
            } else {
                self.drawFallbackIcon(in: rect)
            }

            context.restoreGState()
            return true
        }

        image.isTemplate = true
        return image
    }

    private func trimCacheIfNeeded() {
        guard self.iconCache.count > self.maxCacheSize else { return }
        let entriesToRemove = self.iconCache.count - self.maxCacheSize
        self.iconCache.keys.prefix(entriesToRemove).forEach { self.iconCache.removeValue(forKey: $0) }
    }

    private func draw(menuIcon: NSImage, in rect: NSRect) {
        let iconSize = menuIcon.size
        let scale = min(rect.width / iconSize.width, rect.height / iconSize.height)
        let scaledSize = NSSize(width: iconSize.width * scale, height: iconSize.height * scale)
        let drawRect = NSRect(
            x: rect.midX - scaledSize.width / 2,
            y: rect.midY - scaledSize.height / 2,
            width: scaledSize.width,
            height: scaledSize.height)
        menuIcon.draw(in: drawRect)
    }

    private func drawFallbackIcon(in rect: NSRect) {
        NSColor.controlAccentColor.set()
        let fallbackPath = NSBezierPath(ovalIn: rect.insetBy(dx: 4, dy: 4))
        fallbackPath.fill()
    }

    deinit {
        logger.info("MenuBarAnimationController deallocated")
    }
}
