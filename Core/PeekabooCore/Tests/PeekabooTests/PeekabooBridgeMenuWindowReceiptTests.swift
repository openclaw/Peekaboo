import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeMenuWindowReceiptTests {
    @Test
    func `indexed menu receipt signs the exact routed window among one process windows`() async throws {
        let first = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: CGRect(x: 10, y: 10, width: 30, height: 20))
        let second = WindowMutationIdentity(
            windowID: 701,
            ownerProcessIdentifier: 4242,
            ownerProcessStartIdentity: 99,
            capturedBounds: CGRect(x: 50, y: 10, width: 30, height: 20))
        let menu = try await MainActor.run { try MenuWindowReceiptService(windows: [first, second]) }
        let services = await MainActor.run { MenuWindowReceiptServices(menu: menu) }
        let socketPath = "/tmp/peekaboo-menu-window-receipt-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                allowedOperations: [.listMenuBarItems, .clickMenuBarItemIndex],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid()))
        _ = try await client.clickMenuBarItem(at: 1)

        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.operation == .clickMenuBarItemIndex)
        #expect(bundle.receipt.payload.target == .window(second))
        #expect(bundle.receipt.payload.target != .window(first))
        #expect(await MainActor.run { menu.clickedIndices } == [1])
    }
}

@MainActor
private final class MenuWindowReceiptService: MenuServiceExactLeafActionResultProviding {
    private let windows: [WindowMutationIdentity]
    private(set) var clickedIndices: [Int] = []

    init(windows: [WindowMutationIdentity]) throws {
        guard windows.count >= 2 else { throw PeekabooError.invalidInput("Two menu windows are required") }
        self.windows = windows
    }

    func clickMenuBarItemActionResult(at index: Int) throws -> UIAutomationActionResult<ClickResult> {
        guard self.windows.indices.contains(index),
              let bounds = self.windows[index].capturedBounds
        else { throw PeekabooError.invalidInput("Invalid menu index") }
        self.clickedIndices.append(index)
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: self.windows[index], bounds: bounds)
        return try UIAutomationActionResult(
            payload: .init(elementDescription: "Menu item \(index)", location: nil),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow),
            selectedLeafEvidence: [self.leaf(index: index)])
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        throw PeekabooError.notImplemented("unused")
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
        try self.windows.indices.map { index in
            try MenuBarItemInfo(
                title: "Menu item \(index)",
                index: index,
                frame: self.windows[index].capturedBounds,
                selectionEvidence: self.leaf(index: index))
        }
    }

    func clickMenuBarItem(named _: String) async throws -> ClickResult {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        try self.clickMenuBarItemActionResult(at: index).payload
    }

    func clickMenuItemActionResult(app _: String, itemPath _: String) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuItemByNameActionResult(app _: String, itemName _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuExtraActionResult(title _: String) async throws -> UIAutomationActionResult<Void> {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuBarItemActionResult(named _: String) async throws -> UIAutomationActionResult<ClickResult> {
        throw PeekabooError.notImplemented("unused")
    }

    func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        try self.clickMenuBarItemActionResult(at: request.index ?? 0)
    }

    private func leaf(index: Int) throws -> DesktopSelectedLeafEvidence {
        let window = self.windows[index]
        return try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: String(index),
            matchKind: .index,
            selectedProcessIdentity: window.processIdentity,
            selectedWindowIdentity: window,
            selectedIndex: index,
            selectedTitle: "Menu item \(index)",
            selectedIdentifier: "fixture.menu.\(index)",
            selectedRole: "AXStatusItem",
            selectedFrame: #require(window.capturedBounds),
            candidateSetSHA256: String(repeating: "c", count: 64),
            candidateCount: self.windows.count)
    }
}

@MainActor
private final class MenuWindowReceiptServices: PeekabooBridgeServiceProviding {
    private let base = PeekabooServices()
    let menu: any MenuServiceProtocol

    init(menu: any MenuServiceProtocol) {
        self.menu = menu
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
        self.base.applications
    }

    var dock: any DockServiceProtocol {
        self.base.dock
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
