import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    struct ForegroundDialogPlan {
        let target: UIAutomationTarget.ExactWindow
        let resolvedTarget: ResolvedDialogTargetEvidence?
        let window: Element
        let dialog: Element
    }

    struct RetainedDialogInputPlan {
        let text: String
        let fieldIdentifier: String?
        let clearExisting: Bool
        let focusPolicy: DialogForegroundFocusPolicy
        let dialog: ForegroundDialogPlan
        let field: Element
        let exactFieldSelection: Bool
        let publishTargetReceipt: Bool
    }

    static let foregroundKeyboardDelivery = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground)
    static let backgroundDialogInputDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityValue,
        mode: .background)
    static let forcedDismissMutationScope = DesktopOperationScope.global

    static func attributedDialogActionFailure(
        _ failure: DesktopActionFailure,
        target: UIAutomationTarget.ExactWindow) -> DesktopActionFailure
    {
        failure.attributed(to: self.desktopActionTargetReceipt(target))
    }

    public func enterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult
    {
        try await self.enterText(DialogLegacyInputExecutionRequest(
            text: text,
            fieldIdentifier: fieldIdentifier,
            clearExisting: clearExisting,
            windowTitle: windowTitle,
            appName: appName,
            focus: DialogForegroundFocusPolicy()))
    }

    public func enterText(_ request: DialogLegacyInputExecutionRequest) async throws -> DialogActionResult {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let plan = try await self.prepareForegroundDialogPlan(
                windowTitle: request.windowTitle,
                appName: request.appName)
            let targetField = try self.textField(in: plan.dialog, identifier: request.fieldIdentifier)
            return try await self.executeDialogInput(RetainedDialogInputPlan(
                text: request.text,
                fieldIdentifier: request.fieldIdentifier,
                clearExisting: request.clearExisting,
                focusPolicy: request.focus,
                dialog: plan,
                field: targetField,
                exactFieldSelection: false,
                publishTargetReceipt: false))
        }
    }

    public func enterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let candidates = try await self.targetedDialogCandidates(
                target: request.target,
                membership: .structuralMutation)
            guard candidates.count == 1, let candidate = candidates.first else {
                throw self.dialogCandidateRefusal(target: request.target, candidates: candidates)
            }
            let plan = ForegroundDialogPlan(
                target: candidate.target,
                resolvedTarget: candidate.resolvedTarget,
                window: candidate.window,
                dialog: candidate.dialog)
            do {
                let targetField = try self.exactDialogInputField(
                    in: plan.dialog,
                    identifier: request.fieldIdentifier)
                return try await self.executeBackgroundDialogInput(
                    request,
                    plan: plan,
                    retainedField: targetField)
            } catch let failure as DesktopActionFailure {
                throw Self.attributedDialogActionFailure(failure, target: plan.target)
            }
        }
    }

    public func enterTextForegroundCompatible(
        _ request: DialogInputExecutionRequest) async throws -> DialogActionResult
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            let candidates = try await self.targetedDialogCandidates(
                target: request.target,
                membership: .structuralMutation)
            guard candidates.count == 1, let candidate = candidates.first else {
                throw self.dialogCandidateRefusal(target: request.target, candidates: candidates)
            }
            let plan = ForegroundDialogPlan(
                target: candidate.target,
                resolvedTarget: candidate.resolvedTarget,
                window: candidate.window,
                dialog: candidate.dialog)
            do {
                let targetField = try self.exactDialogInputField(
                    in: plan.dialog,
                    identifier: request.fieldIdentifier)
                return try await self.executeDialogInput(RetainedDialogInputPlan(
                    text: request.text,
                    fieldIdentifier: request.fieldIdentifier,
                    clearExisting: request.clearExisting,
                    focusPolicy: request.focus,
                    dialog: plan,
                    field: targetField,
                    exactFieldSelection: true,
                    publishTargetReceipt: true))
            } catch let failure as DesktopActionFailure {
                throw Self.attributedDialogActionFailure(failure, target: plan.target)
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func executeBackgroundDialogInput(
        _ request: DialogInputExecutionRequest,
        plan: ForegroundDialogPlan,
        retainedField: Element) async throws -> DialogActionResult
    {
        self.logger.info("Entering text into exact dialog field with background AXValue delivery")
        try Task.checkCancellation()
        let dispatchTarget = try await self.revalidateDialogTarget(
            target: plan.target,
            retainedWindow: plan.window,
            retainedDialog: plan.dialog,
            operation: "background dialog input planning")
        var field = try self.revalidateDialogInputField(
            retainedField,
            in: dispatchTarget.dialog,
            identifier: request.fieldIdentifier,
            exactSelection: true)
        if request.text.isEmpty, !request.clearExisting {
            return self.backgroundDialogInputResult(
                request: request,
                plan: plan,
                field: field,
                outcome: .confirmedNoChange(),
                verification: .init(valueVerified: false, cursorUpdated: false))
        }
        guard field.role() != "AXSecureTextField",
              field.subrole() != "AXSecureTextField"
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Exact background dialog input cannot set a secure text field through Accessibility.",
                hint: "Use an explicitly foreground input workflow for secure text.")
        }
        guard field.isAttributeSettable(named: AXAttributeNames.kAXValueAttribute) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The exact dialog field does not expose a settable AXValue.",
                hint: "Choose a settable text field or use an explicitly foreground input workflow.")
        }

        let currentValue = field.rawAttributeValue(named: AXAttributeNames.kAXValueAttribute) as? String
        let selectedRange = Self.dialogSelectedTextRange(field)
        let edit: DialogBackgroundTextEdit
        do {
            edit = try Self.backgroundDialogTextEdit(
                currentValue: currentValue,
                selectedRange: selectedRange,
                replacement: request.text,
                clearExisting: request.clearExisting)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact dialog field did not expose a stable background text selection.",
                hint: "Refresh the dialog field or use clear-existing background input.",
                causeDescription: error.localizedDescription)
        }
        let latestValue = field.rawAttributeValue(named: AXAttributeNames.kAXValueAttribute) as? String
        let latestSelectedRange = Self.dialogSelectedTextRange(field)
        guard latestValue == currentValue,
              request.clearExisting || Self.sameDialogTextRange(latestSelectedRange, selectedRange)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact dialog field value or selection changed before background dispatch.",
                hint: "Read the field again and retry against its current selection.")
        }

        let dispatchPlan = Self.backgroundDialogEditDispatchPlan(
            currentValue: currentValue,
            selectedRange: selectedRange,
            edit: edit)
        if !dispatchPlan.valueNeedsUpdate, !dispatchPlan.cursorNeedsUpdate {
            try Task.checkCancellation()
            return self.backgroundDialogInputResult(
                request: request,
                plan: plan,
                field: field,
                outcome: .confirmedNoChange(),
                verification: .init(valueVerified: true, cursorUpdated: false))
        }

        let cursorValue = try Self.backgroundDialogCursorDispatchValue(
            dispatchPlan: dispatchPlan,
            cursorRange: edit.cursorRange)
        {
            field.isAttributeSettable(named: AXAttributeNames.kAXSelectedTextRangeAttribute)
        }
        var submittedUnitCount = 0
        if dispatchPlan.valueNeedsUpdate {
            try Task.checkCancellation()
            guard field.setValue(edit.value, forAttribute: AXAttributeNames.kAXValueAttribute) else {
                throw DesktopActionFailure.indeterminate(
                    delivery: Self.backgroundDialogInputDelivery,
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "Background dialog AXValue delivery returned without acceptance evidence.",
                    hint: "Read the exact dialog field before retrying.")
            }
            submittedUnitCount = 1
        }
        if let cursorValue {
            do {
                try Task.checkCancellation()
            } catch {
                guard submittedUnitCount > 0 else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .requestCancelled,
                        message: "Background dialog cursor placement was cancelled before dispatch.",
                        hint: "Submit a new request only if the input is still wanted.")
                }
                throw DesktopActionFailure.dispatchedUnverified(
                    delivery: Self.backgroundDialogInputDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: Self.dispatchUnitCount(submittedUnitCount),
                    message: "Background dialog AXValue was accepted before cursor placement was cancelled.",
                    hint: "Read the exact dialog field before retrying.")
            }
            try Self.setDialogSelectedTextRange(
                cursorValue,
                on: field,
                priorSubmittedUnitCount: submittedUnitCount)
            submittedUnitCount += 1
        }

        do {
            try Task.checkCancellation()
            let postDispatchTarget = try await self.revalidateDialogTarget(
                target: plan.target,
                retainedWindow: plan.window,
                retainedDialog: plan.dialog,
                operation: "background dialog AXValue postcondition")
            field = try self.revalidateDialogInputField(
                field,
                in: postDispatchTarget.dialog,
                identifier: request.fieldIdentifier,
                exactSelection: true)
        } catch {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: Self.backgroundDialogInputDelivery,
                evidence: .deliveryAccepted,
                unitCount: Self.dispatchUnitCount(submittedUnitCount),
                message: "Background dialog input was accepted, but its exact target changed during verification.",
                hint: "Read the exact dialog field before retrying.",
                causeDescription: error.localizedDescription)
        }
        let observedValue = field.rawAttributeValue(named: AXAttributeNames.kAXValueAttribute) as? String
        guard observedValue == edit.value else {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: Self.backgroundDialogInputDelivery,
                evidence: .deliveryAccepted,
                unitCount: Self.dispatchUnitCount(submittedUnitCount),
                message: "Background dialog input was accepted, but the retained AXValue did not match.",
                hint: "Read the exact dialog field before retrying.")
        }
        if dispatchPlan.cursorNeedsUpdate {
            let observedCursor = Self.dialogSelectedTextRange(field)
            guard Self.sameDialogTextRange(observedCursor, edit.cursorRange) else {
                throw DesktopActionFailure.dispatchedUnverified(
                    delivery: Self.backgroundDialogInputDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: Self.dispatchUnitCount(submittedUnitCount),
                    message: "Background dialog input was accepted, but its cursor range did not match.",
                    hint: "Read the exact dialog field before retrying.")
            }
        }
        return self.backgroundDialogInputResult(
            request: request,
            plan: plan,
            field: field,
            outcome: .dispatchedUnverified(
                delivery: Self.backgroundDialogInputDelivery,
                evidence: .deliveryAccepted,
                unitCount: dispatchPlan.successfulUnitCount),
            verification: .init(
                valueVerified: true,
                cursorUpdated: dispatchPlan.cursorNeedsUpdate))
    }

    private struct DialogBackgroundInputVerification {
        let valueVerified: Bool
        let cursorUpdated: Bool
    }

    private func backgroundDialogInputResult(
        request: DialogInputExecutionRequest,
        plan: ForegroundDialogPlan,
        field: Element,
        outcome: DesktopActionOutcome,
        verification: DialogBackgroundInputVerification) -> DialogActionResult
    {
        var details = self.dialogInputDetails(
            plan: plan,
            field: field,
            textLength: request.text.count,
            cleared: request.clearExisting,
            valueVerified: verification.valueVerified,
            focusPolicy: request.focus)
        details["delivery_mode"] = DesktopActionOutcome.Delivery.Mode.background.rawValue
        details["delivery_mechanism"] = DesktopActionOutcome.Delivery.Mechanism.accessibilityValue.rawValue
        details["focus_applied"] = "false"
        details["cursor_updated"] = String(verification.cursorUpdated)
        return DialogActionResult(
            success: true,
            action: .enterText,
            details: details,
            outcome: outcome,
            targetReceipt: Self.desktopActionTargetReceipt(plan.target),
            targetWindowIdentity: plan.target.identity,
            targetWindowBounds: plan.target.bounds,
            focusedElement: plan.target.focusedElement,
            resolvedTarget: plan.resolvedTarget)
    }

    struct DialogBackgroundTextEdit {
        let value: String
        let cursorRange: CFRange
    }

    struct DialogBackgroundEditDispatchPlan: Equatable {
        let valueNeedsUpdate: Bool
        let cursorNeedsUpdate: Bool

        var successfulUnitCount: DesktopActionOutcome.DispatchUnitCount? {
            DesktopActionOutcome.DispatchUnitCount(
                (self.valueNeedsUpdate ? 1 : 0) + (self.cursorNeedsUpdate ? 1 : 0))
        }
    }

    enum DialogBackgroundTextEditError: Error {
        case currentValueUnavailable
        case selectionUnavailable
        case invalidSelection
    }

    static func backgroundDialogTextEdit(
        currentValue: String?,
        selectedRange: CFRange?,
        replacement: String,
        clearExisting: Bool) throws -> DialogBackgroundTextEdit
    {
        if clearExisting {
            return DialogBackgroundTextEdit(
                value: replacement,
                cursorRange: CFRange(location: (replacement as NSString).length, length: 0))
        }
        guard let currentValue else { throw DialogBackgroundTextEditError.currentValueUnavailable }
        guard !replacement.isEmpty else {
            let cursor = selectedRange ?? CFRange(location: (currentValue as NSString).length, length: 0)
            return DialogBackgroundTextEdit(value: currentValue, cursorRange: cursor)
        }
        guard let selectedRange else { throw DialogBackgroundTextEditError.selectionUnavailable }
        let current = currentValue as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= current.length,
              selectedRange.length <= current.length - selectedRange.location
        else {
            throw DialogBackgroundTextEditError.invalidSelection
        }
        let replacementLength = (replacement as NSString).length
        return DialogBackgroundTextEdit(
            value: current.replacingCharacters(
                in: NSRange(location: selectedRange.location, length: selectedRange.length),
                with: replacement),
            cursorRange: CFRange(location: selectedRange.location + replacementLength, length: 0))
    }

    static func backgroundDialogEditDispatchPlan(
        currentValue: String?,
        selectedRange: CFRange?,
        edit: DialogBackgroundTextEdit) -> DialogBackgroundEditDispatchPlan
    {
        DialogBackgroundEditDispatchPlan(
            valueNeedsUpdate: currentValue != edit.value,
            cursorNeedsUpdate: !self.sameDialogTextRange(selectedRange, edit.cursorRange))
    }

    static func backgroundDialogCursorDispatchValue(
        dispatchPlan: DialogBackgroundEditDispatchPlan,
        cursorRange: CFRange,
        isCursorSettable: () -> Bool) throws -> AXValue?
    {
        guard dispatchPlan.cursorNeedsUpdate else { return nil }
        guard isCursorSettable() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The exact dialog field cannot establish its required cursor range through Accessibility.",
                hint: "Use an explicitly foreground input workflow for this field.")
        }
        guard let cursorValue = self.dialogTextRangeAXValue(cursorRange) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The exact dialog cursor range could not be encoded before background dispatch.",
                hint: "Use an explicitly foreground input workflow for this field.")
        }
        return cursorValue
    }

    static func dialogSelectedTextRange(_ field: Element) -> CFRange? {
        guard let rawValue = field.rawAttributeValue(named: AXAttributeNames.kAXSelectedTextRangeAttribute),
              CFGetTypeID(rawValue as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        let value = unsafeDowncast(rawValue as CFTypeRef, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        return AXValueGetValue(value, .cfRange, &range) ? range : nil
    }

    static func sameDialogTextRange(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            true
        case let (lhs?, rhs?):
            lhs.location == rhs.location && lhs.length == rhs.length
        case (nil, _?), (_?, nil):
            false
        }
    }

    static func dialogTextRangeAXValue(_ range: CFRange) -> AXValue? {
        var range = range
        return AXValueCreate(.cfRange, &range)
    }

    static func setDialogSelectedTextRange(
        _ value: AXValue,
        on field: Element,
        priorSubmittedUnitCount: Int) throws
    {
        guard field.setValue(value, forAttribute: AXAttributeNames.kAXSelectedTextRangeAttribute) else {
            throw DesktopActionFailure.indeterminate(
                delivery: self.backgroundDialogInputDelivery,
                evidence: .completionUnknown,
                unitCount: self.dispatchUnitCount(priorSubmittedUnitCount + 1),
                message: "Dialog AXValue changed, but cursor placement returned without acceptance evidence.",
                hint: "Read the exact dialog field before retrying.")
        }
    }

    private func executeDialogInput(_ execution: RetainedDialogInputPlan) async throws -> DialogActionResult {
        let text = execution.text
        let fieldIdentifier = execution.fieldIdentifier
        let clearExisting = execution.clearExisting
        let focusPolicy = execution.focusPolicy
        let plan = execution.dialog
        let exactFieldSelection = execution.exactFieldSelection
        self.logDialogInput(execution)

        var targetField = execution.field
        let isSecure = targetField.role() == "AXSecureTextField" ||
            targetField.subrole() == "AXSecureTextField"
        if text.isEmpty, !clearExisting {
            try Task.checkCancellation()
            try await self.revalidateDialogTarget(
                target: plan.target,
                retainedWindow: plan.window,
                retainedDialog: plan.dialog,
                operation: "no-change input postcondition")
            _ = try self.revalidateDialogInputField(
                targetField,
                in: plan.dialog,
                identifier: fieldIdentifier,
                exactSelection: exactFieldSelection)
            return DialogActionResult(
                success: true,
                action: .enterText,
                details: self.dialogInputDetails(
                    plan: plan,
                    field: targetField,
                    textLength: 0,
                    cleared: false,
                    valueVerified: false,
                    focusPolicy: focusPolicy),
                outcome: .confirmedNoChange(),
                targetReceipt: execution.publishTargetReceipt ? Self.desktopActionTargetReceipt(plan.target) : nil,
                targetWindowIdentity: plan.target.identity,
                targetWindowBounds: plan.target.bounds,
                focusedElement: plan.target.focusedElement,
                resolvedTarget: execution.publishTargetReceipt ? plan.resolvedTarget : nil)
        }

        try Task.checkCancellation()
        try await self.revalidateDialogTarget(
            target: plan.target,
            retainedWindow: plan.window,
            retainedDialog: plan.dialog,
            operation: "dialog focus")
        try await self.establishDialogWindowFocus(plan: plan, policy: focusPolicy)
        try await self.revalidateDialogTarget(
            target: plan.target,
            retainedWindow: plan.window,
            retainedDialog: plan.dialog,
            operation: "dialog input")
        targetField = try self.revalidateDialogInputField(
            targetField,
            in: plan.dialog,
            identifier: fieldIdentifier,
            exactSelection: exactFieldSelection)
        let focusMutationDispatched = try self.focusTextFieldForInput(targetField)
        do {
            try await self.revalidateDialogTarget(
                target: plan.target,
                retainedWindow: plan.window,
                retainedDialog: plan.dialog,
                operation: "keyboard dispatch")
            targetField = try self.revalidateDialogInputField(
                targetField,
                in: plan.dialog,
                identifier: fieldIdentifier,
                exactSelection: exactFieldSelection)
        } catch where focusMutationDispatched {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one,
                message: "Dialog target changed after the field focus mutation was accepted.",
                hint: "Observe the exact dialog and field before retrying.",
                causeDescription: error.localizedDescription)
        }
        let dispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount?
        do {
            dispatchedUnitCount = try self.dispatchValidatedDialogInput(
                execution,
                focusMutationDispatched: focusMutationDispatched)
        } catch is CancellationError where focusMutationDispatched {
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one,
                message: "Dialog input was cancelled after the field focus mutation was accepted.",
                hint: "Refresh the dialog and field focus before retrying.")
        }
        // AX wrappers can retain the pre-input value after global keyboard delivery. Re-select the
        // exact retained field before sampling the postcondition, then validate it again after the
        // bounded read so a replacement field can never supply confirmation evidence.
        targetField = try await self.refreshedDialogInputField(
            targetField,
            execution: execution,
            operation: "input retained-value read",
            dispatchedUnitCount: dispatchedUnitCount,
            failureMessage: "Dialog input was dispatched, but the exact field could not be refreshed for verification.")
        let expectedValue = clearExisting ? text : nil
        let observedValue: String?
        do {
            observedValue = try await self.readDialogInputValue(
                from: targetField,
                expectedValue: expectedValue)
        } catch is CancellationError {
            try Self.rethrowDialogInputReadCancellation(dispatchedUnitCount: dispatchedUnitCount)
        }
        targetField = try await self.refreshedDialogInputField(
            targetField,
            execution: execution,
            operation: "input postcondition",
            dispatchedUnitCount: dispatchedUnitCount,
            failureMessage: "Dialog input was dispatched, but the exact dialog field receipt changed.")
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
            details: self.dialogInputDetails(
                plan: plan,
                field: targetField,
                textLength: text.count,
                cleared: clearExisting,
                valueVerified: retainedValueMatchesRequest,
                focusPolicy: focusPolicy),
            outcome: outcome,
            targetReceipt: execution.publishTargetReceipt ? Self.desktopActionTargetReceipt(plan.target) : nil,
            targetWindowIdentity: plan.target.identity,
            targetWindowBounds: plan.target.bounds,
            focusedElement: plan.target.focusedElement,
            resolvedTarget: execution.publishTargetReceipt ? plan.resolvedTarget : nil)
        self.logger.info("\(AgentDisplayTokens.Status.success) Dialog input delivery completed")
        return result
    }

    private func refreshedDialogInputField(
        _ retainedField: Element,
        execution: RetainedDialogInputPlan,
        operation: String,
        dispatchedUnitCount: DesktopActionOutcome.DispatchUnitCount?,
        failureMessage: String) async throws -> Element
    {
        do {
            let refreshedTarget = try await self.revalidateDialogTarget(
                target: execution.dialog.target,
                retainedWindow: execution.dialog.window,
                retainedDialog: execution.dialog.dialog,
                operation: operation)
            return try self.revalidateDialogInputField(
                retainedField,
                in: refreshedTarget.dialog,
                identifier: execution.fieldIdentifier,
                exactSelection: execution.exactFieldSelection)
        } catch {
            guard let dispatchedUnitCount else { throw error }
            throw DesktopActionFailure.dispatchedUnverified(
                delivery: Self.foregroundKeyboardDelivery,
                evidence: .deliveryAccepted,
                unitCount: dispatchedUnitCount,
                message: failureMessage,
                hint: "Observe the exact dialog and field before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private func dispatchValidatedDialogInput(
        _ execution: RetainedDialogInputPlan,
        focusMutationDispatched: Bool) throws -> DesktopActionOutcome.DispatchUnitCount?
    {
        try self.dispatchDialogInput(
            text: execution.text,
            clearExisting: execution.clearExisting,
            validateEachCharacter: true,
            unitFocusValidation: { dispatchedKeyboardUnits in
                do {
                    try self.focusService.requireDialogDispatchFocus(
                        target: execution.dialog.target,
                        retainedWindow: execution.dialog.window,
                        dialog: execution.dialog.dialog,
                        field: execution.field)
                } catch {
                    throw Self.dialogDispatchFocusFailure(
                        focusMutationDispatched: focusMutationDispatched,
                        dispatchedKeyboardUnits: dispatchedKeyboardUnits,
                        cause: error)
                }
            })
    }

    private func logDialogInput(_ execution: RetainedDialogInputPlan) {
        self.logger.info("Entering text into dialog field")
        self.logger.debug(
            "Text length: \(execution.text.count) chars, clear existing: \(execution.clearExisting)")
        if let fieldIdentifier = execution.fieldIdentifier {
            self.logger.debug("Target field: \(fieldIdentifier)")
        }
    }

    func forceDismissDialog(windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        try await self.operationLaneCoordinator.run(scope: Self.forcedDismissMutationScope, access: .write) {
            let plan = try await self.prepareForegroundDialogPlan(windowTitle: windowTitle, appName: appName)
            return try await self.executeForcedDialogDismiss(
                plan: plan,
                focus: DialogForegroundFocusPolicy(autoFocus: false))
        }
    }

    public func forceDismissDialog(_ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult {
        try await self.operationLaneCoordinator.run(scope: Self.forcedDismissMutationScope, access: .write) {
            let candidates = try await self.targetedDialogCandidates(
                target: request.target,
                membership: .structuralMutation)
            guard candidates.count == 1, let candidate = candidates.first else {
                throw self.dialogCandidateRefusal(target: request.target, candidates: candidates)
            }
            let plan = ForegroundDialogPlan(
                target: candidate.target,
                resolvedTarget: candidate.resolvedTarget,
                window: candidate.window,
                dialog: candidate.dialog)
            return try await self.executeForcedDialogDismiss(plan: plan, focus: request.focus)
        }
    }

    private func executeForcedDialogDismiss(
        plan: ForegroundDialogPlan,
        focus: DialogForegroundFocusPolicy) async throws -> DialogActionResult
    {
        do {
            try await self.revalidateDialogTarget(
                target: plan.target,
                retainedWindow: plan.window,
                retainedDialog: plan.dialog,
                operation: "forced Escape")
            try Task.checkCancellation()
            try await self.establishDialogWindowFocus(plan: plan, policy: focus)
            do {
                try Task.checkCancellation()
                try self.focusService.requireDialogGlobalKeyboardFocus(
                    target: plan.target,
                    retainedWindow: plan.window,
                    dialog: plan.dialog)
            } catch is CancellationError where !focus.autoFocus {
                throw CancellationError()
            } catch {
                // Automatic focus may already have activated or raised the retained window.
                // Preserve that possible side effect instead of erasing it as bare cancellation.
                throw Self.dialogWindowFocusFailure(autoFocus: focus.autoFocus, cause: error)
            }
            do {
                try Task.checkCancellation()
            } catch {
                throw Self.dialogWindowFocusFailure(autoFocus: focus.autoFocus, cause: error)
            }
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
                outcome: outcome,
                targetReceipt: Self.desktopActionTargetReceipt(plan.target),
                targetWindowIdentity: plan.target.identity,
                targetWindowBounds: plan.target.bounds,
                focusedElement: plan.target.focusedElement,
                resolvedTarget: plan.resolvedTarget)
        } catch let failure as DesktopActionFailure {
            throw Self.attributedDialogActionFailure(failure, target: plan.target)
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

    func revalidateDialogInputField(
        _ retainedField: Element,
        in dialog: Element,
        identifier: String?,
        exactSelection: Bool = false) throws -> Element
    {
        let selected = if exactSelection {
            try self.exactDialogInputField(in: dialog, identifier: identifier)
        } else {
            try self.textField(in: dialog, identifier: identifier)
        }
        guard Self.sameElement(selected, retainedField),
              Self.rawElementPresence(retainedField, in: dialog) == .present
        else {
            throw self.targetUnavailable("Prepared dialog input field changed before keyboard delivery.")
        }
        return selected
    }

    func exactDialogInputField(in dialog: Element, identifier: String?) throws -> Element {
        let textFields = self.collectTextFields(from: dialog)
        guard !textFields.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact dialog contains no text fields.",
                hint: "List the exact dialog again before retrying.")
        }
        if let identifier, let index = Int(identifier) {
            guard textFields.indices.contains(index) else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Dialog text field index \(index) is unavailable.",
                    hint: "List the exact dialog and provide one current field index.")
            }
            return textFields[index]
        }

        let matches: [Element] = if let identifier {
            textFields.filter { field in
                field.title() == identifier ||
                    field.attribute(Attribute<String>("AXPlaceholderValue")) == identifier ||
                    field.descriptionText()?.contains(identifier) == true
            }
        } else {
            textFields
        }
        guard matches.count == 1, let field = matches.first else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: matches.isEmpty
                    ? "No dialog text field matched the exact input request."
                    : "Dialog text field selection is ambiguous across \(matches.count) matches.",
                hint: "List the exact dialog and provide one unique field label, placeholder, or index.")
        }
        return field
    }

    func dialogInputDetails(
        plan: ForegroundDialogPlan,
        field: Element,
        textLength: Int,
        cleared: Bool,
        valueVerified: Bool,
        focusPolicy: DialogForegroundFocusPolicy = DialogForegroundFocusPolicy()) -> [String: String]
    {
        var details = Self.dialogTargetDetails(plan.target)
        details.merge([
            "dialog_identifier": self.dialogIdentifier(for: plan.dialog),
            "dialog_role": plan.dialog.role() ?? "Unknown",
            "dialog_title": plan.dialog.title() ?? "Untitled Dialog",
            "field": field.title() ?? "Text Field",
            "text_length": String(textLength),
            "cleared": String(cleared),
            "value_verified": String(valueVerified),
            "auto_focus": String(focusPolicy.autoFocus),
            "focus_timeout_seconds": String(focusPolicy.timeout),
            "focus_retry_count": String(focusPolicy.retryCount),
            "switch_space": String(focusPolicy.switchSpace),
            "bring_to_current_space": String(focusPolicy.bringToCurrentSpace),
        ]) { _, new in new }
        return details
    }

    static func dialogInputFocusOptions(
        _ policy: DialogForegroundFocusPolicy) -> FocusManagementService.FocusOptions
    {
        FocusManagementService.FocusOptions(
            timeout: policy.timeout,
            retryCount: policy.retryCount,
            switchSpace: policy.switchSpace,
            bringToCurrentSpace: policy.bringToCurrentSpace)
    }

    static func dialogFieldFocusUnverifiedFailure() -> DesktopActionFailure {
        .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one,
            message: "Dialog field focus mutation was accepted but focus did not remain verified.",
            hint: "Refresh the dialog and select one exact field before retrying.")
    }

    static func dialogWindowFocusFailure(
        autoFocus: Bool,
        cause: any Error) -> DesktopActionFailure
    {
        if autoFocus {
            return .indeterminate(
                evidence: .completionUnknown,
                message: "Dialog window focus failed after foreground focus may have started.",
                hint: "Observe the exact dialog before retrying keyboard input.",
                causeDescription: cause.localizedDescription)
        }
        return .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "The exact dialog did not have verified foreground focus before keyboard input.",
            hint: "Focus the exact dialog or enable automatic focus before retrying.",
            causeDescription: cause.localizedDescription)
    }

    private func establishDialogWindowFocus(
        plan: ForegroundDialogPlan,
        policy: DialogForegroundFocusPolicy) async throws
    {
        do {
            if policy.autoFocus {
                try await self.focusService.focusDialogWindowWithOwnedLane(
                    target: plan.target,
                    dialog: plan.dialog,
                    options: Self.dialogInputFocusOptions(policy))
            } else {
                try await self.focusService.requireDialogWindowFocusWithOwnedLane(
                    target: plan.target,
                    dialog: plan.dialog,
                    timeout: policy.timeout)
            }
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch is CancellationError where !policy.autoFocus {
            throw CancellationError()
        } catch {
            throw Self.dialogWindowFocusFailure(autoFocus: policy.autoFocus, cause: error)
        }
    }

    static func dialogDispatchFocusFailure(
        focusMutationDispatched: Bool,
        dispatchedKeyboardUnits: Int,
        cause: any Error) -> DesktopActionFailure
    {
        if dispatchedKeyboardUnits > 0 {
            return .dispatchedUnverified(
                delivery: self.foregroundKeyboardDelivery,
                evidence: .deliveryAccepted,
                unitCount: self.dispatchUnitCount(dispatchedKeyboardUnits),
                message: "Dialog field lost exact focus after keyboard delivery started.",
                hint: "Observe the exact dialog field before any retry.",
                causeDescription: cause.localizedDescription)
        }
        if focusMutationDispatched {
            return .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one,
                message: "Dialog lost exact foreground focus after field focus was accepted.",
                hint: "Observe the exact dialog and field before retrying.",
                causeDescription: cause.localizedDescription)
        }
        return .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Dialog lost exact foreground focus before keyboard delivery.",
            hint: "Focus the exact dialog or enable automatic focus before retrying.",
            causeDescription: cause.localizedDescription)
    }

    func dispatchDialogInput(text: String, clearExisting: Bool) throws
        -> DesktopActionOutcome.DispatchUnitCount?
    {
        try self.dispatchDialogInput(
            text: text,
            clearExisting: clearExisting,
            unitFocusValidation: { _ in })
    }

    func dispatchDialogInput(
        text: String,
        clearExisting: Bool,
        validateEachCharacter: Bool = false,
        unitFocusValidation: (Int) throws -> Void) throws -> DesktopActionOutcome.DispatchUnitCount?
    {
        var dispatchedUnits = 0
        if clearExisting {
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try unitFocusValidation(dispatchedUnits)
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                try self.syntheticInputDriver.hotkey(keys: ["cmd", "a"], holdDuration: 0.05)
            }
            dispatchedUnits += 1
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try unitFocusValidation(dispatchedUnits)
            try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
            try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                try self.syntheticInputDriver.tapKey(.delete, modifiers: [])
            }
            dispatchedUnits += 1
        }
        if !text.isEmpty {
            if validateEachCharacter {
                var typeUnitStarted = false
                for character in text {
                    let effectiveUnits = dispatchedUnits + (typeUnitStarted ? 1 : 0)
                    try self.checkDialogInputCancellation(dispatchedUnits: effectiveUnits)
                    try unitFocusValidation(effectiveUnits)
                    try self.checkDialogInputCancellation(dispatchedUnits: effectiveUnits)
                    // Text entry is one logical dispatch unit even when emitted character by character.
                    // The wrapper adds that possibly-started unit; passing effectiveUnits would double-count it.
                    try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                        try self.syntheticInputDriver.type(String(character), delayPerCharacter: 0.01)
                    }
                    typeUnitStarted = true
                }
                if typeUnitStarted {
                    dispatchedUnits += 1
                }
            } else {
                try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
                try unitFocusValidation(dispatchedUnits)
                try self.checkDialogInputCancellation(dispatchedUnits: dispatchedUnits)
                try self.dispatchDialogInputUnit(dispatchedUnits: dispatchedUnits) {
                    try self.syntheticInputDriver.type(text, delayPerCharacter: 0.01)
                }
                dispatchedUnits += 1
            }
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
            return self.uncachedDialogInputValue(from: field)
        }

        var lastReadableValue: String?
        for attempt in 0..<5 {
            try Task.checkCancellation()
            if let value = self.uncachedDialogInputValue(from: field) {
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

    private func uncachedDialogInputValue(from field: Element) -> String? {
        // Element.value() deliberately prefers traversal-prefetched attributes. Those values can
        // predate global keyboard delivery, so only a fresh AXValue read is postcondition evidence.
        field.rawAttributeValue(named: AXAttributeNames.kAXValueAttribute) as? String
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
            resolvedTarget: candidate.resolvedTarget,
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
