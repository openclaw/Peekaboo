import AppKit
import PeekabooCore
import SwiftUI

enum PermissionCapability: String, CaseIterable, Hashable {
    case screenRecording
    case accessibility
    case postEvent

    var isRequired: Bool {
        switch self {
        case .screenRecording, .accessibility: true
        case .postEvent: false
        }
    }

    var title: String {
        switch self {
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .postEvent: "Event Synthesizing"
        }
    }

    var subtitle: String {
        switch self {
        case .screenRecording:
            "Capture screenshots and see on-screen context"
        case .accessibility:
            "Control UI elements, mouse, and keyboard"
        case .postEvent:
            "Send background hotkeys without activating the app"
        }
    }

    var icon: String {
        switch self {
        case .screenRecording: "display"
        case .accessibility: "hand.raised"
        case .postEvent: "keyboard"
        }
    }

    var settingsURLCandidates: [String] {
        switch self {
        case .screenRecording:
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security",
            ]
        case .accessibility:
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security",
            ]
        case .postEvent:
            [
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                "x-apple.systempreferences:com.apple.preference.security",
            ]
        }
    }

    func status(in permissions: Permissions) -> ObservablePermissionsService.PermissionState {
        switch self {
        case .screenRecording:
            permissions.screenRecordingStatus
        case .accessibility:
            permissions.accessibilityStatus
        case .postEvent:
            permissions.postEventStatus
        }
    }

    @MainActor
    func request(using permissions: Permissions) async {
        switch self {
        case .screenRecording:
            await permissions.requestScreenRecording()
        case .accessibility:
            await permissions.requestAccessibility()
        case .postEvent:
            await permissions.requestPostEvent()
        }

        await permissions.refresh()

        if self.status(in: permissions) != .authorized {
            self.openSettings()
        }
    }

    @MainActor
    func openSettings() {
        for candidate in self.settingsURLCandidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

struct PermissionChecklistView: View {
    @Environment(Permissions.self) private var permissions
    let showOptional: Bool

    @State private var isRequesting = false

    init(showOptional: Bool = true) {
        self.showOptional = showOptional
    }

    private var capabilities: [PermissionCapability] {
        if self.showOptional {
            return PermissionCapability.allCases
        }
        return PermissionCapability.allCases.filter(\.isRequired)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(self.capabilities, id: \.self) { cap in
                PermissionChecklistRow(
                    capability: cap,
                    status: cap.status(in: self.permissions),
                    isRequesting: self.isRequesting)
                {
                    Task { @MainActor in
                        guard !self.isRequesting else { return }
                        self.isRequesting = true
                        defer { self.isRequesting = false }
                        await cap.request(using: self.permissions)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    Task { await self.permissions.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Refresh status")

                if self.isRequesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 2)
        }
        .task {
            await self.permissions.check()
        }
        .onAppear {
            self.permissions.setIncludeOptionalPermissions(self.showOptional)
        }
        .onDisappear {
            self.permissions.setIncludeOptionalPermissions(false)
        }
    }
}

struct PermissionChecklistRow: View {
    let capability: PermissionCapability
    let status: ObservablePermissionsService.PermissionState
    let isRequesting: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(self.status == .authorized ? Color.green.opacity(0.2) : Color.gray.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: self.capability.icon)
                    .foregroundStyle(self.status == .authorized ? Color.green : Color.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(self.capability.title)
                        .font(.body.weight(.semibold))
                    if !self.capability.isRequired {
                        Text("Optional")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.secondary.opacity(0.12)))
                    }
                }
                Text(self.capability.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if self.status == .authorized {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Grant") { self.action() }
                    .buttonStyle(.bordered)
                    .disabled(self.isRequesting)
            }
        }
        .padding(.vertical, 6)
    }
}

#if DEBUG
struct PermissionChecklistView_Previews: PreviewProvider {
    static var previews: some View {
        PermissionChecklistView()
            .environment(Permissions())
            .frame(width: 520, height: 420)
            .padding()
    }
}
#endif
