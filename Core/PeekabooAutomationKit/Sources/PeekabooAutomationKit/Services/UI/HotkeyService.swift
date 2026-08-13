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
    private let frontmostApplicationResolver: @MainActor @Sendable () -> NSRunningApplication?
    private let runningApplicationResolver: @MainActor @Sendable (pid_t) -> NSRunningApplication?
    private let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    let inputPolicy: UIInputPolicy
    private let actionInputDriver: any ActionInputDriving
    private let desktopOperationExecutor: DesktopOperationExecutor
    private let operationFinalizer: @MainActor () -> Void

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
            runningApplicationResolver: runningApplicationResolver,
            processStartIdentityProvider: SystemIdentityResolver.processStartIdentity,
            desktopOperationExecutor: DesktopOperationExecutor())
    }

    init(
        inputPolicy: UIInputPolicy = .currentBehavior,
        actionInputDriver: any ActionInputDriving = ActionInputDriver(),
        postEventAccessEvaluator: @escaping @MainActor @Sendable ()
            -> Bool = { CGPreflightPostEventAccess() },
        eventPoster: @escaping @MainActor @Sendable (CGEvent, pid_t) -> Void = HotkeyService.defaultTargetedEventPoster,
        frontmostApplicationResolver: @escaping @MainActor @Sendable () -> NSRunningApplication? = {
            NSWorkspace.shared.frontmostApplication
        },
        runningApplicationResolver: @escaping @MainActor @Sendable (pid_t) -> NSRunningApplication? = {
            NSRunningApplication(processIdentifier: $0)
        },
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        desktopOperationExecutor: DesktopOperationExecutor = DesktopOperationExecutor(),
        operationFinalizer: @escaping @MainActor () -> Void = {})
    {
        self.inputPolicy = inputPolicy
        self.actionInputDriver = actionInputDriver
        self.postEventAccessEvaluator = postEventAccessEvaluator
        self.eventPoster = eventPoster
        self.frontmostApplicationResolver = frontmostApplicationResolver
        self.runningApplicationResolver = runningApplicationResolver
        self.processStartIdentityProvider = processStartIdentityProvider
        self.desktopOperationExecutor = desktopOperationExecutor
        self.operationFinalizer = operationFinalizer
    }

    private static func defaultTargetedEventPoster(_ event: CGEvent, _ pid: pid_t) {
        BackgroundInputDriver.postEvent(event, to: pid)
    }

    /// Press a hotkey combination.
    /// Keys are comma-separated (e.g. "cmd,shift,4" or "ctrl,alt,backspace").
    @discardableResult
    public func hotkey(keys: String, holdDuration: Int) async throws -> UIInputExecutionResult {
        try await self.hotkeyWithLanePreparation(keys: keys, holdDuration: holdDuration)
    }

    func hotkeyWithLanePreparation(
        keys: String,
        holdDuration: Int,
        lanePreparation: @escaping @MainActor () async -> Void = {},
        laneCompletion: @escaping @MainActor (UIInputExecutionResult) async -> Void = { _ in }) async throws
        -> UIInputExecutionResult
    {
        self.logger.debug("Hotkey requested: '\(keys)', hold: \(holdDuration)ms")
        let parsedKeys = try self.parsedKeys(keys)
        var application: NSRunningApplication?
        var bundleIdentifier: String?
        let plan = try DesktopOperationPlan(
            verb: .hotkey,
            selector: .focused,
            captureReceipt: DesktopOperationPlan.CaptureReceipt(target: .foreground),
            strategy: self.inputPolicy.strategy(for: .hotkey),
            prepare: {
                application = self.frontmostApplicationResolver()
                bundleIdentifier = application?.bundleIdentifier
                await lanePreparation()
            },
            routing: {
                DesktopOperationPlan.Routing(
                    strategy: self.inputPolicy.strategy(for: .hotkey, bundleIdentifier: bundleIdentifier),
                    bundleIdentifier: bundleIdentifier)
            },
            action: DesktopOperationPlan.ActionRoute {
                guard let application else {
                    throw ActionInputError.unsupported(.missingElement)
                }
                return try self.actionInputDriver.tryHotkey(application: application, keys: parsedKeys)
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                try await self.performSyntheticHotkey(keys: parsedKeys, holdDuration: holdDuration)
                return .dispatchedUnverified(
                    delivery: DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted)
            },
            success: laneCompletion,
            finalize: self.operationFinalizer)
        let result = try await self.desktopOperationExecutor.execute(plan)

        self.logger.debug("Hotkey completed via \(result.path.rawValue, privacy: .public)")
        return result
    }

    /// Press a hotkey combination by posting the key event to a specific process.
    ///
    /// This path avoids changing the frontmost application, but macOS delivers it differently
    /// from hardware keyboard input. Some apps only handle shortcuts for their key window and
    /// may ignore targeted events while in the background.
    @discardableResult
    public func hotkey(
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil,
        expectedProcessIdentity: ApplicationProcessIdentity? = nil) async throws
        -> UIInputExecutionResult
    {
        let automationTarget: UIAutomationTarget = try .process(UIAutomationTarget.Process(
            processIdentifier: targetProcessIdentifier,
            identity: expectedProcessIdentity))
        return try await self.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            automationTarget: automationTarget,
            deliveryValidator: deliveryValidator)
    }

    @discardableResult
    func hotkey(
        keys: String,
        holdDuration: Int,
        automationTarget: UIAutomationTarget,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil) async throws
        -> UIInputExecutionResult
    {
        guard let targetProcessIdentifier = automationTarget.processIdentifier else {
            throw PeekabooError.invalidInput("Targeted hotkey requires a process target")
        }
        self.logger.debug(
            "Targeted hotkey requested: '\(keys)', hold: \(holdDuration)ms, pid: \(targetProcessIdentifier)")

        try BackgroundHotkeyPolicy.validate(keys: keys)
        let parsedKeys = try self.parsedKeys(keys)
        let targetValidator: @MainActor @Sendable () async throws -> Void = {
            if let expectedProcessIdentity = automationTarget.processIdentity,
               self.processStartIdentityProvider(targetProcessIdentifier) !=
               expectedProcessIdentity.processStartIdentity
            {
                throw PeekabooError.invalidInput(
                    "Background hotkey target process exited or changed process generation")
            }
            try await deliveryValidator?()
        }
        var application: NSRunningApplication?
        var bundleIdentifier: String?
        let plan = try DesktopOperationPlan(
            verb: .hotkey,
            selector: .focused,
            captureReceipt: DesktopOperationPlan.CaptureReceipt(target: automationTarget),
            strategy: self.inputPolicy.strategy(for: .hotkey),
            prepare: {
                application = self.runningApplicationResolver(targetProcessIdentifier)
                bundleIdentifier = application?.bundleIdentifier
            },
            routing: {
                DesktopOperationPlan.Routing(
                    strategy: self.inputPolicy.strategy(for: .hotkey, bundleIdentifier: bundleIdentifier),
                    bundleIdentifier: bundleIdentifier)
            },
            action: DesktopOperationPlan.ActionRoute {
                try await self.validateDelivery(
                    targetValidator,
                    emittedUnitCount: 0)
                try Self.validateTargetProcess(targetProcessIdentifier)
                guard let application else {
                    throw ActionInputError.unsupported(.missingElement)
                }
                let actionResult = try self.actionInputDriver.tryHotkey(application: application, keys: parsedKeys)
                try await self.validateDelivery(
                    targetValidator,
                    emittedUnitCount: 1)
                return actionResult
            },
            synthesis: DesktopOperationPlan.SynthesisRoute {
                try await self.validateDelivery(
                    targetValidator,
                    emittedUnitCount: 0)
                try Self.validateTargetProcess(targetProcessIdentifier)
                let plan = try self.makeHotkeyPlan(parsedKeys)
                if try BackgroundInputDriver.performFocusedTextHotkey(
                    primaryKey: plan.primaryKey,
                    modifierFlags: plan.modifierFlags,
                    targetProcessIdentifier: targetProcessIdentifier)
                {
                    try await self.validateDelivery(
                        targetValidator,
                        emittedUnitCount: 1)
                    return .dispatchedUnverified(
                        delivery: DesktopActionOutcome.Delivery(
                            mechanism: .accessibilityAction,
                            mode: .background),
                        evidence: .deliveryAccepted)
                }

                let holdNanoseconds = try Self.holdNanoseconds(for: holdDuration)
                let emittedUnitCount = try await self.postHotkey(
                    plan,
                    holdNanoseconds: holdNanoseconds,
                    targetProcessIdentifier: targetProcessIdentifier,
                    deliveryValidator: targetValidator)

                do {
                    if holdDuration <= 0 {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try await self.validateDelivery(
                        targetValidator,
                        emittedUnitCount: emittedUnitCount)
                } catch let error as InputDeliveryIndeterminateError {
                    throw error
                } catch {
                    throw InputDeliveryIndeterminateError(
                        operation: .hotkey,
                        emittedUnitCount: emittedUnitCount,
                        causeDescription: error.localizedDescription)
                }
                return .dispatchedUnverified(
                    delivery: DesktopActionOutcome.Delivery(
                        mechanism: .processTargetedEvents,
                        mode: .background),
                    evidence: .deliveryAccepted)
            },
            finalize: self.operationFinalizer)
        let result = try await self.desktopOperationExecutor.execute(plan)

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

    private func postHotkey(
        _ plan: HotkeyPlan,
        holdNanoseconds: UInt64,
        targetProcessIdentifier: pid_t,
        deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil) async throws
        -> Int
    {
        guard self.postEventAccessEvaluator() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }

        let eventPlan = try BackgroundInputDriver.keyboardEventPlan(
            keyCode: plan.keyCode,
            flags: plan.modifierFlags,
            targetProcessIdentifier: targetProcessIdentifier)

        var pressedModifierKeyCodes: Set<Int64> = []
        var primaryKeyIsDown = false
        var emittedUnitCount = 0
        defer {
            if primaryKeyIsDown {
                self.eventPoster(eventPlan.primaryKeyUpEvent, targetProcessIdentifier)
            }
            for event in eventPlan.modifierKeyUpEvents where pressedModifierKeyCodes.contains(
                event.getIntegerValueField(.keyboardEventKeycode))
            {
                self.eventPoster(event, targetProcessIdentifier)
            }
        }

        do {
            // Exact-window targeting must fail before the first event is posted. Validate again after
            // the modifier sequence because focus can move while those events are being delivered.
            try await self.validateDelivery(
                deliveryValidator,
                emittedUnitCount: emittedUnitCount)

            for event in eventPlan.modifierKeyDownEvents {
                pressedModifierKeyCodes.insert(event.getIntegerValueField(.keyboardEventKeycode))
                self.eventPoster(event, targetProcessIdentifier)
                emittedUnitCount += 1
                usleep(1000)
            }

            try await self.validateDelivery(
                deliveryValidator,
                emittedUnitCount: emittedUnitCount)
            primaryKeyIsDown = true
            self.eventPoster(eventPlan.primaryKeyDownEvent, targetProcessIdentifier)
            emittedUnitCount += 1

            if holdNanoseconds > 0 {
                try await Task.sleep(nanoseconds: holdNanoseconds)
            }

            self.eventPoster(eventPlan.primaryKeyUpEvent, targetProcessIdentifier)
            emittedUnitCount += 1
            primaryKeyIsDown = false
            for event in eventPlan.modifierKeyUpEvents {
                usleep(1000)
                self.eventPoster(event, targetProcessIdentifier)
                emittedUnitCount += 1
                pressedModifierKeyCodes.remove(event.getIntegerValueField(.keyboardEventKeycode))
            }
            return emittedUnitCount
        } catch let error as InputDeliveryIndeterminateError {
            throw error
        } catch {
            guard emittedUnitCount > 0 else { throw error }
            throw InputDeliveryIndeterminateError(
                operation: .hotkey,
                emittedUnitCount: emittedUnitCount,
                causeDescription: error.localizedDescription)
        }
    }

    private func validateDelivery(
        _ deliveryValidator: (@MainActor @Sendable () async throws -> Void)?,
        emittedUnitCount: Int) async throws
    {
        guard let deliveryValidator else { return }

        do {
            try await deliveryValidator()
        } catch let error as InputDeliveryIndeterminateError {
            throw error
        } catch {
            guard emittedUnitCount > 0 else { throw error }
            throw InputDeliveryIndeterminateError(
                operation: .hotkey,
                emittedUnitCount: emittedUnitCount,
                causeDescription: error.localizedDescription)
        }
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
