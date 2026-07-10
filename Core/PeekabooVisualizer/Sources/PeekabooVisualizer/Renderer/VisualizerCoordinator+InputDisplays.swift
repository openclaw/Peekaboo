import CoreGraphics
import Foundation
import PeekabooFoundation
import SwiftUI

// MARK: - Input Display Methods

@available(macOS 14.0, *)
extension VisualizerCoordinator {
    func displayScreenshotFlash(in rect: CGRect, showGhost: Bool) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.screenshotFlashEnabled ?? true
        else {
            self.logger.info("📸 Visualizer: Screenshot flash disabled in settings")
            return false
        }

        let intensity = self.settings?.visualizerEffectIntensity ?? 1.0
        let message = [
            "📸 Visualizer: Creating screenshot flash view",
            "showGhost: \(showGhost)",
            "intensity: \(intensity)",
        ].joined(separator: ", ")
        self.logger.info("\(message, privacy: .public)")

        // Create flash view
        let flashView = ScreenshotFlashView(
            showGhost: showGhost,
            intensity: intensity)

        // The veil must cover exactly the captured rect, so no chrome margin.
        _ = self.overlayManager.showAnimation(
            at: rect,
            content: flashView,
            duration: self.scaledDuration(AnimationBaseline.screenshotFlash, applySlowdown: false),
            fadeOut: false,
            chromeMargin: 0)

        return true
    }

    func displayWatchHUD(in rect: CGRect, sequence: Int) async -> Bool {
        guard self.isEnabled() else { return false }
        guard self.settings?.watchCaptureHUDEnabled ?? true else { return false }
        let view = WatchCaptureHUDView(sequence: sequence)
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.watchHUD),
            content: view,
            duration: self.scaledDuration(2.4),
            fadeOut: true,
            replaceKey: OverlaySlot.watchHUD)
        return true
    }

    func displayClickAnimation(at point: CGPoint, type: ClickType) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.clickAnimationEnabled ?? true
        else {
            return false
        }

        // Create click animation view
        let clickView = ClickAnimationView(
            clickType: type,
            durationScale: self.durationScaledAnimationSpeed)

        // Calculate window rect centered on click point
        let size: CGFloat = 320
        let rect = CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.click),
            content: clickView,
            duration: self.scaledDuration(AnimationBaseline.clickCursor),
            fadeOut: true)

        return true
    }

    func displayTypingWidget(keys: [String], duration: TimeInterval, cadence: TypingCadence?) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.typeAnimationEnabled ?? true
        else {
            return false
        }

        // Create typing caption view
        let overlayDuration = self.scaledDuration(for: duration, minimum: AnimationBaseline.typingOverlay)
        let typingView = TypeAnimationView(
            keys: keys,
            cadence: cadence,
            durationScale: self.durationScaledAnimationSpeed,
            displayDuration: overlayDuration)

        // Position at bottom center of the screen where mouse is located
        let screen = self.getTargetScreen()
        let screenFrame = screen.frame
        let widgetSize = CGSize(width: 680, height: 120)
        let rect = CGRect(
            x: screenFrame.midX - widgetSize.width / 2,
            y: screenFrame.minY + 60,
            width: widgetSize.width,
            height: widgetSize.height)

        // Display using overlay manager; consecutive type commands crossfade
        // through the shared typing slot instead of stacking captions.
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.typing),
            content: typingView,
            duration: overlayDuration,
            fadeOut: true,
            replaceKey: OverlaySlot.typing)

        return true
    }

    func displayScrollIndicators(
        at point: CGPoint,
        direction: ScrollDirection,
        amount: Int) async -> Bool
    {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.scrollAnimationEnabled ?? true
        else {
            return false
        }

        // Create scroll indicator view
        let scrollView = ScrollAnimationView(
            direction: direction,
            amount: amount,
            durationScale: self.durationScaledAnimationSpeed)

        // Position near scroll point
        let size: CGFloat = 100
        let rect = CGRect(
            x: point.x - size / 2,
            y: point.y - size / 2,
            width: size,
            height: size)

        // Display using overlay manager
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: Self.OverlayPadding.scroll),
            content: scrollView,
            duration: self.scaledDuration(AnimationBaseline.scrollIndicator),
            fadeOut: true)

        return true
    }

    func displayMouseTrail(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.mouseTrailEnabled ?? true
        else {
            return false
        }

        // Overlay window spanning the travel path plus breathing room
        let windowRect = Self.travelWindowRect(
            from: from,
            to: to,
            padding: Self.OverlayPadding.mouseTrail + 50)

        // Create mouse trail view with window-local coordinates
        let mouseDuration = self.scaledDuration(for: duration, minimum: AnimationBaseline.mouseTrail)
        let mouseView = MouseTrailView(
            from: Self.windowLocalPoint(from, in: windowRect),
            to: Self.windowLocalPoint(to, in: windowRect),
            duration: mouseDuration)

        // Cursor-trail coordinates are window-local; the travel padding is the margin.
        _ = self.overlayManager.showAnimation(
            at: windowRect,
            content: mouseView,
            duration: mouseDuration + 0.35,
            fadeOut: true,
            chromeMargin: 0)

        return true
    }

    func displaySwipeAnimation(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.swipePathEnabled ?? true
        else {
            return false
        }

        // Overlay window spanning the gesture plus breathing room
        let windowRect = Self.travelWindowRect(
            from: from,
            to: to,
            padding: Self.OverlayPadding.swipe + 100)

        // Create swipe path view with window-local coordinates
        let swipeDuration = self.scaledDuration(for: duration, minimum: AnimationBaseline.swipePath)
        let swipeView = SwipePathView(
            from: Self.windowLocalPoint(from, in: windowRect),
            to: Self.windowLocalPoint(to, in: windowRect),
            duration: swipeDuration)

        // Comet coordinates are window-local; the travel padding is the margin.
        _ = self.overlayManager.showAnimation(
            at: windowRect,
            content: swipeView,
            duration: swipeDuration + 0.35,
            fadeOut: true,
            chromeMargin: 0)

        return true
    }

    func displayHotkeyOverlay(keys: [String], duration: TimeInterval) async -> Bool {
        // Check if enabled
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.hotkeyOverlayEnabled ?? true
        else {
            return false
        }

        let overlayDuration = self.scaledDuration(for: duration, minimum: AnimationBaseline.hotkeyOverlay)
        // Create hotkey overlay view
        let hotkeyView = HotkeyOverlayView(
            keys: keys,
            duration: overlayDuration)

        // Position at center of screen where mouse is located
        let screen = self.getTargetScreen()
        let screenFrame = screen.frame
        let overlaySize = Self.estimatedHotkeyOverlaySize(for: keys)
        let rect = CGRect(
            x: screenFrame.midX - overlaySize.width / 2,
            y: screenFrame.midY - overlaySize.height / 2,
            width: overlaySize.width,
            height: overlaySize.height)

        // Display using overlay manager; repeated hotkeys crossfade through
        // the shared slot instead of stacking chips.
        _ = self.overlayManager.showAnimation(
            at: Self.paddedRect(rect, padding: 0),
            content: hotkeyView,
            duration: overlayDuration,
            fadeOut: true,
            replaceKey: OverlaySlot.hotkey)

        return true
    }
}
