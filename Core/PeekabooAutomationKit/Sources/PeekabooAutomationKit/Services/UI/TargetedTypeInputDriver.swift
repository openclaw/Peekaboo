import CoreGraphics
import PeekabooFoundation

/// Primitive operations stay separate so a policy cannot cross into its forbidden mutation path.
@MainActor
struct TargetedTypeInputDriver {
    var insertText: (String, pid_t) throws -> Bool = { text, pid in
        try BackgroundInputDriver.insertTextIntoFocusedText(text, targetProcessIdentifier: pid)
    }

    var performTextKey: (PeekabooFoundation.SpecialKey, pid_t) throws -> FocusedTextKeyDispatch = { key, pid in
        try BackgroundInputDriver.performFocusedTextKey(key, targetProcessIdentifier: pid)
    }

    var replaceText: (String, pid_t) throws -> Bool = { text, pid in
        try BackgroundInputDriver.replaceFocusedText(with: text, targetProcessIdentifier: pid)
    }

    var typeCharacter: (Character, pid_t) throws -> Void = { character, pid in
        try BackgroundInputDriver.typeCharacter(character, targetProcessIdentifier: pid)
    }

    var tapKey: (CGKeyCode, CGEventFlags, pid_t) throws -> Void = { code, flags, pid in
        try BackgroundInputDriver.tapKey(keyCode: code, modifiers: flags, targetProcessIdentifier: pid)
    }

    func character(
        _ character: Character,
        processIdentifier: pid_t,
        strategy: UIInputStrategy,
        keyboardDelivery: DesktopActionOutcome.Delivery) throws -> TypeActionDispatchSummary
    {
        try self.dispatch(
            strategy: strategy,
            keyboardDelivery: keyboardDelivery,
            action: {
                try self.insertText(String(character), processIdentifier) ? .accessibilityValue : .unsupported
            },
            synthesis: { try self.typeCharacter(character, processIdentifier) })
    }

    func specialKey(
        _ key: PeekabooFoundation.SpecialKey,
        processIdentifier: pid_t,
        strategy: UIInputStrategy,
        keyboardDelivery: DesktopActionOutcome.Delivery) throws -> TypeActionDispatchSummary
    {
        try self.dispatch(
            strategy: strategy,
            keyboardDelivery: keyboardDelivery,
            action: { try self.performTextKey(key, processIdentifier) },
            synthesis: { try self.tapKey(TypeServiceSpecialKeyMapping.keyCode(for: key), [], processIdentifier) })
    }

    func clearUsingAccessibility(processIdentifier: pid_t, strategy: UIInputStrategy) throws -> Bool {
        guard strategy == .actionFirst || strategy == .actionOnly else { return false }
        if try self.replaceText("", processIdentifier) {
            return true
        }
        try Self.requireSynthesisAllowed(strategy)
        return false
    }

    func tapKeyboardKey(_ code: CGKeyCode, flags: CGEventFlags, processIdentifier: pid_t) throws {
        try Self.performEvent { try self.tapKey(code, flags, processIdentifier) }
    }

    private func dispatch(
        strategy: UIInputStrategy,
        keyboardDelivery: DesktopActionOutcome.Delivery,
        action: () throws -> FocusedTextKeyDispatch,
        synthesis: () throws -> Void) throws -> TypeActionDispatchSummary
    {
        let attemptsAction = strategy == .actionFirst || strategy == .actionOnly
        if attemptsAction {
            switch try action() {
            case .accessibilityValue:
                return .dispatched(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background),
                    keyPressCount: 0)
            case .noChange:
                return .noChange
            case .unsupported:
                try Self.requireSynthesisAllowed(strategy)
            }
        }
        try Self.performEvent(synthesis)
        return .dispatched(
            delivery: keyboardDelivery,
            keyPressCount: 1,
            fallbackReason: attemptsAction ? .attributeUnsupported : nil)
    }

    private static func requireSynthesisAllowed(_ strategy: UIInputStrategy) throws {
        guard strategy != .actionOnly else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The focused control does not support this accessibility text edit.",
                hint: "The actionOnly policy does not permit keyboard-event fallback.")
        }
    }

    private static func performEvent(_ operation: () throws -> Void) throws {
        do {
            try operation()
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .permissionDenied,
                message: "Event Synthesizing permission is required for keyboard delivery.")
        }
    }
}
