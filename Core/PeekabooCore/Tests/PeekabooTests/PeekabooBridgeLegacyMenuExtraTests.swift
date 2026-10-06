import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
struct PeekabooBridgeLegacyMenuExtraTests {
    @Test(arguments: [false, true])
    func `direct legacy menu APIs retain AX delivery without a CG window`(rawNamed: Bool) async throws {
        for showMenu in [false, true] {
            let fixture = LegacyMenuNativeFixture()
            fixture.showMenu = showMenu
            if rawNamed {
                try await Self.check(fixture.service.clickMenuBarItemActionResult(named: "Clock"), fixture: fixture)
            } else {
                try await Self.check(fixture.service.clickMenuExtraActionResult(title: "Clock"), fixture: fixture)
            }
            #expect(fixture.reads == 2)
            #expect(fixture.submissions == [showMenu])
            #expect(fixture.cgReads == 0 && fixture.scopedReads == 0)
        }
    }

    @Test
    func `attested legacy extra needs Accessibility but not PostEvent`() async throws {
        let fixture = LegacyMenuNativeFixture()
        let services = RemoteMenuDockResultServices(
            menu: fixture.service,
            dock: StubServices().dock,
            ownedLaneOperations: PeekabooBridgeOperation.nativeDesktopOperationLaneOperations)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: [.clickMenuExtra],
            permissions: .init(screenRecording: false, accessibility: true, postEvent: false))
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.clickMenuExtra.rawValue] == [.accessibility])
        #expect(handshake.enabledOperations?.contains(.clickMenuExtra) == true)
        let result = try await RemoteMenuService(client: client).clickMenuExtraActionResult(title: "Clock")
        try Self.check(result, fixture: fixture)
        #expect(fixture.submissions == [false] && fixture.cgReads == 0 && fixture.scopedReads == 0)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.operation == .clickMenuExtra)
        #expect(bundle.receipt.payload.target == .process(fixture.owner))
        #expect(bundle.receipt.payload.outcome?.deliveryMechanism == .accessibilityAction)
        #expect(bundle.receipt.payload.selectedLeafEvidence == result.selectedLeafEvidence)
        await host.stop()
    }

    @Test(arguments: [false, true])
    func `legacy submission uncertainty never falls back to Press or CG input`(rawNamed: Bool) async throws {
        let fixture = LegacyMenuNativeFixture()
        fixture.showMenu = true
        fixture.failSubmission = true
        do {
            if rawNamed {
                _ = try await fixture.service.clickMenuBarItemActionResult(named: "Clock")
            } else {
                _ = try await fixture.service.clickMenuExtraActionResult(title: "Clock")
            }
            Issue.record("Expected indeterminate AX submission")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == fixture.owner.actionTargetReceipt)
        }
        #expect(fixture.submissions == [true])
        #expect(fixture.cgReads == 0 && fixture.scopedReads == 0)
    }

    @Test
    func `receiptless named Bridge API preserves its AX first route`() async throws {
        let fixture = LegacyMenuNativeFixture()
        let services = RemoteMenuDockResultServices(
            menu: fixture.service,
            dock: StubServices().dock,
            ownedLaneOperations: PeekabooBridgeOperation.nativeDesktopOperationLaneOperations)
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: version...version,
            allowedOperations: [.clickMenuBarItemNamed],
            permissions: .init(screenRecording: false, accessibility: true, postEvent: false))
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.identity)
        #expect(handshake.negotiatedVersion == version)
        #expect(handshake.enabledOperations?.contains(.clickMenuBarItemNamed) == true)
        let response = try await client.send(.clickMenuBarItemNamed(.init(name: "Clock")))
        guard case let .clickResult(result) = response else {
            Issue.record("Expected a legacy named click result")
            return
        }
        #expect(result.elementDescription.contains("Clock"))
        #expect(fixture.reads == 2 && fixture.submissions == [false])
        #expect(fixture.cgReads == 0 && fixture.scopedReads == 0)
        await host.stop()
    }

    @Test(arguments: ["element", "generation", "index", "frame"])
    func `legacy extra revalidates its native identity before submission`(replacement: String) async throws {
        let fixture = LegacyMenuNativeFixture()
        fixture.replacement = replacement
        await #expect(throws: PeekabooError.self) {
            try await fixture.service.clickMenuExtraActionResult(title: "Clock")
        }
        #expect(fixture.reads == 2 && fixture.submissions.isEmpty && fixture.cgReads == 0)
    }

    @Test
    func `ambiguous legacy named extras never enter CG fallback`() async throws {
        let fixture = LegacyMenuNativeFixture()
        fixture.duplicate = true
        do {
            _ = try await fixture.service.clickMenuBarItemActionResult(named: "Clock")
            Issue.record("Expected ambiguous legacy item refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .invalidRequest)
        }
        #expect(fixture.submissions.isEmpty && fixture.cgReads == 0 && fixture.scopedReads == 0)
    }

    private static let identity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.legacy-menu-extra-tests", teamIdentifier: nil, processIdentifier: getpid())

    private static func check(
        _ result: UIAutomationActionResult<some Sendable>, fixture: LegacyMenuNativeFixture) throws
    {
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount == .one)
        #expect(try result.targetIdentity == DesktopTargetIdentity(processIdentity: fixture.owner))
        let leaf = try #require(result.selectedLeafEvidence?.first)
        #expect(leaf.selectedProcessIdentity == fixture.owner)
        #expect(leaf.selectedTargetReceipt.windowID == nil)
        #expect(leaf.selectedIndex == 4)
    }
}

@MainActor
private final class LegacyMenuNativeFixture {
    let owner = ApplicationProcessIdentity(processIdentifier: 953_201, processStartIdentity: 99)
    let frame = CGRect(x: 100, y: 10, width: 25, height: 25)
    var reads = 0
    var cgReads = 0
    var scopedReads = 0
    var submissions: [Bool] = []
    var showMenu = false
    var failSubmission = false
    var duplicate = false
    var replacement: String?

    lazy var service: MenuService = {
        var readers = MenuExtraDiscoveryReaders()
        readers.windowExtras = {
            self.cgReads += 1
            return [MenuExtraInfo(
                title: "Clock",
                position: CGPoint(x: 112, y: 22),
                windowID: nil,
                ownerPID: self.owner.processIdentifier,
                source: "fixture")]
        }
        readers.snapshots = { _, _ in self.scopedReads += 1; return [] }
        readers.processGeneration = { _ in self.owner.processStartIdentity }
        readers.displayBounds = { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        var native = LegacyMenuExtraNativeAccess()
        native.inventory = { _ in
            self.reads += 1
            let changed = self.reads > 1
            var snapshots = [self.snapshot(changed: changed)]
            if self.duplicate {
                snapshots.append(self.snapshot(changed: false, duplicate: true))
            }
            return LegacyAXMenuExtraInventory(
                snapshots: snapshots,
                extraCount: 7,
                allPositions: [CGPoint(x: self.frame.minX, y: self.frame.minY)])
        }
        native.supportsAction = { _, action in action == "AXPress" || self.showMenu && action == "AXShowMenu" }
        native.submit = { _, showMenu in
            self.submissions.append(showMenu)
            if self.failSubmission {
                throw PeekabooError.accessibilityIncomplete("Synthetic AX uncertainty")
            }
        }
        return MenuService(
            operationLaneCoordinator: .init(), menuExtraReaders: readers, legacyMenuExtraAccess: native)
    }()

    private func snapshot(changed: Bool, duplicate: Bool = false) -> LegacyAXMenuExtraSnapshot {
        let replaced = changed ? self.replacement : nil
        return LegacyAXMenuExtraSnapshot(
            element: Element(AXUIElementCreateApplication(
                replaced == "element" || duplicate ? 953_202 : self.owner.processIdentifier)),
            index: replaced == "index" || duplicate ? 5 : 4,
            title: "Clock",
            matchFields: ["Clock"],
            identifier: duplicate ? "other.clock" : "fixture.clock",
            role: "AXMenuBarItem",
            subrole: "AXMenuExtra",
            frame: replaced == "frame" ? self.frame.offsetBy(dx: 1, dy: 0) : self.frame,
            processIdentity: replaced == "generation"
                ? .init(processIdentifier: self.owner.processIdentifier, processStartIdentity: 100) : self.owner)
    }
}
