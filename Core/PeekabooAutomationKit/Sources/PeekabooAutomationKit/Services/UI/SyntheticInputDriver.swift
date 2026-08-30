import AXorcist
import CoreGraphics
import Foundation
import enum PeekabooFoundation.ClickType
import struct PeekabooFoundation.DesktopActionFailure
import struct PeekabooFoundation.DesktopActionOutcome
import enum PeekabooFoundation.PeekabooError

struct ExactWindowPointerTarget: Sendable {
    let identity: WindowMutationIdentity
    let bounds: CGRect
}

struct SharedInputActivityToken: Equatable, Sendable {
    private static let capsLockVirtualKeyCode: CGKeyCode = 0x39
    private let tracksActivity: Bool
    let moved: UInt32
    let leftDragged: UInt32
    let rightDragged: UInt32
    let otherDragged: UInt32
    let leftDown: UInt32
    let leftUp: UInt32
    let rightDown: UInt32
    let rightUp: UInt32
    let otherDown: UInt32
    let otherUp: UInt32
    let keyDown: UInt32
    let keyUp: UInt32
    let flagsChanged: UInt32
    let scrollWheel: UInt32
    let heldKeysLow: UInt64
    let heldKeysHigh: UInt64
    let heldMouseButtons: UInt32

    var hasHeldInput: Bool {
        self.heldKeysLow != 0 || self.heldKeysHigh != 0 || self.heldMouseButtons != 0
    }

    static let zero = Self(
        tracksActivity: false,
        moved: 0,
        leftDragged: 0,
        rightDragged: 0,
        otherDragged: 0,
        leftDown: 0,
        leftUp: 0,
        rightDown: 0,
        rightUp: 0,
        otherDown: 0,
        otherUp: 0,
        keyDown: 0,
        keyUp: 0,
        flagsChanged: 0,
        scrollWheel: 0,
        heldKeysLow: 0,
        heldKeysHigh: 0,
        heldMouseButtons: 0)
    static let trackedZero = Self(
        tracksActivity: true,
        moved: 0,
        leftDragged: 0,
        rightDragged: 0,
        otherDragged: 0,
        leftDown: 0,
        leftUp: 0,
        rightDown: 0,
        rightUp: 0,
        otherDown: 0,
        otherUp: 0,
        keyDown: 0,
        keyUp: 0,
        flagsChanged: 0,
        scrollWheel: 0,
        heldKeysLow: 0,
        heldKeysHigh: 0,
        heldMouseButtons: 0)

    static func current(
        keyStateProvider: (CGKeyCode) -> Bool = {
            CGEventSource.keyState(.combinedSessionState, key: $0)
        },
        buttonStateProvider: (CGMouseButton) -> Bool = {
            CGEventSource.buttonState(.combinedSessionState, button: $0)
        }) -> Self
    {
        let heldKeys = self.heldKeyBitmap(keyStateProvider: keyStateProvider)
        let heldMouseButtons = self.heldMouseButtonBitmap(buttonStateProvider: buttonStateProvider)
        return Self(
            tracksActivity: true,
            moved: CGEventSource.counterForEventType(.combinedSessionState, eventType: .mouseMoved),
            leftDragged: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDragged),
            rightDragged: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDragged),
            otherDragged: CGEventSource.counterForEventType(.combinedSessionState, eventType: .otherMouseDragged),
            leftDown: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseDown),
            leftUp: CGEventSource.counterForEventType(.combinedSessionState, eventType: .leftMouseUp),
            rightDown: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseDown),
            rightUp: CGEventSource.counterForEventType(.combinedSessionState, eventType: .rightMouseUp),
            otherDown: CGEventSource.counterForEventType(.combinedSessionState, eventType: .otherMouseDown),
            otherUp: CGEventSource.counterForEventType(.combinedSessionState, eventType: .otherMouseUp),
            keyDown: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown),
            keyUp: CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyUp),
            flagsChanged: CGEventSource.counterForEventType(.combinedSessionState, eventType: .flagsChanged),
            scrollWheel: CGEventSource.counterForEventType(.combinedSessionState, eventType: .scrollWheel),
            heldKeysLow: heldKeys.low,
            heldKeysHigh: heldKeys.high,
            heldMouseButtons: heldMouseButtons)
    }

    func withHeldKey(_ key: CGKeyCode) -> Self {
        guard key < 128 else { return self }
        if key < 64 {
            return self.with(heldKeysLow: self.heldKeysLow | (UInt64(1) << UInt64(key)))
        }
        return self.with(heldKeysHigh: self.heldKeysHigh | (UInt64(1) << UInt64(key - 64)))
    }

    func withHeldMouseButton(_ button: CGMouseButton) -> Self {
        guard button.rawValue < 32 else { return self }
        return self.with(heldMouseButtons: self.heldMouseButtons | (UInt32(1) << button.rawValue))
    }

    func afterModifierClick(
        _ clickType: ClickType,
        modifiers: [PointerModifier] = []) -> Self
    {
        guard self.tracksActivity else { return self }
        let count: UInt32 = switch clickType {
        case .double: 2
        case .triple: 3
        default: 1
        }
        let mouseActivity = switch clickType {
        case .right:
            self.with(rightDown: self.rightDown &+ count, rightUp: self.rightUp &+ count)
        case .middle:
            self.with(otherDown: self.otherDown &+ count, otherUp: self.otherUp &+ count)
        case .single, .double, .triple, .longPress:
            self.with(leftDown: self.leftDown &+ count, leftUp: self.leftUp &+ count)
        }
        let modifierCount = UInt32(modifiers.count)
        return mouseActivity.with(
            flagsChanged: mouseActivity.flagsChanged &+ (modifierCount &* 2))
    }

    func afterMouseMove() -> Self {
        guard self.tracksActivity else { return self }
        return self.with(moved: self.moved &+ 1)
    }

    func afterKeyboardInput() -> Self {
        guard self.tracksActivity else { return self }
        return self.with(keyDown: self.keyDown &+ 1)
    }

    func afterModifierFlagsChange() -> Self {
        guard self.tracksActivity else { return self }
        return self.with(flagsChanged: self.flagsChanged &+ 1)
    }

    func afterScrollInput() -> Self {
        guard self.tracksActivity else { return self }
        return self.with(scrollWheel: self.scrollWheel &+ 1)
    }

    private func with(
        moved: UInt32? = nil,
        leftDown: UInt32? = nil,
        leftUp: UInt32? = nil,
        rightDown: UInt32? = nil,
        rightUp: UInt32? = nil,
        otherDown: UInt32? = nil,
        otherUp: UInt32? = nil,
        keyDown: UInt32? = nil,
        keyUp: UInt32? = nil,
        flagsChanged: UInt32? = nil,
        scrollWheel: UInt32? = nil,
        heldKeysLow: UInt64? = nil,
        heldKeysHigh: UInt64? = nil,
        heldMouseButtons: UInt32? = nil) -> Self
    {
        Self(
            tracksActivity: self.tracksActivity,
            moved: moved ?? self.moved,
            leftDragged: self.leftDragged,
            rightDragged: self.rightDragged,
            otherDragged: self.otherDragged,
            leftDown: leftDown ?? self.leftDown,
            leftUp: leftUp ?? self.leftUp,
            rightDown: rightDown ?? self.rightDown,
            rightUp: rightUp ?? self.rightUp,
            otherDown: otherDown ?? self.otherDown,
            otherUp: otherUp ?? self.otherUp,
            keyDown: keyDown ?? self.keyDown,
            keyUp: keyUp ?? self.keyUp,
            flagsChanged: flagsChanged ?? self.flagsChanged,
            scrollWheel: scrollWheel ?? self.scrollWheel,
            heldKeysLow: heldKeysLow ?? self.heldKeysLow,
            heldKeysHigh: heldKeysHigh ?? self.heldKeysHigh,
            heldMouseButtons: heldMouseButtons ?? self.heldMouseButtons)
    }

    private static func heldKeyBitmap(
        keyStateProvider: (CGKeyCode) -> Bool) -> (low: UInt64, high: UInt64)
    {
        var low: UInt64 = 0
        var high: UInt64 = 0
        // Caps Lock's key state is the persistent latch, not physical-down state. Exclude it from
        // the held bitmap: it never autorepeats, while every down/up transition still changes the
        // flagsChanged counter already bound into this token and therefore revokes ownership.
        for key in CGKeyCode(0)..<CGKeyCode(128)
            where key != self.capsLockVirtualKeyCode && keyStateProvider(key)
        {
            if key < 64 {
                low |= UInt64(1) << UInt64(key)
            } else {
                high |= UInt64(1) << UInt64(key - 64)
            }
        }
        return (low, high)
    }

    private static func heldMouseButtonBitmap(
        buttonStateProvider: (CGMouseButton) -> Bool) -> UInt32
    {
        var bitmap: UInt32 = 0
        // CGMouseButton is an extensible raw-value type on macOS: 3...31 represent auxiliary
        // hardware buttons even though only left/right/center have named constants.
        for rawValue in UInt32(0)..<UInt32(32) {
            guard let button = CGMouseButton(rawValue: rawValue), buttonStateProvider(button) else { continue }
            bitmap |= UInt32(1) << rawValue
        }
        return bitmap
    }
}

@MainActor
enum CursorRestorationOwnership {
    struct Receipt {
        let original: CGPoint
        let lastWritten: CGPoint
        let activityToken: SharedInputActivityToken
    }

    static func restore(
        _ receipt: Receipt,
        currentActivity: () -> SharedInputActivityToken,
        currentLocation: () -> CGPoint?,
        move: (CGPoint) throws -> Void) throws -> SharedDesktopRestorationStatus
    {
        let original = receipt.original
        let lastWritten = receipt.lastWritten
        let activityToken = receipt.activityToken
        guard currentActivity() == activityToken else {
            return .preservedNewerState
        }
        guard let current = currentLocation() else {
            throw ForegroundModifierClickError.cursorRestorationUnverified
        }
        if self.pointsMatch(current, original) {
            return .notNeeded
        }
        guard self.pointsMatch(current, lastWritten) else {
            return .preservedNewerState
        }
        // Recheck the shared event-generation journal inside the synchronous restore primitive,
        // immediately before posting our move. Any intervening physical move/drag owns the cursor.
        guard currentActivity() == activityToken else {
            return .preservedNewerState
        }
        try move(original)
        guard currentLocation().map({ self.pointsMatch($0, original) }) == true else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "The physical cursor restoration was dispatched but could not be verified.",
                hint: "Inspect the shared desktop state before taking another input action.")
        }
        return .restored
    }

    private static func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }
}

@MainActor
protocol SyntheticInputDriving: Sendable {
    func click(at point: CGPoint, button: MouseButton, count: Int) throws -> DesktopActionOutcome
    func click(at point: CGPoint, button: MouseButton, count: Int, targetProcessIdentifier: pid_t) async throws
        -> DesktopActionOutcome
    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID?) async throws -> DesktopActionOutcome
    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        target: ExactWindowPointerTarget) async throws -> DesktopActionOutcome
    func move(to point: CGPoint) throws
    func currentLocation() -> CGPoint?
    func sharedInputActivityToken() -> SharedInputActivityToken
    func restoreCursorIfOwned(
        original: CGPoint,
        lastWritten: CGPoint,
        activityToken: SharedInputActivityToken) throws -> SharedDesktopRestorationStatus
    func pressHold(at point: CGPoint, button: MouseButton, duration: TimeInterval) async throws
    func scroll(deltaX: Double, deltaY: Double, at point: CGPoint?) throws
    func type(_ text: String, delayPerCharacter: TimeInterval) throws
    func tapKey(_ key: SpecialKey, modifiers: CGEventFlags) throws
    func hotkey(keys: [String], holdDuration: TimeInterval) throws
}

extension SyntheticInputDriving {
    func sharedInputActivityToken() -> SharedInputActivityToken {
        .zero
    }

    func restoreCursorIfOwned(
        original: CGPoint,
        lastWritten: CGPoint,
        activityToken: SharedInputActivityToken) throws -> SharedDesktopRestorationStatus
    {
        try CursorRestorationOwnership.restore(
            CursorRestorationOwnership.Receipt(
                original: original,
                lastWritten: lastWritten,
                activityToken: activityToken),
            currentActivity: self.sharedInputActivityToken,
            currentLocation: self.currentLocation,
            move: self.move)
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        target: ExactWindowPointerTarget) async throws -> DesktopActionOutcome
    {
        try await self.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: target.identity.ownerProcessIdentifier,
            targetWindowID: CGWindowID(target.identity.windowID))
    }

    func click(
        at point: CGPoint,
        button: MouseButton,
        count: Int,
        targetProcessIdentifier: pid_t,
        targetWindowID: CGWindowID?) async throws -> DesktopActionOutcome
    {
        guard targetWindowID == nil else {
            throw PeekabooError.serviceUnavailable(
                "Synthetic input driver does not support exact-window click delivery")
        }
        return try await self.click(
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

    func click(at point: CGPoint, button: MouseButton = .left, count: Int = 1) throws -> DesktopActionOutcome {
        try InputDriver.click(at: point, button: button, count: count)
        return .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
    }

    func click(
        at point: CGPoint,
        button: MouseButton = .left,
        count: Int = 1,
        targetProcessIdentifier: pid_t) async throws -> DesktopActionOutcome
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
        targetWindowID: CGWindowID?) async throws -> DesktopActionOutcome
    {
        try await BackgroundInputDriver.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: targetProcessIdentifier,
            targetWindowID: targetWindowID)
    }

    func click(
        at point: CGPoint,
        button: MouseButton = .left,
        count: Int = 1,
        target: ExactWindowPointerTarget) async throws -> DesktopActionOutcome
    {
        try await BackgroundInputDriver.click(
            at: point,
            button: button,
            count: count,
            targetProcessIdentifier: target.identity.ownerProcessIdentifier,
            targetWindowID: CGWindowID(target.identity.windowID),
            expectedWindowIdentity: target.identity,
            expectedWindowBounds: target.bounds)
    }

    func move(to point: CGPoint) throws {
        try InputDriver.move(to: point)
    }

    func currentLocation() -> CGPoint? {
        InputDriver.currentLocation()
    }

    func sharedInputActivityToken() -> SharedInputActivityToken {
        .current()
    }

    func restoreCursorIfOwned(
        original: CGPoint,
        lastWritten: CGPoint,
        activityToken: SharedInputActivityToken) throws -> SharedDesktopRestorationStatus
    {
        try CursorRestorationOwnership.restore(
            CursorRestorationOwnership.Receipt(
                original: original,
                lastWritten: lastWritten,
                activityToken: activityToken),
            currentActivity: self.sharedInputActivityToken,
            currentLocation: self.currentLocation,
            move: self.move)
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
