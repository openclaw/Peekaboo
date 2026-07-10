import CoreGraphics
import Foundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

#if !PEEKABOO_SKIP_AUTOMATION
@Suite(.tags(.automation), .enabled(if: CLITestEnvironment.runAutomationRead))
struct DockCommandTests {
    @Test
    func `Help output is consistent with V1`() async throws {
        let result = try await self.runCommand(["dock", "--help"])
        let output = result.output

        // Check for expected help content
        #expect(output.contains("Interact with the macOS Dock"))
        #expect(output.contains("launch"))
        #expect(output.contains("right-click"))
        #expect(output.contains("hide"))
        #expect(output.contains("show"))
        #expect(output.contains("list"))
    }

    @Test
    func `List command JSON structure`() async throws {
        let result = try await self.runCommand(["dock", "list", "--json"])
        let output = result.output

        // Parse JSON
        let jsonData = Data(output.utf8)
        let response = try JSONDecoder().decode(JSONResponse.self, from: jsonData)

        #expect(response.success == true)
        // For now, just check success since we don't have access to the response data structure
        // This would need to be updated based on the actual dock command response format
    }

    private struct CommandResult {
        let output: String
        let status: Int32
    }

    private func runCommand(_ arguments: [String]) async throws -> CommandResult {
        let services = await MainActor.run { self.makeTestServices() }
        let result = try await InProcessCommandRunner.run(arguments, services: services)
        let output = result.stdout.isEmpty ? result.stderr : result.stdout
        return CommandResult(output: output, status: result.exitStatus)
    }

    @MainActor
    private func makeTestServices() -> PeekabooServices {
        let applications = StubApplicationService(applications: [])
        let dockItems = [
            DockItem(
                index: 0,
                title: "Finder",
                itemType: .application,
                isRunning: true,
                bundleIdentifier: "com.apple.finder",
                position: CGPoint(x: 0, y: 0),
                size: CGSize(width: 64, height: 64)
            ),
        ]
        let dockService = StubDockService(items: dockItems, autoHidden: false)
        return TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: StubWindowService(windowsByApp: [:]),
            menu: StubMenuService(menusByApp: [:]),
            dialogs: StubDialogService(),
            dock: dockService
        )
    }
}
#endif

@Suite(.tags(.safe), .serialized)
struct DockCommandJSONContractTests {
    @Test
    @MainActor
    func `dock list JSON emits legacy and preferred item keys`() async throws {
        let dockItems = [
            DockItem(
                index: 0,
                title: "Finder",
                itemType: .application,
                isRunning: true,
                bundleIdentifier: "com.apple.finder",
                position: CGPoint(x: 0, y: 0),
                size: CGSize(width: 64, height: 64)
            ),
        ]
        let services = TestServicesFactory.makePeekabooServices(
            dock: StubDockService(items: dockItems, autoHidden: false)
        )

        let result = try await InProcessCommandRunner.run(["dock", "list", "--json"], services: services)

        #expect(result.exitStatus == 0)
        let data = try #require(result.stdout.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payloadData = try #require(json["data"] as? [String: Any])
        let dockItemsLegacy = try #require(payloadData["dockItems"] as? [[String: Any]])
        let dockItemsPreferred = try #require(payloadData["dock_items"] as? [[String: Any]])
        #expect(dockItemsLegacy.count == 1)
        #expect(dockItemsPreferred.count == dockItemsLegacy.count)
        #expect(payloadData["count"] as? Int == 1)
    }
}
