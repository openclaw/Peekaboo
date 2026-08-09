import CoreGraphics
import Foundation
import PeekabooFoundation
import PeekabooProtocols

@available(macOS 14.0, *)
@MainActor
extension VisualizerCoordinator {
    public func showScreenshotFlash(in rect: CGRect) async -> Bool {
        let now = Date()
        guard now.timeIntervalSince(self.lastScreenshotFlashDate) >= FeedbackThrottle.screenshotFlash else {
            return true
        }
        self.lastScreenshotFlashDate = now
        return await self.animationQueue.enqueue(priority: .high) {
            await self.displayScreenshotBorder(in: rect)
        }
    }

    public func showWatchCapture(in rect: CGRect) async -> Bool {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.captureIndicatorsEnabled ?? true
        else {
            return false
        }
        let now = Date()
        guard now.timeIntervalSince(self.lastWatchHUDDate) >= 1 else { return true }
        self.lastWatchHUDDate = now
        let sequence = self.watchHUDSequence % WatchCaptureHUDView.Constants.timelineSegments
        self.watchHUDSequence = (self.watchHUDSequence + 1) % WatchCaptureHUDView.Constants.timelineSegments
        let hudSize = CGSize(width: 220, height: 48)
        let screen = self.getTargetScreen(for: CGPoint(x: rect.midX, y: rect.midY))
        let origin = CGPoint(
            x: max(screen.frame.minX + 16, min(rect.midX - hudSize.width / 2, screen.frame.maxX - hudSize.width - 16)),
            y: max(screen.frame.minY + 16, min(rect.minY + 24, screen.frame.maxY - hudSize.height - 16)))
        return await self.animationQueue.enqueue(priority: .low) {
            await self.displayWatchHUD(in: CGRect(origin: origin, size: hudSize), sequence: sequence)
        }
    }

    public func showClickFeedback(
        at point: CGPoint,
        type: ClickType,
        target: VisualizerTargetWindow? = nil) async -> Bool
    {
        if let target, self.visibleTargetWindow(target) == nil {
            return false
        }
        return await self.animationQueue.enqueue(priority: .high) {
            if let target, await self.visibleTargetWindow(target) == nil {
                return false
            }
            return await self.displayClickPulse(at: point, type: type)
        }
    }

    public func showTypingFeedback(
        keys: [String],
        duration: TimeInterval,
        cadence _: TypingCadence?,
        target: VisualizerTargetWindow?) async -> Bool
    {
        guard let target, self.visibleTargetWindow(target) != nil else { return false }
        return await self.animationQueue.enqueue(priority: .normal) {
            guard let visibleTarget = await self.visibleTargetWindow(target) else { return false }
            return await self.displayInputHUD(
                .typing(keys),
                target: visibleTarget,
                duration: self.scaledDuration(for: duration, minimum: AnimationBaseline.inputHUD))
        }
    }

    public func showScrollFeedback(
        at _: CGPoint,
        direction: ScrollDirection,
        amount: Int,
        target: VisualizerTargetWindow?) async -> Bool
    {
        guard let target, self.visibleTargetWindow(target) != nil else { return false }
        let now = Date()
        guard now.timeIntervalSince(self.lastScrollDate) >= FeedbackThrottle.scroll else { return true }
        self.lastScrollDate = now
        return await self.animationQueue.enqueue(priority: .normal) {
            guard let visibleTarget = await self.visibleTargetWindow(target) else { return false }
            return await self.displayInputHUD(
                .scroll(direction, amount),
                target: visibleTarget,
                duration: self.scaledDuration(AnimationBaseline.inputHUD))
        }
    }

    public func showHotkeyDisplay(
        keys: [String],
        duration: TimeInterval,
        target: VisualizerTargetWindow?) async -> Bool
    {
        guard let target, self.visibleTargetWindow(target) != nil else { return false }
        return await self.animationQueue.enqueue(priority: .high) {
            guard let visibleTarget = await self.visibleTargetWindow(target) else { return false }
            return await self.displayInputHUD(
                .hotkey(keys),
                target: visibleTarget,
                duration: self.scaledDuration(for: duration, minimum: AnimationBaseline.inputHUD))
        }
    }

    public func showMouseMovement(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        // The agent cursor is intentionally screen-space. Background-routed
        // inputs are suppressed by the interaction layer; a foreground window
        // may legitimately deactivate while the pointer is still moving.
        guard duration >= FeedbackThrottle.minimumPointerDuration,
              hypot(to.x - from.x, to.y - from.y) >= FeedbackThrottle.minimumCursorDistance
        else {
            return true
        }
        let now = Date()
        guard now.timeIntervalSince(self.lastAgentCursorDate) >= FeedbackThrottle.agentCursor else { return true }
        self.lastAgentCursorDate = now
        return await self.animationQueue.enqueue(priority: .low) {
            await self.displayAgentCursor(from: from, to: to, duration: duration, isPressed: false)
        }
    }

    public func showSwipeGesture(
        from: CGPoint,
        to: CGPoint,
        duration: TimeInterval,
        target _: VisualizerTargetWindow? = nil) async -> Bool
    {
        // Pressed drag/swipe motion follows the same screen-space rule as an
        // unpressed agent cursor.
        await self.animationQueue.enqueue(priority: .normal) {
            await self.displayAgentCursor(from: from, to: to, duration: duration, isPressed: true)
        }
    }

    public func showElementDetection(elements: [String: CGRect], duration: TimeInterval) async -> Bool {
        let now = Date()
        guard now.timeIntervalSince(self.lastElementDetectionDate) >= FeedbackThrottle.elementDetection else {
            return true
        }
        self.lastElementDetectionDate = now
        return await self.animationQueue.enqueue {
            await self.displayElementOverlays(elements: elements, duration: duration)
        }
    }

    public func showAnnotatedScreenshot(
        imageData: Data,
        elements: [DetectedElement],
        windowBounds: CGRect,
        duration: TimeInterval) async -> Bool
    {
        await self.animationQueue.enqueue(priority: .high) {
            await self.displayAnnotatedScreenshot(
                imageData: imageData,
                elements: elements,
                windowBounds: windowBounds,
                duration: duration)
        }
    }
}
