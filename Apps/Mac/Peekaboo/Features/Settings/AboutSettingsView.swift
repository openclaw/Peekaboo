import AppKit
import SwiftUI

@MainActor
struct AboutSettingsView: View {
    @State private var iconHover = false

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    var body: some View {
        VStack(spacing: 12) {
            if let image = NSApplication.shared.applicationIconImage {
                Button(action: self.openProjectHome) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: 104, height: 104)
                        .cornerRadius(18)
                        .scaleEffect(self.iconHover ? 1.05 : 1.0)
                        .shadow(color: self.iconHover ? .accentColor.opacity(0.25) : .clear, radius: 8)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                        self.iconHover = hovering
                    }
                }
            }

            VStack(spacing: 2) {
                Text("Peekaboo")
                    .font(.title3).bold()
                Text("Version \(self.versionString)")
                    .foregroundStyle(.secondary)
                Text("Menu bar companion for Peekaboo CLI permissions + automation.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }

            HStack(spacing: 18) {
                AboutLink(
                    icon: "chevron.left.slash.chevron.right",
                    title: "GitHub",
                    url: "https://github.com/openclaw/Peekaboo")
                AboutLink(icon: "globe", title: "Website", url: "https://steipete.me")
                AboutLink(icon: "envelope", title: "Email", url: "mailto:peter@steipete.me")
            }
            .padding(.top, 8)

            Text("© 2026 Peter Steinberger. MIT License.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 4)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func openProjectHome() {
        guard let url = URL(string: "https://github.com/openclaw/Peekaboo") else { return }
        NSWorkspace.shared.open(url)
    }
}

@MainActor
private struct AboutLink: View {
    let icon: String
    let title: String
    let url: String

    var body: some View {
        if let destination = URL(string: self.url) {
            Link(destination: destination) {
                Label(self.title, systemImage: self.icon)
            }
            .focusable(false)
        }
    }
}
