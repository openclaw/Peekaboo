import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
struct PeekabooBridgeConcreteMenuBarLaneTests {
    @Test
    func `non-owning preparation providers retain the Bridge fallback lane`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-menu-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let probe = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let owner = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let menu = try RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: owner))
        var protected = false
        menu.beforeMenuBarPreparation = {
            do {
                _ = try await probe.run(scope: .global, access: .read) {
                    Issue.record("Non-owning provider entered preparation without the Bridge fallback lane")
                }
            } catch DesktopOperationLaneError.nestedAcquisition {
                protected = true
            }
        }
        let services = RemoteMenuDockResultServices(menu: menu, dock: StubServices().dock)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: [.prepareMenuBarItem, .clickMenuBarItemNamed],
            operationLaneCoordinator: coordinator)
        defer { Task { await host.stop() } }
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.menu-fallback-tests", teamIdentifier: nil, processIdentifier: getpid()))
        _ = try await RemoteMenuService(client: client).prepareMenuBarItem(.init(
            name: "Clock", applicationScope: .init(processIdentifier: owner.processIdentifier)))
        #expect(protected)
        #expect(menu.preparationRequests.count == 1 && menu.actionCount == 0)
        await host.stop()
    }

    @Test(arguments: [false, true])
    func `concrete scoped menu service owns preparation and dispatch lanes exactly once`(usePID: Bool) async throws {
        let policy = PeekabooBridgeOperationResultSemantics.operationPolicy(for: .prepareMenuBarItem)
        #expect(policy.lane.nativeOwnership == .service)
        #expect(policy.lane.readPolicy == .globalExclusive)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-menu-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let serviceLane = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let bridgeLane = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let probeLane = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let owner = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let target = try DesktopTargetIdentity(processIdentity: owner)
        let frame = CGRect(x: 10, y: 10, width: 25, height: 25)
        var scopes: [MenuBarApplicationScope] = []
        var reads = 0
        var inventoryReads = 0
        var submissions = 0
        var probes = 0
        var readers = MenuExtraDiscoveryReaders()
        readers.resolveOwner = { scope, _, _ in
            scopes.append(scope)
            return ServiceApplicationInfo(
                processIdentifier: owner.processIdentifier,
                processStartIdentity: owner.processStartIdentity,
                bundleIdentifier: "dev.fixture.menu",
                name: "Menu Fixture")
        }
        let leaf = MenuExtraAXIdentity(element: AXUIElementCreateApplication(953_101))
        readers.snapshots = { requestedOwner, _ in
            #expect(requestedOwner == owner)
            reads += 1
            do {
                _ = try await probeLane.run(scope: .global, access: .read) {
                    Issue.record("Preparation or dispatch entered its leaf without retaining lane ownership")
                }
                Issue.record("Same-domain probe unexpectedly acquired a nested lane")
            } catch DesktopOperationLaneError.nestedAcquisition {
                probes += 1
            }
            return [MenuExtraAXSnapshot(
                identity: leaf,
                processIdentity: owner,
                title: "Clock",
                help: nil,
                description: nil,
                identifier: "dev.fixture.clock",
                role: "AXMenuBarItem",
                subrole: "AXMenuExtra",
                frame: frame,
                actions: ["AXPress"])]
        }
        readers.windowExtras = { inventoryReads += 1; return [] }
        readers.processGeneration = { _ in owner.processStartIdentity }
        readers.displayBounds = { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        readers.submit = { _, _ in submissions += 1 }
        let menu = MenuService(operationLaneCoordinator: serviceLane, menuExtraReaders: readers)
        let services = RemoteMenuDockResultServices(
            menu: menu,
            dock: StubServices().dock,
            ownedLaneOperations: PeekabooBridgeOperation.nativeDesktopOperationLaneOperations)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: [.prepareMenuBarItem, .clickMenuBarItemNamed],
            operationLaneCoordinator: bridgeLane)
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.concrete-menu-lane-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        #expect(handshake.supportsScopedMenuBarActions)
        let remote = RemoteMenuService(client: client)
        let scope: MenuBarApplicationScope = try usePID
            ? .init(processIdentifier: owner.processIdentifier)
            : .init(applicationIdentifier: "dev.fixture.menu")
        let request = try MenuBarItemPreparationRequest(name: "Clock", applicationScope: scope)
        let prepared = try await remote.prepareMenuBarItem(request)
        let evidence = try #require(prepared.selectionEvidence)
        #expect(evidence.selectedProcessIdentity == owner)
        #expect(evidence.selectedTargetReceipt.windowID == nil)
        #expect(reads == 1 && probes == 1 && submissions == 0 && inventoryReads == 0)
        let preparation = try #require(await client.lastOperationReceiptBundle())
        try preparation.validateIntegrity()
        #expect(preparation.receipt.payload.operation == .prepareMenuBarItem)
        #expect(preparation.receipt.payload.outcome == nil)

        let result = try await remote.clickMenuBarItemActionResult(request: .init(
            named: request.name, expectedLeafEvidence: evidence, applicationScope: scope))

        #expect(scopes == Array(repeating: scope, count: 3))
        #expect(reads == 3 && probes == 3 && submissions == 1 && inventoryReads == 0)
        #expect(result.selectedLeafEvidence == [evidence])
        #expect(result.targetIdentity == target)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        let action = try #require(await client.lastOperationReceiptBundle())
        try action.validateIntegrity()
        #expect(action.receipt.payload.selectedLeafEvidence == [evidence])
        await host.stop()
    }
}
