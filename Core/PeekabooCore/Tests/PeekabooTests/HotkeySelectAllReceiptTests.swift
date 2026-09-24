import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct HotkeySelectAllReceiptTests {
    @Test func `default focused select all reports its accepted value mutation`() async throws {
        let fixture = Fixture()
        let result = try await fixture.service().hotkey(
            keys: "cmd,a",
            holdDuration: 50,
            automationTarget: fixture.target())

        #expect(fixture.selectionAttempts == 1)
        #expect(fixture.postedEvents.isEmpty)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(!result.outcome.projection.retrySafe)
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .notImplemented, .illegalArgument, .noValue])
    func `uncertain selection writes stop without keyboard replay`(error: AXError) async throws {
        let fixture = Fixture()
        fixture.selectionError = error

        do {
            _ = try await fixture.service().hotkey(
                keys: "cmd,a",
                holdDuration: 50,
                automationTarget: fixture.target())
            Issue.record("Expected indeterminate selection write")
        } catch let failure as InputDeliveryIndeterminateError {
            #expect(failure.operation == .hotkey)
            #expect(failure.delivery?.mechanism == .accessibilityValue)
            #expect(!failure.retrySafe)
        }

        #expect(fixture.selectionAttempts == 1)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test(arguments: [AXError.apiDisabled, .invalidUIElement, .invalidUIElementObserver])
    func `selection permission and stale receiver errors refuse without replay`(error: AXError) async throws {
        let fixture = Fixture()
        fixture.selectionError = error

        do {
            _ = try await fixture.service().hotkey(
                keys: "cmd,a",
                holdDuration: 50,
                automationTarget: fixture.target())
            Issue.record("Expected pre-dispatch selection refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }

        #expect(fixture.selectionAttempts == 1)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test(arguments: [AXError.attributeUnsupported, .parameterizedAttributeUnsupported, .actionUnsupported])
    func `definite unsupported selection preserves the existing event fallback`(error: AXError) async throws {
        let fixture = Fixture()
        fixture.selectionError = error
        let result = try await fixture.service().hotkey(
            keys: "cmd,a",
            holdDuration: 50,
            automationTarget: fixture.target())

        #expect(fixture.selectionAttempts == 1)
        #expect(fixture.postedEvents == [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        #expect(result.outcome.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(result.outcome.state == .dispatchedUnverified)
    }

    @Test func `focused receiver drift refuses before selecting or posting`() async throws {
        let fixture = Fixture()
        await #expect(throws: PeekabooError.self) {
            _ = try await fixture.service().hotkey(
                keys: "cmd,a",
                holdDuration: 50,
                automationTarget: fixture.target(),
                deliveryValidator: { throw PeekabooError.snapshotStale("Focused receiver changed") })
        }
        #expect(fixture.selectionAttempts == 0)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test(arguments: ["cmd,a", "command+a", "meta a", "command + a", "cmdOrCtrl,a"])
    func `normalized select all preserves its exact value receipt`(keys: String) throws {
        let receipt = Self.receipt(.accessibilityValue)
        #expect(try ExactWindowKeyboardRuntime.validateHotkeyRouteReceipt(
            receipt,
            keys: keys,
            operation: "Select all").outcome == receipt.outcome)
    }

    @Test(arguments: ["a", "cmd,l", "cmd,shift,a", "ctrl,a", "cmd,a,b", "", ","])
    func `other or malformed chords cannot claim a selection receipt`(keys: String) {
        #expect(throws: DesktopActionFailure.self) {
            try ExactWindowKeyboardRuntime.validateHotkeyRouteReceipt(
                Self.receipt(.accessibilityValue),
                keys: keys,
                operation: "Other chord")
        }
    }

    @Test(arguments: [
        DesktopActionOutcome.Delivery.Mechanism.accessibilityAction, .composite,
        .processTargetedEvents, .globalEvents, .clipboardTransaction, .nativeFramework,
        .browserProtocol, .capturePipeline,
    ])
    func `select all cannot disguise a broader route as exact value delivery`(
        mechanism: DesktopActionOutcome.Delivery.Mechanism)
    {
        #expect(throws: DesktopActionFailure.self) {
            try ExactWindowKeyboardRuntime.validateHotkeyRouteReceipt(
                Self.receipt(mechanism),
                keys: "cmd,a",
                operation: "Select all")
        }
    }

    @Test(arguments: [
        DesktopActionOutcome.Delivery.Mechanism.windowTargetedEvents, .accessibilityValue, .accessibilityAction,
    ])
    func `select all cannot accept foreground delivery`(mechanism: DesktopActionOutcome.Delivery.Mechanism) {
        #expect(throws: DesktopActionFailure.self) {
            try ExactWindowKeyboardRuntime.validateHotkeyRouteReceipt(
                Self.receipt(mechanism, mode: .foreground),
                keys: "cmd,a",
                operation: "Select all")
        }
    }

    @Test(arguments: ["cmd,a", "cmd,l", "shift,tab"])
    func `exact background events remain valid for every chord`(keys: String) throws {
        let receipt = Self.receipt(.windowTargetedEvents)
        #expect(try ExactWindowKeyboardRuntime.validateHotkeyRouteReceipt(
            receipt,
            keys: keys,
            operation: "Exact hotkey").outcome == receipt.outcome)
    }

    @Test(arguments: [false, true], [
        DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .background),
        .init(mechanism: .processTargetedEvents, mode: .background),
        .init(mechanism: .globalEvents, mode: .foreground),
        .init(mechanism: .windowTargetedEvents, mode: .foreground),
        .init(mechanism: .accessibilityValue, mode: .foreground),
        .init(mechanism: .composite, mode: .foreground),
    ])
    func `existing type and paste policies still reject unrelated delivery`(
        allowsCompositeTypeDelivery: Bool,
        delivery: DesktopActionOutcome.Delivery)
    {
        #expect(throws: DesktopActionFailure.self) {
            try ExactWindowKeyboardRuntime.validateRouteReceipt(
                Self.receipt(delivery.mechanism, mode: delivery.mode),
                operation: "Existing keyboard route",
                allowsCompositeTypeDelivery: allowsCompositeTypeDelivery)
        }
    }

    @Test func `composite type permission does not leak into ordinary keyboard or paste validation`() throws {
        for mechanism in [DesktopActionOutcome.Delivery.Mechanism.accessibilityValue, .composite] {
            let receipt = Self.receipt(mechanism)
            #expect(throws: DesktopActionFailure.self) {
                try ExactWindowKeyboardRuntime.validateRouteReceipt(receipt, operation: "Exact paste")
            }
            #expect(try ExactWindowKeyboardRuntime.validateRouteReceipt(
                receipt,
                operation: "Composite typing",
                allowsCompositeTypeDelivery: true).outcome == receipt.outcome)
        }
    }

    private static func receipt(
        _ mechanism: DesktopActionOutcome.Delivery.Mechanism,
        mode: DesktopActionOutcome.Delivery.Mode = .background) -> UIAutomationActionResult<Int>
    {
        UIAutomationActionResult(
            payload: 1,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: mechanism, mode: mode),
                evidence: .deliveryAccepted,
                unitCount: .one))
    }

    @MainActor
    private final class Fixture {
        var selectionAttempts = 0
        var selectionError = AXError.success
        var postedEvents: [CGEventType] = []

        func service() -> HotkeyService {
            HotkeyService(
                focusedTextHotkey: { key, modifiers, pid in
                    #expect(key == "a")
                    #expect(modifiers == .maskCommand)
                    #expect(pid == getpid())
                    self.selectionAttempts += 1
                    return try BackgroundInputDriver.textMutationAccepted(self.selectionError, operation: .hotkey)
                },
                postEventAccessEvaluator: { true },
                eventPoster: { event, _ in self.postedEvents.append(event.type) },
                runningApplicationResolver: { _ in NSRunningApplication.current },
                processStartIdentityProvider: { _ in 812 },
                holdSleeper: { _ in },
                heldInterEventDelay: {})
        }

        func target() throws -> UIAutomationTarget {
            try .exactWindow(.init(
                identity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: getpid(),
                    ownerProcessStartIdentity: 812),
                bounds: CGRect(x: 0, y: 0, width: 300, height: 200)))
        }
    }
}
