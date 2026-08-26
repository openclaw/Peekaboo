import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation

extension TypeService {
    func typeSpecialKey(
        _ key: PeekabooFoundation.SpecialKey,
        keyboardDelivery: DesktopActionOutcome.Delivery) throws -> TypeActionDispatchSummary
    {
        let keyCode = TypeServiceSpecialKeyMapping.keyCode(for: key)
        try TypeServiceSpecialKeyMapping.postKey(keyCode)
        return .dispatched(delivery: keyboardDelivery, keyPressCount: 1)
    }

    static func typeTargetedSpecialKey(
        _ key: PeekabooFoundation.SpecialKey,
        targetProcessIdentifier: pid_t,
        keyboardDelivery: DesktopActionOutcome.Delivery) throws -> TypeActionDispatchSummary
    {
        switch try BackgroundInputDriver.performFocusedTextKey(
            key,
            targetProcessIdentifier: targetProcessIdentifier)
        {
        case .accessibilityValue:
            return .dispatched(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                keyPressCount: 0)
        case .noChange:
            return .noChange
        case .unsupported:
            let keyCode = TypeServiceSpecialKeyMapping.keyCode(for: key)
            try BackgroundInputDriver.tapKey(
                keyCode: keyCode,
                targetProcessIdentifier: targetProcessIdentifier)
            return .dispatched(delivery: keyboardDelivery, keyPressCount: 1)
        }
    }
}

enum TypeServiceSpecialKeyMapping {
    private static let keyCodes: [String: CGKeyCode] = [
        "return": 0x24,
        "enter": 0x4C,
        "tab": 0x30,
        "escape": 0x35,
        "delete": 0x33,
        "forwarddelete": 0x75,
        "space": 0x31,
        "left": 0x7B,
        "right": 0x7C,
        "up": 0x7E,
        "down": 0x7D,
        "pageup": 0x74,
        "pagedown": 0x79,
        "home": 0x73,
        "end": 0x77,
        "f1": 0x7A,
        "f2": 0x78,
        "f3": 0x63,
        "f4": 0x76,
        "f5": 0x60,
        "f6": 0x61,
        "f7": 0x62,
        "f8": 0x64,
        "f9": 0x65,
        "f10": 0x6D,
        "f11": 0x67,
        "f12": 0x6F,
        "capslock": 0x39,
        "clear": 0x47,
        "help": 0x72,
    ]

    private static let aliases: [String: String] = [
        "esc": "escape",
        "backspace": "delete",
        "del": "delete",
        "forward_delete": "forwarddelete",
        "spacebar": "space",
        "arrow_left": "left",
        "arrow_right": "right",
        "arrow_up": "up",
        "arrow_down": "down",
        "page_up": "pageup",
        "page_down": "pagedown",
        "caps_lock": "capslock",
    ]

    static func keyCode(for key: PeekabooFoundation.SpecialKey) -> CGKeyCode {
        let rawKey = key.rawValue
        guard let keyCode = self.keyCode(forRawKey: rawKey) else {
            preconditionFailure("Missing key code for SpecialKey.\(key)")
        }
        return keyCode
    }

    static func keyCode(forRawKey rawKey: String) -> CGKeyCode? {
        let normalized = self.normalizedName(for: rawKey)
        return self.keyCodes[normalized]
    }

    static func normalizedName(for rawKey: String) -> String {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return self.aliases[key] ?? key
    }

    static func postKey(_ keyCode: CGKeyCode) throws {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false)
        else {
            throw PeekabooError.operationError(message: "Failed to create keyboard event")
        }

        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.001)
        keyUp.post(tap: .cghidEventTap)
    }
}
