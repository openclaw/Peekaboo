//
//  FormattingUtilities.swift
//  PeekabooCore
//

import Foundation

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
        if seconds < 0.001 {
            return String(format: "%.0fµs", seconds * 1_000_000)
        } else if seconds < 1.0 {
            return String(format: "%.0fms", seconds * 1000)
        } else if seconds < 60.0 {
            return String(format: "%.1fs", seconds)
        } else {
            let minutes = Int(seconds / 60)
            let remainingSeconds = Int(seconds.truncatingRemainder(dividingBy: 60))
            return String(format: "%dmin %ds", minutes, remainingSeconds)
        }
    }
}
