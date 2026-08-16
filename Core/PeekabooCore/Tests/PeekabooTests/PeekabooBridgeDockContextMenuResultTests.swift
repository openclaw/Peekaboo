import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeDockContextMenuResultTests {
    @Test
    func `Dock Bridge receipts retain the dispatched generation instead of a successor`() throws {
        let dispatched = ApplicationProcessIdentity(
            processIdentifier: 456,
            processStartIdentity: 11)
        let successor = ApplicationProcessIdentity(
            processIdentifier: 456,
            processStartIdentity: 12)
        let target = try DesktopTargetIdentity(processIdentity: dispatched)
        let requests: [PeekabooBridgeRequest] = [
            .launchDockItem(.init(appName: "Safari")),
            .rightClickDockItem(.init(appName: "Safari", menuItem: "Options")),
        ]

        for request in requests {
            let receipt = try PeekabooBridgeOperationTargetAttribution.resolveReceipt(
                request: request,
                response: .ok,
                handledTarget: target)
            #expect(receipt.target == .process(dispatched))
            #expect(receipt.target != .process(successor))
        }
    }

    @Test
    @MainActor
    func `Bridge preserves the known first Dock right-click dispatch`() throws {
        let localFailure = DesktopActionFailure.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "The Dock right-click was dispatched, but selection was not submitted.")

        let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: localFailure,
            operation: .rightClickDockItem)
        let failure = try #require(envelope.desktopActionFailure)

        #expect(failure.outcome == .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one))
        #expect(failure.message == localFailure.message)
    }

    @Test
    @MainActor
    func `Bridge preserves indeterminate mixed Dock selection delivery`() throws {
        let localFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "The Dock right-click and menu selection may both have been dispatched.")

        let envelope = PeekabooBridgeServer.bridgeErrorEnvelope(
            for: localFailure,
            operation: .rightClickDockItem)
        let failure = try #require(envelope.desktopActionFailure)

        #expect(failure.outcome == .indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.escalation == .observeBeforeRetry)
        #expect(failure.message == localFailure.message)
    }
}
