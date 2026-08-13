import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe), .serialized)
struct PasteCommandInventoryEligibilityTests {
    @Test
    @MainActor
    func `Background paste refuses prohibited and incomplete inventory rows before dispatch`() async throws {
        let ineligibleApplications = [
            AutomationTestFixtures.application(
                processIdentifier: 2468,
                processStartIdentity: 24,
                bundleIdentifier: "com.example.helper",
                name: "Prohibited Helper",
                isHiddenKnown: true,
                activationPolicy: .prohibited
            ),
            ServiceApplicationInfo(
                processIdentifier: 9753,
                processStartIdentity: 97,
                bundleIdentifier: nil,
                name: "Incomplete Helper",
                isHiddenKnown: false,
                activationPolicy: nil,
                metadataWarnings: ["metadata timed out"]
            ),
        ]

        for application in ineligibleApplications {
            let automation = StubAutomationService()
            let clipboard = StubClipboardService()
            let result = try await InProcessCommandRunner.run(
                [
                    "paste",
                    "--app", application.name,
                    "--text", "must not dispatch",
                    "--json",
                    "--no-remote",
                ],
                services: TestServicesFactory.makePeekabooServices(
                    applications: StubApplicationService(applications: [application]),
                    clipboard: clipboard,
                    automation: automation
                )
            )

            #expect(result.exitStatus != 0)
            #expect(result.stdout.contains("cannot receive background input"))
            let envelope = try ActionEnvelopeTestProbe.decode(result.stdout)
            ActionEnvelopeTestAssertions.expectCanonicalRefusal(reason: .targetUnavailable, in: envelope)
            #expect(automation.targetedTypeActionsCalls.isEmpty)
            #expect(automation.targetedHotkeyCalls.isEmpty)
            #expect(automation.hotkeyCalls.isEmpty)
            #expect(try clipboard.get(prefer: nil) == nil)
        }
    }
}
