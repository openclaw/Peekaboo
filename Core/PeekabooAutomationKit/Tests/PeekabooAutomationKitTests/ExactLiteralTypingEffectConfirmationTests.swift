import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ExactLiteralTypingEffectConfirmationTests {
    @Test
    func `clear plus printable literal confirms only exact background readback`() throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("MAIN_BG_20260825")],
            target: self.target()))
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)

        let confirmed = confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "",
            observedValue: "MAIN_BG_20260825")
        let mismatch = confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "",
            observedValue: "")

        #expect(confirmed.state == .confirmedChange)
        #expect(confirmed.delivery == dispatched.delivery)
        #expect(confirmed.dispatchState == dispatched.dispatchState)
        #expect(mismatch == dispatched)
    }

    @Test
    func `printable Unicode confirmation uses exact AXValue equality without normalization`() throws {
        let precomposed = "caf\u{00E9} 🦞"
        let decomposed = "cafe\u{0301} 🦞"
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text(precomposed)],
            target: self.target()))
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "old",
            observedValue: precomposed).state == .confirmedChange)
        #expect(confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "old",
            observedValue: decomposed) == dispatched)
    }

    @Test
    func `clear-only supports a confirmed empty readback`() throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear],
            target: self.target()))
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted)

        #expect(confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "not empty",
            observedValue: "").state == .confirmedChange)
        #expect(confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "",
            observedValue: "") == dispatched)
    }

    @Test(arguments: [
        [TypeAction.text("text without clear")],
        [.clear, .key(.return)],
        [.clear, .text("line\nbreak")],
        [.clear, .text("tab\tvalue")],
    ])
    func `selection-dependent and special-key shapes remain unverifiable`(_ actions: [TypeAction]) throws {
        #expect(try ExactLiteralTypingEffectConfirmation.plan(actions: actions, target: self.target()) == nil)
    }

    @Test
    func `secure and value-less focus never confirms`() throws {
        let secureTarget = try self.target(role: "AXSecureTextField")
        #expect(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("secret")],
            target: secureTarget) == nil)

        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        #expect(confirmation.readableValue(from: .success(ExactWindowFocusSnapshot(
            processIdentifier: 333,
            windowID: 42,
            frame: CGRect(x: 20, y: 20, width: 200, height: 30),
            role: "AXTextField",
            subrole: "AXSecureTextField",
            identifier: "editor",
            value: "masked"))) == nil)
        #expect(!DetachedExactWindowFocusReader.allowsValueRead(role: "AXSecureTextField", subrole: nil))
        #expect(!DetachedExactWindowFocusReader.allowsValueRead(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    @Test
    func `wrong delivery never promotes even when value matches`() throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        let foreground = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)

        #expect(confirmation.confirmedOutcome(
            from: foreground,
            previousValue: "old",
            observedValue: "safe") == foreground)
    }

    @Test
    func `already equal value never proves that typing changed the field`() throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "safe",
            observedValue: "safe") == dispatched)
    }

    @Test
    func `post-read failure and mismatch preserve dispatched evidence byte-for-byte`() throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(7))
        let mismatch = confirmation.confirmedOutcome(
            from: dispatched,
            previousValue: "old",
            observedValue: "different")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        #expect(confirmation.readableValue(from: .failure(.focusedAttributeUnreadable)) == nil)
        #expect(mismatch == dispatched)
        #expect(try encoder.encode(mismatch) == encoder.encode(dispatched))
        #expect(mismatch.evidence == .deliveryAccepted)
        #expect(mismatch.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(7))
    }

    @Test
    @MainActor
    func `value readback is rejected when the process generation changes around it`() async throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        let generations = TypingGenerationSequence([33, 34])
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            exactFocusedElementValueReader: { focusedElement in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: focusedElement.processIdentifier,
                    windowID: focusedElement.windowID,
                    frame: focusedElement.frame,
                    role: focusedElement.role,
                    identifier: focusedElement.identifier,
                    value: "safe"))
            },
            processStartIdentityProvider: { _ in generations.next() })

        #expect(await service.exactFocusedValue(for: confirmation) == nil)
        #expect(generations.readCount == 2)
    }

    @Test
    @MainActor
    func `value readback survives an unchanged exact process generation`() async throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            exactFocusedElementValueReader: { focusedElement in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: focusedElement.processIdentifier,
                    windowID: focusedElement.windowID,
                    frame: focusedElement.frame,
                    role: focusedElement.role,
                    identifier: focusedElement.identifier,
                    value: "safe"))
            },
            processStartIdentityProvider: { _ in 33 })

        #expect(await service.exactFocusedValue(for: confirmation) == "safe")
    }

    @Test
    @MainActor
    func `effect baseline is sampled after lane preparation`() async throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear, .text("safe")],
            target: self.target()))
        let value = TypingLockedValue("before preparation")
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            exactFocusedElementValueReader: { focusedElement in
                .success(ExactWindowFocusSnapshot(
                    processIdentifier: focusedElement.processIdentifier,
                    windowID: focusedElement.windowID,
                    frame: focusedElement.frame,
                    role: focusedElement.role,
                    identifier: focusedElement.identifier,
                    value: value.get()))
            },
            processStartIdentityProvider: { _ in 33 })

        let baseline = await service.prepareEffectConfirmationBaseline(confirmation) {
            value.set("after preparation")
        }

        #expect(baseline == "after preparation")
    }

    @Test
    @MainActor
    func `delayed event settlement confirms within the bounded readback window`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before")
        let clock = TypingEffectPollClock { sleepCount in
            if sleepCount == 1 {
                value.set("safe")
            }
        }
        let service = self.eventFallbackService(
            value: value,
            timing: clock.timing(),
            valueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(summary.executionResult.outcome.state == .confirmedChange)
        #expect(summary.executionResult.outcome.delivery == .init(
            mechanism: .composite,
            mode: .background))
        #expect(clock.sleepCount == 1)
    }

    @Test
    @MainActor
    func `mismatched event readback stops at the monotonic deadline`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before")
        let clock = TypingEffectPollClock()
        let service = self.eventFallbackService(
            value: value,
            timing: clock.timing(),
            valueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(summary.executionResult.outcome.state == .dispatchedUnverified)
        #expect(clock.sleepCount == 3)
        #expect(clock.elapsed == .milliseconds(60))
    }

    @Test
    @MainActor
    func `settlement samples receive only their remaining monotonic budget`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before")
        let clock = TypingEffectPollClock()
        let observedTimeouts = TypingLockedValue<[Duration]>([])
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            },
            targetedTextReplacer: { text, _ in
                value.set(text)
                return true
            },
            exactFocusedElementValueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            },
            exactFocusedValueRunner: { _, _, timeout, operation in
                observedTimeouts.update { $0.append(timeout) }
                return operation()
            },
            processStartIdentityProvider: { _ in 33 },
            effectConfirmationTiming: clock.timing())

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(summary.executionResult.outcome.state == .dispatchedUnverified)
        #expect(observedTimeouts.get() == [
            .milliseconds(200),
            .milliseconds(60),
            .milliseconds(40),
            .milliseconds(20),
        ])
    }

    @Test
    @MainActor
    func `generation drift during event settlement stops polling without promotion`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before")
        let clock = TypingEffectPollClock()
        let generations = TypingGenerationSequence([33, 33, 33, 33, 34])
        let service = self.eventFallbackService(
            value: value,
            timing: clock.timing(),
            valueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            },
            processStartIdentityProvider: { _ in generations.next() })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(summary.executionResult.outcome.state == .dispatchedUnverified)
        #expect(clock.sleepCount == 1)
        #expect(generations.readCount == 5)
    }

    @Test
    @MainActor
    func `focused element drift during event settlement stops polling without promotion`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before")
        let clock = TypingEffectPollClock()
        let readCount = TypingLockedCounter()
        let service = self.eventFallbackService(
            value: value,
            timing: clock.timing(),
            valueReader: { focusedElement in
                switch readCount.next() {
                case 1:
                    .success(Self.focusSnapshot(focusedElement, value: "before"))
                case 2:
                    .success(Self.focusSnapshot(focusedElement, value: "mismatch"))
                default:
                    .failure(.identifierMismatch)
                }
            })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(summary.executionResult.outcome.state == .dispatchedUnverified)
        #expect(clock.sleepCount == 1)
        #expect(readCount.value == 3)
    }

    @Test
    @MainActor
    func `cancelled event settlement never promotes a matching future value`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before")
        let clock = TypingEffectPollClock { _ in throw CancellationError() }
        let service = self.eventFallbackService(
            value: value,
            timing: clock.timing(),
            valueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(summary.executionResult.outcome.state == .dispatchedUnverified)
        #expect(clock.sleepCount == 1)
    }

    @Test
    @MainActor
    func `full exact literal pipeline confirms only the typing leaf value transition`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before preparation")
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, _ in
                value.set(value.get() + String(character))
                return .dispatched(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background),
                    keyPressCount: 0)
            },
            targetedTextReplacer: { text, _ in
                value.set(text)
                return true
            },
            exactFocusedElementValueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            },
            processStartIdentityProvider: { _ in 33 })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {},
            lanePreparation: { value.set("after preparation") })

        #expect(value.get() == "safe")
        #expect(summary.executionResult.outcome.state == .confirmedChange)
        #expect(summary.executionResult.outcome.delivery == .init(
            mechanism: .accessibilityValue,
            mode: .background))
        #expect(summary.executionResult.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(5))
        #expect(summary.result.totalCharacters == 4)
        #expect(summary.result.keyPresses == 0)
        #expect(summary.result.specialKeyPresses == 0)
    }

    @Test
    @MainActor
    func `direct clear reports one accessibility write and zero key presses`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("occupied")
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedTextReplacer: { text, _ in
                value.set(text)
                return true
            },
            exactFocusedElementValueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            },
            processStartIdentityProvider: { _ in 33 })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {})

        #expect(value.get().isEmpty)
        #expect(summary.executionResult.outcome.state == .confirmedChange)
        #expect(summary.executionResult.outcome.delivery == .init(
            mechanism: .accessibilityValue,
            mode: .background))
        #expect(summary.executionResult.outcome.dispatchState.unitCount == .one)
        #expect(summary.result.totalCharacters == 0)
        #expect(summary.result.keyPresses == 0)
        #expect(summary.result.specialKeyPresses == 0)
    }

    @Test
    @MainActor
    func `failure after direct clear preserves its accumulated delivery prefix`() async throws {
        let target = try self.target()
        let cases: [(failOnCharacter: Int, units: Int, mechanism: DesktopActionOutcome.Delivery.Mechanism)] = [
            (1, 1, .accessibilityValue),
            (2, 2, .accessibilityValue),
        ]

        for testCase in cases {
            var characterCalls = 0
            let service = TypeService(
                randomSource: SystemTypingCadenceRandomSource(),
                focusedElementSecurityProbe: { _ in false },
                targetedCharacterTyper: { _, _, _ in
                    characterCalls += 1
                    if characterCalls == testCase.failOnCharacter {
                        throw TypingEffectFixtureError.characterDispatchFailed
                    }
                    return .dispatched(
                        delivery: .init(mechanism: .accessibilityValue, mode: .background),
                        keyPressCount: 0)
                },
                targetedTextReplacer: { _, _ in true },
                processStartIdentityProvider: { _ in 33 })

            do {
                _ = try await service.typeActionsTrackingSecureInput(
                    [.clear, .text("xy")],
                    cadence: .fixed(milliseconds: 0),
                    snapshotId: nil,
                    automationTarget: .exactWindow(target),
                    deliveryValidator: {})
                Issue.record("Expected the configured character failure")
            } catch let error as InputDeliveryIndeterminateError {
                #expect(error.emittedUnitCount == testCase.units)
                #expect(error.delivery == .init(mechanism: testCase.mechanism, mode: .background))
                let fallback = DesktopActionOutcome.Delivery(
                    mechanism: .windowTargetedEvents,
                    mode: .background)
                #expect(error.desktopActionFailure(delivery: fallback).outcome.delivery == error.delivery)
            }
        }
    }

    @Test
    @MainActor
    func `fallback clear validation failure retains the accepted select-all delivery`() async throws {
        var validationCalls = 0
        let service = TypeService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            syntheticInputDriver: ClickRecordingSyntheticInputDriver(),
            randomSource: SystemTypingCadenceRandomSource())

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.clear],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                automationTarget: .foreground,
                deliveryValidator: {
                    validationCalls += 1
                    if validationCalls == 2 {
                        throw TypingEffectFixtureError.deliveryValidationFailed
                    }
                })
            Issue.record("Expected validation failure after Cmd+A")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(error.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        }
    }

    @Test
    @MainActor
    func `full exact literal pipeline rejects setup-only change when typing is dropped`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before preparation")
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, _ in .noChange },
            targetedTextReplacer: { _, _ in true },
            exactFocusedElementValueReader: { focusedElement in
                .success(Self.focusSnapshot(focusedElement, value: value.get()))
            },
            processStartIdentityProvider: { _ in 33 })

        let summary = try await service.typeActionsTrackingSecureInput(
            [.clear, .text("safe")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            automationTarget: .exactWindow(target),
            deliveryValidator: {},
            lanePreparation: { value.set("safe") })

        #expect(value.get() == "safe")
        #expect(summary.executionResult.outcome.state == .dispatchedUnverified)
        #expect(summary.executionResult.outcome.delivery == .init(
            mechanism: .accessibilityValue,
            mode: .background))
        #expect(summary.executionResult.outcome.dispatchState.unitCount == .one)
        #expect(summary.result.keyPresses == 0)
        #expect(summary.result.specialKeyPresses == 0)
    }

    private func target(
        role: String = "AXTextField",
        processIdentifier: pid_t = 333) throws -> UIAutomationTarget.ExactWindow
    {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 33,
            capturedBounds: bounds)
        return try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds,
            focusedElement: FocusedElementIdentity(
                processIdentifier: processIdentifier,
                windowID: 42,
                role: role,
                identifier: "editor",
                frame: CGRect(x: 20, y: 20, width: 200, height: 30)))
    }

    @MainActor
    private func eventFallbackService(
        value: TypingLockedValue<String>,
        timing: ExactLiteralTypingEffectConfirmationTiming,
        valueReader: @escaping @Sendable (FocusedElementIdentity)
            -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64? = { _ in 33 }) -> TypeService
    {
        TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, delivery in
                .dispatched(delivery: delivery, keyPressCount: 1)
            },
            targetedTextReplacer: { text, _ in
                value.set(text)
                return true
            },
            exactFocusedElementValueReader: valueReader,
            processStartIdentityProvider: processStartIdentityProvider,
            effectConfirmationTiming: timing)
    }

    private static func focusSnapshot(
        _ focusedElement: FocusedElementIdentity,
        value: String) -> ExactWindowFocusSnapshot
    {
        ExactWindowFocusSnapshot(
            processIdentifier: focusedElement.processIdentifier,
            windowID: focusedElement.windowID,
            frame: focusedElement.frame,
            role: focusedElement.role,
            identifier: focusedElement.identifier,
            value: value)
    }
}

private enum TypingEffectFixtureError: Error {
    case characterDispatchFailed
    case deliveryValidationFailed
}

private final class TypingGenerationSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var generations: [UInt64?]
    private var storedReadCount = 0

    var readCount: Int {
        self.lock.withLock { self.storedReadCount }
    }

    init(_ generations: [UInt64?]) {
        self.generations = generations
    }

    func next() -> UInt64? {
        self.lock.withLock {
            self.storedReadCount += 1
            guard self.generations.count > 1 else { return self.generations.first.flatMap(\.self) }
            return self.generations.removeFirst()
        }
    }
}

private final class TypingLockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        self.lock.withLock { self.value }
    }

    func set(_ value: Value) {
        self.lock.withLock { self.value = value }
    }

    func update(_ body: (inout Value) -> Void) {
        self.lock.withLock { body(&self.value) }
    }
}

private final class TypingLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        self.lock.withLock { self.storedValue }
    }

    func next() -> Int {
        self.lock.withLock {
            self.storedValue += 1
            return self.storedValue
        }
    }
}

@MainActor
private final class TypingEffectPollClock {
    private let start = ContinuousClock.now
    private var instant: ContinuousClock.Instant
    private let onSleep: @MainActor (Int) throws -> Void
    private(set) var sleepCount = 0

    var elapsed: Duration {
        self.start.duration(to: self.instant)
    }

    init(onSleep: @escaping @MainActor (Int) throws -> Void = { _ in }) {
        self.instant = self.start
        self.onSleep = onSleep
    }

    func timing() -> ExactLiteralTypingEffectConfirmationTiming {
        .init(
            timeout: .milliseconds(60),
            interval: .milliseconds(20),
            maximumSampleCount: 8,
            now: { self.instant },
            sleep: { duration in
                self.sleepCount += 1
                self.instant = self.instant.advanced(by: duration)
                try self.onSleep(self.sleepCount)
            })
    }
}
