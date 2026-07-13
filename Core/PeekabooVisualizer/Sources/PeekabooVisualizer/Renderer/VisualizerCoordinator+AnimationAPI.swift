import CoreGraphics
import Foundation
import PeekabooFoundation
import PeekabooProtocols

// MARK: - Animation API

@available(macOS 14.0, *)
@MainActor
extension VisualizerCoordinator {
    public func showScreenshotFlash(in rect: CGRect) async -> Bool {
        self.logger.info("📸 Visualizer: Showing screenshot flash for rect: \(String(describing: rect))")

        // Agents capture in bursts (`see` after every action); one flash per
        // burst is plenty.
        let now = Date()
        guard now.timeIntervalSince(self.lastScreenshotFlashDate) >= FeedbackThrottle.screenshotFlash else {
            return true
        }
        self.lastScreenshotFlashDate = now

        self.screenshotCount += 1
        let showGhost = self.screenshotCount % 100 == 0
        self.logger.debug("Screenshot count: \(self.screenshotCount), show ghost: \(showGhost)")

        return await self.animationQueue.enqueue(priority: .high) {
            await self.displayScreenshotFlash(in: rect, showGhost: showGhost)
        }
    }

    public func showWatchCapture(in rect: CGRect) async -> Bool {
        guard self.settings?.visualizerEnabled ?? true,
              self.settings?.watchCaptureHUDEnabled ?? true
        else {
            return false
        }

        let now = Date()
        guard now.timeIntervalSince(self.lastWatchHUDDate) >= 1.0 else {
            return true
        }
        self.lastWatchHUDDate = now
        let sequence = self.watchHUDSequence % WatchCaptureHUDView.Constants.timelineSegments
        self.watchHUDSequence = (self.watchHUDSequence + 1) % WatchCaptureHUDView.Constants.timelineSegments

        let hudSize = CGSize(width: 340, height: 70)
        let screen = self.getTargetScreen(for: CGPoint(x: rect.midX, y: rect.midY))
        var hudOrigin = CGPoint(
            x: rect.midX - hudSize.width / 2,
            y: rect.minY + 40)
        hudOrigin.x = max(screen.frame.minX + 20, min(hudOrigin.x, screen.frame.maxX - hudSize.width - 20))
        hudOrigin.y = max(screen.frame.minY + 20, min(hudOrigin.y, screen.frame.maxY - hudSize.height - 20))
        let hudRect = CGRect(origin: hudOrigin, size: hudSize)

        return await self.animationQueue.enqueue(priority: .low) {
            await self.displayWatchHUD(in: hudRect, sequence: sequence)
        }
    }

    public func showClickFeedback(at point: CGPoint, type: ClickType) async -> Bool {
        self.logger.info("🖱️ Visualizer: Showing click feedback at \(String(describing: point)), type: \(type)")

        return await self.animationQueue.enqueue(priority: .high) {
            await self.displayClickAnimation(at: point, type: type)
        }
    }

    public func showTypingFeedback(keys: [String], duration: TimeInterval, cadence: TypingCadence?) async -> Bool {
        self.logger.info("⌨️ Visualizer: Showing typing feedback for \(keys.count) keys: \(keys.joined())")

        return await self.animationQueue.enqueue(priority: .normal) {
            await self.displayTypingWidget(keys: keys, duration: duration, cadence: cadence)
        }
    }

    public func showScrollFeedback(
        at point: CGPoint,
        direction: ScrollDirection,
        amount: Int) async -> Bool
    {
        let message = [
            "📜 Visualizer: Showing scroll feedback at \(String(describing: point))",
            "direction: \(direction), amount: \(amount)",
        ].joined(separator: ", ")
        self.logger.info("\(message, privacy: .public)")

        // Scroll wheels emit streams of events; one chip per burst reads better.
        let now = Date()
        guard now.timeIntervalSince(self.lastScrollDate) >= FeedbackThrottle.scroll else {
            return true
        }
        self.lastScrollDate = now

        return await self.animationQueue.enqueue(priority: .normal) {
            await self.displayScrollIndicators(at: point, direction: direction, amount: amount)
        }
    }

    public func showMouseMovement(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        let message = [
            "🐭 Visualizer: Showing mouse movement from \(String(describing: from))",
            "to \(String(describing: to)), duration: \(duration)s",
        ].joined(separator: " ")
        self.logger.info("\(message, privacy: .public)")

        // Instant hops should stay instant. Short hops don't need a cursor trail,
        // and rapid successive moves are coalesced by the pointer overlay slot.
        guard duration >= FeedbackThrottle.minimumPointerDuration else { return true }
        let distance = hypot(to.x - from.x, to.y - from.y)
        guard distance >= FeedbackThrottle.minimumTrailDistance else { return true }
        let now = Date()
        guard now.timeIntervalSince(self.lastMouseTrailDate) >= FeedbackThrottle.mouseTrail else {
            return true
        }
        self.lastMouseTrailDate = now

        return await self.animationQueue.enqueue(priority: .low) {
            await self.displayMouseTrail(from: from, to: to, duration: duration)
        }
    }

    public func showSwipeGesture(from: CGPoint, to: CGPoint, duration: TimeInterval) async -> Bool {
        let message = [
            "👆 Visualizer: Showing swipe gesture from \(String(describing: from))",
            "to \(String(describing: to)), duration: \(duration)s",
        ].joined(separator: " ")
        self.logger.info("\(message, privacy: .public)")

        return await self.animationQueue.enqueue(priority: .normal) {
            await self.displaySwipeAnimation(from: from, to: to, duration: duration)
        }
    }

    public func showHotkeyDisplay(keys: [String], duration: TimeInterval) async -> Bool {
        self.logger.debug("Showing hotkey display for keys: \(keys)")

        return await self.animationQueue.enqueue(priority: .high) {
            await self.displayHotkeyOverlay(keys: keys, duration: duration)
        }
    }

    public func showAppLaunch(appName: String, iconPath: String?) async -> Bool {
        self.logger.debug("Showing app launch animation for: \(appName)")

        return await self.animationQueue.enqueue {
            await self.displayAppLaunchAnimation(appName: appName, iconPath: iconPath)
        }
    }

    public func showAppQuit(appName: String, iconPath: String?) async -> Bool {
        self.logger.debug("Showing app quit animation for: \(appName)")

        return await self.animationQueue.enqueue {
            await self.displayAppQuitAnimation(appName: appName, iconPath: iconPath)
        }
    }

    public func showWindowOperation(
        _ operation: WindowOperation,
        windowRect: CGRect,
        duration: TimeInterval) async -> Bool
    {
        self.logger.debug("Showing window operation: \(String(describing: operation))")

        return await self.animationQueue.enqueue {
            await self.displayWindowOperation(operation, windowRect: windowRect, duration: duration)
        }
    }

    public func showMenuNavigation(menuPath: [String]) async -> Bool {
        self.logger.debug("Showing menu navigation for path: \(menuPath)")

        return await self.animationQueue.enqueue {
            await self.displayMenuHighlights(menuPath: menuPath)
        }
    }

    public func showDialogInteraction(
        element: DialogElementType,
        elementRect: CGRect,
        action: DialogActionType) async -> Bool
    {
        let message = [
            "Showing dialog interaction: \(String(describing: element))",
            "action: \(String(describing: action))",
        ].joined(separator: " ")
        self.logger.debug("\(message, privacy: .public)")

        return await self.animationQueue.enqueue {
            await self.displayDialogFeedback(element: element, elementRect: elementRect, action: action)
        }
    }

    public func showSpaceSwitch(from: Int, to: Int, direction: SpaceDirection) async -> Bool {
        self.logger.debug("Showing space switch from \(from) to \(to)")

        return await self.animationQueue.enqueue {
            await self.displaySpaceTransition(from: from, to: to, direction: direction)
        }
    }

    public func showElementDetection(elements: [String: CGRect], duration: TimeInterval) async -> Bool {
        self.logger.debug("Showing element detection for \(elements.count) elements")

        // `see` runs back to back during agent loops; refreshing the sheet
        // once a second is plenty (each refresh replaces the previous one).
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
        self.logger.info("🎯 Visualizer: Showing annotated screenshot with \(elements.count) elements")

        return await self.animationQueue.enqueue(priority: .high) {
            await self.displayAnnotatedScreenshot(
                imageData: imageData,
                elements: elements,
                windowBounds: windowBounds,
                duration: duration)
        }
    }
}
