import PeekabooFoundation
import SwiftUI

struct InputHUDView: View {
    enum Content {
        case typing([String])
        case hotkey([String])
        case scroll(ScrollDirection, Int)
    }

    let content: Content

    @State private var opacity = 0.0
    @State private var scale: CGFloat = 0.96

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: self.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(VisualizerTheme.accent)
            Text(self.label)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(VisualizerTheme.hudText)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .hudChip(cornerRadius: 16)
        .scaleEffect(self.scale)
        .opacity(self.opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.12)) {
                self.opacity = 1
                self.scale = 1
            }
        }
    }

    private var icon: String {
        switch self.content {
        case .typing: "keyboard"
        case .hotkey: "command"
        case let .scroll(direction, _):
            switch direction {
            case .up: "arrow.up"
            case .down: "arrow.down"
            case .left: "arrow.left"
            case .right: "arrow.right"
            }
        }
    }

    private var label: String {
        switch self.content {
        case let .typing(keys):
            return keys.map(Self.displayKey).joined()
        case let .hotkey(keys):
            return keys.map(Self.hotkeyGlyph).joined()
        case let .scroll(direction, amount):
            let directionLabel = switch direction {
            case .up: "Scroll up"
            case .down: "Scroll down"
            case .left: "Scroll left"
            case .right: "Scroll right"
            }
            return amount > 1 ? "\(directionLabel) ×\(amount)" : directionLabel
        }
    }

    private static func displayKey(_ key: String) -> String {
        VisualizerKeyGlyphs.inlineSymbol(for: key) ?? key
    }

    private static func hotkeyGlyph(_ key: String) -> String {
        switch key.lowercased() {
        case "cmd", "command", "⌘": "⌘"
        case "shift", "⇧": "⇧"
        case "option", "alt", "⌥": "⌥"
        case "control", "ctrl", "⌃": "⌃"
        default: self.displayKey(key).uppercased()
        }
    }
}
