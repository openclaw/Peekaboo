import PeekabooAutomationKit
import Testing
@testable import PeekabooAgentRuntime

struct DesktopContextApplicationFilteringTests {
    @Test
    func `recent apps omit prohibited and incomplete inventory rows before applying limit`() {
        let applications = [
            Self.application(name: "A Daemon", policy: .prohibited),
            Self.application(name: "B Incomplete", isHiddenKnown: false, policy: nil),
            Self.application(name: "Editor", policy: .regular),
            Self.application(name: "Menu Extra", policy: .accessory),
            Self.application(name: "Browser", isActive: true, policy: .regular),
        ]

        let names = DesktopContextService.recentApplicationNames(applications)

        #expect(names == ["Browser", "Editor", "Menu Extra"])
    }

    private static func application(
        name: String,
        isActive: Bool = false,
        isHiddenKnown: Bool? = nil,
        policy: ServiceApplicationActivationPolicy?) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: Int32(abs(name.hashValue % 10000) + 1),
            bundleIdentifier: "com.example.\(name)",
            name: name,
            isActive: isActive,
            isHiddenKnown: isHiddenKnown,
            activationPolicy: policy)
    }
}
