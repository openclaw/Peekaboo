import AppKit
import PeekabooCore
import SwiftUI

let permissionsOnboardingSeenKey = "peekaboo.permissionsOnboardingSeen"
let permissionsOnboardingVersionKey = "peekaboo.permissionsOnboardingVersion"

@MainActor
final class PermissionsOnboardingController {
    static let shared = PermissionsOnboardingController()

    private var window: NSWindow?

    func show(permissions: Permissions) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = PermissionsOnboardingView(permissions: permissions)
            .environment(permissions)
        let hosting = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Permissions"
        window.setContentSize(NSSize(width: 680, height: 760))
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        self.window?.close()
        self.window = nil
    }
}

struct PermissionsOnboardingView: View {
    @Bindable var permissions: Permissions

    private let pageWidth: CGFloat = 680
    private let contentHeight: CGFloat = 520
    private var buttonTitle: String {
        "Done"
    }

    var body: some View {
        VStack(spacing: 0) {
            GhostImageView(state: .peek2, size: CGSize(width: 96, height: 96))
                .padding(.top, 18)
                .padding(.bottom, 4)
                .frame(height: 132)

            GeometryReader { _ in
                self.permissionsPage()
                    .frame(width: self.pageWidth)
                    .frame(height: self.contentHeight, alignment: .top)
            }
            .frame(height: self.contentHeight)

            self.navigationBar
        }
        .frame(width: self.pageWidth, height: 720)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await self.permissions.check()
        }
        .onAppear {
            self.permissions.registerMonitoring()
        }
        .onDisappear {
            self.permissions.unregisterMonitoring()
        }
    }

    private func permissionsPage() -> some View {
        self.onboardingPage {
            Text("Permissions checklist")
                .font(.largeTitle.weight(.semibold))
            Text(
                "Peekaboo 3.9.6 completes the move to the OpenClaw Foundation signing identity. " +
                    "macOS may treat it as a new permission client, so re-grant Screen Recording, " +
                    "Accessibility, and any Automation access you use.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
                .fixedSize(horizontal: false, vertical: true)

            self.onboardingCard {
                PermissionChecklistView(showOptional: true)

                Button("Open Settings → Permissions") {
                    SettingsOpener.openSettings(tab: .permissions)
                }
                .buttonStyle(.link)
                .padding(.top, 6)
            }
        }
    }

    private var navigationBar: some View {
        HStack {
            Spacer()
            Button(action: self.finish) {
                Text(self.buttonTitle)
                    .frame(minWidth: 88)
            }
            .keyboardShortcut(.return)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(height: 60)
    }

    private func onboardingPage(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 22) {
            content()
            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(width: self.pageWidth, alignment: .top)
    }

    private func onboardingCard(
        spacing: CGFloat = 12,
        padding: CGFloat = 16,
        @ViewBuilder _ content: () -> some View) -> some View
    {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 3))
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: permissionsOnboardingSeenKey)
        UserDefaults.standard.set(
            PeekabooPermissionOnboardingPolicy.currentVersion,
            forKey: permissionsOnboardingVersionKey)
        PermissionsOnboardingController.shared.close()
    }
}
