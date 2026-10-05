import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PeekabooBridgeNamedMenuPreparationTests {
    @Test(arguments: [false, true])
    func `named clicks preserve prepared AX ownership across signed success and indeterminate failure`(
        failsAfterDispatch: Bool) async throws
    {
        let owner = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 456)
        let target = try DesktopTargetIdentity(processIdentity: owner)
        let menu = RemoteResultMenuFixture(target: target)
        menu.listedMenuBarItems = [MenuBarItemInfo(
            title: "Clock",
            index: 3,
            ownerName: "Control Center",
            frame: CGRect(x: 10, y: 10, width: 20, height: 20),
            rawWindowID: 700,
            rawOwnerPID: 999,
            rawSource: "cgwindow")]
        menu.failMenuBarAfterDispatch = failsAfterDispatch
        let services = RemoteMenuDockResultServices(menu: menu, dock: StubServices().dock)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: [.listMenuBarItems, .prepareMenuBarItemNamed, .clickMenuBarItemNamed])
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.supportsNamedMenuBarPreparation)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.prepareMenuBarItemNamed.rawValue] == [.accessibility])
        let remote = RemoteMenuService(client: client)

        let listed = try await remote.listMenuBarItems(includeRaw: true)
        #expect(listed.first?.rawOwnerPID == 999)
        let prepared = try await remote.prepareMenuBarItem(named: "clock")
        let evidence = try #require(prepared.selectionEvidence)
        #expect(evidence.selectedProcessIdentity == owner)
        #expect(evidence.selectedTargetReceipt.windowID == nil)
        #expect(evidence.matchKind == .normalizedExact)
        let preparationBundle = try #require(await client.lastOperationReceiptBundle())
        try preparationBundle.validateIntegrity()
        #expect(preparationBundle.receipt.payload.operation == .prepareMenuBarItemNamed)
        #expect(preparationBundle.receipt.payload.outcome == nil)
        #expect(!PeekabooBridgeRequest.prepareMenuBarItemNamed("clock").mayMutateDesktop)

        do {
            let result = try await remote.clickMenuBarItemResult(named: "clock")
            #expect(!failsAfterDispatch)
            #expect(result.targetIdentity == target)
            #expect(result.selectedLeafEvidence == [evidence])
        } catch let failure as DesktopActionFailure {
            #expect(failsAfterDispatch)
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety != .safe)
            #expect(failure.targetReceipt == evidence.selectedTargetReceipt)
            #expect(failure.selectedLeafEvidence == [evidence])
        }
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.operation == .clickMenuBarItemNamed)
        #expect(bundle.receipt.payload.target == .process(owner))
        #expect(bundle.receipt.payload.selectedLeafEvidence == [evidence])
        #expect(bundle.receipt.payload.outcome?.deliveryMechanism == .accessibilityAction)
        #expect(bundle.receipt.payload.outcome?.deliveryMode == .foreground)
        #expect(menu.lastMenuBarRequest?.expectedLeafEvidence == evidence)
        #expect(menu.preparedNames == ["clock", "clock"])
        #expect(menu.menuBarListCount == 1)
        #expect(menu.actionCount == 1)
        await host.stop()
    }

    @Test
    func `same version client without raw offer never receives the new operation`() async throws {
        let menu = try RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 123,
            processStartIdentity: 456)))
        let services = RemoteMenuDockResultServices(menu: menu, dock: StubServices().dock)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: [.listMenuBarItems, .prepareMenuBarItemNamed, .clickMenuBarItemNamed])
        defer { Task { await host.stop() } }
        let response = try await client.send(.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: Self.clientIdentity,
            operationClientInstanceID: UUID(),
            clientCapabilities: [])))
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected handshake response")
            return
        }
        #expect(!handshake.supportedOperations.contains(.prepareMenuBarItemNamed))
        #expect(handshake.enabledOperations?.contains(.prepareMenuBarItemNamed) != true)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.namedMenuBarPreparation) != true)
        #expect(handshake.supportedOperations.contains(.listMenuBarItems))
        #expect(handshake.supportedOperations.contains(.clickMenuBarItemNamed))
        #expect(menu.preparedNames.isEmpty)
        await host.stop()
    }

    @Test(arguments: [false, true])
    func `missing preparation provider or operation refuses before read and mutation`(
        hasProvider: Bool) async throws
    {
        let menu = try RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 123,
            processStartIdentity: 456)))
        let base = StubServices()
        let services = RemoteMenuDockResultServices(menu: hasProvider ? menu : base.menu, dock: base.dock)
        var operations: Set<PeekabooBridgeOperation> = [.listMenuBarItems, .clickMenuBarItemNamed]
        if !hasProvider {
            operations.insert(.prepareMenuBarItemNamed)
        }
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: operations)
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(!handshake.supportsNamedMenuBarPreparation)
        #expect(!handshake.supportedOperations.contains(.prepareMenuBarItemNamed))
        do {
            _ = try await RemoteMenuService(client: client).clickMenuBarItemResult(named: "Clock")
            Issue.record("Expected unsupported preparation to refuse before mutation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(menu.preparedNames.isEmpty)
        #expect(menu.menuBarListCount == 0)
        #expect(menu.actionCount == 0)
        await host.stop()
    }

    @Test
    func `preparation negotiation requires current version capability and enabled operation`() {
        let operation = PeekabooBridgeOperation.prepareMenuBarItemNamed
        let current = PeekabooBridgeConstants.namedMenuBarPreparationVersion
        let previous = PeekabooBridgeProtocolVersion(major: current.major, minor: current.minor - 1)
        let capabilities = [
            PeekabooBridgeHostCapability.namedMenuBarPreparation,
            PeekabooBridgeHostCapability.attestedOperationReceipts,
        ]
        func handshake(
            version: PeekabooBridgeProtocolVersion? = nil,
            supported: [PeekabooBridgeOperation]? = nil,
            enabled: [PeekabooBridgeOperation]? = nil,
            advertised: [String]? = nil) -> PeekabooBridgeHandshakeResponse
        {
            .init(
                negotiatedVersion: version ?? current,
                hostKind: .gui,
                build: nil,
                supportedOperations: supported ?? [operation],
                enabledOperations: enabled,
                hostCapabilities: advertised ?? capabilities)
        }
        #expect(handshake().supportsNamedMenuBarPreparation)
        #expect(!handshake(version: previous).supportsNamedMenuBarPreparation)
        #expect(!handshake(supported: []).supportsNamedMenuBarPreparation)
        #expect(!handshake(enabled: []).supportsNamedMenuBarPreparation)
        for capability in capabilities {
            #expect(!handshake(advertised: [capability]).supportsNamedMenuBarPreparation)
        }
        #expect(!PeekabooBridgeOperation.compatible([operation], with: previous).contains(operation))
        #expect(PeekabooBridgeClient.offeredCapabilities(for: current).contains(
            PeekabooBridgeClientCapability.namedMenuBarPreparation))
        #expect(!PeekabooBridgeClient.offeredCapabilities(for: previous).contains(
            PeekabooBridgeClientCapability.namedMenuBarPreparation))
    }

    @Test
    func `preparation rejects absent ambiguous or selector-incompatible evidence`() throws {
        let valid = try Self.item(evidence: self.leaf())
        let invalidInventories: [[MenuBarItemInfo]] = try [
            [],
            [valid, valid],
            [Self.item(evidence: nil)],
            [Self.item(evidence: self.leaf(selector: "another item"))],
            [Self.item(evidence: self.leaf(matchKind: .index))],
            [Self.item(evidence: self.leaf(kind: .dockItem))],
            [Self.item(evidence: self.leaf(winningCandidateCount: 2))],
            [Self.item(evidence: self.leaf(), index: 4)],
        ]
        let accepted = try PeekabooBridgeClient.validatedNamedMenuBarPreparation([valid], named: "Clock")
        #expect(accepted.selectionEvidence == valid.selectionEvidence)
        for items in invalidInventories {
            do {
                _ = try PeekabooBridgeClient.validatedNamedMenuBarPreparation(items, named: "Clock")
                Issue.record("Expected invalid preparation to refuse")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.refusalReason == .invalidRequest)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
            }
        }
    }

    @Test(arguments: [false, true])
    func `signed named receipt rejects replacement owner or borrowed window`(borrowsWindow: Bool) async throws {
        let root = URL(
            fileURLWithPath: "/tmp/pbor-named-menu-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let expectedLeaf = try self.leaf()
        let owner = borrowsWindow ? expectedLeaf.selectedProcessIdentity :
            ApplicationProcessIdentity(processIdentifier: 999, processStartIdentity: 888)
        let window: WindowMutationIdentity? = borrowsWindow ? WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: owner.processIdentifier,
            ownerProcessStartIdentity: owner.processStartIdentity,
            capturedBounds: expectedLeaf.selectedFrame) : nil
        let actualLeaf = try self.leaf(processIdentity: owner, window: window)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .clickMenuBarItemNamed(.init(
            name: "Clock",
            expectedLeafEvidence: expectedLeaf))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .clickResult(.init(elementDescription: "Clock", location: nil)),
            outcome: outcome.projection))
        let receiptTarget: PeekabooBridgeOperationTargetReceipt = if let window {
            .window(window)
        } else {
            .process(owner)
        }
        let bundle = try await session.signedBundle(
            authority: authority,
            sequence: 0,
            request: request,
            response: response,
            target: receiptTarget,
            selectedLeafEvidence: [actualLeaf],
            outcome: outcome.projection)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try bundle.validateIntegrity()
        }
    }

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        .init(
            bundleIdentifier: "dev.peekaboo.named-menu-preparation-tests",
            teamIdentifier: nil,
            processIdentifier: getpid())
    }

    private static func item(evidence: DesktopSelectedLeafEvidence?, index: Int = 3) -> MenuBarItemInfo {
        MenuBarItemInfo(title: "Clock", index: index, selectionEvidence: evidence)
    }

    private func leaf(
        selector: String = "Clock",
        matchKind: DesktopSelectedLeafEvidence.MatchKind = .exact,
        kind: DesktopSelectedLeafEvidence.Kind = .menuBarItem,
        winningCandidateCount: Int = 1,
        processIdentity: ApplicationProcessIdentity = .init(processIdentifier: 123, processStartIdentity: 456),
        window: WindowMutationIdentity? = nil) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: kind,
            normalizedSelector: DeterministicDesktopLeafSelector.normalized(selector),
            matchKind: matchKind,
            selectedProcessIdentity: processIdentity,
            selectedWindowIdentity: window,
            selectedIndex: 3,
            selectedTitle: "Clock",
            selectedIdentifier: "fixture.clock",
            selectedRole: "AXStatusItem",
            selectedFrame: CGRect(x: 10, y: 10, width: 20, height: 20),
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 2,
            winningCandidateCount: winningCandidateCount,
            hasWinningTie: winningCandidateCount > 1)
    }
}
