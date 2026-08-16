import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct RemoteMenuDockServiceActionResultTests {
    @Test
    func `remote Menu and Dock mutations preserve canonical outcomes and exact targets`() async throws {
        let menuTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 123,
            processStartIdentity: 456))
        let dockTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 741,
            processStartIdentity: 7401))
        let menu = RemoteResultMenuFixture(target: menuTarget)
        let dock = RemoteResultDockFixture(target: dockTarget)
        let services = RemoteMenuDockResultServices(menu: menu, dock: dock)
        let socketPath = "/tmp/peekaboo-remote-menu-dock-results-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-menu-dock-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let remoteMenu = RemoteMenuService(client: client)
        let remoteDock = RemoteDockService(client: client)

        let menuItem = try await remoteMenu.clickMenuItemResult(app: "StubApp", itemPath: "File > New")
        Self.expect(menuItem, outcome: menu.applicationMenuOutcome(), target: menuTarget)
        let namedMenuItem = try await remoteMenu.clickMenuItemByNameResult(app: "StubApp", itemName: "New")
        Self.expect(namedMenuItem, outcome: menu.applicationMenuOutcome(), target: menuTarget)
        let menuExtra = try await remoteMenu.clickMenuExtraResult(title: "Clock")
        Self.expect(menuExtra, outcome: menu.outcome, target: menuTarget)
        let namedMenuBarItem = try await remoteMenu.clickMenuBarItemResult(named: "Clock")
        Self.expect(namedMenuBarItem, outcome: menu.outcome, target: menuTarget)
        #expect(namedMenuBarItem.payload.elementDescription == "Clock")
        let indexedMenuBarItem = try await remoteMenu.clickMenuBarItemResult(at: 3)
        Self.expect(indexedMenuBarItem, outcome: menu.outcome, target: menuTarget)
        #expect(indexedMenuBarItem.payload.elementDescription == "menu-index-3")

        let dockLaunch = try await remoteDock.launchFromDockResult(appName: "Safari")
        Self.expect(dockLaunch, outcome: dock.launchOutcome, target: dockTarget)
        let dockContext = try await remoteDock.rightClickDockItemResult(
            appName: "Safari",
            menuItem: "Options")
        Self.expect(dockContext, outcome: dock.contextOutcome, target: dockTarget)

        try await remoteMenu.clickMenuItem(app: "StubApp", itemPath: "File > Open")
        try await remoteDock.launchFromDock(appName: "TextEdit")
        #expect(menu.actionCount == 6)
        #expect(menu.pinnedDeliveryModes == [.background, .background, .background])
        #expect(dock.itemActionCount == 3)

        await host.stop()
    }

    @Test
    func `protocol 1 28 target result APIs refuse before dispatch while legacy APIs remain`() async throws {
        let menu = try RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 123,
            processStartIdentity: 456)))
        let dock = try RemoteResultDockFixture(target: DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 772,
            processStartIdentity: 7702)))
        let services = RemoteMenuDockResultServices(menu: menu, dock: dock)
        let socketPath = "/tmp/peekaboo-remote-menu-dock-legacy-results-\(UUID().uuidString).sock"
        let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: ClosedRange(uncheckedBounds: (
                lower: PeekabooBridgeConstants.supportedProtocolRange.lowerBound,
                upper: legacyVersion)),
            allowedOperations: [.clickMenuItem, .launchDockItem, .rightClickDockItem],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-menu-dock-legacy-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.negotiatedVersion == legacyVersion)
        let remoteMenu = RemoteMenuService(client: client)
        let remoteDock = RemoteDockService(client: client)

        await Self.expectReceiptlessTargetResultRefusal {
            try await remoteMenu.clickMenuItemResult(app: "Fixture", itemPath: "File > New")
        }
        await Self.expectReceiptlessTargetResultRefusal {
            try await remoteDock.launchFromDockResult(appName: "Safari")
        }
        await Self.expectReceiptlessTargetResultRefusal {
            try await remoteDock.rightClickDockItemResult(appName: "Safari", menuItem: "Options")
        }
        #expect(menu.actionCount == 0)
        #expect(dock.itemActionCount == 0)

        try await remoteMenu.clickMenuItem(app: "Fixture", itemPath: "File > Open")
        try await remoteDock.launchFromDock(appName: "TextEdit")
        try await remoteDock.rightClickDockItem(appName: "TextEdit", menuItem: nil)
        #expect(menu.actionCount == 1)
        #expect(dock.itemActionCount == 2)
        await host.stop()
    }

    @Test
    func `remote Dock visibility preserves every admitted canonical success state`() async throws {
        let dock = try RemoteResultDockFixture(target: DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 751,
            processStartIdentity: 7501)))
        let services = try RemoteMenuDockResultServices(
            menu: RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 123,
                processStartIdentity: 456))),
            dock: dock)
        let socketPath = "/tmp/peekaboo-remote-dock-visibility-results-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-dock-visibility-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let remote = RemoteDockService(client: client)
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let outcomes: [DesktopActionOutcome] = [
            .confirmedChange(delivery: delivery, unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            .confirmedNoChange(),
            .dispatchedUnverified(
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            .suspectedNoop(
                delivery: delivery,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
        ]

        for outcome in outcomes {
            dock.visibilityOutcome = outcome
            let hidden = try await remote.hideDockResult()
            #expect(hidden.outcome == outcome.routed(to: .bridge))
            let shown = try await remote.showDockResult()
            #expect(shown.outcome == outcome.routed(to: .bridge))
        }

        try await remote.hideDock()
        try await remote.showDock()
        #expect(dock.visibilityActionCount == outcomes.count * 2 + 2)
        await host.stop()
    }

    @Test
    func `signed remote Dock context selection preserves composite two-unit delivery`() async throws {
        let dockTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 761,
            processStartIdentity: 7601))
        let dock = RemoteResultDockFixture(target: dockTarget)
        let services = try RemoteMenuDockResultServices(
            menu: RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 123,
                processStartIdentity: 456))),
            dock: dock)
        let socketPath = "/tmp/peekaboo-remote-dock-context-results-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-dock-context-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let result = try await RemoteDockService(client: client).rightClickDockItemResult(
            appName: "Safari",
            menuItem: "Options")

        Self.expect(result, outcome: dock.contextOutcome, target: dockTarget)
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.operation == .rightClickDockItem)
        #expect(receipt.payload.target == .process(dockTarget.processIdentity))
        #expect(receipt.payload.outcome?.deliveryMechanism == .composite)
        #expect(receipt.payload.outcome?.deliveryMode == .foreground)
        #expect(receipt.payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        await host.stop()
    }

    @Test
    func `signed remote Dock failure preserves the dispatched tile evidence`() async throws {
        let dockTarget = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 781,
            processStartIdentity: 7801))
        let dock = RemoteResultDockFixture(target: dockTarget)
        dock.failContextAfterRightClick = true
        let services = try RemoteMenuDockResultServices(
            menu: RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
                processIdentifier: 123,
                processStartIdentity: 456))),
            dock: dock)
        let socketPath = "/tmp/peekaboo-remote-dock-failure-results-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-dock-failure-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        do {
            _ = try await RemoteDockService(client: client).rightClickDockItemResult(
                appName: "Safari",
                menuItem: "Options")
            Issue.record("Expected the dispatched Dock failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.selectedLeafEvidence?.map(\.kind) == [.dockItem])
            #expect(failure.selectedLeafEvidence?.first?.selectedTitle == "Safari")
        }

        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.selectedLeafEvidence?.map(\.kind) == [.dockItem])
        await host.stop()
    }

    private static func expect(
        _ result: UIAutomationActionResult<some Sendable>,
        outcome: DesktopActionOutcome,
        target: DesktopTargetIdentity)
    {
        #expect(result.outcome == outcome.routed(to: .bridge))
        #expect(result.targetIdentity == target)
    }

    private static func expectReceiptlessTargetResultRefusal(
        _ operation: () async throws -> some Any) async
    {
        do {
            _ = try await operation()
            Issue.record("Expected receiptless exact-target result to refuse before dispatch")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected receiptless result error: \(error)")
        }
    }
}

@MainActor
private final class RemoteResultMenuFixture: MenuServiceGenerationPinnedActionResultProviding,
    MenuServiceExactLeafActionResultProviding
{
    let outcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one)
    private let target: DesktopTargetIdentity
    private(set) var actionCount = 0
    private(set) var pinnedDeliveryModes: [DesktopActionOutcome.Delivery.Mode] = []

    init(target: DesktopTargetIdentity) {
        self.target = target
    }

    func clickMenuItemActionResult(app _: String, itemPath _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        self.voidResult(outcome: self.applicationMenuOutcome())
    }

    func clickMenuItemByNameActionResult(app _: String, itemName _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        self.voidResult(outcome: self.applicationMenuOutcome())
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) async throws
        -> UIAutomationActionResult<Void>
    {
        self.pinnedDeliveryModes.append(request.deliveryMode)
        return self.voidResult(outcome: self.applicationMenuOutcome(mode: request.deliveryMode))
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) async throws
        -> UIAutomationActionResult<Void>
    {
        self.pinnedDeliveryModes.append(request.deliveryMode)
        return self.voidResult(outcome: self.applicationMenuOutcome(mode: request.deliveryMode))
    }

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try self.voidResult(selectedLeafEvidence: [self.menuLeaf(selector: title, matchKind: .exact)])
    }

    func clickMenuBarItemActionResult(named name: String) async throws -> UIAutomationActionResult<ClickResult> {
        self.actionCount += 1
        return try .init(
            payload: .init(elementDescription: name, location: nil),
            outcome: self.outcome,
            targetIdentity: self.target,
            selectedLeafEvidence: [self.menuLeaf(selector: name, matchKind: .exact)])
    }

    func clickMenuBarItemActionResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult> {
        self.actionCount += 1
        return try .init(
            payload: .init(elementDescription: "menu-index-\(index)", location: nil),
            outcome: self.outcome,
            targetIdentity: self.target,
            selectedLeafEvidence: [self.menuLeaf(selector: String(index), matchKind: .index, index: index)])
    }

    func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        if let name = request.name {
            return try await self.clickMenuBarItemActionResult(named: name)
        }
        return try await self.clickMenuBarItemActionResult(at: request.index ?? 3)
    }

    func applicationMenuOutcome(
        mode: DesktopActionOutcome.Delivery.Mode = .background) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: mode),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    private func voidResult(
        outcome: DesktopActionOutcome? = nil,
        selectedLeafEvidence: [DesktopSelectedLeafEvidence]? = nil) -> UIAutomationActionResult<Void>
    {
        self.actionCount += 1
        return .init(
            payload: (),
            outcome: outcome ?? self.outcome,
            targetIdentity: self.target,
            selectedLeafEvidence: selectedLeafEvidence)
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuItem(app: String, itemPath: String) async throws {
        _ = try await self.clickMenuItemActionResult(app: app, itemPath: itemPath)
    }

    func clickMenuItemByName(app: String, itemName: String) async throws {
        _ = try await self.clickMenuItemByNameActionResult(app: app, itemName: itemName)
    }

    func clickMenuExtra(title: String) async throws {
        _ = try await self.clickMenuExtraActionResult(title: title)
    }

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
        try [MenuBarItemInfo(
            title: "Clock",
            index: 3,
            frame: CGRect(x: 10, y: 10, width: 20, height: 20),
            selectionEvidence: self.menuLeaf(selector: "3", matchKind: .index, index: 3))]
    }

    func clickMenuBarItem(named name: String) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResult(named: name).payload
    }

    func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        try await self.clickMenuBarItemActionResult(at: index).payload
    }

    private func menuLeaf(
        selector: String,
        matchKind: DesktopSelectedLeafEvidence.MatchKind,
        index: Int = 3) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: DeterministicDesktopLeafSelector.normalized(selector),
            matchKind: matchKind,
            selectedProcessIdentity: self.target.processIdentity,
            selectedIndex: index,
            selectedTitle: "Clock",
            selectedIdentifier: "fixture.clock",
            selectedRole: "AXStatusItem",
            selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
    }
}

@MainActor
private final class RemoteResultDockFixture: DockServiceActionResultProviding {
    let launchOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: .one)
    let contextOutcome = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .composite, mode: .foreground),
        evidence: .deliveryAccepted,
        unitCount: DesktopActionOutcome.DispatchUnitCount(2))
    var visibilityOutcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: DesktopActionOutcome.DispatchUnitCount(2))
    private let target: DesktopTargetIdentity
    private(set) var itemActionCount = 0
    private(set) var visibilityActionCount = 0
    var failContextAfterRightClick = false

    init(target: DesktopTargetIdentity) {
        self.target = target
    }

    func launchFromDockActionResult(appName: String) async throws -> UIAutomationActionResult<Void> {
        self.itemActionCount += 1
        return try .init(
            payload: (),
            outcome: self.launchOutcome,
            targetIdentity: self.target,
            selectedLeafEvidence: [self.dockLeaf(kind: .dockItem, selector: appName)])
    }

    func rightClickDockItemActionResult(appName: String, menuItem: String?) async throws
        -> UIAutomationActionResult<Void>
    {
        self.itemActionCount += 1
        var leaves = try [self.dockLeaf(kind: .dockItem, selector: appName)]
        if self.failContextAfterRightClick {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one,
                message: "Dock right-click dispatched before context lookup failed")
                .attributed(to: leaves[0].selectedTargetReceipt)
                .selectingLeaves(leaves)
        }
        if let menuItem {
            try leaves.append(self.dockLeaf(kind: .dockContextMenuItem, selector: menuItem, index: 1))
        }
        return .init(
            payload: (),
            outcome: self.contextOutcome,
            targetIdentity: self.target,
            selectedLeafEvidence: leaves)
    }

    func hideDockActionResult() async throws -> DesktopActionResult<Void> {
        self.visibilityActionCount += 1
        return .init(outcome: self.visibilityOutcome)
    }

    func showDockActionResult() async throws -> DesktopActionResult<Void> {
        self.visibilityActionCount += 1
        return .init(outcome: self.visibilityOutcome)
    }

    func launchFromDock(appName: String) async throws {
        _ = try await self.launchFromDockActionResult(appName: appName)
    }

    func addToDock(path _: String, persistent _: Bool) async throws {}
    func removeFromDock(appName _: String) async throws {}

    func rightClickDockItem(appName: String, menuItem: String?) async throws {
        _ = try await self.rightClickDockItemActionResult(appName: appName, menuItem: menuItem)
    }

    func hideDock() async throws {
        _ = try await self.hideDockActionResult()
    }

    func showDock() async throws {
        _ = try await self.showDockActionResult()
    }

    func isDockAutoHidden() async -> Bool {
        false
    }

    func listDockItems(includeAll _: Bool) async throws -> [DockItem] {
        []
    }

    func findDockItem(name _: String) async throws -> DockItem {
        throw PeekabooError.notImplemented("unused")
    }

    private func dockLeaf(
        kind: DesktopSelectedLeafEvidence.Kind,
        selector: String,
        index: Int = 0) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: kind,
            normalizedSelector: DeterministicDesktopLeafSelector.normalized(selector),
            matchKind: .exact,
            selectedProcessIdentity: self.target.processIdentity,
            selectedIndex: index,
            selectedTitle: selector,
            selectedIdentifier: "fixture.\(kind.rawValue).\(index)",
            selectedRole: kind == .dockItem ? "AXDockItem" : "AXMenuItem",
            selectedFrame: CGRect(x: 10 + CGFloat(index * 30), y: 10, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "b", count: 64),
            candidateCount: 1)
    }
}

@MainActor
private final class RemoteMenuDockResultServices: PeekabooBridgeServiceProviding {
    private let base = StubServices()
    private let applicationService = RemoteMenuApplicationService()
    let menu: any MenuServiceProtocol
    let dock: any DockServiceProtocol

    init(menu: any MenuServiceProtocol, dock: any DockServiceProtocol) {
        self.menu = menu
        self.dock = dock
    }

    var permissions: PermissionsService {
        self.base.permissions
    }

    var screenCapture: any ScreenCaptureServiceProtocol {
        self.base.screenCapture
    }

    var automation: any UIAutomationServiceProtocol {
        self.base.automation
    }

    var windows: any WindowManagementServiceProtocol {
        self.base.windows
    }

    var applications: any ApplicationServiceProtocol {
        self.applicationService
    }

    var dialogs: any DialogServiceProtocol {
        self.base.dialogs
    }

    var snapshots: any SnapshotManagerProtocol {
        self.base.snapshots
    }

    var desktopObservation: any DesktopObservationServiceProtocol {
        self.base.desktopObservation
    }
}

@MainActor
private final class RemoteMenuApplicationService: StubApplicationService {
    override func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        let application = try await super.findApplication(identifier: identifier)
        guard let processIdentity = application.processIdentity,
              let matchKind = ApplicationIdentifierMatcher.matchKind(
                  for: .init(application),
                  identifier: identifier)
        else {
            return application
        }
        return application.withSelectorResolutionProofs([SelectorResolutionProof(
            scope: .application,
            normalizedSelector: ApplicationIdentifierMatcher.normalized(identifier),
            matchKind: matchKind,
            matchPrecedence: matchKind.precedence,
            selectedProcessIdentity: processIdentity,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1,
            winningCandidateCount: 1,
            hasWinningTie: false)])
    }
}
