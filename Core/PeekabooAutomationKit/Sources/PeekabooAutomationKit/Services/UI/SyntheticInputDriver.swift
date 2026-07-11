import AXorcist
import CoreGraphics
import Foundation
import enum PeekabooFoundation.PeekabooError

@MainActor
protocol SyntheticInputDriving: Sendable {
    func click(at point: CGPoint, button: MouseButton, count: Int) throws
    func click(at point: CGPoint, button: MouseButton, count: Int, targetProcessIdentifier: pid_t) async throws
    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID?) async throws
    func move(to point: CGPoint) throws
    func currentLocation() -> CGPoint?
    func pressHold(at point: CGPoint, button: MouseButton, duration: TimeInterval) async throws
    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws
    func type(_ text: String, delayPerCharacter: TimeInterval) throws
    func tapKey(_ key: SpecialKey, modifiers: CGEventFlags) throws
    func hotkey(keys: [String], holdDuration: TimeInterval) throws
}

extension SyntheticInputDriving {
    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID?) async throws
    {
        guard targetWindowID == nil else {
            throw PeekabooError.serviceUnavailable(
                "Synthetic input driver does not support exact-window click delivery")
        }
        try await self.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: targetProcessIdentifier)
    }
}

/// Thin injectable wrapper over AXorcist's low-level synthetic input helpers.
@MainActor
struct SyntheticInputDriver: SyntheticInputDriving {
    private let postEventAccessEvaluator: @MainActor @Sendable () -> Bool
    private let eventPoster: @MainActor @Sendable (CGEvent) -> Void
    private let holdSleeper: @MainActor @Sendable (TimeInterval) async throws -> Void

    init(
        postEventAccessEvaluator: @escaping @MainActor @Sendable () -> Bool = {
            CGPreflightPostEventAccess()
        },
        eventPoster: @escaping @MainActor @Sendable (CGEvent) -> Void = { event in
            event.post(tap: .cghidEventTap)
        },
        holdSleeper: @escaping @MainActor @Sendable (TimeInterval) async throws -> Void = { duration in
            try await ContinuousClock().sleep(for: .seconds(duration))
        })
    {
        self.postEventAccessEvaluator = postEventAccessEvaluator
        self.eventPoster = eventPoster
        self.holdSleeper = holdSleeper
    }

    func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) throws {
        try InputDriver.click(at: point, button: button, count: count)
    }

    func click(
        at point: CGPoint,
        button: MouseButton = .left,
        count: Int = 1,
        targetProcessIdentifier: pid_t) async throws
    {
        try await self.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: nil)
    }

    func click(
        at point: CGPoint,
        button: MouseButton = .left,
        count: Int = 1,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID?) async throws
    {
        try await BackgroundInputDriver.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID)
    }

    func move(to point: CGPoint) throws {
        try InputDriver.move(to: point)
    }

    func currentLocation() -> CGPoint? {
        InputDriver.currentLocation()
    }

    func pressHold(at point: CGPoint, button: MouseButton = .left, duration: TimeInterval) async throws {
        guard self.postEventAccessEvaluator() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }
        let events = try Self.makePressHoldEvents(at: point, button: button)
        self.eventPoster(events.down)
        defer { self.eventPoster(events.up) }
        if duration > 0 {
            try await self.holdSleeper(duration)
        }
    }

    static func makePressHoldEvents(
        at point: CGPoint,
        button: MouseButton) throws -> (down: CGEvent, up: CGEvent)
    {
        let cgButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        guard let down = CGEvent(
            mouseEventSource: nil,
            mouseType: downType,
            mouseCursorPosition: point,
            mouseButton: cgButton),
            let up = CGEvent(
                mouseEventSource: nil,
                mouseType: upType,
                mouseCursorPosition: point,
                mouseButton: cgButton)
        else {
            throw UIAutomationError.failedToCreateEvent
        }
        return (down, up)
    }

    func scroll(deltaX: Double = 0, deltaY: Double, at point: CGPoint? = nil) throws {
        try InputDriver.scroll(deltaX: deltaX, deltaY: deltaY, at: point)
    }

    func type(_ text: String, delayPerCharacter: TimeInterval = 0.0) throws {
        try InputDriver.type(text, delayPerCharacter: delayPerCharacter)
    }

    func tapKey(_ key: SpecialKey, modifiers: CGEventFlags = []) throws {
        try InputDriver.tapKey(key, modifiers: modifiers)
    }

    func hotkey(keys: [String], holdDuration: TimeInterval = 0.1) throws {
        try InputDriver.hotkey(keys: keys, holdDuration: holdDuration)
    }
}
