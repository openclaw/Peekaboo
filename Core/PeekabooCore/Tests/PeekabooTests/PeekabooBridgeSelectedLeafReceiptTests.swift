import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeSelectedLeafReceiptTests {
    @Test
    func `indexed menu receipt accepts the exact requested selected leaf`() async throws {
        let fixture = try await self.menuFixture()

        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            fixture.payload,
            request: fixture.request,
            response: fixture.response)
    }

    @Test
    func `indexed menu receipt rejects candidate-set digest substitution`() async throws {
        let fixture = try await self.menuFixture(actualDigest: "b")

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                fixture.payload,
                request: fixture.request,
                response: fixture.response)
        }
    }

    @Test
    func `indexed menu receipt rejects concrete leaf substitution`() async throws {
        let fixture = try await self.menuFixture(actualTitle: "Control Center")

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                fixture.payload,
                request: fixture.request,
                response: fixture.response)
        }
    }

    @Test
    func `Dock receipt rejects selected leaf owned by another process`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-leaf-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .launchDockItem(.init(
            appName: "Safari"))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .ok,
            outcome: outcome.projection))
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let receiptTarget = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 99)
        let substitutedLeaf = try self.dockLeaf(
            processIdentity: .init(processIdentifier: 43, processStartIdentity: 100),
            title: "Safari",
            digest: "c")
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .process(receiptTarget),
            selectedLeafEvidence: [substitutedLeaf],
            outcome: outcome.projection)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                payload,
                request: request,
                response: response)
        }
        authority.complete(accepted.claim)
    }

    @Test
    func `dispatched failure receipt preserves selected leaf evidence`() async throws {
        let fixture = try await self.menuFailureFixture()

        try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
            fixture.payload,
            request: fixture.request,
            response: fixture.response)
    }

    @Test
    func `dispatched failure receipt rejects omitted selected leaf evidence`() async throws {
        let fixture = try await self.menuFailureFixture(omitPayloadEvidence: true)

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                fixture.payload,
                request: fixture.request,
                response: fixture.response)
        }
    }

    @Test
    func `dispatched failure receipt rejects response and receipt leaf disagreement`() async throws {
        let fixture = try await self.menuFailureFixture(payloadDigest: "b")

        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try PeekabooBridgeOperationReceiptSemantics.validateReceiptCarriage(
                fixture.payload,
                request: fixture.request,
                response: fixture.response)
        }
    }

    private func menuFixture(
        actualDigest: Character = "a",
        actualTitle: String = "Clock") async throws -> (
        payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse)
    {
        let root = URL(fileURLWithPath: "/tmp/pbor-leaf-\(UUID().uuidString)", isDirectory: true)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let window = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 99,
            capturedBounds: CGRect(x: 10, y: 10, width: 30, height: 20))
        let expectedLeaf = try self.menuLeaf(window: window, title: "Clock", digest: "a")
        let actualLeaf = try self.menuLeaf(window: window, title: actualTitle, digest: actualDigest)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .clickMenuBarItemIndex(.init(
            index: 2,
            expectedLeafEvidence: expectedLeaf))))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .clickResult(.init(elementDescription: "Clock", location: CGPoint(x: 25, y: 20))),
            outcome: outcome.projection))
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .window(window),
            selectedLeafEvidence: [actualLeaf],
            outcome: outcome.projection)
        authority.complete(accepted.claim)
        try? FileManager.default.removeItem(at: root)
        return (payload, request, response)
    }

    private func menuFailureFixture(
        omitPayloadEvidence: Bool = false,
        payloadDigest: Character = "a") async throws -> (
        payload: PeekabooBridgeOperationReceiptPayload,
        request: PeekabooBridgeRequest,
        response: PeekabooBridgeResponse)
    {
        let root = URL(fileURLWithPath: "/tmp/pbor-leaf-failure-\(UUID().uuidString)", isDirectory: true)
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let window = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 99,
            capturedBounds: CGRect(x: 10, y: 10, width: 30, height: 20))
        let expectedLeaf = try self.menuLeaf(window: window, title: "Clock", digest: "a")
        let payloadLeaf = try self.menuLeaf(window: window, title: "Clock", digest: payloadDigest)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .clickMenuBarItemIndex(.init(
            index: 2,
            expectedLeafEvidence: expectedLeaf))))
        let outcome = DesktopActionOutcome.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one)
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Menu bar click completion is unknown")
            .attributed(to: payloadLeaf.selectedTargetReceipt)
            .selectingLeaves([expectedLeaf])
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .error(.init(code: .internalError, actionFailure: failure)),
            outcome: outcome.projection))
        let accepted = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: request)
        let payload = try OperationReceiptSessionFixture.receiptPayload(
            authority: authority,
            claim: accepted.claim,
            request: request,
            response: response,
            target: .window(window),
            selectedLeafEvidence: omitPayloadEvidence ? nil : [payloadLeaf],
            outcome: outcome.projection)
        authority.complete(accepted.claim)
        try? FileManager.default.removeItem(at: root)
        return (payload, request, response)
    }

    private func menuLeaf(
        window: WindowMutationIdentity,
        title: String,
        digest: Character) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "2",
            matchKind: .index,
            selectedProcessIdentity: window.processIdentity,
            selectedWindowIdentity: window,
            selectedIndex: 2,
            selectedTitle: title,
            selectedIdentifier: "fixture.\(title)",
            selectedRole: "AXStatusItem",
            selectedFrame: CGRect(x: 10, y: 10, width: 30, height: 20),
            candidateSetSHA256: String(repeating: digest, count: 64),
            candidateCount: 3)
    }

    private func dockLeaf(
        processIdentity: ApplicationProcessIdentity,
        title: String,
        digest: Character) throws -> DesktopSelectedLeafEvidence
    {
        try DesktopSelectedLeafEvidence(
            kind: .dockItem,
            normalizedSelector: DeterministicDesktopLeafSelector.normalized(title),
            matchKind: .exact,
            selectedProcessIdentity: processIdentity,
            selectedIndex: 0,
            selectedTitle: title,
            selectedIdentifier: "fixture.\(title)",
            selectedRole: "AXDockItem",
            selectedFrame: CGRect(x: 10, y: 10, width: 30, height: 20),
            candidateSetSHA256: String(repeating: digest, count: 64),
            candidateCount: 3)
    }
}
