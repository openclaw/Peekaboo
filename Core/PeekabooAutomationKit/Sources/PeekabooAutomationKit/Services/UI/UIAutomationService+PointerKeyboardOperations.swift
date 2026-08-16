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
        _ = try await self.scrollWithOutcome(request)
    }

    public func scrollWithOutcome(_ request: ScrollRequest) async throws -> UIAutomationActionResult<Void> {
        self.logger.debug("Delegating scroll to ScrollService")
        var visualizerTarget: VisualizerTargetWindow?
        let result = try await self.normalizingSnapshotErrors {
            try await self.scrollService.scrollWithLanePreparation(
                request,
                lanePreparation: {
                    visualizerTarget = await self.visualizerTargetWindow(snapshotId: request.snapshotId)
                },
                laneCompletion: { result in
                    await self.visualizeScroll(
                        request,
                        actionAnchor: result.anchorPoint,
                        visualizerTarget: visualizerTarget)
                })
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: result.outcome,
            targetIdentity: result.targetIdentity)
    }

    /// Background scrolls are AX actions scoped to a snapshot element and never emit foreground feedback.
    func visualizeScroll(
        _ request: ScrollRequest,
        actionAnchor: CGPoint?,
        visualizerTarget: VisualizerTargetWindow? = nil) async
    {
        guard request.foreground else { return }
        let feedbackPoint = actionAnchor ?? InputDriver.currentLocation() ?? .zero
        _ = await self.feedbackClient.showScrollFeedback(
            at: feedbackPoint,
            direction: request.direction,
            amount: request.amount,
            target: visualizerTarget ?? VisualizerTargetWindowResolver.frontmostWindow())
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
        _ = try await self.hotkeyWithOutcome(keys: keys, holdDuration: holdDuration)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int) async throws -> UIAutomationActionResult<Void>
    {
        self.logger.debug("Delegating hotkey to HotkeyService")
        var visualizerTarget: VisualizerTargetWindow?
        let result = try await self.hotkeyService.hotkeyWithLanePreparation(
            keys: keys,
            holdDuration: holdDuration,
            lanePreparation: {
                visualizerTarget = VisualizerTargetWindowResolver.frontmostWindow()
            },
            laneCompletion: { _ in
                await self.visualizeHotkey(
                    keys: keys,
                    targetProcessIdentifier: nil,
                    visualizerTarget: visualizerTarget)
            })
        return UIAutomationActionResult(payload: (), outcome: result.outcome)
    }

    public func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            targetProcessIdentifier: targetProcessIdentifier)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t) async throws -> UIAutomationActionResult<Void>
    {
        self.logger.debug("Delegating targeted hotkey to HotkeyService")
        let automationTarget: UIAutomationTarget = try .process(UIAutomationTarget.Process(
            processIdentifier: targetProcessIdentifier))
        let result = try await self.hotkeyService.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            automationTarget: automationTarget)

        await self.visualizeHotkey(keys: keys, targetProcessIdentifier: targetProcessIdentifier)
        return UIAutomationActionResult(payload: (), outcome: result.outcome)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws
    {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            expectedProcessIdentity: expectedProcessIdentity)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        let automationTarget: UIAutomationTarget = try .process(UIAutomationTarget.Process(
            processIdentifier: expectedProcessIdentity.processIdentifier,
            identity: expectedProcessIdentity))
        let validator: @MainActor @Sendable () async throws -> Void = {
            guard self.processStartIdentityProvider(expectedProcessIdentity.processIdentifier) ==
                expectedProcessIdentity.processStartIdentity
            else {
                throw PeekabooError.invalidInput(
                    "Background hotkey target process exited or changed process generation")
            }
        }
        let result = try await self.hotkeyService.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            automationTarget: automationTarget,
            deliveryValidator: validator)
        return UIAutomationActionResult(payload: (), outcome: result.outcome)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws -> UIAutomationActionResult<Void>
    {
        let automationTarget: UIAutomationTarget = try .exactWindow(UIAutomationTarget.ExactWindow(
            identity: expectedWindowIdentity,
            bounds: expectedWindowBounds))
        let validator: @MainActor @Sendable () async throws -> Void = {
            try await self.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds)
        }
        let result = try await self.hotkeyService.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            automationTarget: automationTarget,
            deliveryValidator: validator)
        return UIAutomationActionResult(payload: (), outcome: result.outcome)
    }

    public func hotkey(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws
    {
        _ = try await self.hotkeyWithOutcome(
            keys: keys,
            holdDuration: holdDuration,
            target: target)
    }

    public func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: ExactWindowKeyboardTarget) async throws -> UIAutomationActionResult<Void>
    {
        let automationTarget: UIAutomationTarget = try .exactWindow(UIAutomationTarget.ExactWindow(
            identity: target.windowIdentity,
            bounds: target.windowBounds,
            focusedElement: target.focusedElement))
        let validator: @MainActor @Sendable () async throws -> Void = {
            try await self.requireExactWindowKeyboardFocus(
                expectedWindowIdentity: target.windowIdentity,
                expectedWindowBounds: target.windowBounds,
                expectedFocusedElement: target.focusedElement)
        }
        let result = try await self.hotkeyService.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            automationTarget: automationTarget,
            deliveryValidator: validator)
        return UIAutomationActionResult(payload: (), outcome: result.outcome)
    }

    /// PID-routed hotkeys are background operations and never emit foreground feedback.
    func visualizeHotkey(
        keys: String,
        targetProcessIdentifier: pid_t?,
        visualizerTarget: VisualizerTargetWindow? = nil) async
    {
        guard targetProcessIdentifier == nil else { return }
        let keyArray = keys.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        _ = await self.feedbackClient.showHotkeyDisplay(
            keys: keyArray,
            duration: 1.0,
            target: visualizerTarget ?? VisualizerTargetWindowResolver.frontmostWindow())
    }

    // MARK: - Gesture Operations

    public func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.debug("Delegating swipe to GestureService")
            defer { self.elementDetectionService.invalidateCache() }
            _ = await self.feedbackClient.showSwipeGesture(
                from: from,
                to: to,
                duration: TimeInterval(duration) / 1000.0,
                target: VisualizerTargetWindowResolver.frontmostWindow())
            try await self.gestureService.swipe(
                from: from,
                to: to,
                duration: duration,
                steps: steps,
                profile: profile)
        }
    }

    public func drag(_ request: DragOperationRequest) async throws {
        _ = try await self.dragWithOutcome(request)
    }

    public func dragWithOutcome(_ request: DragOperationRequest) async throws -> UIAutomationActionResult<Void> {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.debug("Delegating drag to GestureService")
            defer { self.elementDetectionService.invalidateCache() }
            _ = await self.feedbackClient.showSwipeGesture(
                from: request.from,
                to: request.to,
                duration: TimeInterval(request.duration) / 1000.0,
                target: VisualizerTargetWindowResolver.frontmostWindow())
            try await self.gestureService.drag(request)
            return UIAutomationActionResult(
                payload: (),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one))
        }
    }

    public func moveMouse(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        _ = try await self.moveMouseWithOutcome(
            to: to,
            duration: duration,
            steps: steps,
            profile: profile)
    }

    public func moveMouseWithOutcome(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws -> UIAutomationActionResult<Void>
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.debug("Delegating moveMouse to GestureService")
            defer { self.elementDetectionService.invalidateCache() }

            let fromPoint = InputDriver.currentLocation() ?? to
            // Dispatch before moving so the overlay follows the real pointer instead of replaying it afterward.
            _ = await self.feedbackClient.showMouseMovement(
                from: fromPoint,
                to: to,
                duration: TimeInterval(duration) / 1000.0,
                target: VisualizerTargetWindowResolver.frontmostWindow())
            try await self.gestureService.moveMouse(to: to, duration: duration, steps: steps, profile: profile)
            return UIAutomationActionResult(
                payload: (),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one))
        }
    }

    public func currentMouseLocation() -> CGPoint? {
        InputDriver.currentLocation()
    }
}
