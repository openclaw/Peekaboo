import PeekabooCore
import PeekabooUICore
import SwiftUI

struct VisualizerSettingsView: View {
    @Bindable var settings: PeekabooSettings

    var body: some View {
        Form {
            Section("Menu Bar") {
                SettingsToggleRow(
                    title: "Show automated app icons in the menu bar",
                    subtitle: "Show recently automated apps next to Peekaboo's menu bar icon.",
                    systemImage: "app.badge",
                    isOn: self.$settings.showAutomationTargetIcons)
            }

            Section {
                SettingsToggleRow(
                    title: "Enable visualizer",
                    subtitle: "Show quiet, app-anchored feedback for Peekaboo operations.",
                    systemImage: "sparkles",
                    isOn: self.$settings.visualizerEnabled)
            }

            Section("Feedback") {
                SettingsToggleRow(
                    title: "Agent cursor",
                    subtitle: "Show natural pointer motion, click pulses, and pressed drags.",
                    systemImage: "cursorarrow.motionlines",
                    isOn: self.$settings.agentCursorEnabled)

                SettingsToggleRow(
                    title: "Input HUD",
                    subtitle: "Show typing, shortcuts, and scrolling at the target window's bottom edge.",
                    systemImage: "keyboard",
                    isOn: self.$settings.inputHUDEnabled)

                SettingsToggleRow(
                    title: "Capture indicators",
                    subtitle: "Outline captures and show the privacy-relevant live capture indicator.",
                    systemImage: "camera.viewfinder",
                    isOn: self.$settings.captureIndicatorsEnabled)
            }
            .opacity(self.settings.visualizerEnabled ? 1 : 0.5)
            .disabled(!self.settings.visualizerEnabled)

            Section("Playback") {
                HStack {
                    Label("Animation speed", systemImage: "speedometer")
                    Spacer()
                    Slider(value: self.$settings.visualizerAnimationSpeed, in: 0.1...2, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.1fx", self.settings.visualizerAnimationSpeed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                HStack {
                    Label("Effect intensity", systemImage: "wand.and.rays")
                    Spacer()
                    Slider(value: self.$settings.visualizerEffectIntensity, in: 0.1...2, step: 0.1)
                        .frame(width: 150)
                    Text(String(format: "%.1fx", self.settings.visualizerEffectIntensity))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .opacity(self.settings.visualizerEnabled ? 1 : 0.5)
            .disabled(!self.settings.visualizerEnabled)
        }
        .formStyle(.grouped)
    }
}

#Preview {
    VisualizerSettingsView(settings: PeekabooSettings())
        .frame(width: 650, height: 600)
}
