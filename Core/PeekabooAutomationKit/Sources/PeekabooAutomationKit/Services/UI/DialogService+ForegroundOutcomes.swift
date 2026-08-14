import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    struct ForegroundDialogPlan {
        let target: UIAutomationTarget.ExactWindow
        let window: Element
        let dialog: Element
    }

    static let foregroundKeyboardDelivery = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground)

    public func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Entering text into dialog field")
            self.logger.debug("Text length: \(text.count) chars, clear existing: \(clearExisting)")
            if let identifier = fieldIdentifier {
                self.logger.debug("Target field: \(identifier)")
            }

            let dialog = try await self.resolveDialogElement(windowTitle: windowTitle, appName: appName)
            let targetField = try self.textField(in: dialog, identifier: fieldIdentifier)
            let isSecure = targetField.role() == "AXSecureTextField" ||
                targetField.subrole() == "AXSecureTextField"

            if text.isEmpty, !clearExisting {
                return DialogActionResult(
                    success: true,
                    action: .enterText,
                    details: [
                        "field": targetField.title() ?? "Text Field",
                        "text_length": "0",
                        "cleared": "false",
                        "value_verified": "false",
                    ],
                    outcome: .confirmedNoChange())
            }

            try Task.checkCancellation()
            let focusMutationDispatched = try self.focusTextFieldForInput(targetField)
            let dispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount?
            do {
                dispatchedUnitCount = try self.dispatchDialogInput(text: text, clearExisting: clearExisting)
            } catch is CancellationError where focusMutationDispatched {
                throw DesktopActionFailure.dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one,
                    message: "Dialog input was cancelled after the field focus mutation was accepted.",
                    hint: "Refresh the dialog and field focus before retrying.")
            }
            let expectedValue = clearExisting ? text : nil
            let observedValue: String?
            do {
                observedValue = try await self.readDialogInputValue(
                    from: targetField,
                    expectedValue: expectedValue)
            } catch is CancellationError {
                try Self.rethrowDialogInputReadCancellation(dispatchedUnitCount: dispatchedUnitCount)
            }
            let outcome = try Self.dialogInputOutcome(
                expectedValue: expectedValue,
                observedValue: observedValue,
                isSecure: isSecure,
                dispatchedUnitCount: dispatchedUnitCount)
            let retainedValueMatchesRequest = if let expectedValue, !isSecure {
                observedValue == expectedValue
            } else {
                false
            }

            let result = DialogActionResult(
                success: true,
                action: .enterText,
                details: [
                    "field": targetField.title() ?? "Text Field",
                    "text_length": String(text.count),
                    "cleared": String(clearExisting),
                    "value_verified": String(retainedValueMatchesRequest),
                ],
                outcome: outcome)

            self.logger.info("\(AgentDisplayTokens.Status.success) Dialog input delivery completed")
            return result
        }
    }

    func forceDismissDialog(windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        let plan = try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
            try await self.prepareForegroundDialogPlan(windowTitle: windowTitle, appName: appName)
        }

        return try await self.operationLaneCoordinator.run(scope: .window(plan.target.identity), access: .write) {
            try await self.revalidateDialogTarget(
                target: plan.target,
                retainedWindow: plan.window,
                retainedDialog: plan.dialog,
                operation: "forced Escape")
            try Task.checkCancellation()

            try self.dispatchForcedDialogEscape()

            let presence = self.dialogPresence(target: plan.target, retainedDialog: plan.dialog)
            let outcome = Self.forcedDismissOutcome(dialogPresence: presence)
            var details = Self.dialogTargetDetails(plan.target)
            details.merge([
                "method": "escape",
                "dialog_presence_after_dispatch": Self.dialogPresenceDescription(presence),
            ]) { _, new in new }
            return DialogActionResult(
                success: true,
                action: .dismiss,
                details: details,
                outcome: outcome)
        }
    }

    func focusTextFieldForInput(_ field: Element) throws -> Bool {
        if field.attribute(Attribute<Bool>(AXAttributeNames.kAXFocusedAttribute)) == true {
            return false
        }
        if field.isAttributeSettable(named: AXAttributeNames.kAXFocusedAttribute) {
            let accepted = field.setValue(true, forAttribute: AXAttributeNames.kAXFocusedAttribute)
            if accepted {
                if field.attribute(Attribute<Bool>(AXAttributeNames.kAXFocusedAttribute)) == true {
                    return true
                }
                throw Self.dialogFieldFocusUnverifiedFailure()
            }
        }

        if field.isActionSupported(AXActionNames.kAXPressAction) {
            do {
                try field.performAction(.press)
                if field.attribute(Attribute<Bool>(AXAttributeNames.kAXFocusedAttribute)) == true {
                    return true
                }
                throw DesktopActionFailure.dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one,
                    message: "Dialog field focus action was accepted but focus remained unverified.",
                    hint: "Refresh the dialog and select one exact field before retrying.")
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch {
                throw DesktopActionFailure.indeterminate(
                    delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Dialog field focus action failed after AXPress may have started.",
                    hint: "Refresh the dialog and select one exact field before retrying.",
                    causeDescription: error.localizedDescription)
            }
        }

        throw DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Dialog text field did not confirm focus before keyboard dispatch.",
            hint: "Refresh the dialog and select one exact field before retrying.")
    }

    static func dialogFieldFocusUnverifiedFailure() -> DesktopActionFailure {
        .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Dialog field focus mutation was accepted but focus did not remain verified.",
            hint: "Refresh the dialog and select one exact field before retrying.")
    }

    func dispatchDialogInput(text: String, clearExisting: Bool) throws
        -> DesktopActionOutcome.DispatchUnitCount?
    {
        var dispatchedUnits = 0
        if clearExisting {
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
            }
            dispatchedUnits += 1
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                try self.syntheticInputDriver.tapKey(.delete, modifiers: [])
            }
            dispatchedUnits += 1
        }
        if !text.isEmpty {
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                try self.syntheticInputDriver.type(text, delayPerCharacter: 0.01)
            }
            dispatchedUnits += 1
        }
        return dispatchedUnits == 0 ? nil : Self.dispatchUnitCount(dispatchedUnits)
    }

    func checkDialogInputCancellation(dispatchedUnits: Int) throws {
        do {
            try Task.checkCancellation()
        } catch is CancellationError where dispatchedUnits == 0 {
            throw CancellationError()
        } catch {
            throw Self.dialogInputIndeterminateFailure(
                unitCount: Self.dispatchUnitCount(dispatchedUnits),
                message: "Dialog keyboard input was cancelled after delivery started.",
                causeDescription: error.localizedDescription)
        }
    }

    func dispatchDialogInputUnit(dispatchedUnits: Int, operation: () throws -> Void) throws {
        do {
            try operation()
        } catch {
            throw Self.dialogInputIndeterminateFailure(
                unitCount: Self.dispatchUnitCount(dispatchedUnits + 1),
                message: "Dialog keyboard input failed after delivery may have started.",
                causeDescription: error.localizedDescription)
        }
    }

    static func dialogInputIndeterminateFailure(
        unitCount: DesktopActionOutcome.DispatchUnitCount,
        message: String,
        causeDescription: String) -> DesktopActionFailure
    {
        .indeterminate(
            delivery: self.foregroundKeyboardDelivery,
            evidence: .completionUnknown,
            unitCount: unitCount,
            message: message,
            hint: "Read the retained dialog field before any retry.",
            causeDescription: causeDescription)
    }

    static func rethrowDialogInputReadCancellation(
        dispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount?) throws -> Never
    {
        guard let dispatchedUnitCount else {
            throw CancellationError()
        }
        throw DesktopActionFailure.indeterminate(
            delivery: self.foregroundKeyboardDelivery,
            evidence: .completionUnknown,
            unitCount: dispatchedUnitCount,
            message: "Dialog input was cancelled after keyboard delivery.",
            hint: "Read the retained dialog field before any retry.")
    }

    func dispatchForcedDialogEscape() throws {
        do {
            try self.syntheticInputDriver.tapKey(.escape, modifiers: [])
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: Self.foregroundKeyboardDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Forced dialog Escape returned without a reliable dispatch receipt.",
                hint: "Observe the exact dialog before any retry.",
                causeDescription: error.localizedDescription)
        }
    }

    func readDialogInputValue(from field: Element, expectedValue: String?) async throws -> String? {
        if expectedValue == nil {
            try Task.checkCancellation()
            return field.value() as? String
        }

        var lastReadableValue: String?
        for attempt in 0..<5 {
            try Task.checkCancellation()
            if let value = field.value() as? String {
                lastReadableValue = value
                if value == expectedValue {
                    return value
                }
            }
            if attempt < 4 {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        return lastReadableValue
    }

    static func dialogInputOutcome(
        expectedValue: String?,
        observedValue: String?,
        isSecure: Bool,
        dispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount?) throws -> DesktopActionOutcome
    {
        guard let dispatchedUnitCount else {
            return .confirmedNoChange()
        }
        let unverified = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.foregroundKeyboardDelivery,
            evidence: .deliveryAccepted,
            unitCount: dispatchedUnitCount)
        guard !isSecure, let expectedValue, let observedValue else {
            return unverified
        }
        guard observedValue == expectedValue else {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: Self.foregroundKeyboardDelivery,
                evidence: .deliveryAccepted,
                unitCount: dispatchedUnitCount,
                message: "Dialog keyboard input was dispatched, but the retained field value did not match.",
                hint: "Read the exact field and observe the dialog before any retry.")
        }
        // Global keyboard delivery can race another controller. Matching the retained field proves
        // the requested value is present, but cannot prove these events caused that state.
        return unverified
    }

    static func forcedDismissOutcome(dialogPresence _: DialogPresence) -> DesktopActionOutcome {
        // A global Escape can race another controller. Even observed disappearance cannot attribute the effect.
        .dispatchedUnverified(
            delivery: self.foregroundKeyboardDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    func prepareForegroundDialogPlan(windowTitle: String?, appName: String?) async throws -> ForegroundDialogPlan {
        let selector = try Self.foregroundDialogSelector(
            windowTitle: windowTitle,
            appName: appName,
            frontmostProcessIdentifier: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let candidates = try await self.targetedDialogCandidates(
            target: selector,
            membership: .structuralMutation)
        guard candidates.count == 1, let candidate = candidates.first else {
            throw self.dialogCandidateRefusal(target: selector, candidates: candidates)
        }
        return ForegroundDialogPlan(
            target: candidate.target,
            window: candidate.window,
            dialog: candidate.dialog)
    }

    static func foregroundDialogSelector(
        windowTitle: String?,
        appName: String?,
        frontmostProcessIdentifier: pid_t?) throws -> DialogTargetSelector
    {
        if let appName, appName.hasPrefix("PID:") {
            guard let pid = Int32(appName.dropFirst(4)), pid > 0 else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Forced dialog dismissal received an invalid PID target.",
                    hint: "Provide a positive PID after 'PID:'.")
            }
            return try DialogTargetSelector(processIdentifier: pid, windowTitle: windowTitle)
        }
        if let appName, !appName.isEmpty {
            return try DialogTargetSelector(
                applicationIdentifier: appName,
                windowTitle: windowTitle)
        }
        guard let frontmostProcessIdentifier, frontmostProcessIdentifier > 0 else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Forced dialog dismissal could not resolve one frontmost dialog owner.",
                hint: "Provide --app, --pid, or --window-id after listing the dialog.")
        }
        return try DialogTargetSelector(
            processIdentifier: frontmostProcessIdentifier,
            windowTitle: windowTitle)
    }

    static func dispatchUnitCount(_ count: Int) -> DesktopActionOutcome.DispatchUnitCount {
        DesktopActionOutcome.DispatchUnitCount(count) ?? .one
    }

    static func dialogPresenceDescription(_ presence: DialogPresence) -> String {
        switch presence {
        case .present: "present"
        case .absent: "absent"
        case .unreadable: "unreadable"
        }
    }
}
