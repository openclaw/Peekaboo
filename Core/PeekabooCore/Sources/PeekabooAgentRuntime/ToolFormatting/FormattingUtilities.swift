//
//  FormattingUtilities.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomationKit

/// Shared formatting utilities for tool output
public enum FormattingUtilities {
    private static let keyboardSymbols = [
        "cmd": "⌘", "command": "⌘", "shift": "⇧",
        "option": "⌥", "opt": "⌥", "alt": "⌥", "control": "⌃", "ctrl": "⌃",
        "return": "↩", "enter": "↩", "escape": "⎋", "esc": "⎋", "tab": "⇥",
        "delete": "⌫", "backspace": "⌫", "del": "⌫",
        "forwarddelete": "⌦", "forward_delete": "⌦",
    ]

    /// Format keyboard shortcut with proper symbols
    public static func formatKeyboardShortcut(_ keys: String) -> String {
        keys.split(whereSeparator: { $0 == "," || $0 == "+" || $0.isWhitespace })
            .map { self.keyboardSymbols[$0.lowercased()] ?? String($0) }
            .joined()
    }

    /// Format duration for display
    public static func formatDetailedDuration(_ seconds: TimeInterval) -> String {
        PeekabooAutomationKit.formatDetailedDuration(seconds)
    }
}
