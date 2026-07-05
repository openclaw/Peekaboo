//
//  ShortcutSettingsView.swift
//  Peekaboo
//

import KeyboardShortcuts
import PeekabooCore
import SwiftUI

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("Global Shortcuts") {
                KeyboardShortcuts.Recorder("Toggle Popover", name: .togglePopover)
                KeyboardShortcuts.Recorder("Show Main Window", name: .showMainWindow)
                KeyboardShortcuts.Recorder("Show Inspector", name: .showInspector)
            }

            Section {
                Text("Shortcuts must include at least one modifier key (⌘, ⌥, ⌃, or ⇧) and take effect immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    ShortcutSettingsView()
        .frame(width: 600, height: 400)
}
