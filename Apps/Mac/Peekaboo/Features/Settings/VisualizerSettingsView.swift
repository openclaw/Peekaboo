import os
import PeekabooCore
import PeekabooFoundation
import PeekabooUICore
import SwiftUI

struct VisualizerSettingsView: View {
    @Bindable var settings: PeekabooSettings
    @Environment(VisualizerCoordinator.self) private var visualizerCoordinator

    var body: some View {
        Form {
            Section {
                SettingsToggleRow(
                    title: "Visual Feedback",
                    subtitle: "Animated on-screen feedback for Peekaboo operations.",
                    systemImage: "sparkles",
                    isOn: self.$settings.visualizerEnabled)
            }

            // Animation Controls Section
            Section("Animation Settings") {
                HStack {
                    Label("Animation Speed", systemImage: "speedometer")
                    Spacer()
                    Slider(value: self.$settings.visualizerAnimationSpeed, in: 0.1...2.0, step: 0.1)
                        .frame(width: 150)
                        .disabled(!self.settings.visualizerEnabled)
                    Text(String(format: "%.1fx", self.settings.visualizerAnimationSpeed))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                HStack {
                    Label("Effect Intensity", systemImage: "wand.and.rays")
                    Spacer()
                    Slider(value: self.$settings.visualizerEffectIntensity, in: 0.1...2.0, step: 0.1)
                        .frame(width: 150)
                        .disabled(!self.settings.visualizerEnabled)
                    Text(String(format: "%.1fx", self.settings.visualizerEffectIntensity))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 36, alignment: .trailing)
                }

                HStack {
                    Label("Sound Effects", systemImage: "speaker.wave.2")
                    Spacer()
                    Toggle("Sound Effects", isOn: self.$settings.visualizerSoundEnabled)
                        .labelsHidden()
                }
                .disabled(!self.settings.visualizerEnabled)
            }
            .opacity(self.settings.visualizerEnabled ? 1 : 0.5)

            // Individual Animations Section
            Section("Animation Types") {
                AnimationToggleRow(
                    title: "Screenshot Flash",
                    icon: "camera.viewfinder",
                    isOn: self.$settings.screenshotFlashEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "screenshot",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Click Animation",
                    icon: "cursorarrow.click",
                    isOn: self.$settings.clickAnimationEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "click",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Type Animation",
                    icon: "keyboard",
                    isOn: self.$settings.typeAnimationEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "type",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Scroll Animation",
                    icon: "arrow.up.arrow.down",
                    isOn: self.$settings.scrollAnimationEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "scroll",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Mouse Trail",
                    icon: "scribble",
                    isOn: self.$settings.mouseTrailEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "trail",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Swipe Path",
                    icon: "hand.draw",
                    isOn: self.$settings.swipePathEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "swipe",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Hotkey Overlay",
                    icon: "command",
                    isOn: self.$settings.hotkeyOverlayEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "hotkey",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "App Lifecycle",
                    icon: "app.badge",
                    isOn: self.$settings.appLifecycleEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "app_launch",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Window Operations",
                    icon: "macwindow",
                    isOn: self.$settings.windowOperationEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "window",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Menu Navigation",
                    icon: "menubar.rectangle",
                    isOn: self.$settings.menuNavigationEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "menu",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Dialog Interaction",
                    icon: "text.bubble",
                    isOn: self.$settings.dialogInteractionEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "dialog",
                    settings: self.settings)

                AnimationToggleRow(
                    title: "Space Transitions",
                    icon: "squares.below.rectangle",
                    isOn: self.$settings.spaceTransitionEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "space",
                    settings: self.settings)
            }
            .opacity(self.settings.visualizerEnabled ? 1 : 0.5)

            Section("Watch Capture") {
                AnimationToggleRow(
                    title: "Watch Capture HUD",
                    subtitle: "Pulse indicator for `peekaboo capture live` sessions",
                    icon: "applewatch.watchface",
                    isOn: self.$settings.watchCaptureHUDEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "watch",
                    settings: self.settings)
            }
            .opacity(self.settings.visualizerEnabled ? 1 : 0.5)

            // Easter Eggs Section
            Section("Easter Eggs") {
                AnimationToggleRow(
                    title: "Ghost Animation",
                    subtitle: "Shows every 10th screenshot",
                    icon: "eye.slash",
                    isOn: self.$settings.ghostEasterEggEnabled,
                    isEnabled: self.settings.visualizerEnabled,
                    animationType: "ghost",
                    settings: self.settings)
            }
            .opacity(self.settings.visualizerEnabled ? 1 : 0.5)
        }
        .formStyle(.grouped)
    }
}

// MARK: - Supporting Views

struct AnimationToggleRow: View {
    let title: String
    var subtitle: String?
    let icon: String
    @Binding var isOn: Bool
    let isEnabled: Bool
    let animationType: String
    let settings: PeekabooSettings

    @Environment(VisualizerCoordinator.self) private var visualizerCoordinator
    @State private var isPreviewRunning = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(self.title)
                        .foregroundStyle(self.isEnabled ? .primary : .secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: self.icon)
                    .foregroundStyle(self.isEnabled ? Color.accentColor : .secondary)
            }

            Spacer()

            // Preview button
            Button {
                Task {
                    await self.runPreview()
                }
            } label: {
                Image(systemName: self.isPreviewRunning ? "stop.circle" : "play.circle")
                    .foregroundStyle(self.canPreview ? Color.accentColor : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(!self.canPreview || self.isPreviewRunning)
            .help("Preview \(self.title) animation")

            Toggle(self.title, isOn: self.$isOn)
                .labelsHidden()
                .disabled(!self.isEnabled)
        }
    }

    private var canPreview: Bool {
        self.isEnabled && self.settings.visualizerEnabled && self.isOn
    }

    @MainActor
    private func runPreview() async {
        self.isPreviewRunning = true
        defer { self.isPreviewRunning = false }

        let screen = NSScreen.mouseScreen
        let centerPoint = CGPoint(x: screen.frame.midX, y: screen.frame.midY)

        await self.performPreview(on: screen, centerPoint: centerPoint)
        // Keep button in running state for a moment to show feedback
        try? await Task.sleep(for: .milliseconds(500))
    }

    @MainActor
    private func performPreview(on screen: NSScreen, centerPoint: CGPoint) async {
        switch self.animationType {
        case "screenshot":
            await self.previewScreenshot(on: screen)
        case "click":
            await self.previewClick(at: centerPoint)
        case "type":
            await self.previewTyping()
        case "scroll":
            await self.previewScroll(at: centerPoint)
        case "trail":
            await self.previewTrail(on: screen)
        case "swipe":
            await self.previewSwipe(on: screen)
        case "hotkey":
            await self.previewHotkey()
        case "app_launch":
            await self.previewAppLifecycle()
        case "window":
            await self.previewWindowMovement(on: screen)
        case "menu":
            await self.previewMenuNavigation()
        case "dialog":
            await self.previewDialog(on: screen)
        case "space":
            await self.previewSpaceSwitch()
        case "ghost":
            await self.previewGhostFlash(on: screen)
        case "watch":
            await self.previewWatchHUD(on: screen)
        default:
            break
        }
    }

    @MainActor
    private func previewScreenshot(on screen: NSScreen) async {
        let rect = CGRect(
            x: screen.frame.midX - 200,
            y: screen.frame.midY - 150,
            width: 400,
            height: 300)
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showScreenshotFlash(in: rect)
        }
    }

    @MainActor
    private func previewClick(at point: CGPoint) async {
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showClickFeedback(at: point, type: .single)
        }
    }

    @MainActor
    private func previewTyping() async {
        let sampleKeys = ["H", "e", "l", "l", "o"]
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showTypingFeedback(
                keys: sampleKeys,
                duration: 2.0,
                cadence: .human(wordsPerMinute: 60))
        }
    }

    @MainActor
    private func previewScroll(at point: CGPoint) async {
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showScrollFeedback(at: point, direction: .down, amount: 3)
        }
    }

    @MainActor
    private func previewTrail(on screen: NSScreen) async {
        let from = CGPoint(x: screen.frame.midX - 150, y: screen.frame.midY - 50)
        let to = CGPoint(x: screen.frame.midX + 150, y: screen.frame.midY + 50)
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showMouseMovement(from: from, to: to, duration: 1.5)
        }
    }

    @MainActor
    private func previewSwipe(on screen: NSScreen) async {
        let swipeFrom = CGPoint(x: screen.frame.midX - 100, y: screen.frame.midY)
        let swipeTo = CGPoint(x: screen.frame.midX + 100, y: screen.frame.midY)
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showSwipeGesture(from: swipeFrom, to: swipeTo, duration: 1.0)
        }
    }

    @MainActor
    private func previewHotkey() async {
        let sampleKeys = ["⌘", "⇧", "P"]
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showHotkeyDisplay(keys: sampleKeys, duration: 2.0)
        }
    }

    @MainActor
    private func previewAppLifecycle() async {
        await self.visualizerCoordinator.runPreview {
            if Bool.random() {
                _ = await self.visualizerCoordinator.showAppLaunch(appName: "Peekaboo", iconPath: nil as String?)
            } else {
                _ = await self.visualizerCoordinator.showAppQuit(appName: "TextEdit", iconPath: nil as String?)
            }
        }
    }

    @MainActor
    private func previewWindowMovement(on screen: NSScreen) async {
        let windowRect = CGRect(
            x: screen.frame.midX - 150,
            y: screen.frame.midY - 100,
            width: 300,
            height: 200)
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showWindowOperation(.move, windowRect: windowRect, duration: 1.0)
        }
    }

    @MainActor
    private func previewMenuNavigation() async {
        let menuPath = ["File", "Export", "PNG Image"]
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showMenuNavigation(menuPath: menuPath)
        }
    }

    @MainActor
    private func previewDialog(on screen: NSScreen) async {
        let dialogRect = CGRect(
            x: screen.frame.midX - 100,
            y: screen.frame.midY - 25,
            width: 200,
            height: 50)
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showDialogInteraction(
                element: .button,
                elementRect: dialogRect,
                action: .clickButton)
        }
    }

    @MainActor
    private func previewSpaceSwitch() async {
        await self.visualizerCoordinator.runPreview {
            _ = await self.visualizerCoordinator.showSpaceSwitch(from: 1, to: 2, direction: .right)
        }
    }

    @MainActor
    private func previewGhostFlash(on screen: NSScreen) async {
        if let window = NSApp.keyWindow {
            _ = await self.visualizerCoordinator.showScreenshotFlash(in: window.frame)
            return
        }

        let rect = CGRect(
            x: screen.frame.midX - 200,
            y: screen.frame.midY - 150,
            width: 400,
            height: 300)
        _ = await self.visualizerCoordinator.showScreenshotFlash(in: rect)
    }

    @MainActor
    private func previewWatchHUD(on screen: NSScreen) async {
        let hudRect = CGRect(
            x: screen.frame.midX - 170,
            y: screen.frame.midY - 150,
            width: 340,
            height: 70)
        _ = await self.visualizerCoordinator.showWatchCapture(in: hudRect)
    }
}

#Preview {
    VisualizerSettingsView(settings: PeekabooSettings())
        .frame(width: 650, height: 1000)
}
