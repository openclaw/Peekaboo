import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), .serialized)
struct MenuBarCommandConsentTests {
    @Test
    @MainActor
    func `named click without foreground refuses before lookup or dispatch`() async throws {
        let menu = RecordingMenuBarService()
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--verify", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 1)
        #expect(result.stderr.isEmpty)
        let payload = try self.decodeResponse(result)
        #expect(payload.effect == .refused)
        #expect(payload.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(payload.error?.retry_safe == true)
        #expect(payload.error?.mutation_dispatched == false)
        #expect(payload.error?.hint?.contains("menubar list") == true)
        #expect(menu.listCallCount == 0)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    @MainActor
    func `index click without foreground refuses before lookup or dispatch`() async throws {
        let menu = RecordingMenuBarService()
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "--index", "2", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 1)
        let payload = try self.decodeResponse(result)
        #expect(payload.effect == .refused)
        #expect(payload.error?.retry_safe == true)
        #expect(payload.error?.mutation_dispatched == false)
        #expect(menu.listCallCount == 0)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `missing named item is one typed pre-dispatch refusal`(verify: Bool) async throws {
        let menu = RecordingMenuBarService()
        var arguments = ["menubar", "click", "Missing", "--foreground", "--json"]
        if verify {
            arguments.append("--verify")
        }

        let result = try await InProcessCommandRunner.run(
            arguments,
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 1)
        #expect(result.stderr.isEmpty)
        let payload = try self.decodeResponse(result)
        #expect(payload.effect == .refused)
        #expect(payload.error?.code == ErrorCode.MENU_ITEM_NOT_FOUND.rawValue)
        #expect(payload.error?.message == "Menu bar item not found: Missing")
        #expect(payload.error?.retry_safe == true)
        #expect(payload.error?.mutation_dispatched == false)
        #expect(menu.listCallCount == 1)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    @MainActor
    func `human consent refusal is actionable and performs no lookup`() async throws {
        let menu = RecordingMenuBarService()
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Menu bar clicks require --foreground"))
        #expect(result.stderr.contains("Use 'peekaboo menubar list' for read-only discovery"))
        #expect(menu.listCallCount == 0)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    @MainActor
    func `list remains read-only without foreground`() async throws {
        let menu = RecordingMenuBarService(items: [Self.item])
        let result = try await InProcessCommandRunner.run(
            ["menubar", "list", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 0)
        let data = try #require(result.stdout.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["success"] as? Bool == true)
        #expect(json["effect"] == nil)
        #expect(menu.listCallCount == 1)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    @MainActor
    func `foreground named click preserves name-based dispatch`() async throws {
        let menu = RecordingMenuBarService(items: [Self.item])
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--foreground", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 0)
        #expect(menu.listCallCount == 1)
        #expect(menu.namedClickCalls == ["Wi-Fi"])
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    @MainActor
    func `foreground index click dispatches the requested index`() async throws {
        let menu = RecordingMenuBarService(items: [Self.item])
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "--index", "2", "--foreground", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 0)
        #expect(menu.listCallCount == 1)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls == [2])
    }

    @Test
    @MainActor
    func `foreground named click carries exact selected leaf evidence`() async throws {
        let evidence = try Self.evidence(index: 2, digest: "a")
        let menu = RecordingMenuBarService(items: [Self.item(selectionEvidence: evidence)])
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--foreground", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 0)
        let request = try #require(menu.exactRequests.first)
        #expect(request.name == "Wi-Fi")
        #expect(request.expectedLeafEvidence.normalizedSelector == "wi-fi")
        #expect(request.expectedLeafEvidence.matchKind == .exact)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    @MainActor
    func `foreground named click refuses a reordered selected leaf without legacy fallback`() async throws {
        let initial = try Self.evidence(index: 2, digest: "a")
        let reordered = try Self.evidence(index: 3, digest: "b")
        let menu = RecordingMenuBarService(
            items: [Self.item(selectionEvidence: initial)],
            liveEvidence: reordered
        )
        let result = try await InProcessCommandRunner.run(
            ["menubar", "click", "Wi-Fi", "--foreground", "--json"],
            services: TestServicesFactory.makePeekabooServices(menu: menu)
        )

        #expect(result.exitStatus == 1)
        let payload = try self.decodeResponse(result)
        #expect(payload.effect == .refused)
        #expect(payload.error?.retry_safe == true)
        #expect(payload.error?.mutation_dispatched == false)
        #expect(menu.exactRequests.count == 1)
        #expect(menu.namedClickCalls.isEmpty)
        #expect(menu.indexClickCalls.isEmpty)
    }

    @Test
    func `click help exposes foreground while list does not`() async throws {
        let click = try await InProcessCommandRunner.runShared(["menubar", "click", "--help"])
        let list = try await InProcessCommandRunner.runShared(["menubar", "list", "--help"])

        #expect(click.stdout.contains("--foreground"))
        #expect(click.stdout.contains("required"))
        #expect(!list.stdout.contains("--foreground"))
    }

    @MainActor
    private func decodeResponse(_ result: CommandRunResult) throws -> JSONResponse {
        let data = try #require(result.stdout.data(using: .utf8))
        return try JSONDecoder().decode(JSONResponse.self, from: data)
    }

    private static let item = MenuBarItemInfo(
        title: "Wi-Fi",
        index: 2,
        isVisible: true,
        description: "Wi-Fi status",
        rawTitle: "WiFi",
        bundleIdentifier: "com.apple.controlcenter",
        ownerName: "Control Center",
        frame: CGRect(x: 300, y: 0, width: 20, height: 20),
        identifier: "com.apple.controlcenter.wifi",
        rawOwnerPID: 42
    )

    private static func item(selectionEvidence: DesktopSelectedLeafEvidence) -> MenuBarItemInfo {
        MenuBarItemInfo(
            title: "Wi-Fi",
            index: 2,
            isVisible: true,
            description: "Wi-Fi status",
            rawTitle: "WiFi",
            bundleIdentifier: "com.apple.controlcenter",
            ownerName: "Control Center",
            frame: CGRect(x: 300, y: 0, width: 20, height: 20),
            identifier: "com.apple.controlcenter.wifi",
            rawOwnerPID: 42,
            selectionEvidence: selectionEvidence
        )
    }

    private static func evidence(index: Int, digest: Character) throws -> DesktopSelectedLeafEvidence {
        try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: String(index),
            matchKind: .index,
            selectedProcessIdentity: .init(processIdentifier: 42, processStartIdentity: 99),
            selectedIndex: index,
            selectedTitle: "Wi-Fi",
            selectedIdentifier: "com.apple.controlcenter.wifi",
            selectedRole: "AXStatusItem",
            selectedFrame: CGRect(x: 300 + CGFloat((index - 2) * 20), y: 0, width: 20, height: 20),
            candidateSetSHA256: String(repeating: digest, count: 64),
            candidateCount: 3
        )
    }
}

@MainActor
private final class RecordingMenuBarService: MenuServiceExactLeafActionResultProviding {
    let items: [MenuBarItemInfo]
    let liveEvidence: DesktopSelectedLeafEvidence?
    private(set) var listCallCount = 0
    private(set) var namedClickCalls: [String] = []
    private(set) var indexClickCalls: [Int] = []
    private(set) var exactRequests: [MenuBarItemActionRequest] = []

    init(items: [MenuBarItemInfo] = [], liveEvidence: DesktopSelectedLeafEvidence? = nil) {
        self.items = items
        self.liveEvidence = liveEvidence
    }

    func listMenus(for appIdentifier: String) async throws -> MenuStructure {
        self.emptyStructure(application: appIdentifier)
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        self.emptyStructure(application: "frontmost")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {}
    func clickMenuItemByName(app _: String, itemName _: String) async throws {}
    func clickMenuExtra(title _: String) async throws {}

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        self.listCallCount += 1
        return self.items
    }

    func clickMenuBarItem(named name: String) async throws -> PeekabooCore.ClickResult {
        self.namedClickCalls.append(name)
        return PeekabooCore.ClickResult(elementDescription: "Menu bar item: \(name)", location: nil)
    }

    func clickMenuBarItem(at index: Int) async throws -> PeekabooCore.ClickResult {
        self.indexClickCalls.append(index)
        return PeekabooCore.ClickResult(elementDescription: "Menu bar item [\(index)]", location: nil)
    }

    func clickMenuItemActionResult(app: String, itemPath: String) async throws -> UIAutomationActionResult<Void> {
        try await self.clickMenuItem(app: app, itemPath: itemPath)
        return .init(payload: (), outcome: nil)
    }

    func clickMenuItemByNameActionResult(app: String, itemName: String) async throws
    -> UIAutomationActionResult<Void> {
        try await self.clickMenuItemByName(app: app, itemName: itemName)
        return .init(payload: (), outcome: nil)
    }

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try await self.clickMenuExtra(title: title)
        return .init(payload: (), outcome: nil)
    }

    func clickMenuBarItemActionResult(named name: String) async throws
    -> UIAutomationActionResult<PeekabooAutomationKit.ClickResult> {
        try await .init(
            payload: self.clickMenuBarItem(named: name),
            outcome: self.clickOutcome,
            targetIdentity: self.clickTarget
        )
    }

    func clickMenuBarItemActionResult(at index: Int) async throws
    -> UIAutomationActionResult<PeekabooAutomationKit.ClickResult> {
        try await .init(
            payload: self.clickMenuBarItem(at: index),
            outcome: self.clickOutcome,
            targetIdentity: self.clickTarget
        )
    }

    func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
    -> UIAutomationActionResult<PeekabooAutomationKit.ClickResult> {
        self.exactRequests.append(request)
        let current = self.liveEvidence ?? request.expectedLeafEvidence
        guard request.expectedLeafEvidence.hasSameResolvedLeaf(as: current) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu bar item changed before dispatch"
            )
        }
        let target = try DesktopTargetIdentity(processIdentity: current.selectedProcessIdentity)
        let description = request.name.map { "Menu bar item: \($0)" } ??
            "Menu bar item [\(request.index ?? -1)]"
        return .init(
            payload: .init(elementDescription: description, location: nil),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one
            ),
            targetIdentity: target,
            selectedLeafEvidence: [request.expectedLeafEvidence]
        )
    }

    private func emptyStructure(application: String) -> MenuStructure {
        MenuStructure(
            application: ServiceApplicationInfo(
                processIdentifier: 1,
                bundleIdentifier: "test.menu",
                name: application
            ),
            menus: []
        )
    }

    private var clickOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
    }

    private var clickTarget: DesktopTargetIdentity {
        get throws {
            try DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 42,
                processStartIdentity: 99
            ))
        }
    }
}
