import ApplicationServices
import AXorcist
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct FocusRaiseDispatchAccountingTests {
    private let raiseDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .foreground)

    @Test(arguments: [AXError.actionUnsupported, .attributeUnsupported])
    func `native unsupported raise adds no dispatch unit and preserves its error`(_ code: AXError) {
        var records: [FocusDispatchRecord] = []
        let error = #expect(throws: AccessibilitySystemError.self) {
            try FocusDispatchAccounting.submittingRaise(
                onDispatch: { records.append($0) },
                operation: { throw AccessibilitySystemError(code) })
        }

        #expect(error?.axError == code)
        #expect(records.isEmpty)
    }

    @Test(arguments: [AXError.actionUnsupported, .attributeUnsupported])
    func `unsupported errors from other focus operations still record possible dispatch`(_ code: AXError) {
        var records: [FocusDispatchRecord] = []
        let delivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
        #expect(throws: AccessibilitySystemError.self) {
            try FocusDispatchAccounting.submittingThrowing(
                delivery: delivery,
                onDispatch: { records.append($0) },
                operation: { throw AccessibilitySystemError(code) })
        }
        #expect(records == [.mayHaveDispatched(delivery)])
    }

    @Test(arguments: [0, 1, 2], [AXError.actionUnsupported, .attributeUnsupported])
    @MainActor
    func `unsupported raise preserves accepted prefix and requires exact focus settlement`(
        acceptedPrefix: Int,
        code: AXError) async throws
    {
        let prefix: [FocusDispatchRecord] = [
            .accepted(.init(mechanism: .nativeFramework, mode: .foreground)),
            .accepted(.init(mechanism: .accessibilityValue, mode: .foreground)),
        ]
        var records = Array(prefix.prefix(acceptedPrefix))
        var events: [String] = []

        try await FocusRaiseSettlement.run(
            attemptCount: 3,
            performAttempt: {
                try await FocusRaiseSettlement.attempt(
                    requiresStrictDispatchOwnership: false,
                    prepareAttempt: {},
                    dispatchRaise: {
                        events.append("raise")
                        try FocusDispatchAccounting.submittingRaise(
                            onDispatch: { records.append($0) },
                            operation: { throw AccessibilitySystemError(code) })
                    },
                    verifyFocus: { events.append("verify exact focus") },
                    completeRaise: { events.append("complete raise") })
            },
            sleepBeforeRetry: { events.append("retry") },
            fallbackError: FocusError.focusVerificationFailed(801))

        #expect(events == ["raise", "verify exact focus"])
        #expect(records == Array(prefix.prefix(acceptedPrefix)))
        var sequence = DesktopActionSequenceAccumulator()
        records.forEach { sequence.record($0.sequenceStep) }
        let outcome = FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
        #expect(outcome.isConfirmed)
        #expect(outcome.dispatchState == (acceptedPrefix == 0
                ? .none : .dispatched(unitCount: .init(acceptedPrefix))))
        #expect(outcome.state == (acceptedPrefix == 0 ? .confirmedNoChange : .confirmedChange))
    }

    @Test(arguments: [
        AccessibilitySystemError(.cannotComplete), AccessibilitySystemError(.failure),
        AccessibilitySystemError(.notImplemented), AccessibilitySystemError(.illegalArgument),
        AccessibilitySystemError(.noValue), AccessibilitySystemError(.invalidUIElement),
        AccessibilitySystemError(.apiDisabled), AccessibilitySystemError(.parameterizedAttributeUnsupported),
        ActionInputError.unsupported(.missingElement), ActionInputError.unsupported(.actionUnsupported),
        CancellationError(), FocusRaiseProbeError.unknown,
    ] as [any Error])
    func `other raise errors remain possible dispatch even after verified focus`(_ error: any Error) {
        var sequence = DesktopActionSequenceAccumulator()
        #expect(throws: (any Error).self) {
            try FocusDispatchAccounting.submittingRaise(
                onDispatch: { sequence.record($0.sequenceStep) },
                operation: { throw error })
        }

        let outcome = FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
        #expect(outcome.state == .indeterminate)
        #expect(outcome.evidence == .completionUnknown)
        #expect(outcome.delivery == self.raiseDelivery)
        #expect(outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
        #expect(!outcome.isConfirmed)
        #expect(!outcome.projection.retrySafe)
    }

    @Test
    func `accepted raise records its exact delivery and pre-cancelled raise makes no call`() throws {
        var records: [FocusDispatchRecord] = []
        var calls = 0
        try FocusDispatchAccounting.submittingRaise(
            onDispatch: { records.append($0) },
            operation: { calls += 1 })
        #expect(records == [.accepted(self.raiseDelivery)])

        #expect(throws: CancellationError.self) {
            try FocusDispatchAccounting.submittingRaise(
                onDispatch: { records.append($0) },
                checkCancellation: { throw CancellationError() },
                operation: { calls += 1 })
        }
        #expect(calls == 1)
        #expect(records == [.accepted(self.raiseDelivery)])
    }

    @Test(arguments: [false, true])
    @MainActor
    func `unsupported raise preserves strict refusal and failed focus verification`(strict: Bool) async {
        let prefix = FocusDispatchRecord.accepted(.init(mechanism: .accessibilityValue, mode: .foreground))
        var records = [prefix]
        var verificationCalls = 0
        var completed = false

        do {
            try await FocusRaiseSettlement.run(
                attemptCount: 1,
                performAttempt: {
                    try await FocusRaiseSettlement.attempt(
                        requiresStrictDispatchOwnership: strict,
                        prepareAttempt: {},
                        dispatchRaise: {
                            try FocusDispatchAccounting.submittingRaise(
                                onDispatch: { records.append($0) },
                                operation: { throw AccessibilitySystemError(.attributeUnsupported) })
                        },
                        verifyFocus: {
                            verificationCalls += 1
                            throw FocusError.focusVerificationFailed(801)
                        },
                        completeRaise: { completed = true })
                },
                sleepBeforeRetry: { Issue.record("No retry was authorized") },
                fallbackError: FocusError.focusVerificationFailed(801))
            Issue.record("Unproven focus must not succeed")
        } catch let error as AccessibilitySystemError {
            #expect(strict)
            #expect(error.axError == .attributeUnsupported)
        } catch FocusError.focusVerificationFailed(801) {
            #expect(!strict)
        } catch {
            Issue.record("Unexpected failure: \(error)")
        }

        #expect(records == [prefix])
        #expect(verificationCalls == (strict ? 0 : 1))
        #expect(!completed)

        var sequence = DesktopActionSequenceAccumulator()
        records.forEach { sequence.record($0.sequenceStep) }
        let failure = sequence.failure(
            combining: DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Exact focus was not proven"),
            message: "Focus did not complete")
        #expect(failure.outcome.dispatchState.unitCount == .one)
        #expect(failure.outcome.projection.mutationDispatched)
        #expect(!failure.outcome.projection.retrySafe)
        #expect(!failure.outcome.isConfirmed)
    }
}

private enum FocusRaiseProbeError: Error {
    case unknown
}
