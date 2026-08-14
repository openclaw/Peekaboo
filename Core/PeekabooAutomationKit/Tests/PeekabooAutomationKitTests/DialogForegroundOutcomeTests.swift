import enum AXorcist.MouseButton
import enum AXorcist.SpecialKey
import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("Foreground dialog outcomes")
struct DialogForegroundOutcomeTests {
    @Test
    func `dialog input dispatch uses injected driver and counts successful units`() throws {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)

        let count = try service.dispatchDialogInput(text: "hello", clearExisting: true)

        #expect(count?.rawValue == 3)
        #expect(driver.hotkeys == [["cmd", "a"]])
        #expect(driver.tappedKeys == [.delete])
        #expect(driver.typedText == ["hello"])
    }

    @Test
    func `dialog input clear and typing failures propagate as retry unsafe outcomes`() throws {
        let clearDriver = RecordingDialogSyntheticDriver(failure: .hotkey)
        let clearService = DialogService(syntheticInputDriver: clearDriver)
        do {
            _ = try clearService.dispatchDialogInput(text: "hello", clearExisting: true)
            Issue.record("Expected clear failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(clearDriver.tappedKeys.isEmpty)
        #expect(clearDriver.typedText.isEmpty)

        let typeDriver = RecordingDialogSyntheticDriver(failure: .type)
        let typeService = DialogService(syntheticInputDriver: typeDriver)
        do {
            _ = try typeService.dispatchDialogInput(text: "hello", clearExisting: false)
            Issue.record("Expected typing failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `dialog input postcondition verifies value without claiming global event causality`() throws {
        let matching = try DialogService.dialogInputOutcome(
            expectedValue: "hello",
            observedValue: "hello",
            isSecure: false,
            dispatchedUnitCount: .one)
        #expect(matching.state == .dispatchedUnverified)
        #expect(matching.effect == .unverifiable)
        #expect(matching.retrySafety == .unsafe)

        do {
            _ = try DialogService.dialogInputOutcome(
                expectedValue: "hello",
                observedValue: "",
                isSecure: false,
                dispatchedUnitCount: .one)
            Issue.record("Expected retained-value mismatch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.retrySafety == .unsafe)
        }

        let unreadable = try DialogService.dialogInputOutcome(
            expectedValue: "hello",
            observedValue: nil,
            isSecure: false,
            dispatchedUnitCount: .one)
        #expect(unreadable.state == .dispatchedUnverified)

        let secure = try DialogService.dialogInputOutcome(
            expectedValue: "hello",
            observedValue: "•••••",
            isSecure: true,
            dispatchedUnitCount: .one)
        #expect(secure.state == .dispatchedUnverified)
    }

    @Test
    func `driver cancellation is retry unsafe even before the first unit returns`() throws {
        let driver = RecordingDialogSyntheticDriver(failure: .cancellation)
        let service = DialogService(syntheticInputDriver: driver)

        do {
            _ = try service.dispatchDialogInput(text: "hello", clearExisting: false)
            Issue.record("Expected driver cancellation to remain indeterminate")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `value read cancellation preserves zero dispatch and unsafe post dispatch attribution`() throws {
        #expect(throws: CancellationError.self) {
            try DialogService.rethrowDialogInputReadCancellation(dispatchedUnitCount: nil)
        }

        do {
            try DialogService.rethrowDialogInputReadCancellation(dispatchedUnitCount: .one)
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `legacy foreground success and accepted focus remain causally unverified`() {
        let legacy = DialogActionResult(success: true, action: .enterText)
            .foregroundOutcomeOrUnverified(route: .bridge)
        #expect(legacy.state == .dispatchedUnverified)
        #expect(legacy.route == .bridge)
        #expect(legacy.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(legacy.retrySafety == .unsafe)

        let supplied = DialogActionResult(
            success: true,
            action: .dismiss,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one))
            .foregroundOutcomeOrUnverified(route: .bridge)
        #expect(supplied.route == .bridge)
        #expect(supplied.state == .dispatchedUnverified)

        let focusFailure = DialogService.dialogFieldFocusUnverifiedFailure()
        #expect(focusFailure.outcome.state == .dispatchedUnverified)
        #expect(focusFailure.outcome.delivery == .init(mechanism: .accessibilityAction, mode: .foreground))
        #expect(focusFailure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `dialog window focus failures distinguish read only verification from possible focus mutation`() {
        let verification = DialogService.dialogWindowFocusFailure(
            autoFocus: false,
            cause: FocusError.focusVerificationFailed(700))
        #expect(verification.outcome.state == .refused)
        #expect(verification.outcome.refusalReason == .targetUnavailable)
        #expect(verification.outcome.dispatchState == .none)
        #expect(verification.outcome.retrySafety == .safe)

        let automatic = DialogService.dialogWindowFocusFailure(
            autoFocus: true,
            cause: FocusError.focusVerificationTimeout(700))
        #expect(automatic.outcome.state == .indeterminate)
        #expect(automatic.outcome.delivery == nil)
        #expect(automatic.outcome.dispatchState.unitCount == nil)
        #expect(automatic.outcome.retrySafety == .unsafe)
        #expect(automatic.outcome.escalation == .observeBeforeRetry)

        let cancelledAutomatic = DialogService.dialogWindowFocusFailure(
            autoFocus: true,
            cause: CancellationError())
        #expect(cancelledAutomatic.outcome == automatic.outcome)
    }

    @Test
    func `external forced-dismiss race never upgrades global Escape to confirmed`() {
        #expect(DialogService.forcedDismissMutationScope == .global)
        for presence in [
            DialogService.DialogPresence.present,
            .absent,
            .unreadable,
        ] {
            let outcome = DialogService.forcedDismissOutcome(dialogPresence: presence)
            #expect(outcome.state == .dispatchedUnverified)
            #expect(outcome.effect == .unverifiable)
            #expect(outcome.dispatchState.unitCount == .one)
            #expect(outcome.retrySafety == .unsafe)
            #expect(outcome.escalation == .observeBeforeRetry)
        }
    }

    @Test
    func `forced dismiss requires one successful injected Escape unit`() throws {
        let driver = RecordingDialogSyntheticDriver()
        let service = DialogService(syntheticInputDriver: driver)
        try service.dispatchForcedDialogEscape()
        #expect(driver.tappedKeys == [.escape])

        let failingDriver = RecordingDialogSyntheticDriver(failure: .tapKey)
        let failingService = DialogService(syntheticInputDriver: failingDriver)
        do {
            try failingService.dispatchForcedDialogEscape()
            Issue.record("Expected Escape dispatch failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
    }

    @Test
    func `forced dismiss selector preserves an exact PID or current frontmost owner`() throws {
        let exact = try DialogService.foregroundDialogSelector(
            windowTitle: "Save",
            appName: "PID:42",
            frontmostProcessIdentifier: 99)
        #expect(exact.processIdentifier == 42)
        #expect(exact.applicationIdentifier == nil)
        #expect(exact.windowTitle == "Save")

        let named = try DialogService.foregroundDialogSelector(
            windowTitle: nil,
            appName: "Playground",
            frontmostProcessIdentifier: 99)
        #expect(named.applicationIdentifier == "Playground")

        let frontmost = try DialogService.foregroundDialogSelector(
            windowTitle: nil,
            appName: nil,
            frontmostProcessIdentifier: 99)
        #expect(frontmost.processIdentifier == 99)

        #expect(throws: DesktopActionFailure.self) {
            _ = try DialogService.foregroundDialogSelector(
                windowTitle: nil,
                appName: nil,
                frontmostProcessIdentifier: nil)
        }
        #expect(throws: DesktopActionFailure.self) {
            _ = try DialogService.foregroundDialogSelector(
                windowTitle: nil,
                appName: "PID:not-a-number",
                frontmostProcessIdentifier: 99)
        }
    }

    @Test
    func `dialog action target details preserve exact process generation and window receipt`() throws {
        let target = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 73,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: 9_007_199_254_740_993),
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200))

        let details = DialogService.dialogTargetDetails(target)

        #expect(details["pid"] == "42")
        #expect(details["process_start_identity"] == "9007199254740993")
        #expect(details["process_start_identity_decimal"] == "9007199254740993")
        #expect(details["window_id"] == "73")
    }
}

@MainActor
final class RecordingDialogSyntheticDriver: SyntheticInputDriving {
    enum Failure: Equatable {
        case hotkey
        case cancellation
        case tapKey
        case type
    }

    struct DriverFailure: Error {}

    let failure: Failure?
    let failTypeAtCall: Int?
    private(set) var hotkeys: [[String]] = []
    private(set) var tappedKeys: [SpecialKey] = []
    private(set) var typedText: [String] = []

    init(failure: Failure? = nil, failTypeAtCall: Int? = nil) {
        self.failure = failure
        self.failTypeAtCall = failTypeAtCall
    }

    func click(at _: CGPoint, button _: MouseButton, count _: Int) throws -> DesktopActionOutcome {
        .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    func click(
        at _: CGPoint,
        button _: MouseButton,
        count _: Int,
        targetProcessIdentifier _: pid_t) async throws -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    func click(
        at _: CGPoint,
        button _: MouseButton,
        count _: Int,
        targetProcessIdentifier _: pid_t,
        targetWindowID _: CGWindowID?) async throws -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    func move(to _: CGPoint) throws {}
    func currentLocation() -> CGPoint? {
        nil
    }

    func pressHold(at _: CGPoint, button _: MouseButton, duration _: TimeInterval) async throws {}
    func scroll(deltaX _: Double, deltaY _: Double, at _: CGPoint?) throws {}

    func type(_ text: String, delayPerCharacter _: TimeInterval) throws {
        if self.failure == .cancellation {
            throw CancellationError()
        }
        if self.failure == .type || self.failTypeAtCall == self.typedText.count + 1 {
            throw DriverFailure()
        }
        self.typedText.append(text)
    }

    func tapKey(_ key: SpecialKey, modifiers _: CGEventFlags) throws {
        if self.failure == .tapKey {
            throw DriverFailure()
        }
        self.tappedKeys.append(key)
    }

    func hotkey(keys: [String], holdDuration _: TimeInterval) throws {
        if self.failure == .hotkey {
            throw DriverFailure()
        }
        self.hotkeys.append(keys)
    }
}
