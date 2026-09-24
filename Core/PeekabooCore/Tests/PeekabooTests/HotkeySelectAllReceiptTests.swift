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

    @Test func `stable exact select all writes the resolved receiver once`() async throws {
        let fixture = ReceiverFixture()
        let result = try await fixture.run()

        #expect(fixture.resolverCalls == 1)
        #expect(fixture.textReceivers == [1])
        #expect(fixture.snapshotReceivers == [1])
        #expect(fixture.selections == [.init(receiver: 1, location: 0, length: 3)])
        #expect(fixture.postedEvents.isEmpty)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 1)
        #expect(!result.outcome.projection.retrySafe)
    }

    @Test(arguments: [false, true])
    func `focus changed after preflight cannot select a sibling receiver`(sameWindow: Bool) async throws {
        let fixture = ReceiverFixture()
        fixture.siblingWindowID = sameWindow ? 42 : 43
        fixture.siblingIdentifier = sameWindow ? "sibling-editor" : "editor"

        do {
            _ = try await fixture.run(deliveryValidator: {
                #expect(fixture.focusedReceiver == 1)
                fixture.preflightCalls += 1
                fixture.focusedReceiver = 2
            })
            Issue.record("Expected the resolved sibling to refuse before a selection write")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }

        #expect(fixture.preflightCalls == 1)
        #expect(fixture.resolverCalls == 1)
        #expect(fixture.snapshotReceivers == [2])
        #expect(fixture.textReceivers.isEmpty)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test func `changed noneditable receiver refuses before text eligibility`() async throws {
        let fixture = ReceiverFixture()
        fixture.siblingTextSupported = false

        do {
            _ = try await fixture.run(deliveryValidator: {
                #expect(fixture.focusedReceiver == 1)
                fixture.preflightCalls += 1
                fixture.focusedReceiver = 2
            })
            Issue.record("Expected the wrong window to refuse before checking text eligibility")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }

        #expect(fixture.preflightCalls == 1)
        #expect(fixture.resolverCalls == 1)
        #expect(fixture.receiverCalls == ["resolve", "snapshot:2"])
        #expect(fixture.textReceivers.isEmpty)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test func `exact window without a field pin still rejects another window`() async throws {
        let fixture = ReceiverFixture()
        fixture.pinsFocusedElement = false
        fixture.focusedReceiver = 2

        do {
            _ = try await fixture.run()
            Issue.record("Expected an unpinned exact window to reject the sibling window")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }

        #expect(fixture.resolverCalls == 1)
        #expect(fixture.receiverCalls == ["resolve", "snapshot:2"])
        #expect(fixture.textReceivers.isEmpty)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test func `exact window without a field pin allows another field in that window`() async throws {
        let fixture = ReceiverFixture()
        fixture.pinsFocusedElement = false
        fixture.focusedReceiver = 2
        fixture.siblingWindowID = 42
        fixture.siblingIdentifier = "sibling-editor"
        let result = try await fixture.run()

        #expect(fixture.resolverCalls == 1)
        #expect(fixture.receiverCalls == ["resolve", "snapshot:2", "text:2", "select:2"])
        #expect(fixture.selections == [.init(
            receiver: 2,
            location: 0,
            length: "Different sibling text".utf16.count)])
        #expect(fixture.postedEvents.isEmpty)
        #expect(result.outcome.state == .dispatchedUnverified)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 1)
    }

    @Test(arguments: [false, true])
    func `missing exact receiver refuses without keyboard fallback`(pinsFocusedElement: Bool) async throws {
        let fixture = ReceiverFixture()
        fixture.pinsFocusedElement = pinsFocusedElement
        fixture.focusedReceiver = nil

        do {
            _ = try await fixture.run()
            Issue.record("Expected a missing exact receiver to refuse before input")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }

        #expect(fixture.resolverCalls == 1)
        #expect(fixture.receiverCalls == ["resolve"])
        #expect(fixture.snapshotReceivers.isEmpty)
        #expect(fixture.textReceivers.isEmpty)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test func `unreadable resolved receiver snapshot refuses before selection`() async throws {
        let fixture = ReceiverFixture()
        fixture.snapshotReadable = false

        do {
            _ = try await fixture.run()
            Issue.record("Expected an unreadable receiver to refuse before a selection write")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }

        #expect(fixture.resolverCalls == 1)
        #expect(fixture.snapshotReceivers == [1])
        #expect(fixture.textReceivers.isEmpty)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.postedEvents.isEmpty)
    }

    @Test func `focus changes during text read cannot replace the retained selection receiver`() async throws {
        let fixture = ReceiverFixture()
        fixture.changeFocusDuringTextRead = true
        let result = try await fixture.run()

        #expect(fixture.focusedReceiver == 2)
        #expect(fixture.resolverCalls == 1)
        #expect(fixture.textReceivers == [1])
        #expect(fixture.snapshotReceivers == [1])
        #expect(fixture.receiverCalls == ["resolve", "snapshot:1", "text:1", "select:1"])
        #expect(fixture.selections == [.init(receiver: 1, location: 0, length: 3)])
        #expect(fixture.postedEvents.isEmpty)
        #expect(result.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(result.outcome.dispatchState.unitCount?.rawValue == 1)
    }

    @Test func `text receiver continuation permits in-window reflow but initial validation stays strict`() throws {
        let expectedFocus = ReceiverFixture().focusedIdentity
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: getpid(),
                ownerProcessStartIdentity: 812),
            bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
            focusedElement: expectedFocus)
        let movedReceiver = ExactWindowFocusSnapshot(
            processIdentifier: getpid(),
            windowID: 42,
            frame: CGRect(x: 30, y: 30, width: 150, height: 30),
            role: expectedFocus.role,
            identifier: expectedFocus.identifier)

        #expect(throws: DesktopActionFailure.self) {
            try BackgroundInputDriver.validateExactWindowTextReceiver(movedReceiver, exactWindow: exactWindow)
        }
        try BackgroundInputDriver.validateExactWindowTextReceiver(
            movedReceiver,
            exactWindow: exactWindow,
            phase: .continuation)
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
                focusedTextHotkey: { key, modifiers, pid, _ in
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

    @MainActor
    private final class ReceiverFixture {
        struct Selection: Equatable {
            let receiver: Int
            let location: Int
            let length: Int
        }

        var focusedReceiver: Int? = 1
        var pinsFocusedElement = true
        var siblingWindowID = 43
        var siblingIdentifier = "editor"
        var siblingTextSupported = true
        var snapshotReadable = true
        var changeFocusDuringTextRead = false
        var preflightCalls = 0
        var resolverCalls = 0
        var receiverCalls: [String] = []
        var textReceivers: [Int] = []
        var snapshotReceivers: [Int] = []
        var selections: [Selection] = []
        var postedEvents: [CGEventType] = []

        var focusedIdentity: FocusedElementIdentity {
            FocusedElementIdentity(
                processIdentifier: getpid(),
                windowID: 42,
                role: "AXTextField",
                identifier: "editor",
                frame: CGRect(x: 20, y: 20, width: 150, height: 30))
        }

        func run(
            deliveryValidator: (@MainActor @Sendable () async throws -> Void)? = nil) async throws
            -> UIInputExecutionResult
        {
            let service = HotkeyService(
                focusedTextHotkey: { key, modifiers, pid, exactWindow in
                    #expect(pid == getpid())
                    #expect(exactWindow?.identity.windowID == 42)
                    let expectedFocus = self.pinsFocusedElement ? self.focusedIdentity : nil
                    #expect(exactWindow?.focusedElement == expectedFocus)
                    return try BackgroundInputDriver.performFocusedTextHotkey(
                        primaryKey: key,
                        modifierFlags: modifiers,
                        exactWindow: exactWindow,
                        access: .init(
                            focusedElement: {
                                self.resolverCalls += 1
                                self.receiverCalls.append("resolve")
                                return self.focusedReceiver
                            },
                            textValue: { receiver in
                                self.textReceivers.append(receiver)
                                self.receiverCalls.append("text:\(receiver)")
                                if self.changeFocusDuringTextRead {
                                    self.focusedReceiver = 2
                                }
                                guard receiver != 2 || self.siblingTextSupported else { return nil }
                                return receiver == 1 ? "A🙂" : "Different sibling text"
                            },
                            focusSnapshot: { receiver in
                                self.snapshotReceivers.append(receiver)
                                self.receiverCalls.append("snapshot:\(receiver)")
                                guard self.snapshotReadable else { return nil }
                                return ExactWindowFocusSnapshot(
                                    processIdentifier: getpid(),
                                    windowID: receiver == 1 ? 42 : self.siblingWindowID,
                                    frame: self.focusedIdentity.frame,
                                    role: self.focusedIdentity.role,
                                    identifier: receiver == 1 ? "editor" : self.siblingIdentifier)
                            },
                            selectRange: { range, receiver in
                                self.receiverCalls.append("select:\(receiver)")
                                self.selections.append(Selection(
                                    receiver: receiver,
                                    location: range.location,
                                    length: range.length))
                                return true
                            }))
                },
                postEventAccessEvaluator: { true },
                eventPoster: { event, _ in self.postedEvents.append(event.type) },
                runningApplicationResolver: { _ in NSRunningApplication.current },
                processStartIdentityProvider: { _ in 812 },
                holdSleeper: { _ in },
                heldInterEventDelay: {})
            let target = try UIAutomationTarget.exactWindow(.init(
                identity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: getpid(),
                    ownerProcessStartIdentity: 812),
                bounds: CGRect(x: 0, y: 0, width: 300, height: 200),
                focusedElement: self.pinsFocusedElement ? self.focusedIdentity : nil))
            return try await service.hotkey(
                keys: "cmd,a",
                holdDuration: 50,
                automationTarget: target,
                deliveryValidator: deliveryValidator)
        }
    }
}
