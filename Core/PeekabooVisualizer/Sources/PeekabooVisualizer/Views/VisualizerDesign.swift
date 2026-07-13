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

    /// Destructive tint, reserved for close/quit/dismiss.
    static let destructive = Color(red: 1.0, green: 0.42, blue: 0.42)

    /// Positive tint, reserved for launch/confirm status accents.
    static let positive = Color(red: 0.4, green: 0.87, blue: 0.56)

    /// Fill for HUD chips.
    static let hudFill = Color.black.opacity(0.58)

    /// Hairline stroke for HUD chips and keycaps.
    static let hudStroke = Color.white.opacity(0.16)

    /// Primary text on HUD chips.
    static let hudText = Color.white.opacity(0.92)

    /// Secondary text on HUD chips.
    static let hudTextSecondary = Color.white.opacity(0.55)

    /// Idle keycap fill.
    static let keycapFill = Color.white.opacity(0.1)

    /// Diagonal accent gradient for strokes and highlights.
    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [self.accent, self.accentSecondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing)
    }
}

// MARK: - Motion

/// Standard motion curves so every animation speaks one dialect.
enum VisualizerMotion {
    /// Quick springy entrance for chips, badges, and keycaps.
    static func pop(_ response: Double = 0.32) -> Animation {
        .spring(response: response, dampingFraction: 0.72)
    }

    /// Gentle spring for secondary movement.
    static func settle(_ response: Double = 0.45) -> Animation {
        .spring(response: response, dampingFraction: 0.85)
    }

    /// Ease-out for entrances and expansions.
    static func enter(_ duration: Double) -> Animation {
        .easeOut(duration: duration)
    }

    /// Ease-in for exits and fades.
    static func exit(_ duration: Double) -> Animation {
        .easeIn(duration: duration)
    }

    /// Ease-in-out for travel (comets, slides).
    static func glide(_ duration: Double) -> Animation {
        .easeInOut(duration: duration)
    }

    /// Fast acceleration with a longer, precise settle for pointer travel.
    static func pointerTravel(_ duration: Double) -> Animation {
        .timingCurve(0.22, 0.05, 0.18, 1.0, duration: duration)
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

    /// Small caption shown under modifier symbols on keycaps.
    static func caption(for key: String) -> String? {
        switch key.lowercased() {
        case "cmd", "command": "command"
        case "shift": "shift"
        case "option", "alt": "option"
        case "ctrl", "control": "control"
        case "return", "enter": "return"
        case "delete", "backspace": "delete"
        case "escape", "esc": "esc"
        case "tab": "tab"
        case "space": "space"
        default: nil
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

    /// Keycap width for a key name; wider caps for modifiers and space.
    static func keycapWidth(for key: String) -> CGFloat {
        switch key.lowercased() {
        case "space": 120
        case "shift", "return", "enter", "delete", "backspace": 80
        case "cmd", "command", "ctrl", "control", "option", "alt": 60
        default: 44
        }
    }
}

// MARK: - Keycap

/// A minimal macOS-style keycap used by the hotkey and typing animations.
struct KeycapView: View {
    let key: String
    var isPressed = false

    var body: some View {
        VStack(spacing: 2) {
            Text(VisualizerKeyGlyphs.symbol(for: self.key))
                .font(.system(size: 19, weight: .medium, design: .rounded))
                .foregroundStyle(VisualizerTheme.hudText)

            if let caption = VisualizerKeyGlyphs.caption(for: self.key) {
                Text(caption)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(VisualizerTheme.hudTextSecondary)
            }
        }
        .frame(width: VisualizerKeyGlyphs.keycapWidth(for: self.key), height: 46)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(self.isPressed ? VisualizerTheme.accent.opacity(0.38) : VisualizerTheme.keycapFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(
                            self.isPressed ? VisualizerTheme.accent.opacity(0.9) : VisualizerTheme.hudStroke,
                            lineWidth: 1))
                .shadow(
                    color: self.isPressed ? VisualizerTheme.accent.opacity(0.5) : .black.opacity(0.3),
                    radius: self.isPressed ? 8 : 2,
                    y: self.isPressed ? 0 : 2))
        .scaleEffect(self.isPressed ? 0.94 : 1.0)
    }
}

// MARK: - Corner Brackets

/// Viewfinder-style corner brackets used by capture and resize feedback.
struct CornerBracketsShape: Shape {
    var inset: CGFloat = 10
    var armLength: CGFloat = 26

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(self.inset, self.armLength) }
        set {
            self.inset = newValue.first
            self.armLength = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inner = rect.insetBy(dx: self.inset, dy: self.inset)
        let arm = min(self.armLength, inner.width / 3, inner.height / 3)

        // Top-left
        path.move(to: CGPoint(x: inner.minX, y: inner.minY + arm))
        path.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
        path.addLine(to: CGPoint(x: inner.minX + arm, y: inner.minY))
        // Top-right
        path.move(to: CGPoint(x: inner.maxX - arm, y: inner.minY))
        path.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
        path.addLine(to: CGPoint(x: inner.maxX, y: inner.minY + arm))
        // Bottom-right
        path.move(to: CGPoint(x: inner.maxX, y: inner.maxY - arm))
        path.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        path.addLine(to: CGPoint(x: inner.maxX - arm, y: inner.maxY))
        // Bottom-left
        path.move(to: CGPoint(x: inner.minX + arm, y: inner.maxY))
        path.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        path.addLine(to: CGPoint(x: inner.minX, y: inner.maxY - arm))

        return path
    }
}

// MARK: - Glyph Badge

/// A small circular HUD badge holding an SF Symbol, used to label spatial feedback.
struct GlyphBadgeView: View {
    let systemName: String
    var tint: Color = VisualizerTheme.accent

    var body: some View {
        Image(systemName: self.systemName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(self.tint)
            .frame(width: 34, height: 34)
            .background(
                Circle()
                    .fill(VisualizerTheme.hudFill)
                    .overlay(Circle().strokeBorder(VisualizerTheme.hudStroke, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 8, y: 3))
    }
}

// MARK: - Utilities

extension Array {
    subscript(safe index: Int) -> Element? {
        index >= 0 && index < self.count ? self[index] : nil
    }
}
