import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct FocusDispatchAccountingTests {
    private let nativeForeground = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .foreground)
    private let valueForeground = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityValue,
        mode: .foreground)
    private let actionForeground = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .foreground)

    @Test
    func `rejected activation and AX value requests record no phantom units`() throws {
        var records: [FocusDispatchRecord] = []

        #expect(try !FocusDispatchAccounting.acceptingBool(
            delivery: self.nativeForeground,
            onDispatch: { records.append($0) },
            operation: { false }))
        #expect(try !FocusDispatchAccounting.acceptingBool(
            delivery: self.valueForeground,
            onDispatch: { records.append($0) },
            operation: { false }))
        #expect(records.isEmpty)
    }

    @Test
    func `accepted Bool requests record their exact delivery`() throws {
        var records: [FocusDispatchRecord] = []

        #expect(try FocusDispatchAccounting.acceptingBool(
            delivery: self.nativeForeground,
            onDispatch: { records.append($0) },
            operation: { true }))
        #expect(try FocusDispatchAccounting.acceptingBool(
            delivery: self.valueForeground,
            onDispatch: { records.append($0) },
            operation: { true }))
        #expect(records == [.accepted(self.nativeForeground), .accepted(self.valueForeground)])
    }

    @Test
    func `pre-cancelled focus submissions dispatch no activation main or raise units`() {
        var records: [FocusDispatchRecord] = []
        var operations: [String] = []
        let cancel: () throws -> Void = { throw CancellationError() }

        #expect(throws: CancellationError.self) {
            _ = try FocusDispatchAccounting.acceptingBool(
                delivery: self.nativeForeground,
                onDispatch: { records.append($0) },
                checkCancellation: cancel,
                operation: { operations.append("activate"); return true })
        }
        #expect(throws: CancellationError.self) {
            _ = try FocusDispatchAccounting.acceptingBool(
                delivery: self.valueForeground,
                onDispatch: { records.append($0) },
                checkCancellation: cancel,
                operation: { operations.append("main"); return true })
        }
        #expect(throws: CancellationError.self) {
            _ = try FocusDispatchAccounting.submittingThrowing(
                delivery: self.actionForeground,
                onDispatch: { records.append($0) },
                checkCancellation: cancel,
                operation: { operations.append("raise") })
        }

        #expect(operations.isEmpty)
        #expect(records.isEmpty)
    }

    @Test
    func `throwing AX request records ambiguous attempt and accepted success`() throws {
        var records: [FocusDispatchRecord] = []

        #expect(throws: FocusDispatchProbeError.self) {
            try FocusDispatchAccounting.submittingThrowing(
                delivery: self.actionForeground,
                onDispatch: { records.append($0) },
                operation: { throw FocusDispatchProbeError.rejected })
        }
        #expect(records == [.mayHaveDispatched(self.actionForeground)])

        let value = try FocusDispatchAccounting.submittingThrowing(
            delivery: self.actionForeground,
            onDispatch: { records.append($0) },
            operation: { () throws -> Int in 42 })
        #expect(value == 42)
        #expect(records == [
            .mayHaveDispatched(self.actionForeground),
            .accepted(self.actionForeground),
        ])
    }

    @Test
    func `throwing AX attempt resolves to indeterminate completion unknown`() {
        var sequence = DesktopActionSequenceAccumulator()

        #expect(throws: FocusDispatchProbeError.self) {
            try FocusDispatchAccounting.submittingThrowing(
                delivery: self.actionForeground,
                onDispatch: { sequence.record($0.sequenceStep) },
                operation: { throw FocusDispatchProbeError.rejected })
        }
        let leaf = DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "AX raise returned an error")
        let failure = sequence.failure(
            combining: leaf,
            message: "Focus completion is unknown")

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .completionUnknown)
        #expect(failure.outcome.delivery == self.actionForeground)
        #expect(failure.outcome.dispatchState.unitCount == .one)
    }

    @Test
    @MainActor
    func `strict accepted raise completes after asynchronous exact focus settlement`() async throws {
        var exactFocusSettled = false
        var raiseCount = 0
        var verificationCount = 0
        var completionCount = 0
        var retryCount = 0

        try await FocusRaiseSettlement.run(
            attemptCount: 2,
            performAttempt: {
                try await FocusRaiseSettlement.attempt(
                    requiresStrictDispatchOwnership: true,
                    prepareAttempt: {},
                    dispatchRaise: { raiseCount += 1 },
                    verifyFocus: {
                        verificationCount += 1
                        #expect(!exactFocusSettled)
                        await Task.yield()
                        exactFocusSettled = true
                    },
                    completeRaise: {
                        #expect(exactFocusSettled)
                        completionCount += 1
                    })
            },
            sleepBeforeRetry: { retryCount += 1 },
            fallbackError: FocusDispatchProbeError.rejected)

        #expect(raiseCount == 1)
        #expect(verificationCount == 1)
        #expect(completionCount == 1)
        #expect(retryCount == 0)
    }

    @Test
    @MainActor
    func `strict accepted raise that never settles does not complete or retry`() async {
        var raiseCount = 0
        var verificationCount = 0
        var completionCount = 0
        var retryCount = 0

        await #expect(throws: FocusDispatchProbeError.self) {
            try await FocusRaiseSettlement.run(
                attemptCount: 3,
                performAttempt: {
                    try await FocusRaiseSettlement.attempt(
                        requiresStrictDispatchOwnership: true,
                        prepareAttempt: {},
                        dispatchRaise: { raiseCount += 1 },
                        verifyFocus: {
                            verificationCount += 1
                            throw FocusDispatchProbeError.rejected
                        },
                        completeRaise: { completionCount += 1 })
                },
                sleepBeforeRetry: { retryCount += 1 },
                fallbackError: FocusDispatchProbeError.rejected)
        }

        #expect(raiseCount == 1)
        #expect(verificationCount == 1)
        #expect(completionCount == 0)
        #expect(retryCount == 0)
    }

    @Test
    @MainActor
    func `non strict accepted raises complete before transient verification retry`() async throws {
        var attempt = 0
        var events: [String] = []

        try await FocusRaiseSettlement.run(
            attemptCount: 2,
            performAttempt: {
                try await FocusRaiseSettlement.attempt(
                    requiresStrictDispatchOwnership: false,
                    prepareAttempt: {},
                    dispatchRaise: {
                        attempt += 1
                        events.append("raise\(attempt)")
                    },
                    verifyFocus: {
                        events.append("verify\(attempt)")
                        if attempt == 1 {
                            throw FocusDispatchProbeError.rejected
                        }
                    },
                    completeRaise: { events.append("complete\(attempt)") })
            },
            sleepBeforeRetry: { events.append("retry\(attempt)") },
            fallbackError: FocusDispatchProbeError.rejected)

        #expect(events == [
            "raise1", "complete1", "verify1", "retry1",
            "raise2", "complete2", "verify2",
        ])
    }

    @Test
    @MainActor
    func `non strict exhausted verification retries retain every accepted completion`() async {
        var raiseCount = 0
        var completionCount = 0
        var verificationCount = 0
        var retryCount = 0

        await #expect(throws: FocusDispatchProbeError.self) {
            try await FocusRaiseSettlement.run(
                attemptCount: 3,
                performAttempt: {
                    try await FocusRaiseSettlement.attempt(
                        requiresStrictDispatchOwnership: false,
                        prepareAttempt: {},
                        dispatchRaise: { raiseCount += 1 },
                        verifyFocus: {
                            verificationCount += 1
                            throw FocusDispatchProbeError.rejected
                        },
                        completeRaise: { completionCount += 1 })
                },
                sleepBeforeRetry: { retryCount += 1 },
                fallbackError: FocusDispatchProbeError.rejected)
        }

        #expect(raiseCount == 3)
        #expect(completionCount == 3)
        #expect(verificationCount == 3)
        #expect(retryCount == 2)
    }

    @Test(arguments: [-1, 0, 1, 2])
    @MainActor
    func `settlement constructs fallback only without attempts and preserves the last verification error`(
        attemptCount: Int) async
    {
        var fallbackCount = 0
        var verificationCount = 0
        var retryCount = 0
        @MainActor func fallbackError() -> FocusError {
            fallbackCount += 1
            return .focusVerificationFailed(712)
        }

        do {
            try await FocusRaiseSettlement.run(
                attemptCount: attemptCount,
                performAttempt: {
                    try await FocusRaiseSettlement.attempt(
                        requiresStrictDispatchOwnership: false,
                        prepareAttempt: { #expect(attemptCount > 0) },
                        dispatchRaise: {},
                        verifyFocus: {
                            verificationCount += 1
                            if attemptCount == 2 {
                                throw FocusError.focusVerificationTimeout(UInt32(verificationCount))
                            }
                        },
                        completeRaise: {})
                },
                sleepBeforeRetry: { retryCount += 1 },
                fallbackError: fallbackError())
            #expect(attemptCount == 1)
        } catch FocusError.focusVerificationFailed(712) {
            #expect(attemptCount <= 0)
        } catch FocusError.focusVerificationTimeout(2) {
            #expect(attemptCount == 2)
        } catch {
            Issue.record("Unexpected settlement error: \(error)")
        }

        #expect(fallbackCount == (attemptCount <= 0 ? 1 : 0))
        #expect(verificationCount == max(attemptCount, 0))
        #expect(retryCount == (attemptCount == 2 ? 1 : 0))
    }

    @Test(arguments: [false, true], ["prepare", "raise", "verify", "complete"])
    @MainActor
    func `settlement cancellation preserves completion and retry ordering without evaluating fallback`(
        strict: Bool,
        cancelledPhase: String) async
    {
        var events: [String] = []
        @MainActor func record(_ phase: String) throws {
            events.append(phase)
            if phase == cancelledPhase {
                throw CancellationError()
            }
        }
        @MainActor func fallbackError() -> FocusDispatchProbeError {
            Issue.record("Cancellation must not evaluate fallback")
            return .rejected
        }

        await #expect(throws: CancellationError.self) {
            try await FocusRaiseSettlement.run(
                attemptCount: 2,
                performAttempt: {
                    try await FocusRaiseSettlement.attempt(
                        requiresStrictDispatchOwnership: strict,
                        prepareAttempt: { try record("prepare") },
                        dispatchRaise: { try record("raise") },
                        verifyFocus: { try record("verify") },
                        completeRaise: { try record("complete") })
                },
                sleepBeforeRetry: { events.append("retry") },
                fallbackError: fallbackError())
        }

        let expected: [String] = switch cancelledPhase {
        case "prepare":
            ["prepare"]
        case "raise":
            ["prepare", "raise"]
        case "verify" where !strict:
            [
                "prepare", "raise", "complete", "verify", "retry",
                "prepare", "raise", "complete", "verify",
            ]
        case "verify":
            ["prepare", "raise", "verify"]
        default:
            strict ? ["prepare", "raise", "verify", "complete"] : ["prepare", "raise", "complete"]
        }
        #expect(events == expected)
    }

    @Test
    func `unknown Space success is accounted while active Space is skipped`() async throws {
        #expect(FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: nil))
        #expect(FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: false))
        #expect(!FocusDispatchAccounting.shouldAccountSpaceSwitch(isActive: true))
        var records: [FocusDispatchRecord] = []

        try await FocusDispatchAccounting.submittingAsync(
            delivery: self.nativeForeground,
            onDispatch: { records.append($0) },
            operation: { () async throws in })
        #expect(records == [.accepted(self.nativeForeground)])
    }

    @Test
    func `unknown Space cancellation records possible unit`() async {
        var sequence = DesktopActionSequenceAccumulator()

        await #expect(throws: CancellationError.self) {
            try await FocusDispatchAccounting.submittingAsync(
                delivery: self.nativeForeground,
                onDispatch: { sequence.record($0.sequenceStep) },
                operation: { throw CancellationError() })
        }
        let failure = sequence.cancellationFailure(
            fallbackRoute: .local,
            message: "Space switch cancelled",
            hint: "Observe before retrying",
            causeDescription: "cancelled")

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.evidence == .completionUnknown)
        #expect(failure?.outcome.delivery == self.nativeForeground)
        #expect(failure?.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `exact Space focus plans preserve the generation-pinned window receipt`() {
        let identity = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: .init(x: 10, y: 20, width: 300, height: 200))

        #expect(FocusSpaceActionPlan.make(
            bringToCurrentSpace: true,
            expectedIdentity: identity) == .moveToCurrentSpace(expectedIdentity: identity))
        #expect(FocusSpaceActionPlan.make(
            bringToCurrentSpace: false,
            expectedIdentity: identity) == .switchToWindowSpace(expectedIdentity: identity))
    }

    @Test
    func `pinned Space outcome accounting preserves exact units and delivery`() {
        let background = DesktopActionOutcome.Delivery(
            mechanism: .nativeFramework,
            mode: .background)
        var records: [FocusDispatchRecord] = []

        FocusDispatchAccounting.report(
            outcome: .confirmedChange(
                delivery: background,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            onDispatch: { records.append($0) })
        FocusDispatchAccounting.report(
            outcome: .confirmedNoChange(),
            onDispatch: { records.append($0) })

        #expect(records == [.accepted(background), .accepted(background)])
    }

    @Test
    func `pinned Space outcome validation rejects missing receipt as one possible exact dispatch`() throws {
        let identity = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: .init(x: 10, y: 20, width: 300, height: 200))
        let result = UIAutomationActionResult<Void>(payload: (), outcome: nil)

        let failure = #expect(throws: DesktopActionFailure.self) {
            _ = try FocusDispatchAccounting.requirePinnedSpaceOutcome(
                result,
                expectedIdentity: identity,
                requiredDeliveryMode: .foreground,
                operation: "Exact-window Space switch")
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.delivery == .init(mechanism: .nativeFramework, mode: .foreground))
        #expect(failure?.outcome.dispatchState.unitCount == .one)
        #expect(failure?.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 999,
            processStartIdentity: 1234,
            windowID: 4040))
    }

    @Test
    func `verified exact focus promotes definite delivery for strict foreground consumers`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(FocusDispatchRecord.accepted(self.actionForeground).sequenceStep)
        let unverified = sequence.successResolution()

        #expect(unverified.outcome?.state == .dispatchedUnverified)
        let verified = FocusDispatchAccounting.verifiedFocusOutcome(unverified)
        #expect(verified.state == .confirmedChange)
        #expect(verified.isConfirmed)
        #expect(verified.delivery == self.actionForeground)
        #expect(verified.dispatchState.unitCount == .one)

        let noDispatch = FocusDispatchAccounting.verifiedFocusOutcome(
            DesktopActionSequenceAccumulator().successResolution())
        #expect(noDispatch.state == .confirmedNoChange)
        #expect(noDispatch.dispatchState == .none)
    }

    @Test
    func `verified focus never promotes a possible dispatch`() {
        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(FocusDispatchRecord.mayHaveDispatched(self.actionForeground).sequenceStep)

        let outcome = FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())

        #expect(outcome.state == .indeterminate)
        #expect(!outcome.isConfirmed)
        #expect(outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `pinned Space failure is composed once for one and two unit focus sequences`() throws {
        let identity = WindowMutationIdentity(
            windowID: 4040,
            ownerProcessIdentifier: 999,
            ownerProcessStartIdentity: 1234,
            capturedBounds: .init(x: 10, y: 20, width: 300, height: 200))
        let bounds = try #require(identity.capturedBounds)
        let target = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
        let result = UIAutomationActionResult<Void>(
            payload: (),
            outcome: .indeterminate(
                delivery: self.nativeForeground,
                evidence: .completionUnknown,
                unitCount: .one),
            targetIdentity: target)
        var records: [FocusDispatchRecord] = []
        let failure = #expect(throws: DesktopActionFailure.self) {
            try FocusDispatchAccounting.reportPinnedSpaceOutcome(
                result,
                expectedIdentity: identity,
                requiredDeliveryMode: .foreground,
                operation: "Exact-window Space switch",
                onDispatch: { records.append($0) })
        }
        #expect(records.isEmpty)
        let leaf = try #require(failure)

        let emptySequence = DesktopActionSequenceAccumulator()
        let oneUnit = emptySequence.failure(combining: leaf, message: "Focus failed")
        #expect(oneUnit.outcome.dispatchState.unitCount == .one)

        var prefixedSequence = DesktopActionSequenceAccumulator()
        prefixedSequence.record(FocusDispatchRecord.accepted(self.nativeForeground).sequenceStep)
        let twoUnits = prefixedSequence.failure(combining: leaf, message: "Focus failed")
        #expect(twoUnits.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))
    }
}

private enum FocusDispatchProbeError: Error {
    case rejected
}
