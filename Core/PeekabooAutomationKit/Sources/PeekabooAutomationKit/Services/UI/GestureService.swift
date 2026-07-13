@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Service for handling gesture operations (swipe, drag, mouse movement)
@MainActor
public final class GestureService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "GestureService")

    struct HeldModifierKey: Equatable {
        let name: String
        let keyCode: CGKeyCode
        let flag: CGEventFlags
    }

    public init() {}

    /// Perform a swipe gesture
    public func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        let gestureDescription = self.describeGesture(
            name: "Swipe requested",
            details: [
                "from: (\(from.x), \(from.y))",
                "to: (\(to.x), \(to.y))",
                "duration: \(duration)ms",
                "steps: \(steps)",
                "profile: \(profile.logDescription)",
            ])
        self.logger.debug("\(gestureDescription)")

        try self.ensurePositiveSteps(steps, action: "Swipe")

        let path = self.buildGesturePath(
            from: from,
            to: to,
            duration: duration,
            steps: steps,
            profile: profile)
        try await self.performSwipe(path: path, start: from, button: .left)

        self.logger.debug("Swipe completed")
    }

    /// Perform a drag operation with optional modifiers
    public func drag(_ request: DragOperationRequest) async throws {
        // Perform a drag operation with optional modifiers
        let gestureDescription = self.describeGesture(
            name: "Drag requested",
            details: [
                "from: (\(request.from.x), \(request.from.y))",
                "to: (\(request.to.x), \(request.to.y))",
                "duration: \(request.duration)ms",
                "modifiers: \(request.modifiers ?? "none")",
                "profile: \(request.profile.logDescription)",
            ])
        self.logger.debug("\(gestureDescription)")

        try self.ensurePositiveSteps(request.steps, action: "Drag")

        let path = self.buildGesturePath(
            from: request.from,
            to: request.to,
            duration: request.duration,
            steps: request.steps,
            profile: request.profile)
        let modifierKeys = Self.heldModifierKeys(for: request.modifiers)
        let modifierEvents = try self.makeModifierEvents(for: modifierKeys)
        modifierEvents.down.forEach { $0.post(tap: .cghidEventTap) }
        defer {
            modifierEvents.up.forEach { $0.post(tap: .cghidEventTap) }
        }

        try await self.performDrag(path: path, start: request.from)

        self.logger.debug("Drag completed")
    }

    /// Move mouse to a specific point
    public func moveMouse(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        let gestureDescription = self.describeGesture(
            name: "Mouse move requested",
            details: [
                "to: (\(to.x), \(to.y))",
                "duration: \(duration)ms",
                "steps: \(steps)",
                "profile: \(profile.logDescription)",
            ])
        self.logger.debug("\(gestureDescription)")

        try self.ensurePositiveSteps(steps, action: "Mouse move")

        let startPoint = self.getCurrentMouseLocation()
        let distance = hypot(to.x - startPoint.x, to.y - startPoint.y)

        switch profile {
        case .linear:
            let path = self.linearPath(from: startPoint, to: to, steps: steps)
            try await self.playPath(path, duration: duration)
        case let .human(configuration):
            let generator = HumanMousePathGenerator(
                start: startPoint,
                target: to,
                distance: distance,
                duration: duration,
                stepsHint: steps,
                configuration: configuration)
            let path = generator.generate()
            try await self.playPath(path.points, duration: path.duration)
        }

        self.logger.debug("Mouse move completed")
    }

    // MARK: - Private Methods

    private func getCurrentMouseLocation() -> CGPoint {
        // Prefer AXorcist InputDriver move-less lookup; default to .zero when unavailable
        InputDriver.currentLocation() ?? .zero
    }

    private func describeGesture(name: String, details: [String]) -> String {
        ([name] + details).joined(separator: " | ")
    }

    private func ensurePositiveSteps(_ steps: Int, action: String) throws {
        guard steps > 0 else {
            throw PeekabooError.invalidInput("\(action) requires at least one step")
        }
    }

    private func stepDelay(duration: Int, steps: Int) -> UInt64 {
        guard duration > 0, steps > 1 else { return 0 }
        let secondsPerStep = Double(duration) / 1000.0 / Double(steps - 1)
        return UInt64(secondsPerStep * 1_000_000_000)
    }

    private func performSwipe(
        path: HumanMousePath,
        start: CGPoint,
        button: MouseButton) async throws
    {
        try await self.playDragPath(path.points, from: start, button: button, duration: path.duration)
    }

    private func performDrag(
        path: HumanMousePath,
        start: CGPoint) async throws
    {
        try await self.playDragPath(path.points, from: start, button: .left, duration: path.duration)
    }

    private func makeModifierEvents(for keys: [HeldModifierKey]) throws -> (down: [CGEvent], up: [CGEvent]) {
        guard !keys.isEmpty else { return ([], []) }

        let source = CGEventSource(stateID: .hidSystemState)
        var activeFlags: CGEventFlags = []
        let downEvents: [CGEvent] = try keys.map { key in
            activeFlags.insert(key.flag)
            return try Self.makeModifierEvent(source: source, key: key, keyDown: true, flags: activeFlags)
        }

        let upEvents: [CGEvent] = try keys.reversed().map { key in
            activeFlags.remove(key.flag)
            return try Self.makeModifierEvent(source: source, key: key, keyDown: false, flags: activeFlags)
        }

        return (downEvents, upEvents)
    }

    private static func makeModifierEvent(
        source: CGEventSource?,
        key: HeldModifierKey,
        keyDown: Bool,
        flags: CGEventFlags) throws -> CGEvent
    {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: keyDown) else {
            throw PeekabooError.invalidInput("Could not create \(key.name) modifier event")
        }
        event.flags = flags
        return event
    }

    static func heldModifierKeys(for modifiers: String?) -> [HeldModifierKey] {
        guard let modifiers else { return [] }

        var seen = Set<String>()
        return modifiers
            .split(separator: ",")
            .compactMap { rawModifier -> HeldModifierKey? in
                let rawName = rawModifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let key: HeldModifierKey? = switch rawName {
                case "command", "cmd":
                    HeldModifierKey(name: "command", keyCode: 0x37, flag: .maskCommand)
                case "shift":
                    HeldModifierKey(name: "shift", keyCode: 0x38, flag: .maskShift)
                case "option", "alt":
                    HeldModifierKey(name: "option", keyCode: 0x3A, flag: .maskAlternate)
                case "control", "ctrl":
                    HeldModifierKey(name: "control", keyCode: 0x3B, flag: .maskControl)
                case "function", "fn":
                    HeldModifierKey(name: "function", keyCode: 0x3F, flag: .maskSecondaryFn)
                default:
                    nil
                }
                guard let key, !seen.contains(key.name) else { return nil }
                seen.insert(key.name)
                return key
            }
    }

    private func playPath(_ points: [CGPoint], duration: Int) async throws {
        guard !points.isEmpty else { return }
        let delay = self.stepDelay(duration: duration, steps: points.count)
        for (index, point) in points.enumerated() {
            try InputDriver.move(to: point)
            if delay > 0, index < points.count - 1 {
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }

    private func playDragPath(
        _ points: [CGPoint],
        from start: CGPoint,
        button: MouseButton,
        duration: Int) async throws
    {
        guard let end = points.last else { return }
        let mouseButton: CGMouseButton = button == .left ? .left : .right
        let downType: CGEventType = button == .left ? .leftMouseDown : .rightMouseDown
        let draggedType: CGEventType = button == .left ? .leftMouseDragged : .rightMouseDragged
        let upType: CGEventType = button == .left ? .leftMouseUp : .rightMouseUp
        guard let downEvent = CGEvent(
            mouseEventSource: nil,
            mouseType: downType,
            mouseCursorPosition: start,
            mouseButton: mouseButton),
            let upEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: upType,
                mouseCursorPosition: end,
                mouseButton: mouseButton)
        else {
            throw UIAutomationError.failedToCreateEvent
        }

        var lastPoint = start
        downEvent.post(tap: .cghidEventTap)
        defer {
            upEvent.location = lastPoint
            upEvent.post(tap: .cghidEventTap)
        }

        let delay = self.stepDelay(duration: duration, steps: points.count)
        for (index, point) in points.enumerated() {
            guard let dragEvent = CGEvent(
                mouseEventSource: nil,
                mouseType: draggedType,
                mouseCursorPosition: point,
                mouseButton: mouseButton)
            else {
                throw UIAutomationError.failedToCreateEvent
            }
            dragEvent.post(tap: .cghidEventTap)
            lastPoint = point
            if delay > 0, index < points.count - 1 {
                try await Task.sleep(nanoseconds: delay)
            }
        }
    }
}
