@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

extension UIAutomationService {
    // MARK: - Scroll Operations

    /**
     * Perform smooth scrolling operations with visual feedback.
     *
     * - Parameter request: Scroll configuration including direction, amount, target, style, and snapshot context.
     * - Throws: `PeekabooError` if target element cannot be found.
     *
     * ## Example
     * ```swift
     * let request = ScrollRequest(direction: .down, amount: 5, smooth: true, delay: 10)
     * try await automation.scroll(request)
     * ```
     */
    public func scroll(_ request: ScrollRequest) async throws {
        self.logger.debug("Delegating scroll to ScrollService")
        let result = try await self.normalizingSnapshotErrors {
            try await self.scrollService.scroll(request)
        }

        let feedbackPoint = result.anchorPoint ?? InputDriver.currentLocation() ?? .zero
        _ = await self.feedbackClient.showScrollFeedback(
            at: feedbackPoint,
            direction: request.direction,
            amount: request.amount)
    }

    // MARK: - Hotkey Operations

    /**
     * Execute keyboard shortcuts and key combinations.
     *
     * - Parameters:
     *   - keys: Comma-separated key combination (e.g., "cmd,c" for copy, "cmd,shift,t" for new tab)
     *   - holdDuration: Duration to hold keys in milliseconds (50-200ms typical)
     * - Throws: `PeekabooError` if invalid key combination or system hotkey execution fails
     *
     * ## Supported Keys
     * - Modifier keys: cmd, shift, alt, ctrl, fn
     * - Letters: a-z (case insensitive)
     * - Numbers: 0-9
     * - Special: space, return, tab, escape, delete
     * - Arrows: arrow_up, arrow_down, arrow_left, arrow_right
     * - Function: f1-f12
     *
     * ## Examples
     * ```swift
     * // Copy selection
     * try await automation.hotkey(keys: "cmd,c", holdDuration: 100)
     *
     * // Open new tab
     * try await automation.hotkey(keys: "cmd,t", holdDuration: 50)
     *
     * // Three-key combination
     * try await automation.hotkey(keys: "cmd,shift,z", holdDuration: 100)
     * ```
     */
    public func hotkey(keys: String, holdDuration: Int) async throws {
        self.logger.debug("Delegating hotkey to HotkeyService")
        _ = try await self.hotkeyService.hotkey(keys: keys, holdDuration: holdDuration)

        let keyArray = keys.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        _ = await self.feedbackClient.showHotkeyDisplay(keys: keyArray, duration: 1.0)
    }

    public func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        self.logger.debug("Delegating targeted hotkey to HotkeyService")
        _ = try await self.hotkeyService.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier)

        let keyArray = keys.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        _ = await self.feedbackClient.showHotkeyDisplay(keys: keyArray, duration: 1.0)
    }

    // MARK: - Gesture Operations

    public func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        self.logger.debug("Delegating swipe to GestureService")
        try await self.gestureService.swipe(
            from: from,
            to: to,
            duration: duration,
            steps: steps,
            profile: profile)

        _ = await self.feedbackClient.showSwipeGesture(from: from, to: to, duration: TimeInterval(duration) / 1000.0)
    }

    public func drag(_ request: DragOperationRequest) async throws {
        self.logger.debug("Delegating drag to GestureService")
        try await self.gestureService.drag(request)
    }

    public func moveMouse(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        self.logger.debug("Delegating moveMouse to GestureService")

        let fromPoint = InputDriver.currentLocation() ?? to
        try await self.gestureService.moveMouse(to: to, duration: duration, steps: steps, profile: profile)

        _ = await self.feedbackClient.showMouseMovement(
            from: fromPoint,
            to: to,
            duration: TimeInterval(duration) / 1000.0)
    }

    public func currentMouseLocation() -> CGPoint? {
        InputDriver.currentLocation()
    }
}
