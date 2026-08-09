import AppKit
import AXorcist
import CoreGraphics
import Darwin
import Foundation
import os.log
import PeekabooFoundation

/// Service for handling keyboard shortcuts and hotkeys.
@MainActor
public final class HotkeyService {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "HotkeyService")
    private let postEventAccessEvaluator: @MainActor @Sendable () -> Bool
    private let eventPoster: @MainActor @Sendable (CGEvent, pid_t) -> Void
    private let runningApplicationResolver: @MainActor @Sendable (pid_t) -> NSRunningApplication?
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving

    public convenience init(
        inputPolicy: UIInputPolicy = .currentBehavior,
        postEventAccessEvaluator: @escaping @MainActor @Sendable ()
            -> Bool = { CGPreflightPostEventAccess() },
        eventPoster: (@MainActor @Sendable (CGEvent, pid_t) -> Void)? = nil,
        runningApplicationResolver: @escaping @MainActor @Sendable (pid_t) -> NSRunningApplication? = {
            NSRunningApplication(processIdentifier: $0)
        })
    {
        self.init(
            inputPolicy: inputPolicy,
            actionInputDriver: ActionInputDriver(),
            postEventAccessEvaluator: postEventAccessEvaluator,
            eventPoster: eventPoster ?? Self.defaultTargetedEventPoster,
            runningApplicationResolver: runningApplicationResolver)
    }

    init(
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        postEventAccessEvaluator: @escaping @MainActor @Sendable ()
            -> Bool = { CGPreflightPostEventAccess() },
        eventPoster: @escaping @MainActor @Sendable (CGEvent, pid_t) -> Void = HotkeyService.defaultTargetedEventPoster,
        runningApplicationResolver: @escaping @MainActor @Sendable (pid_t) -> NSRunningApplication? = {
            NSRunningApplication(processIdentifier: $0)
        })
    {
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.postEventAccessEvaluator = postEventAccessEvaluator
        self.eventPoster = eventPoster
        self.runningApplicationResolver = runningApplicationResolver
    }

    private static func defaultTargetedEventPoster(_ event: CGEvent, _ pid: pid_t) {
        BackgroundInputDriver.postEvent(event, to: pid)
    }

    /// Press a hotkey combination.
    /// Keys are comma-separated (e.g. "cmd,shift,4" or "ctrl,alt,backspace").
    @discardableResult
    public func hotkey(keys: String, holdDuration: Int) async throws -> UIInputExecutionResult {
        self.logger.debug("Hotkey requested: '\(keys)', hold: \(holdDuration)ms")
        let parsedKeys = try self.parsedKeys(keys)
        let application = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = application?.bundleIdentifier
        let result = try await UIInputDispatcher.run(
            verb: .hotkey,
            strategy: self.inputPolicy.strategy(for: .hotkey, bundleIdentifier: bundleIdentifier),
            bundleIdentifier: bundleIdentifier,
            action: {
                guard let application else {
                    throw ActionInputError.unsupported(.missingElement)
                }
                return try self.actionInputDriver.tryHotkey(application: application, keys: parsedKeys)
            },
            synth: {
                try await self.performSyntheticHotkey(keys: parsedKeys, holdDuration: holdDuration)
            })

        self.logger.debug("Hotkey completed via \(result.path.rawValue, privacy: .public)")
        return result
    }

    /// Press a hotkey combination by posting the key event to a specific process.
    ///
    /// This path avoids changing the frontmost application, but macOS delivers it differently
    /// from hardware keyboard input. Some apps only handle shortcuts for their key window and
    /// may ignore targeted events while in the background.
    @discardableResult
    public func hotkey(keys: String, holdDuration: Int, targetProcessIdentifier: pid_t) async throws
        -> UIInputExecutionResult
    {
        self.logger.debug(
            "Targeted hotkey requested: '\(keys)', hold: \(holdDuration)ms, pid: \(targetProcessIdentifier)")

        try BackgroundHotkeyPolicy.validate(keys: keys)
        let parsedKeys = try self.parsedKeys(keys)
        let application = self.runningApplicationResolver(targetProcessIdentifier)
        let bundleIdentifier = application?.bundleIdentifier
        let result = try await UIInputDispatcher.run(
            verb: .hotkey,
            strategy: self.inputPolicy.strategy(for: .hotkey, bundleIdentifier: bundleIdentifier),
            bundleIdentifier: bundleIdentifier,
            action: {
                try Self.validateTargetProcess(targetProcessIdentifier)
                guard let application else {
                    throw ActionInputError.unsupported(.missingElement)
                }
                return try self.actionInputDriver.tryHotkey(application: application, keys: parsedKeys)
            },
            synth: {
                try Self.validateTargetProcess(targetProcessIdentifier)
                let plan = try self.makeHotkeyPlan(parsedKeys)
                if try BackgroundInputDriver.performFocusedTextHotkey(
                    primaryKey: plan.primaryKey,
                    modifierFlags: plan.modifierFlags,
                    targetProcessIdentifier: targetProcessIdentifier)
                {
                    return
                }

                let holdNanoseconds = try Self.holdNanoseconds(for: holdDuration)
                try await self.postHotkey(
                    plan,
                    holdNanoseconds: holdNanoseconds,
                    targetProcessIdentifier: targetProcessIdentifier)

                if holdDuration <= 0 {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
            })

        self.logger.debug("Targeted hotkey completed via \(result.path.rawValue, privacy: .public)")
        return result
    }

    private func performSyntheticHotkey(keys: [String], holdDuration: Int) async throws {
        let plan = try self.makeHotkeyPlan(keys)
        let holdNanoseconds = try Self.holdNanoseconds(for: holdDuration)
        let source = CGEventSource(stateID: .hidSystemState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: plan.keyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: plan.keyCode, keyDown: false)
        else {
            throw PeekabooError.operationError(message: "Failed to create keyboard events")
        }

        keyDown.flags = plan.modifierFlags
        keyUp.flags = plan.modifierFlags
        keyDown.post(tap: .cghidEventTap)
        var keyUpPosted = false
        defer {
            if !keyUpPosted {
                keyUp.post(tap: .cghidEventTap)
            }
        }

        if holdNanoseconds > 0 {
            try await Task.sleep(nanoseconds: holdNanoseconds)
        }

        keyUp.post(tap: .cghidEventTap)
        keyUpPosted = true

        if holdDuration <= 0 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func postHotkey(_ plan: HotkeyPlan, holdNanoseconds: UInt64, targetProcessIdentifier: pid_t) async throws {
        guard self.postEventAccessEvaluator() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }

        let eventPlan = try BackgroundInputDriver.keyboardEventPlan(
            keyCode: plan.keyCode,
            flags: plan.modifierFlags,
            targetProcessIdentifier: targetProcessIdentifier)

        for event in eventPlan.modifierKeyDownEvents {
            self.eventPoster(event, targetProcessIdentifier)
            usleep(1000)
        }

        self.eventPoster(eventPlan.primaryKeyDownEvent, targetProcessIdentifier)
        var released = false
        defer {
            if !released {
                self.eventPoster(eventPlan.primaryKeyUpEvent, targetProcessIdentifier)
                for event in eventPlan.modifierKeyUpEvents {
                    self.eventPoster(event, targetProcessIdentifier)
                }
            }
        }

        if holdNanoseconds > 0 {
            try await Task.sleep(nanoseconds: holdNanoseconds)
        }

        self.eventPoster(eventPlan.primaryKeyUpEvent, targetProcessIdentifier)
        for event in eventPlan.modifierKeyUpEvents {
            usleep(1000)
            self.eventPoster(event, targetProcessIdentifier)
        }
        released = true
    }

    private static func holdNanoseconds(for holdDuration: Int) throws -> UInt64 {
        let holdMilliseconds = max(0, holdDuration)
        let (nanoseconds, overflow) = UInt64(holdMilliseconds).multipliedReportingOverflow(by: 1_000_000)
        if overflow {
            throw PeekabooError.invalidInput("Hold duration is too large")
        }

        return nanoseconds
    }

    private static func validateTargetProcess(_ targetProcessIdentifier: pid_t) throws {
        guard targetProcessIdentifier > 0 else {
            throw PeekabooError.invalidInput("Target process identifier must be greater than 0")
        }

        guard self.isProcessAlive(targetProcessIdentifier) else {
            throw PeekabooError.invalidInput("Target process identifier is not running: \(targetProcessIdentifier)")
        }
    }

    private static func isProcessAlive(_ processIdentifier: pid_t) -> Bool {
        errno = 0
        if kill(processIdentifier, 0) == 0 {
            return true
        }

        return errno == EPERM
    }
}

#if DEBUG
extension HotkeyService {
    public func normalizeKeysForTesting(_ raw: [String]) -> [String] {
        raw.map { HotkeyKey.normalizedName(for: $0) }
    }

    public func parsedKeysForTesting(_ raw: String) throws -> [String] {
        try self.parsedKeys(raw)
    }

    func targetedHotkeyPlanForTesting(_ raw: [String]) throws
    -> (primaryKey: String, keyCode: CGKeyCode, flags: CGEventFlags) {
        let plan = try self.makeHotkeyPlan(raw)
        return (plan.primaryKey, plan.keyCode, plan.modifierFlags)
    }

    static func holdNanosecondsForTesting(_ holdDuration: Int) throws -> UInt64 {
        try self.holdNanoseconds(for: holdDuration)
    }

    static func isProcessAliveForTesting(_ processIdentifier: pid_t) -> Bool {
        self.isProcessAlive(processIdentifier)
    }
}
#endif
