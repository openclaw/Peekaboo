import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

struct BrowserResponseProgressFixture: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let browserResponse: PeekabooBridgeBrowserToolResponse
    let outcome: DesktopActionOutcome
    let acceptsSigned: Bool
    let acceptsReceiptless: Bool

    static let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 9001)
    static let connection = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        processIdentifier: 42,
        processStartIdentity: 9001,
        bundleIdentifier: "com.google.Chrome")

    static var request: PeekabooBridgeRequest {
        .browserExecute(.init(
            calls: [
                .init(toolName: "take_snapshot", arguments: [:]),
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "type_text", arguments: [:]),
                .init(toolName: "list_console_messages", arguments: [:]),
            ],
            channel: "stable",
            expectedConnectionReceipt: self.connection))
    }

    var response: PeekabooBridgeResponse {
        .projectedAction(.init(response: .browserToolResponse(self.browserResponse), outcome: self.outcome.projection))
    }

    static var cases: [Self] {
        let delivery = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .background)
        let two = DesktopActionOutcome.DispatchUnitCount(2)
        let success = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge, delivery: delivery, evidence: .deliveryAccepted, unitCount: two)
        let running = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge, delivery: delivery, evidence: .operationStillRunning, unitCount: two)
        let partial = DesktopActionFailure.partial(
            route: .bridge, delivery: delivery, unitCount: two, message: "fixture partial")
        let unknown = DesktopActionFailure.indeterminate(
            route: .bridge, delivery: delivery, evidence: .completionUnknown, message: "fixture unknown")
        let lost = DesktopActionFailure.indeterminate(
            route: .bridge, delivery: delivery, evidence: .responseLost, message: "fixture lost")
        let knownUnknown = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: delivery,
            evidence: .completionUnknown,
            unitCount: two,
            message: "fixture known dispatch")
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge, reason: .targetUnavailable, message: "fixture refusal")
        let runningFailure = DesktopActionFailure.dispatchedUnverified(
            route: .bridge,
            delivery: delivery,
            evidence: .operationStillRunning,
            unitCount: two,
            message: "fixture running")
        let suspectedNoop = DesktopActionFailure.suspectedNoop(
            route: .bridge, delivery: delivery, unitCount: two, message: "fixture no change")

        func fixture(
            _ name: String,
            completed: Int? = 2,
            dispatched: Int? = 2,
            outcome: DesktopActionOutcome? = nil,
            failure: DesktopActionFailure? = nil,
            isError: Bool? = nil,
            connection: PeekabooBridgeBrowserConnectionReceipt? = Self.connection,
            signed: Bool = true,
            receiptless: Bool? = nil) -> Self
        {
            .init(
                testDescription: name,
                browserResponse: .init(
                    content: [],
                    isError: isError ?? (failure != nil),
                    meta: nil,
                    connectionReceipt: connection,
                    completedCallCount: completed,
                    dispatchedCallCount: dispatched,
                    actionFailure: failure),
                outcome: outcome ?? failure?.outcome ?? success,
                acceptsSigned: signed,
                acceptsReceiptless: receiptless ?? signed)
        }

        return [
            fixture("mixed read and mutation batch completes two mutations"),
            fixture("partial completion", completed: 1, failure: partial),
            fixture("unknown dispatch", completed: nil, dispatched: nil, failure: unknown),
            fixture("known dispatch with unknown completion", completed: 1, failure: knownUnknown),
            fixture("zero dispatch refusal", completed: 0, dispatched: 0, failure: refusal),
            fixture("positive typed running failure", completed: 1, failure: runningFailure),
            fixture("positive suspected no change", completed: 1, failure: suspectedNoop),
            fixture("legacy successful running evidence", outcome: running, signed: false, receiptless: true),
            fixture(
                "legacy refusal without connection",
                completed: 0,
                dispatched: 0,
                failure: refusal,
                connection: nil,
                signed: false,
                receiptless: true),
            fixture(
                "legacy refusal with noncanonical connection",
                completed: 0,
                dispatched: 0,
                failure: refusal,
                connection: .init(channel: "unknown"),
                signed: false,
                receiptless: true),
            fixture("missing completed count", completed: nil, signed: false),
            fixture("missing dispatched count", dispatched: nil, signed: false),
            fixture("negative completed count", completed: -1, signed: false),
            fixture("negative dispatched count", completed: 0, dispatched: -1, signed: false),
            fixture("completion exceeds dispatch", dispatched: 1, signed: false),
            fixture("dispatch exceeds mutation count", completed: 3, dispatched: 3, signed: false),
            fixture(
                "incomplete success",
                completed: 1,
                dispatched: 1,
                outcome: .dispatchedUnverified(
                    route: .bridge, delivery: delivery, evidence: .deliveryAccepted, unitCount: .one),
                signed: false),
            fixture(
                "missing outcome units",
                outcome: .dispatchedUnverified(route: .bridge, delivery: delivery, evidence: .deliveryAccepted),
                signed: false),
            fixture(
                "wrong outcome units",
                outcome: .dispatchedUnverified(
                    route: .bridge, delivery: delivery, evidence: .deliveryAccepted, unitCount: .one),
                signed: false),
            fixture("failure without error marker", failure: partial, isError: false, signed: false),
            fixture("error marker without failure", isError: true, signed: false),
            fixture("failure projection mismatch", outcome: success, failure: partial, signed: false),
            fixture("unknown response lost", completed: nil, dispatched: nil, failure: lost, signed: false),
            fixture(
                "unknown counts with known dispatch",
                completed: nil,
                dispatched: nil,
                failure: knownUnknown,
                signed: false),
            fixture("zero dispatch success", completed: 0, dispatched: 0, signed: false),
            fixture("zero dispatch unsafe failure", completed: 0, dispatched: 0, failure: unknown, signed: false),
            fixture("wrong route", outcome: success.routed(to: .local), signed: false),
            fixture(
                "foreground delivery",
                outcome: .dispatchedUnverified(
                    route: .bridge,
                    delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: two),
                signed: false),
            fixture("dispatched response without connection", connection: nil, signed: false),
            fixture(
                "unknown response without connection",
                completed: nil,
                dispatched: nil,
                failure: unknown,
                connection: nil,
                signed: false),
        ]
    }
}
