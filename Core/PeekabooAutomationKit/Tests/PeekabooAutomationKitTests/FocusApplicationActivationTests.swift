import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct FocusApplicationActivationTests {
    @Test
    func `already settled activation dispatches nothing`() async throws {
        let probe = ActivationProbe()
        probe.settled = true

        try await probe.run()

        #expect(probe.events.isEmpty)
        #expect(probe.records.isEmpty)
        #expect(probe.elapsed == .zero)
    }

    @Test
    func `declined native request that nevertheless settles skips AX`() async throws {
        let probe = ActivationProbe()
        probe.nativeAccepted = false
        probe.nativeSettlementPoll = 0

        try await probe.run()

        #expect(probe.nativeRequests == 1)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.records.isEmpty)
        #expect(probe.acceptanceCount == 0)
        #expect(probe.completionCount == 0)
        #expect(probe.elapsed == .zero)
    }

    @Test(arguments: [0, 1, 10])
    func `native acceptance settles without AX including the last short interval`(poll: Int) async throws {
        let probe = ActivationProbe()
        probe.nativeSettlementPoll = poll

        try await probe.run()

        #expect(probe.nativeRequests == 1)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.records == [.accepted(ActivationProbe.nativeDelivery)])
        #expect(probe.acceptanceCount == 1)
        #expect(probe.completionCount == 1)
        #expect(probe.elapsed == .milliseconds(poll * 100))
    }

    @Test
    func `accepted native request falls back after one second and completes only once`() async throws {
        let probe = ActivationProbe()

        try await probe.run()

        #expect(probe.nativeRequests == 1)
        #expect(probe.accessibilityRequests == 1)
        #expect(probe.fallbackTime == .seconds(1))
        #expect(probe.elapsed == .milliseconds(1100))
        #expect(probe.records == [
            .accepted(ActivationProbe.nativeDelivery),
            .accepted(ActivationProbe.accessibilityDelivery),
        ])
        #expect(probe.acceptanceCount == 1)
        #expect(probe.completionCount == 1)
        #expect(probe.events == ["identity", "validate", "native", "accept", "identity", "validate", "AX", "complete"])
    }

    @Test
    func `declined native request falls back immediately`() async throws {
        let probe = ActivationProbe()
        probe.nativeAccepted = false

        try await probe.run()

        #expect(probe.nativeRequests == 1)
        #expect(probe.accessibilityRequests == 1)
        #expect(probe.fallbackTime == .zero)
        #expect(probe.elapsed == .milliseconds(100))
        #expect(probe.records == [.accepted(ActivationProbe.accessibilityDelivery)])
        #expect(probe.acceptanceCount == 1)
        #expect(probe.completionCount == 1)
        #expect(probe.events == ["identity", "validate", "native", "identity", "validate", "AX", "accept", "complete"])
    }

    @Test(arguments: [false, true], [false, true])
    func `unsettled requests time out within the original budget`(nativeAccepted: Bool, axAccepted: Bool) async {
        let probe = ActivationProbe()
        probe.nativeAccepted = nativeAccepted
        probe.accessibilityAccepted = axAccepted
        probe.accessibilitySettlementPoll = nil

        do {
            try await probe.run()
            Issue.record("Expected activation timeout")
        } catch FocusError.timeoutWaitingForCondition {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(probe.nativeRequests == 1)
        #expect(probe.accessibilityRequests == 1)
        #expect(probe.elapsed == .seconds(3))
        #expect(probe.fallbackTime == (nativeAccepted ? .seconds(1) : .zero))
        #expect(probe.records == self.expectedRecords(native: nativeAccepted, accessibility: axAccepted))
        #expect(probe.acceptanceCount == (nativeAccepted || axAccepted ? 1 : 0))
        #expect(probe.completionCount == 0)
    }

    @Test(arguments: [false, true])
    func `fallback can settle in the last remaining interval`(nativeAccepted: Bool) async throws {
        let probe = ActivationProbe()
        probe.nativeAccepted = nativeAccepted
        probe.accessibilitySettlementPoll = nativeAccepted ? 20 : 30

        try await probe.run()

        #expect(probe.elapsed == .seconds(3))
        #expect(probe.records == self.expectedRecords(native: nativeAccepted, accessibility: true))
        #expect(probe.acceptanceCount == 1)
        #expect(probe.completionCount == 1)
    }

    @Test(arguments: [false, true])
    func `settlement is honored even if AX reports declined`(nativeAccepted: Bool) async throws {
        let probe = ActivationProbe()
        probe.nativeAccepted = nativeAccepted
        probe.accessibilityAccepted = false

        try await probe.run()

        #expect(probe.accessibilityRequests == 1)
        #expect(probe.records == self.expectedRecords(native: nativeAccepted, accessibility: false))
        #expect(probe.acceptanceCount == (nativeAccepted ? 1 : 0))
        #expect(probe.completionCount == (nativeAccepted ? 1 : 0))
    }

    @Test(arguments: [false, true])
    func `ownership failure before fallback prevents AX`(nativeAccepted: Bool) async {
        let probe = ActivationProbe()
        probe.nativeAccepted = nativeAccepted
        probe.failValidationAt = 2

        await #expect(throws: ActivationProbeError.ownershipLost) { try await probe.run() }

        #expect(probe.validationCount == 2)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.records == self.expectedRecords(native: nativeAccepted, accessibility: false))
        #expect(probe.completionCount == 0)
    }

    @Test(arguments: [1, 2])
    func `identity is checked before each request`(failedCheck: Int) async {
        let probe = ActivationProbe()
        probe.failIdentityAt = failedCheck

        await #expect(throws: ActivationProbeError.identityChanged) { try await probe.run() }

        #expect(probe.identityChecks == failedCheck)
        #expect(probe.validationCount == failedCheck - 1)
        #expect(probe.nativeRequests == failedCheck - 1)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.records == self.expectedRecords(native: failedCheck == 2, accessibility: false))
        #expect(probe.completionCount == 0)
    }

    @Test(arguments: [1, 11])
    func `cancellation propagates from either wait without completion`(cancelledSleep: Int) async {
        let probe = ActivationProbe()
        probe.cancelAtSleep = cancelledSleep

        await #expect(throws: CancellationError.self) { try await probe.run() }

        #expect(probe.accessibilityRequests == (cancelledSleep == 11 ? 1 : 0))
        #expect(probe.records == self.expectedRecords(native: true, accessibility: cancelledSleep == 11))
        #expect(probe.acceptanceCount == 1)
        #expect(probe.completionCount == 0)
    }

    @Test
    func `initial guard rejection dispatches nothing`() async {
        let probe = ActivationProbe()
        probe.failValidationAt = 1

        await #expect(throws: ActivationProbeError.ownershipLost) { try await probe.run() }

        #expect(probe.nativeRequests == 0)
        #expect(probe.accessibilityRequests == 0)
        #expect(probe.records.isEmpty)
        #expect(probe.completionCount == 0)
    }

    @Test(arguments: [0, 11])
    func `accepted activation ownership remains validated in both waits`(failedAfterSleep: Int) async {
        let probe = ActivationProbe()
        probe.failSettlementAfterSleep = failedAfterSleep
        probe.accessibilitySettlementPoll = nil

        await #expect(throws: ActivationProbeError.ownershipLost) { try await probe.run() }

        #expect(probe.sleepCount == failedAfterSleep)
        #expect(probe.accessibilityRequests == (failedAfterSleep == 11 ? 1 : 0))
        #expect(probe.records == self.expectedRecords(native: true, accessibility: failedAfterSleep == 11))
        #expect(probe.completionCount == 0)
    }

    private func expectedRecords(native: Bool, accessibility: Bool) -> [FocusDispatchRecord] {
        (native ? [.accepted(ActivationProbe.nativeDelivery)] : []) +
            (accessibility ? [.accepted(ActivationProbe.accessibilityDelivery)] : [])
    }
}

@MainActor
private final class ActivationProbe {
    static let nativeDelivery = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
    static let accessibilityDelivery = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .foreground)

    var nativeAccepted = true
    var accessibilityAccepted = true
    var nativeSettlementPoll: Int?
    var accessibilitySettlementPoll: Int? = 1
    var settled = false
    var failValidationAt: Int?
    var failIdentityAt: Int?
    var cancelAtSleep: Int?
    var failSettlementAfterSleep: Int?
    var identityChecks = 0
    var validationCount = 0
    var acceptanceCount = 0
    var completionCount = 0
    var nativeRequests = 0
    var accessibilityRequests = 0
    var sleepCount = 0
    var accessibilitySleepCount = 0
    var elapsed = Duration.zero
    var fallbackTime: Duration?
    var records: [FocusDispatchRecord] = []
    var events: [String] = []

    func run() async throws {
        let dispatchGuard = FocusDispatchGuard(
            requiresStrictDispatchOwnership: true,
            validateOwnership: { stage in
                #expect(stage == .applicationActivation)
                self.validationCount += 1
                self.events.append("validate")
                if self.validationCount == self.failValidationAt {
                    throw ActivationProbeError.ownershipLost
                }
            },
            validateAcceptedActivation: {
                if self.sleepCount == self.failSettlementAfterSleep {
                    throw ActivationProbeError.ownershipLost
                }
            },
            acceptedDispatch: { stage in
                #expect(stage == .applicationActivation)
                self.acceptanceCount += 1
                self.events.append("accept")
                #expect(self.acceptanceCount == 1)
            },
            completeDispatch: { stage in
                #expect(stage == .applicationActivation)
                #expect(self.settled)
                self.completionCount += 1
                self.events.append("complete")
                #expect(self.completionCount == 1)
            })

        let activation = FocusApplicationActivation(
            nativeRequest: {
                self.nativeRequests += 1
                self.events.append("native")
                if self.nativeSettlementPoll == 0 {
                    self.settled = true
                }
                return self.nativeAccepted
            },
            accessibilityRequest: {
                self.accessibilityRequests += 1
                self.events.append("AX")
                self.fallbackTime = self.elapsed
                return self.accessibilityAccepted
            },
            isSettled: { self.settled },
            sleep: { duration in
                self.sleepCount += 1
                if self.sleepCount == self.cancelAtSleep {
                    throw CancellationError()
                }
                self.elapsed += duration
                if self.accessibilityRequests > 0 {
                    self.accessibilitySleepCount += 1
                    if self.accessibilitySleepCount == self.accessibilitySettlementPoll {
                        self.settled = true
                    }
                } else if self.sleepCount == self.nativeSettlementPoll {
                    self.settled = true
                }
            })
        try await activation.run(
            dispatchGuard: dispatchGuard,
            onDispatch: { self.records.append($0) },
            requireExpectedIdentity: {
                self.identityChecks += 1
                self.events.append("identity")
                if self.identityChecks == self.failIdentityAt {
                    throw ActivationProbeError.identityChanged
                }
            })
    }
}

private enum ActivationProbeError: Error, Equatable {
    case ownershipLost
    case identityChanged
}
