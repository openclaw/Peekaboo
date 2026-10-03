import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PeekabooBridgePreparedPasteTests {
    private static let identity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.prepared-paste-tests", teamIdentifier: nil, processIdentifier: getpid())

    @Test
    func `prepared success is only eight composite units and failures retain truthful prefixes`() throws {
        let request = try Self.request()
        typealias Semantics = PeekabooBridgeOperationResultSemantics
        for mechanism: DesktopActionOutcome.Delivery
            .Mechanism in [.nativeFramework, .windowTargetedEvents, .composite]
        {
            let delivery = DesktopActionOutcome.Delivery(mechanism: mechanism, mode: .background)
            for count in [1, 2, 3, 4, 7, 8, 9] {
                let outcome = DesktopActionOutcome.dispatchedUnverified(
                    route: .bridge, delivery: delivery, evidence: .deliveryAccepted, unitCount: .init(count))
                #expect(Semantics.successfulOutcomeMatchesContract(outcome, response: .ok, request: request) ==
                    (mechanism == .composite && count == 8))
                #expect(Semantics.failureOutcomeMatchesContract(outcome, request: request) ==
                    ((mechanism == .nativeFramework && count == 1) ||
                        (mechanism == .composite && (2...8).contains(count))))
            }
        }
        #expect(Semantics.failureOutcomeMatchesContract(
            .indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .composite, mode: .background),
                evidence: .completionUnknown), request: request))
        #expect(!Semantics.successfulOutcomeMatchesContract(
            .confirmedChange(
                route: .bridge,
                delivery: .init(mechanism: .composite, mode: .background),
                unitCount: .init(8)), response: .ok, request: request))
    }

    @Test
    func `explicit preparation retains its new version gate even without a claim`() throws {
        for claim in [false, true] {
            let request = try Self.request(claim: claim)
            #expect(request.minimumNegotiatedProtocolVersion == .init(major: 1, minor: 41))
            #expect(request.requiresPreparedClipboardGuardedExactWindowHotkey)
            #expect(PeekabooBridgeRequest.projectedAction(.init(request: request))
                .requiresPreparedClipboardGuardedExactWindowHotkey)
        }
    }

    @Test(arguments: [false, true])
    func `prepared capability is negotiated and cannot survive downgrade or provider refusal`(
        supports: Bool) async throws
    {
        let automation = PreparedPasteAutomationService()
        automation.supportsPreparedClipboardGuardedExactWindowHotkeys = supports
        let fixture = try await BridgeInputCapabilityFixture.startHost(
            services: StubServices(automation: automation),
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...PeekabooBridgeConstants.protocolVersion,
            allowedOperations: [.exactWindowTargetedHotkey])
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(client: Self.identity)
        #expect(handshake.supportsPreparedClipboardGuardedExactWindowHotkeys == supports)
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        let claim = try #require(GeneralPasteboardWriteClaim(changeCount: 11))
        if supports {
            let result = try await fixture.client.hotkeyWithOutcome(
                keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim,
                preparation: .blankWindowChrome)
            #expect(result.outcome?.dispatchState.unitCount?.rawValue == 8)
            let bundle = try #require(await fixture.client.latestVerifiedOperationReceiptBundle)
            try bundle.validateIntegrity()
            #expect(bundle.receipt.payload.outcome?.deliveryMechanism == .composite)
            #expect(bundle.receipt.payload.outcome?.deliveryMode == .background)
        } else {
            await #expect(throws: (any Error).self) {
                try await fixture.client.hotkeyWithOutcome(
                    keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim,
                    preparation: .blankWindowChrome)
            }
        }
        #expect(automation.preparedCalls == (supports ? 1 : 0))
        let old = try await fixture.client.handshake(client: Self.identity, protocolVersion: .init(major: 1, minor: 40))
        #expect(old.supportsClipboardGuardedExactWindowHotkeys)
        #expect(!old.supportsPreparedClipboardGuardedExactWindowHotkeys)
        await #expect(throws: (any Error).self) {
            try await fixture.client.hotkeyWithOutcome(
                keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim, preparation: .blankWindowChrome)
        }
        #expect(automation.preparedCalls == (supports ? 1 : 0))
        let original = try await fixture.client.hotkeyWithOutcome(
            keys: "cmd,v", holdDuration: 50, target: target, clipboardClaim: claim)
        #expect(original.outcome?.dispatchState.unitCount?.rawValue == 4)
        #expect(automation.ordinaryCalls == 1)
        await fixture.host.stop()
    }

    private static func request(claim: Bool = true) throws -> PeekabooBridgeRequest {
        let target = try BridgeInputCapabilityFixture.exactTarget().exactWindow
        return .exactWindowTargetedHotkey(.init(
            keys: "cmd,v", holdDuration: 50, expectedWindowIdentity: target.identity,
            expectedWindowBounds: target.bounds, expectedFocusedElement: target.focusedElement,
            clipboardClaim: claim ? GeneralPasteboardWriteClaim(changeCount: 11) : nil,
            backgroundPreparation: .blankWindowChrome))
    }
}

@MainActor
private final class PreparedPasteAutomationService: StubAutomationService,
PreparedClipboardGuardedExactWindowHotkeyServiceProtocol {
    var supportsClipboardGuardedExactWindowHotkeys = true
    var supportsPreparedClipboardGuardedExactWindowHotkeys = true
    var preparedCalls = 0
    var ordinaryCalls = 0

    func hotkeyWithOutcome(
        keys: String, holdDuration: Int, target: UIAutomationTarget.ExactWindow,
        clipboardClaim: GeneralPasteboardWriteClaim) async throws -> UIAutomationActionResult<Void>
    {
        self.ordinaryCalls += 1
        return UIAutomationActionResult(
            payload: (), outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted, unitCount: .init(4)), targetIdentity: .init(exactWindow: target))
    }

    func hotkeyWithOutcome(
        keys: String, holdDuration: Int, target: UIAutomationTarget.ExactWindow,
        clipboardClaim: GeneralPasteboardWriteClaim,
        preparation: BackgroundWindowKeyboardPreparationMode) async throws -> UIAutomationActionResult<Void>
    {
        self.preparedCalls += 1
        return UIAutomationActionResult(
            payload: (), outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .composite, mode: .background),
                evidence: .deliveryAccepted, unitCount: .init(8)), targetIdentity: .init(exactWindow: target))
    }
}
