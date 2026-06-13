import PeekabooCore
import Testing
@testable import PeekabooCLI

struct AppListFilteringTests {
    @Test
    func `default filtering excludes hidden and background apps`() {
        let applications = [
            Self.application(name: "Regular", activationPolicy: .regular),
            Self.application(name: "Accessory", activationPolicy: .accessory),
            Self.application(name: "Prohibited", activationPolicy: .prohibited),
            Self.application(name: "Hidden", isHidden: true, activationPolicy: .regular),
            Self.application(name: "Unknown", activationPolicy: .unknown),
            Self.application(name: "Legacy", activationPolicy: nil),
        ]

        let filtered = AppCommand.ListSubcommand.filteredApplications(
            applications,
            includeHidden: false,
            includeBackground: false
        )

        #expect(filtered.map(\.name) == ["Regular", "Unknown", "Legacy"])
    }

    @Test
    func `include background retains accessory and prohibited apps`() {
        let applications = [
            Self.application(name: "Regular", activationPolicy: .regular),
            Self.application(name: "Accessory", activationPolicy: .accessory),
            Self.application(name: "Prohibited", activationPolicy: .prohibited),
        ]

        let filtered = AppCommand.ListSubcommand.filteredApplications(
            applications,
            includeHidden: false,
            includeBackground: true
        )

        #expect(filtered.map(\.name) == ["Regular", "Accessory", "Prohibited"])
    }

    @Test
    func `include hidden is independent from include background`() {
        let applications = [
            Self.application(name: "Hidden Regular", isHidden: true, activationPolicy: .regular),
            Self.application(name: "Hidden Accessory", isHidden: true, activationPolicy: .accessory),
        ]

        let filtered = AppCommand.ListSubcommand.filteredApplications(
            applications,
            includeHidden: true,
            includeBackground: false
        )

        #expect(filtered.map(\.name) == ["Hidden Regular"])
    }

    private static func application(
        name: String,
        isHidden: Bool = false,
        activationPolicy: ServiceApplicationActivationPolicy?
    ) -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 42,
            bundleIdentifier: "example.\(name)",
            name: name,
            isHidden: isHidden,
            activationPolicy: activationPolicy
        )
    }
}
