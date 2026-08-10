//
//  VisualizerDesign.swift
//  Peekaboo
//
//  The shared "Ghost HUD" design language for all visualizer animations:
//  one accent, one material, one motion vocabulary.
//

import SwiftUI

// MARK: - Theme

/// Design tokens shared by every visualizer animation.
enum VisualizerTheme {
    /// Primary accent — Peekaboo ghost violet.
    static let accent = Color(red: 0.64, green: 0.53, blue: 1.0)

    /// Secondary accent used for gradient depth.
    static let accentSecondary = Color(red: 0.42, green: 0.75, blue: 1.0)

    /// Fill for HUD chips.
    static let hudFill = Color.black.opacity(0.58)

    /// Hairline stroke for HUD chips and keycaps.
    static let hudStroke = Color.white.opacity(0.16)

    /// Primary text on HUD chips.
    static let hudText = Color.white.opacity(0.92)

    /// Secondary text on HUD chips.
    static let hudTextSecondary = Color.white.opacity(0.55)
}

// MARK: - Motion

/// Standard motion curves so every animation speaks one dialect.
enum VisualizerMotion {
    /// Quick springy entrance for chips, badges, and keycaps.
    static func pop(_ response: Double = 0.32) -> Animation {
        .spring(response: response, dampingFraction: 0.72)
    }

    /// Ease-in for exits and fades.
    static func exit(_ duration: Double) -> Animation {
        .easeIn(duration: duration)
    }
}

// MARK: - HUD Chip

/// The shared translucent container every floating widget sits in.
struct HUDChipModifier: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                    .fill(VisualizerTheme.hudFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: self.cornerRadius, style: .continuous)
                            .strokeBorder(VisualizerTheme.hudStroke, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 14, y: 5))
    }
}

extension View {
    /// Wraps content in the shared dark translucent HUD container.
    func hudChip(cornerRadius: CGFloat = 14) -> some View {
        modifier(HUDChipModifier(cornerRadius: cornerRadius))
    }
}

// MARK: - Key Glyphs

/// Shared key-name → display glyph mapping for keycaps and typed-text streams.
enum VisualizerKeyGlyphs {
    /// Display symbol for a key name (e.g. "cmd" → "⌘").
    static func symbol(for key: String) -> String {
        switch key.lowercased() {
        case "cmd", "command": "⌘"
        case "shift": "⇧"
        case "option", "alt": "⌥"
        case "ctrl", "control": "⌃"
        case "fn": "fn"
        case "space", " ": "␣"
        case "return", "enter", "{return}", "\r", "\n": "⏎"
        case "delete", "backspace", "{delete}": "⌫"
        case "escape", "esc", "{escape}": "⎋"
        case "tab", "{tab}", "\t": "⇥"
        case "capslock", "caps": "⇪"
        case "arrow_up", "up": "↑"
        case "arrow_down", "down": "↓"
        case "arrow_left", "left": "←"
        case "arrow_right", "right": "→"
        case "pageup", "page_up": "⇞"
        case "pagedown", "page_down": "⇟"
        case "home": "↖"
        case "end": "↘"
        default: key.uppercased()
        }
    }

    /// Inline glyph for non-printing keys in a typed-text stream, nil for plain characters.
    static func inlineSymbol(for key: String) -> String? {
        switch key.lowercased() {
        case "{return}", "return", "enter", "\r", "\n": "⏎"
        case "{tab}", "tab", "\t": "⇥"
        case "{delete}", "delete", "backspace": "⌫"
        case "{escape}", "escape", "esc": "⎋"
        default: key.count > 1 ? self.symbol(for: key) : nil
        }
    }
}
