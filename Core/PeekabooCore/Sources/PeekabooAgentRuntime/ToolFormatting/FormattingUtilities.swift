//
//  FormattingUtilities.swift
//  PeekabooCore
//

import Foundation

/// Shared formatting utilities for tool output
public enum FormattingUtilities {
    /// Format keyboard shortcut with proper symbols
    public static func formatKeyboardShortcut(_ keys: String) -> String {
        // Format keyboard shortcut with proper symbols
        keys.replacingOccurrences(of: "cmd", with: "⌘")
            .replacingOccurrences(of: "command", with: "⌘")
            .replacingOccurrences(of: "shift", with: "⇧")
            .replacingOccurrences(of: "option", with: "⌥")
            .replacingOccurrences(of: "opt", with: "⌥")
            .replacingOccurrences(of: "alt", with: "⌥")
            .replacingOccurrences(of: "control", with: "⌃")
            .replacingOccurrences(of: "ctrl", with: "⌃")
            .replacingOccurrences(of: "return", with: "↩")
            .replacingOccurrences(of: "enter", with: "↩")
            .replacingOccurrences(of: "escape", with: "⎋")
            .replacingOccurrences(of: "esc", with: "⎋")
            .replacingOccurrences(of: "tab", with: "⇥")
            .replacingOccurrences(of: "delete", with: "⌫")
            .replacingOccurrences(of: "backspace", with: "⌫")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    /// Format duration for display
    public static func formatDetailedDuration(_ seconds: TimeInterval) -> String {
        // Format duration for display
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
