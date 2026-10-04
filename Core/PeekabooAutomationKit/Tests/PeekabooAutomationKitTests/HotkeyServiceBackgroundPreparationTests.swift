import AppKit
import Darwin
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct HotkeyServiceBackgroundPreparationTests {
    @Test
    func `prepared receipt policy preserves honest prefixes without widening keyboard or type routes`() throws {
        for count: Int? in [nil, 1, 2, 4, 8, 9] {
            for mechanism: DesktopActionOutcome.Delivery.Mechanism in [
                .nativeFramework,
                .composite,
                .windowTargetedEvents,
                .accessibilityValue,
            ] {
                let outcome = DesktopActionOutcome.indeterminate(
                    delivery: .init(mechanism: mechanism, mode: .background),
                    evidence: .completionUnknown,
                    unitCount: count.flatMap { .init($0) })
                let result = UIAutomationActionResult(payload: (), outcome: outcome)
                let allowed = (mechanism == .nativeFramework && (count == nil || count == 1)) ||
                    (mechanism == .composite && (count.map { (2...8).contains($0) } ?? true))
                if allowed {
                    let validated = try ExactWindowKeyboardRuntime.validatePreparedPasteReceipt(
                        result,
                        operation: "test")
                    #expect(validated.outcome == outcome)
                } else {
                    #expect(throws: DesktopActionFailure.self) {
                        try ExactWindowKeyboardRuntime.validatePreparedPasteReceipt(result, operation: "test")
                    }
                }
                if mechanism == .composite {
                    #expect(throws: DesktopActionFailure.self) {
                        try ExactWindowKeyboardRuntime.validateRouteReceipt(result, operation: "legacy")
                    }
                }
            }
        }
    }

    @Test
    func `overflowing hold refuses before any preparation or input`() async throws {
        var preparations = 0
        var events = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in events += 1 },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { 11 },
            backgroundWindowPreparer: { _, _ in preparations += 1; return Self.preparedOutcome })
        await #expect(throws: PeekabooError.self) {
            try await service.hotkey(
                keys: "cmd,v",
                holdDuration: Int.max,
                automationTarget: Self.target(),
                clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
                prepareBackgroundWindow: true)
        }
        #expect(preparations == 0)
        #expect(events == 0)
    }

    @Test
    func `prepared paste runs inside one lane and reports eight composite units`() async throws {
        var prepared = false
        var events = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in events += 1 },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { 11 },
            holdSleeper: { _ in },
            heldInterEventDelay: {},
            backgroundWindowPreparer: { _, validate in
                try validate()
                #expect(events == 0)
                prepared = true
                return Self.preparedOutcome
            })
        let result = try await service.hotkey(
            keys: "cmd,v",
            holdDuration: 50,
            automationTarget: Self.target(),
            clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
            prepareBackgroundWindow: true,
            deliveryValidator: { #expect(prepared) })
        #expect(events == 4)
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 8)
        #expect(result.outcome?.retrySafety == .unsafe)
    }

    @Test
    func `ordinary guarded paste never prepares and keeps four unit contract`() async throws {
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { 11 },
            holdSleeper: { _ in },
            heldInterEventDelay: {},
            backgroundWindowPreparer: { _, _ in Issue.record("Unexpected preparation"); return Self.preparedOutcome })
        let result = try await service.hotkey(
            keys: "cmd,v",
            holdDuration: 50,
            automationTarget: Self.target(),
            clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11))
        #expect(result.outcome?.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 4)
    }

    @Test(arguments: [true, false])
    func `actionOnly and superseded claims refuse before preparation`(actionOnly: Bool) async throws {
        var preparations = 0
        var events = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: actionOnly ? .actionOnly : .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in events += 1 },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { actionOnly ? 11 : 12 },
            backgroundWindowPreparer: { _, _ in preparations += 1; return Self.preparedOutcome })
        await #expect(throws: DesktopActionFailure.self) {
            try await service.hotkey(
                keys: "cmd,v",
                holdDuration: 50,
                automationTarget: Self.target(),
                clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
                prepareBackgroundWindow: true)
        }
        #expect(preparations == 0)
        #expect(events == 0)
    }

    @Test
    func `refused final focus retains preparation prefix and sends no keys`() async throws {
        var events = 0
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { _, _ in events += 1 },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { 11 },
            backgroundWindowPreparer: { _, validate in try validate(); return Self.preparedOutcome })
        do {
            _ = try await service.hotkey(
                keys: "cmd,v",
                holdDuration: 50,
                automationTarget: Self.target(),
                clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
                prepareBackgroundWindow: true,
                deliveryValidator: { throw PeekabooError.invalidInput("Receiver changed") })
            Issue.record("Expected prepared prefix failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 4)
            #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .background))
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(events == 0)
    }

    @Test
    func `claim loss during chord preserves preparation prefix and owed releases`() async throws {
        var generation = 11
        var events: [CGEventType] = []
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, _ in events.append(event.type); generation = 12 },
            processStartIdentityProvider: { _ in 800 },
            clipboardChangeCountProvider: { generation },
            heldInterEventDelay: {},
            backgroundWindowPreparer: { _, validate in try validate(); return Self.preparedOutcome })
        do {
            _ = try await service.hotkey(
                keys: "cmd,v",
                holdDuration: 50,
                automationTarget: Self.target(),
                clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
                prepareBackgroundWindow: true)
            Issue.record("Expected interrupted chord")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 6)
            #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .background))
        }
        #expect(events == [.flagsChanged, .flagsChanged])
    }

    @Test(arguments: [
        FocusedElementReceiptError.windowNotFound, .windowMismatch,
        .windowObservationFailed(stage: .inventory, errorCode: -25204),
        .windowObservationFailed(stage: .inventory, errorCode: nil),
        .windowObservationFailed(stage: .inventoryWindowID, errorCode: -25204),
        .windowObservationFailed(stage: .inventoryWindowID, errorCode: nil),
        .windowObservationFailed(stage: .owningWindow, errorCode: -25204),
        .windowObservationFailed(stage: .owningWindow, errorCode: nil),
        .windowObservationFailed(stage: .owningWindowID, errorCode: -25204),
        .windowObservationFailed(stage: .owningWindowID, errorCode: nil),
    ])
    func `window observation failure after command down preserves cause and releases without paste`(
        cause: FocusedElementReceiptError) async throws
    {
        var events: [(type: CGEventType, code: Int64, flags: CGEventFlags)] = []
        let service = HotkeyService(
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly),
            postEventAccessEvaluator: { true },
            eventPoster: { event, pid in
                #expect(pid == getpid())
                events.append((event.type, event.getIntegerValueField(.keyboardEventKeycode), event.flags))
            },
            processStartIdentityProvider: { pid in #expect(pid == getpid()); return 800 },
            clipboardChangeCountProvider: { 11 },
            heldInterEventDelay: {},
            backgroundWindowPreparer: { _, validate in try validate(); return Self.preparedOutcome })
        do {
            _ = try await service.hotkey(
                keys: "cmd,v",
                holdDuration: 50,
                automationTarget: Self.target(),
                clipboardClaim: GeneralPasteboardWriteClaim(changeCount: 11),
                prepareBackgroundWindow: true,
                deliveryValidator: {
                    if !events.isEmpty {
                        throw cause
                    }
                })
            Issue.record("Expected post-modifier refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 6)
            #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .background))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.causeDescription?.contains(cause.localizedDescription) == true)
            #expect(failure.causeDescription?
                .contains("Held keys were released to the original process generation") == true)
        }
        #expect(events.map(\.type) == [.flagsChanged, .flagsChanged])
        #expect(events.map(\.code) == [0x37, 0x37])
        #expect(events.map(\.flags) == [.maskCommand, []])
    }

    private static var preparedOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(4))
    }

    private static func target() throws -> UIAutomationTarget {
        try .exactWindow(.init(
            identity: WindowMutationIdentity(
                windowID: 100, ownerProcessIdentifier: getpid(), ownerProcessStartIdentity: 800),
            bounds: CGRect(x: 0, y: 0, width: 500, height: 400),
            focusedElement: FocusedElementIdentity(
                processIdentifier: getpid(),
                windowID: 100,
                role: "AXTextArea",
                frame: CGRect(x: 0, y: 32, width: 500, height: 368))))
    }
}
