import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@MainActor
@Suite(.serialized, .tags(.safe))
struct MenuForegroundAuthorityTests {
    @Test
    func `foreground menu list publishes exact focus outcome and pinned menu target`() async throws {
        let fixture = Self.fixture()

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "list", "--app", fixture.application.name,
                "--foreground", "--json", "--no-remote",
            ],
            services: fixture.services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(outcome["state"] as? String == "confirmed_change")
        #expect(outcome["delivery_mode"] as? String == "foreground")
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["process_start_identity_decimal"] as? String == "7")
        #expect(receipt["window_id"] as? Int == 924)
        #expect(fixture.windows.focusCalls.count == 1)
        #expect(fixture.menu.listMenusRequests == ["PID:42"])
    }

    @Test
    func `foreground menu list refuses fuzzy app before focus or lookup`() async throws {
        let fixture = Self.fixture()

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "list", "--app", "Fixt",
                "--foreground", "--json", "--no-remote",
            ],
            services: fixture.services
        )

        #expect(result.exitStatus == 1)
        #expect(result.combinedOutput.contains("not allowed for mutation"))
        #expect(fixture.windows.focusCalls.isEmpty)
        #expect(fixture.menu.listMenusRequests.isEmpty)
    }

    @Test
    func `foreground menu list refuses a partial application catalog before focus`() async throws {
        let fixture = Self.fixture()
        fixture.applications.inventoryCompleteness = .partial
        fixture.applications.inventoryWarnings = ["Fixture metadata was incomplete."]

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "list", "--app", fixture.application.name,
                "--foreground", "--json", "--no-remote",
            ],
            services: fixture.services
        )

        let object = try Self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == "refused")
        #expect(outcome["dispatch_state"] as? String == "none")
        #expect(outcome["retry_safe"] as? Bool == true)
        #expect(fixture.windows.focusCalls.isEmpty)
        #expect(fixture.menu.listMenusRequests.isEmpty)
    }

    @Test
    func `background menu list preserves fuzzy read selectors`() async throws {
        let fixture = Self.fixture(menuIdentifiers: ["Fixt"])

        let result = try await InProcessCommandRunner.run(
            ["menu", "list", "--app", "Fixt", "--json", "--no-remote"],
            services: fixture.services
        )

        #expect(result.exitStatus == 0)
        #expect(fixture.windows.focusCalls.isEmpty)
        #expect(fixture.menu.listMenusRequests == ["Fixt"])
    }

    @Test
    func `foreground menu list discards replacement generation after focus`() async throws {
        let fixture = Self.fixture()
        fixture.menu.listMenusResult = MenuStructure(
            application: ServiceApplicationInfo(
                processIdentifier: 42,
                processStartIdentity: 8,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Replacement"
            ),
            menus: [Menu(title: "Replacement", items: [])]
        )

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "list", "--app", fixture.application.name,
                "--foreground", "--json", "--no-remote",
            ],
            services: fixture.services
        )

        try Self.expectFocusPreservingFailure(result)
        #expect(!result.combinedOutput.contains("Replacement\""))
        #expect(fixture.windows.focusCalls.count == 1)
        #expect(fixture.menu.listMenusRequests == ["PID:42"])
    }

    @Test
    func `foreground menu list failure after focus is indeterminate`() async throws {
        let fixture = Self.fixture()
        fixture.menu.listMenusError = PeekabooError.operationError(message: "Injected menu list failure")

        let result = try await InProcessCommandRunner.run(
            [
                "menu", "list", "--app", fixture.application.name,
                "--foreground", "--json", "--no-remote",
            ],
            services: fixture.services
        )

        try Self.expectFocusPreservingFailure(result)
        #expect(fixture.windows.focusCalls.count == 1)
        #expect(fixture.menu.listMenusRequests == ["PID:42"])
    }

    private struct Fixture {
        let application: ServiceApplicationInfo
        let services: PeekabooServices
        let applications: StubApplicationService
        let windows: OutcomeStubWindowService
        let menu: OutcomeStubMenuService
    }

    private static func fixture(
        menuIdentifiers: [String] = ["PID:42"]
    ) -> Fixture {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture"
        )
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let window = ServiceWindowInfo(
            windowID: 924,
            title: "Fixture",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: 924,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 7,
                capturedBounds: bounds
            )
        )
        let structure = MenuStructure(
            application: application,
            menus: [Menu(title: "File", items: [MenuItem(title: "Save", path: "File > Save")])]
        )
        let windows = OutcomeStubWindowService(windowsByApp: ["PID:42": [window]])
        windows.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one
        )
        let menu = OutcomeStubMenuService(
            menusByApp: Dictionary(uniqueKeysWithValues: menuIdentifiers.map { ($0, structure) })
        )
        let applications = StubApplicationService(applications: [application])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            windows: windows,
            menu: menu
        )
        return Fixture(
            application: application,
            services: services,
            applications: applications,
            windows: windows,
            menu: menu
        )
    }

    private static func expectFocusPreservingFailure(_ result: CommandRunResult) throws {
        let object = try self.jsonObject(result.stdout)
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let receipt = try #require(object["target_receipt"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["mutation_dispatched"] as? Bool == true)
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(receipt["pid"] as? Int == 42)
        #expect(receipt["process_start_identity_decimal"] as? String == "7")
        #expect(receipt["window_id"] as? Int == 924)
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
