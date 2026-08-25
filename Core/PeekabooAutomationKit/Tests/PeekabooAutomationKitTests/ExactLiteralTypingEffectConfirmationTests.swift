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
            observedValue: "MAIN_BG_20260825")
        let mismatch = confirmation.confirmedOutcome(
            from: dispatched,
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

        #expect(confirmation.confirmedOutcome(from: dispatched, observedValue: precomposed).state == .confirmedChange)
        #expect(confirmation.confirmedOutcome(from: dispatched, observedValue: decomposed) == dispatched)
    }

    @Test
    func `clear-only supports a confirmed empty readback`() throws {
        let confirmation = try #require(ExactLiteralTypingEffectConfirmation.plan(
            actions: [.clear],
            target: self.target()))
        let dispatched = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted)

        #expect(confirmation.confirmedOutcome(from: dispatched, observedValue: "").state == .confirmedChange)
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

        #expect(confirmation.confirmedOutcome(from: foreground, observedValue: "safe") == foreground)
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
        let mismatch = confirmation.confirmedOutcome(from: dispatched, observedValue: "different")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        #expect(confirmation.readableValue(from: .failure(.focusedAttributeUnreadable)) == nil)
        #expect(mismatch == dispatched)
        #expect(try encoder.encode(mismatch) == encoder.encode(dispatched))
        #expect(mismatch.evidence == .deliveryAccepted)
        #expect(mismatch.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(7))
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
}
