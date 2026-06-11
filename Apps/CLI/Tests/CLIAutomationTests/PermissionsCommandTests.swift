import Commander
import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct PermissionsCommandTests {
    @Test
    func `permissions command metadata describes current command`() {
        #expect(PermissionsCommand.commandDescription.commandName == "permissions")
        #expect(PermissionsCommand.commandDescription.abstract == "Check Peekaboo permissions")
        #expect(PermissionsCommand.commandDescription.subcommands.count == 4)
    }

    @Test
    func `permissions status parses all sources flag`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: PermissionsCommand.StatusSubcommand.self,
            parsedValues: ParsedValues(
                positional: [],
                options: [:],
                flags: ["all-sources", "no-remote"]
            )
        )

        #expect(command.allSources == true)
        #expect(command.noRemote == true)
    }

    @Test
    func `permissions request screen recording command binds`() throws {
        _ = try CommanderCLIBinder.instantiateCommand(
            ofType: PermissionsCommand.RequestScreenRecordingSubcommand.self,
            parsedValues: ParsedValues(positional: [], options: [:], flags: [])
        )
    }

    @Test
    func `permissions status all sources emits JSON with local source`() async throws {
        let automation = StubAutomationService()
        automation.accessibilityPermissionGranted = false
        let screenCapture = StubScreenCaptureService(permissionGranted: false)

        let services = await MainActor.run {
            TestServicesFactory.makePeekabooServices(
                automation: automation,
                screenCapture: screenCapture
            )
        }

        let result = try await InProcessCommandRunner.run([
            "permissions",
            "status",
            "--all-sources",
            "--no-remote",
            "--json",
        ], services: services)

        #expect(result.exitStatus == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PermissionHelpers.PermissionSourcesResponse>.self
        )
        #expect(payload.success)
        #expect(payload.data.selectedSource == "local")
        #expect(payload.data.sources.count == 1)

        let local = try #require(payload.data.sources.first)
        #expect(local.source == "local")
        #expect(local.isSelected == true)
        #expect(local.permissions.contains { $0.name == "Screen Recording" && !$0.isGranted })
        #expect(local.permissions.contains { $0.name == "Accessibility" && !$0.isGranted })
    }
}
