import SwiftUI

struct PermissionsSettingsView: View {
    @Environment(Permissions.self) private var permissions

    var body: some View {
        Form {
            Section {
                Text("Grant required permissions so Peekaboo can capture and automate reliably.")
            }

            Section("Permissions") {
                PermissionChecklistView(showOptional: true)
                    .padding(.vertical, 4)
            }

            Section {
                Button("Show Permissions Onboarding…") {
                    PermissionsOnboardingController.shared.show(permissions: self.permissions)
                }
            }
        }
        .formStyle(.grouped)
    }
}

#if DEBUG
struct PermissionsSettingsView_Previews: PreviewProvider {
    static var previews: some View {
        PermissionsSettingsView()
            .environment(Permissions())
            .frame(width: 550, height: 700)
    }
}
#endif
