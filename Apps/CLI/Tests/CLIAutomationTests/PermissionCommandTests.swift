import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.serialized, .tags(.permissions))
struct PermissionCommandTests {
    @Test
    func `permissions includes accessibility request`() {
        let names = PermissionsCommand.commandDescription.subcommands.compactMap(\.commandDescription.commandName)
        #expect(names.contains("request"))
    }

    @Test
    func `permissions command emits JSON with stub statuses`() async {
        let automation = StubAutomationService()
        automation.accessibilityPermissionGranted = false
        let screenCapture = StubScreenCaptureService(permissionGranted: false)

        let services = await MainActor.run {
            TestServicesFactory.makePeekabooServices(
                automation: automation,
                screenCapture: screenCapture
            )
        }

        let payload = await CodableJSONResponse(
            success: true,
            data: PermissionHelpers.getCurrentPermissions(services: services, allowRemote: false),
            messages: nil,
            debug_logs: []
        )

        #expect(payload.success == true)
        #expect(payload.data.count == 3)
        if let screenRecording = payload.data.first(where: { $0.name == "Screen Recording" }) {
            #expect(screenRecording.isGranted == false)
            #expect(screenRecording.isRequired == true)
        } else {
            Issue.record("Missing screen recording entry")
        }

        if let accessibility = payload.data.first(where: { $0.name == "Accessibility" }) {
            #expect(accessibility.isGranted == false)
            #expect(accessibility.isRequired == true)
        } else {
            Issue.record("Missing accessibility entry")
        }

        if let eventSynthesizing = payload.data.first(where: { $0.name == "Event Synthesizing" }) {
            #expect(eventSynthesizing.isRequired == false)
        } else {
            Issue.record("Missing event synthesizing entry")
        }
    }

    @Test
    func `permissions command prints grant instructions when missing`() async throws {
        let automation = StubAutomationService()
        automation.accessibilityPermissionGranted = false
        let screenCapture = StubScreenCaptureService(permissionGranted: true)

        let services = await MainActor.run {
            TestServicesFactory.makePeekabooServices(
                automation: automation,
                screenCapture: screenCapture
            )
        }

        let result = try await InProcessCommandRunner.run([
            "permissions"
        ], services: services)

        #expect(result.exitStatus == 0)
    }

    @Test
    func `permissions status JSON includes event synthesizing`() async throws {
        let services = await MainActor.run {
            TestServicesFactory.makePeekabooServices()
        }

        let result = try await InProcessCommandRunner.run([
            "permissions",
            "status",
            "--no-remote",
            "--json",
        ], services: services)

        #expect(result.exitStatus == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PermissionHelpers.PermissionStatusResponse>.self
        )
        #expect(payload.success)
        #expect(payload.data.permissions.contains { $0.name == "Event Synthesizing" })
    }

    @Test
    func `permissions can request event synthesizing in JSON mode`() async throws {
        let services = await MainActor.run {
            TestServicesFactory.makePeekabooServices()
        }

        let result = try await InProcessCommandRunner.run([
            "permissions",
            "request",
            "event-synthesizing",
            "--json",
        ], services: services)

        #expect(result.exitStatus == 0)
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PermissionRequestResultForTest>.self
        )
        #expect(payload.success)
        #expect(payload.data.action == "request-event-synthesizing")
    }
}
#endif

private struct PermissionRequestResultForTest: Codable {
    let action: String
    let already_granted: Bool
    let prompt_triggered: Bool
    let granted: Bool?
}

#if !PEEKABOO_SKIP_AUTOMATION
extension PermissionCommandTests {
    fileprivate static func balancedJSON(in text: Substring) -> String? {
        var curly = 0
        var square = 0
        var end: String.Index?

        for index in text.indices {
            let char = text[index]
            if char == "{" {
                curly += 1
            }
            if char == "}" {
                curly -= 1
            }
            if char == "[" {
                square += 1
            }
            if char == "]" {
                square -= 1
            }

            if curly == 0 && square == 0 && (char == "}" || char == "]") {
                end = text.index(after: index)
                break
            }
        }

        guard let end else { return nil }
        return String(text.prefix(upTo: end))
    }
}
#endif
