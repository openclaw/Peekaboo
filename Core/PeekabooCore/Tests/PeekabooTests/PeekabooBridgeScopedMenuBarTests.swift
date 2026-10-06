import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PeekabooBridgeScopedMenuBarTests {
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
            allowedOperations: [.listMenuBarItems, .prepareMenuBarItem, .clickMenuBarItemNamed])
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.supportsScopedMenuBarActions)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.prepareMenuBarItem.rawValue] == [.accessibility])
        let remote = RemoteMenuService(client: client)

        let listed = try await remote.listMenuBarItems(includeRaw: true)
        #expect(listed.first?.rawOwnerPID == 999)
        let scope = try MenuBarApplicationScope(applicationIdentifier: "com.Fixture.Owner")
        let preparation = try MenuBarItemPreparationRequest(name: "clock", applicationScope: scope)
        let prepared = try await remote.prepareMenuBarItem(preparation)
        let evidence = try #require(prepared.selectionEvidence)
        #expect(evidence.selectedProcessIdentity == owner)
        #expect(evidence.selectedTargetReceipt.windowID == nil)
        #expect(evidence.matchKind == .normalizedExact)
        let preparationBundle = try #require(await client.lastOperationReceiptBundle())
        try preparationBundle.validateIntegrity()
        #expect(preparationBundle.receipt.payload.operation == .prepareMenuBarItem)
        #expect(preparationBundle.receipt.payload.outcome == nil)
        #expect(!PeekabooBridgeRequest.prepareMenuBarItem(preparation).mayMutateDesktop)

        do {
            let result = try await remote.clickMenuBarItemActionResult(request: .init(
                named: preparation.name,
                expectedLeafEvidence: evidence,
                applicationScope: scope))
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
        #expect(menu.preparationRequests == [preparation])
        #expect(menu.lastMenuBarRequest?.applicationScope == scope)
        #expect(menu.lastMenuBarRequest?.applicationScope?.applicationIdentifier == "com.Fixture.Owner")
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
            allowedOperations: [.listMenuBarItems, .prepareMenuBarItem, .clickMenuBarItemNamed])
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
        #expect(!handshake.supportedOperations.contains(.prepareMenuBarItem))
        #expect(handshake.enabledOperations?.contains(.prepareMenuBarItem) != true)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.scopedMenuBarActions) != true)
        #expect(handshake.supportedOperations.contains(.listMenuBarItems))
        #expect(handshake.supportedOperations.contains(.clickMenuBarItemNamed))
        #expect(menu.preparationRequests.isEmpty)
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
            operations.insert(.prepareMenuBarItem)
        }
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.supportedProtocolRange,
            allowedOperations: operations)
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(!handshake.supportsScopedMenuBarActions)
        #expect(!handshake.supportedOperations.contains(.prepareMenuBarItem))
        let preparation = try MenuBarItemPreparationRequest(
            name: "Clock", applicationScope: MenuBarApplicationScope(processIdentifier: 123))
        do {
            _ = try await RemoteMenuService(client: client).prepareMenuBarItem(preparation)
            Issue.record("Expected unsupported preparation to refuse before mutation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(menu.preparationRequests.isEmpty)
        #expect(menu.menuBarListCount == 0)
        #expect(menu.actionCount == 0)
        await host.stop()
    }

    @Test
    func `old host refuses direct scoped requests but preserves unscoped CG named and index calls`() async throws {
        let window = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: CGRect(x: 10, y: 10, width: 20, height: 20))
        let target = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: window, bounds: #require(window.capturedBounds)))
        let menu = RemoteResultMenuFixture(target: target)
        let services = RemoteMenuDockResultServices(menu: menu, dock: StubServices().dock)
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 42)
        let (host, client) = try await BridgeInputCapabilityFixture.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...previous,
            allowedOperations: [.prepareMenuBarItem, .listMenuBarItems, .clickMenuBarItemNamed, .clickMenuBarItemIndex])
        defer { Task { await host.stop() } }
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == previous)
        #expect(!handshake.supportsScopedMenuBarActions)
        let scope = try MenuBarApplicationScope(processIdentifier: 123)
        let preparation = try MenuBarItemPreparationRequest(name: "Clock", applicationScope: scope)
        let requests: [PeekabooBridgeRequest] = try [
            .prepareMenuBarItem(preparation),
            .clickMenuBarItemNamed(.init(
                name: "Clock", expectedLeafEvidence: self.leaf(), applicationScope: scope)),
        ]
        for request in requests {
            do {
                _ = try await client.send(request)
                Issue.record("Expected scoped request refusal before transport")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.refusalReason == .runtimeIncompatible)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
            }
        }
        #expect(menu.menuBarListCount == 0)
        #expect(menu.actionCount == 0)
        let remote = RemoteMenuService(client: client)
        let named = try await remote.clickMenuBarItemResult(named: "Clock")
        #expect(named.targetIdentity == target)
        #expect(named.selectedLeafEvidence?.first?.selectedTargetReceipt.windowID == 700)
        #expect(menu.lastMenuBarRequest?.applicationScope == nil)
        let indexed = try await remote.clickMenuBarItemResult(at: 3)
        #expect(indexed.targetIdentity == target)
        #expect(indexed.selectedLeafEvidence?.first?.selectedTargetReceipt.windowID == 700)
        #expect(menu.preparationRequests.isEmpty)
        #expect(menu.menuBarListCount == 2)
        #expect(menu.actionCount == 2)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validateIntegrity()
        await host.stop()
    }

    @Test
    func `server refuses scoped reads and mutations from a session without the negotiated capability`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-unscoped-session-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            negotiatedCapabilities: .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                scopedMenuBarActions: false))
        let menu = try RemoteResultMenuFixture(target: DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 123, processStartIdentity: 456)))
        let server = PeekabooBridgeServer(
            services: RemoteMenuDockResultServices(menu: menu, dock: StubServices().dock),
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let scope = try MenuBarApplicationScope(processIdentifier: 123)
        let requests: [PeekabooBridgeRequest] = try [
            .prepareMenuBarItem(.init(name: "Clock", applicationScope: scope)),
            .projectedAction(.init(request: .clickMenuBarItemNamed(.init(
                name: "Clock", expectedLeafEvidence: self.leaf(), applicationScope: scope)))),
        ]
        for (index, request) in requests.enumerated() {
            let payload = session.request(authority: authority, sequence: UInt64(index), request: request)
            let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
                try await server.handleAttestedOperation(payload, peer: session.peer)
            }
            guard case let .attestedOperation(response) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self, from: data)
            else {
                Issue.record("Expected signed scoped-operation refusal")
                return
            }
            let bundle = try OperationReceiptSessionFixture.bundle(
                authority: authority,
                sessionAttestation: session.attestation,
                receipt: response.receipt,
                request: request,
                response: response.response)
            try bundle.validateIntegrity()
            #expect(response.receipt.payload.outcome?.refusalReason == .runtimeIncompatible)
            #expect(response.receipt.payload.outcome?.mutationDispatched == false)
            #expect(response.receipt.payload.outcome?.retrySafe == true)
        }
        #expect(menu.preparationRequests.isEmpty)
        #expect(menu.actionCount == 0)
    }

    @Test
    func `scope fields round trip unchanged while unscoped payload omits scope`() throws {
        let scopes = try [
            MenuBarApplicationScope(applicationIdentifier: "com.Fixture.Owner"),
            MenuBarApplicationScope(applicationIdentifier: "PID:123"),
            MenuBarApplicationScope(processIdentifier: 123),
        ]
        for scope in scopes {
            let preparation = try MenuBarItemPreparationRequest(name: "  Clock  ", applicationScope: scope)
            let wire = PeekabooBridgeRequest.prepareMenuBarItem(preparation)
            let data = try JSONEncoder.peekabooBridgeEncoder().encode(wire)
            guard case let .prepareMenuBarItem(decoded) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self, from: data)
            else {
                Issue.record("Expected scoped preparation round trip")
                return
            }
            #expect(decoded == preparation)
            let click = try PeekabooBridgeMenuBarClickByNameRequest(
                name: preparation.name, expectedLeafEvidence: self.leaf(), applicationScope: scope)
            let decodedClick = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeMenuBarClickByNameRequest.self,
                from: JSONEncoder.peekabooBridgeEncoder().encode(click))
            #expect(decodedClick.applicationScope == scope)
            #expect(decodedClick.name == preparation.name)
            #expect(decodedClick.expectedLeafEvidence == click.expectedLeafEvidence)
        }
        let data = try JSONEncoder.peekabooBridgeEncoder()
            .encode(PeekabooBridgeMenuBarClickByNameRequest(name: "Clock"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["applicationScope"] == nil)
    }

    @Test
    func `preparation negotiation requires current version capability and enabled operation`() {
        let operation = PeekabooBridgeOperation.prepareMenuBarItem
        let current = PeekabooBridgeConstants.scopedMenuBarActionsVersion
        let previous = PeekabooBridgeProtocolVersion(major: current.major, minor: current.minor - 1)
        let capabilities = [
            PeekabooBridgeHostCapability.scopedMenuBarActions,
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
                supportedOperations: supported ?? [operation, .clickMenuBarItemNamed],
                enabledOperations: enabled,
                hostCapabilities: advertised ?? capabilities)
        }
        #expect(handshake().supportsScopedMenuBarActions)
        #expect(!handshake(version: previous).supportsScopedMenuBarActions)
        #expect(!handshake(supported: [operation]).supportsScopedMenuBarActions)
        #expect(!handshake(supported: [.clickMenuBarItemNamed]).supportsScopedMenuBarActions)
        #expect(!handshake(enabled: [operation]).supportsScopedMenuBarActions)
        #expect(!handshake(enabled: [.clickMenuBarItemNamed]).supportsScopedMenuBarActions)
        for capability in capabilities {
            #expect(!handshake(advertised: [capability]).supportsScopedMenuBarActions)
        }
        #expect(!PeekabooBridgeOperation.compatible([operation], with: previous).contains(operation))
        #expect(PeekabooBridgeClient.offeredCapabilities(for: current).contains(
            PeekabooBridgeClientCapability.scopedMenuBarActions))
        #expect(!PeekabooBridgeClient.offeredCapabilities(for: previous).contains(
            PeekabooBridgeClientCapability.scopedMenuBarActions))
    }

    @Test
    func `preparation rejects absent ambiguous or selector-incompatible evidence`() throws {
        let request = try MenuBarItemPreparationRequest(
            name: "Clock", applicationScope: MenuBarApplicationScope(processIdentifier: 123))
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
            [Self.item(evidence: self.leaf(processIdentity: .init(processIdentifier: 999, processStartIdentity: 888)))],
            [Self.item(evidence: self.leaf(window: .init(
                windowID: 700, ownerProcessIdentifier: 123, ownerProcessStartIdentity: 456)))],
        ]
        let accepted = try PeekabooBridgeClient.validatedMenuBarPreparation([valid], request: request)
        #expect(accepted.selectionEvidence == valid.selectionEvidence)
        for items in invalidInventories {
            do {
                _ = try PeekabooBridgeClient.validatedMenuBarPreparation(items, request: request)
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
        let request = try PeekabooBridgeRequest.projectedAction(.init(request: .clickMenuBarItemNamed(.init(
            name: "Clock",
            expectedLeafEvidence: expectedLeaf,
            applicationScope: MenuBarApplicationScope(processIdentifier: 123)))))
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
