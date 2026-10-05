import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@MainActor
@Suite(.serialized, .tags(.safe))
struct CLIVerifiedActionResultTests {
    @Test
    func `verified menu bar click preserves an outcome without observed change evidence`() async throws {
        let preFocusApp = ServiceApplicationInfo(
            processIdentifier: 7,
            processStartIdentity: 70,
            bundleIdentifier: "com.apple.finder",
            name: "Finder"
        )
        let menuOwner = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 420,
            bundleIdentifier: "com.apple.controlcenter",
            name: "Control Center"
        )
        let applications = StubApplicationService(applications: [preFocusApp])
        let menu = OutcomeStubMenuService(menusByApp: [:])
        menu.actionOutcome = Self.dispatchedOutcome
        menu.actionTargetIdentity = try Self.processTarget()
        menu.menuBarItems = [MenuBarItemInfo(
            title: "Wi-Fi",
            index: 0,
            bundleIdentifier: menuOwner.bundleIdentifier,
            ownerName: menuOwner.name,
            rawOwnerPID: menuOwner.processIdentifier
        )]
        menu.menuBarClickResult = PeekabooCore.ClickResult(
            elementDescription: "Wi-Fi",
            location: CGPoint(x: 100, y: 10)
        )
        menu.actionCompleted = { applications.applications = [menuOwner] }
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--foreground", "--verify", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let data = try #require(object["data"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["dispatched_unit_count"] as? Int == 1)
        #expect(data["verified"] as? Bool == true)
        try Self.expectProcessTarget(in: object)
    }

    @Test
    func `menu bar verification failure preserves dispatched outcome and target`() async throws {
        let preFocusApp = ServiceApplicationInfo(
            processIdentifier: 7,
            processStartIdentity: 70,
            bundleIdentifier: "com.apple.finder",
            name: "Finder"
        )
        let applications = VerificationFailureApplicationService(applications: [preFocusApp])
        let menu = OutcomeStubMenuService(menusByApp: [:])
        menu.actionOutcome = Self.dispatchedOutcome
        menu.actionTargetIdentity = try Self.processTarget()
        menu.menuBarItems = [MenuBarItemInfo(
            title: "Wi-Fi",
            index: 0,
            bundleIdentifier: "com.apple.controlcenter",
            ownerName: "Control Center",
            rawOwnerPID: 42
        )]
        menu.menuBarClickResult = PeekabooCore.ClickResult(
            elementDescription: "Wi-Fi",
            location: CGPoint(x: 100, y: 10)
        )
        menu.actionCompleted = { applications.failFrontmostLookup = true }
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            menu: menu
        )

        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--foreground", "--verify", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        #expect(result.exitStatus == 1)
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(error["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        try Self.expectProcessTarget(in: object)
    }

    @Test
    func `verified Dock launch preserves an outcome without observed change evidence`() async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 420,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        let dock = OutcomeStubDockService(items: [
            DockItem(
                index: 0,
                title: "Fixture",
                itemType: .application,
                bundleIdentifier: app.bundleIdentifier
            ),
        ])
        dock.actionOutcome = Self.dispatchedOutcome
        dock.actionTargetIdentity = try Self.processTarget()
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            dock: dock
        )

        let result = try await InProcessCommandRunner.run(
            ["dock", "launch", "Fixture", "--foreground", "--verify", "--json", "--no-remote"],
            services: services
        )

        let object = try Self.jsonObject(result.stdout)
        let projection = try #require(object["outcome"] as? [String: Any])
        #expect(result.exitStatus == 0)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(projection["state"] as? String == "dispatched_unverified")
        #expect(projection["route"] as? String == "bridge")
        #expect(projection["dispatched_unit_count"] as? Int == 1)
        try Self.expectProcessTarget(in: object)
    }

    private static let dispatchedOutcome = DesktopActionOutcome.dispatchedUnverified(
        route: .bridge,
        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one
    )

    private static func processTarget() throws -> DesktopTargetIdentity {
        try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 420
        ))
    }

    private static func expectProcessTarget(in object: [String: Any]) throws {
        let target = try #require(object["target_identity"] as? [String: Any])
        #expect(target["kind"] as? String == "process")
        #expect(target["pid"] as? Int == 42)
        #expect(target["process_start_identity_decimal"] as? String == "420")
    }

    private static func jsonObject(_ output: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}

@MainActor
private final class VerificationFailureApplicationService: StubApplicationService {
    var failFrontmostLookup = false

    override func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        if self.failFrontmostLookup {
            throw CancellationError()
        }
        return try await super.getFrontmostApplication()
    }
}
