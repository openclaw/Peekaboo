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
    func `full exact literal pipeline confirms only the typing leaf value transition`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before preparation")
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _ in value.set(value.get() + String(character)) },
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
        #expect(summary.result.totalCharacters == 4)
    }

    @Test
    @MainActor
    func `full exact literal pipeline rejects setup-only change when typing is dropped`() async throws {
        let target = try self.target()
        let value = TypingLockedValue("before preparation")
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _ in },
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
    }

    private func target(role: String = "AXTextField") throws -> UIAutomationTarget.ExactWindow {
        let bounds = CGRect(x: 0, y: 0, width: 500, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 333,
            ownerProcessStartIdentity: 33,
            capturedBounds: bounds)
        return try UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds,
            focusedElement: FocusedElementIdentity(
                processIdentifier: 333,
                windowID: 42,
                role: role,
                identifier: "editor",
                frame: CGRect(x: 20, y: 20, width: 200, height: 30)))
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
}
