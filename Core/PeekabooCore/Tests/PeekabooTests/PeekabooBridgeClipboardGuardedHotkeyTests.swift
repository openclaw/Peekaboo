import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PeekabooBridgeClipboardGuardedHotkeyTests {
    private static let featureVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 40)
    private static let previousVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 39)
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.clipboard-guard-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    func `guarded results reject invented effects routes and counts without changing legacy semantics`() throws {
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        let guarded = self.request(target: target, claim: claim)
        let legacy = self.request(target: target, claim: nil)
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        typealias Semantics = PeekabooBridgeOperationResultSemantics
        for units in [1, 2, 3, 4, 5, 99] {
            let outcome = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            #expect(Semantics
                .successfulOutcomeMatchesContract(outcome, response: .ok, request: guarded) ==
                (units == 4))
            #expect(Semantics.successfulOutcomeMatchesContract(
                outcome,
                response: .ok,
                request: legacy))
            #expect(Semantics
                .failureOutcomeMatchesContract(outcome, request: guarded) == (units <= 4))
        }
        let invalidSuccesses: [DesktopActionOutcome] = [
            .confirmedNoChange(route: .bridge),
            .confirmedChange(route: .bridge, delivery: delivery, unitCount: .init(4)),
            .suspectedNoop(route: .bridge, delivery: delivery, unitCount: .init(4)),
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one),
            .dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(4)),
        ]
        for outcome in invalidSuccesses {
            #expect(!Semantics.successfulOutcomeMatchesContract(
                outcome,
                response: .ok,
                request: guarded))
            #expect(Semantics.successfulOutcomeMatchesContract(
                outcome,
                response: .ok,
                request: legacy))
        }
        for units: Int? in [nil, 1, 2, 3, 4, 5] {
            let unknown = DesktopActionOutcome.indeterminate(
                route: .bridge,
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: units.flatMap { .init($0) })
            #expect(Semantics
                .failureOutcomeMatchesContract(unknown, request: guarded) ==
                (units.map { $0 <= 4 } ?? true))
        }
        #expect(Semantics.failureOutcomeMatchesContract(
            .indeterminate(route: .bridge, evidence: .completionUnknown), request: guarded))
        #expect(!Semantics.failureOutcomeMatchesContract(
            .partial(route: .bridge, delivery: delivery, unitCount: .one), request: guarded))
        #expect(!Semantics.failureOutcomeMatchesContract(
            .suspectedNoop(route: .bridge, delivery: delivery, unitCount: .init(4)),
            request: guarded))
    }

    @Test(arguments: ["cmd,v", "command+V", "meta v", "cmd,a", "cmd,shift,v", ""], [0, 50])
    func `guarded chord admission shares native parsing and refuses before provider calls`(
        keys: String, hold: Int) async throws
    {
        let automation = ClipboardGuardAutomationService()
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        _ = try await fixture.client.handshake(client: Self.clientIdentity)
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        let admitted = hold > 0 && ["cmd,v", "command+V", "meta v"].contains(keys)
        do {
            _ = try await fixture.client.hotkeyWithOutcome(
                keys: keys, holdDuration: hold, target: target, clipboardClaim: claim)
            #expect(admitted)
        } catch {
            #expect(!admitted)
        }
        let bundle = try #require(await fixture.client.latestVerifiedOperationReceiptBundle)
        try bundle.validateIntegrity()
        let outcome = try #require(bundle.receipt.payload.outcome)
        #expect(outcome.state == (admitted ? .dispatchedUnverified : .refused))
        #expect(outcome.dispatchState.mutationDispatched == admitted)
        #expect(outcome.retrySafety == (admitted ? .unsafe : .safe))
        #expect(automation.claims == (admitted ? [claim] : []))
        await fixture.host.stop()
    }

    @Test
    func `only claim bearing requests require the new protocol across carriage forms`() throws {
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        let guarded = self.request(target: target, claim: claim)
        let legacy = self.request(target: target, claim: nil)
        #expect(guarded.minimumNegotiatedProtocolVersion == Self.featureVersion)
        #expect(PeekabooBridgeRequest.projectedAction(.init(request: guarded))
            .requiresClipboardGuardedExactWindowHotkey)
        #expect(legacy.minimumNegotiatedProtocolVersion == nil)
        #expect(!legacy.requiresClipboardGuardedExactWindowHotkey)
        #expect(PeekabooBridgeConstants.clipboardGuardedExactWindowHotkeyVersion == Self
            .featureVersion)
    }

    @Test(arguments: 0..<32)
    func `guard advertisement requires version capability receipts and enabled hotkey`(flags: Int) {
        let current = flags & 1 != 0
        let capability = flags & 2 != 0
        let receipts = flags & 4 != 0
        let enabled = flags & 8 != 0
        let supported = flags & 16 != 0
        var capabilities: [String] = []
        if capability {
            capabilities.append(PeekabooBridgeHostCapability.clipboardGuardedExactWindowHotkeys)
        }
        if receipts {
            capabilities.append(PeekabooBridgeHostCapability.attestedOperationReceipts)
        }
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: current ? Self.featureVersion : Self.previousVersion,
            hostKind: .gui,
            build: "test",
            supportedOperations: supported ? [.exactWindowTargetedHotkey] : [],
            enabledOperations: enabled ? [.exactWindowTargetedHotkey] : [],
            hostCapabilities: capabilities)
        #expect(handshake.supportsClipboardGuardedExactWindowHotkeys ==
            (current && capability && receipts && enabled && supported))
    }

    @Test(arguments: [false, true])
    func `hotkey only host forwards the exact claim with a signed window receipt`(
        legacySupport: Bool) async throws
    {
        let automation = ClipboardGuardAutomationService()
        automation.supportsExactWindowTargetedKeyboard = legacySupport
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(client: Self.clientIdentity)
        #expect(handshake.supportsClipboardGuardedExactWindowHotkeys)
        #expect(!handshake.supportedOperations.contains(.exactWindowTargetedTypeActions))
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 71))
        let result = try await fixture.client.hotkeyWithOutcome(
            keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim)
        #expect(automation.claims == [claim])
        #expect(result.targetIdentity?.exactWindow?.identity == target.identity)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 4)
        let bundle = try #require(await fixture.client.latestVerifiedOperationReceiptBundle)
        try bundle.validateIntegrity()
        #expect(bundle.receipt.payload.target != nil)
        let downgraded = try await fixture.client.handshake(
            client: Self.clientIdentity, protocolVersion: Self.previousVersion)
        #expect(!downgraded.supportsClipboardGuardedExactWindowHotkeys)
        #expect(downgraded.supportedOperations
            .contains(.exactWindowTargetedHotkey) == legacySupport)
        await fixture.host.stop()
    }

    @Test
    func `guarded only provider refuses a claimless request without implying input`() async throws {
        let automation = ClipboardGuardAutomationService()
        automation.supportsExactWindowTargetedKeyboard = false
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        _ = try await fixture.client.handshake(client: Self.clientIdentity)
        let target = try BridgeInputCapabilityFixture.exactTarget().keyboardTarget
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.client.hotkeyWithOutcome(keys: "cmd,v", holdDuration: 50, target: target)
        }
        let bundle = try #require(await fixture.client.latestVerifiedOperationReceiptBundle)
        try bundle.validateIntegrity()
        let outcome = try #require(bundle.receipt.payload.outcome)
        #expect(outcome.state == .refused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.retrySafety == .safe)
        #expect(automation.claims.isEmpty)
        #expect(automation.legacyHotkeyCallCount == 0)
        await fixture.host.stop()
    }

    @Test(arguments: [false, true])
    func `old negotiation or unsupported provider refuses before guarded dispatch`(
        oldVersion: Bool) async throws
    {
        let automation = ClipboardGuardAutomationService()
        automation.supportsClipboardGuardedExactWindowHotkeys = oldVersion
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(
            client: Self.clientIdentity,
            protocolVersion: oldVersion ? Self.previousVersion : Self.featureVersion)
        #expect(!handshake.supportsClipboardGuardedExactWindowHotkeys)
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.client.hotkeyWithOutcome(
                keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim)
        }
        #expect(automation.claims.isEmpty)
        await fixture.host.stop()
    }

    @Test(arguments: [false, true])
    func `missing retained focus or lost provider support returns a signed no dispatch refusal`(
        missingFocus: Bool) async throws
    {
        let automation = ClipboardGuardAutomationService()
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        _ = try await fixture.client.handshake(client: Self.clientIdentity)
        #expect(await fixture.client.clipboardGuardedExactWindowHotkeysEnabled)
        let observed = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let target = try UIAutomationTarget.ExactWindow(
            identity: observed.identity,
            bounds: observed.bounds,
            focusedElement: missingFocus ? nil : observed.focusedElement)
        automation.supportsClipboardGuardedExactWindowHotkeys = missingFocus
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        await #expect(throws: DesktopActionFailure.self) {
            try await fixture.client.hotkeyWithOutcome(
                keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim)
        }
        let bundle = try #require(await fixture.client.latestVerifiedOperationReceiptBundle)
        try bundle.validateIntegrity()
        let outcome = try #require(bundle.receipt.payload.outcome)
        #expect(outcome.state == .refused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.retrySafety == .safe)
        #expect(outcome.refusalReason == (missingFocus ? .invalidRequest : .runtimeIncompatible))
        #expect(automation.claims.isEmpty)
        await fixture.host.stop()
    }

    @Test
    func `cold recovery and explicit downgrade clear the guard without accepting a stale reset`() async throws {
        let automation = ClipboardGuardAutomationService()
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        _ = try await fixture.client.handshake(client: Self.clientIdentity)
        #expect(await fixture.client.clipboardGuardedExactWindowHotkeysEnabled)
        let reservation = try #require(try await fixture.client.reserveOperationSession())
        await fixture.client.requireColdHandshakeRetainingOperationSession(
            sessionID: reservation.sessionAttestation.sessionID, epoch: reservation.epoch + 1)
        #expect(await fixture.client.clipboardGuardedExactWindowHotkeysEnabled)
        await fixture.client.requireColdHandshakeRetainingOperationSession(
            sessionID: reservation.sessionAttestation.sessionID, epoch: reservation.epoch)
        #expect(await !fixture.client.clipboardGuardedExactWindowHotkeysEnabled)
        _ = try await fixture.client.handshake(client: Self.clientIdentity)
        #expect(await fixture.client.clipboardGuardedExactWindowHotkeysEnabled)
        _ = try await fixture.client.handshake(
            client: Self.clientIdentity,
            protocolVersion: Self.previousVersion)
        #expect(await !fixture.client.clipboardGuardedExactWindowHotkeysEnabled)
        #expect(automation.claims.isEmpty)
        await fixture.host.stop()
    }

    @Test(arguments: [false, true])
    func `remote facade variants retain the dedicated guard without requiring type support`(
        elementActions: Bool) async throws
    {
        let automation = ClipboardGuardAutomationService()
        let fixture = try await self.startHost(automation)
        defer { Task { await fixture.host.stop() } }
        _ = try await fixture.client.handshake(client: Self.clientIdentity)
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 19))
        let unsupported = RemotePeekabooServices(
            client: fixture.client,
            supportsElementActions: elementActions)
        let defaultProvider = try #require(
            unsupported.automation as? any ClipboardGuardedExactWindowHotkeyServiceProtocol)
        #expect(!defaultProvider.supportsClipboardGuardedExactWindowHotkeys)
        await #expect(throws: DesktopActionFailure.self) {
            try await defaultProvider.hotkeyWithOutcome(
                keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim)
        }
        #expect(automation.claims.isEmpty)

        let remote = RemotePeekabooServices(
            client: fixture.client,
            supportsClipboardGuardedExactWindowHotkeys: true,
            supportsElementActions: elementActions)
        let provider = try #require(remote
            .automation as? any ClipboardGuardedExactWindowHotkeyServiceProtocol)
        let result = try await provider.hotkeyWithOutcome(
            keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim)
        #expect(automation.claims == [claim])
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 4)
        #expect(result.targetIdentity?.exactWindow?.identity == target.identity)
        await fixture.host.stop()
    }

    @Test(arguments: [false, true])
    func `signed session missing the version or guard receives no dispatch refusal`(oldVersion: Bool) async throws {
        let root = URL(
            fileURLWithPath: "/tmp/peekaboo-clipboard-guard-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(socketPath: root
            .appendingPathComponent("host.sock")
            .path)
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            negotiatedCapabilities: .init(
                protocolVersion: oldVersion ? Self.previousVersion : Self.featureVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                clipboardGuardedExactWindowHotkeys: oldVersion))
        let automation = ClipboardGuardAutomationService()
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: self.request(
            target: target,
            claim: claim)))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let server = PeekabooBridgeServer(
            services: StubServices(automation: automation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.exactWindowTargetedHotkey])
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority
            .withValue(authority) {
                try await server.handleAttestedOperation(payload, peer: session.peer)
            }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder()
            .decode(
                PeekabooBridgeResponse.self,
                from: data)
        else { Issue.record("Expected a signed refusal"); return }
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: request,
            response: attested.response)
        try bundle.validateIntegrity()
        let outcome = try #require(bundle.receipt.payload.outcome)
        #expect(outcome.state == .refused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.refusalReason == .runtimeIncompatible)
        #expect(outcome.retrySafety == .safe)
        #expect(automation.claims.isEmpty)
    }

    private func startHost(_ automation: ClipboardGuardAutomationService) async throws
        -> (host: PeekabooBridgeHost, client: PeekabooBridgeClient)
    {
        try await BridgeInputCapabilityFixture.startHost(
            services: StubServices(automation: automation),
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...Self.featureVersion,
            allowedOperations: [.exactWindowTargetedHotkey])
    }

    private func request(
        target: UIAutomationTarget.ExactWindow,
        claim: GeneralPasteboardWriteClaim?) -> PeekabooBridgeRequest
    {
        .exactWindowTargetedHotkey(.init(
            keys: "cmd,v",
            holdDuration: 50,
            expectedWindowIdentity: target.identity,
            expectedWindowBounds: target.bounds,
            expectedFocusedElement: target.focusedElement,
            clipboardClaim: claim))
    }
}

@MainActor
private final class ClipboardGuardAutomationService: StubAutomationService,
ClipboardGuardedExactWindowHotkeyServiceProtocol {
    var supportsClipboardGuardedExactWindowHotkeys = true
    private(set) var claims: [GeneralPasteboardWriteClaim] = []
    private(set) var legacyHotkeyCallCount = 0

    override func hotkey(
        keys: String,
        holdDuration: Int,
        expectedWindowIdentity: WindowMutationIdentity,
        expectedWindowBounds: CGRect) async throws
    {
        self.legacyHotkeyCallCount += 1
        try await super.hotkey(
            keys: keys,
            holdDuration: holdDuration,
            expectedWindowIdentity: expectedWindowIdentity,
            expectedWindowBounds: expectedWindowBounds)
    }

    func hotkeyWithOutcome(
        keys: String,
        holdDuration: Int,
        target: UIAutomationTarget.ExactWindow,
        clipboardClaim: GeneralPasteboardWriteClaim) async throws -> UIAutomationActionResult<Void>
    {
        #expect(HotkeyService.isPasteShortcut(keys))
        #expect(holdDuration > 0)
        self.claims.append(clipboardClaim)
        return UIAutomationActionResult(
            payload: (),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(4)),
            targetIdentity: .init(exactWindow: target))
    }
}
