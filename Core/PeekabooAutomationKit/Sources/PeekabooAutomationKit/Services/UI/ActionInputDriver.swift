import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

enum ActionInputUnsupportedReason: String, Codable, Equatable {
    case actionUnsupported
    case attributeUnsupported
    case valueNotSettable
    case secureValueNotAllowed
    case menuShortcutUnavailable
    case missingElement
}

enum ActionInputError: Error, Equatable {
    case unsupported(ActionInputUnsupportedReason)
    case staleElement
    case permissionDenied
    case targetUnavailable
    case failed(String)
}

extension ActionInputUnsupportedReason: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .actionUnsupported:
            "Accessibility action is not supported"
        case .attributeUnsupported:
            "Accessibility attribute is not supported"
        case .valueNotSettable:
            "Accessibility value is not settable"
        case .secureValueNotAllowed:
            "Direct value setting is not allowed for secure text fields"
        case .menuShortcutUnavailable:
            "No menu item matches that shortcut"
        case .missingElement:
            "No accessibility element is available for action invocation"
        }
    }
}

extension ActionInputError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .unsupported(reason):
            reason.errorDescription
        case .staleElement:
            "Accessibility element is stale; run see again"
        case .permissionDenied:
            "Accessibility permission is denied"
        case .targetUnavailable:
            "Accessibility target is unavailable"
        case let .failed(reason):
            reason
        }
    }
}

@MainActor
protocol ActionInputDriving: Sendable {
    func tryClick(element: AutomationElement, beforeMutation: @MainActor () throws -> Void) async throws
        -> UIInputExecutionResult.Action
    func tryClick(
        element: AutomationElement,
        allowAccessibilityValueFallback: Bool, beforeMutation: @MainActor () throws -> Void) async throws
        -> UIInputExecutionResult.Action
    func tryFocus(
        element: any AutomationElementRepresenting,
        beforeMutation: @MainActor () throws -> Void) async throws -> UIInputExecutionResult.Action
    func tryRightClick(element: any AutomationElementRepresenting) async throws -> UIInputExecutionResult.Action
    func tryScroll(
        element: AutomationElement,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> UIInputExecutionResult.Action
    func trySetText(
        element: AutomationElement,
        text: String,
        replace: Bool,
        beforeMutation: @MainActor () throws -> Void) async throws -> UIInputExecutionResult
        .Action
    func tryHotkey(application: NSRunningApplication, keys: [String]) throws -> UIInputExecutionResult.Action
    func trySetValue(
        element: AutomationElement,
        value: UIElementValue,
        beforeMutation: @MainActor () throws -> Void) async throws -> UIInputExecutionResult.Action
    func tryPerformAction(element: AutomationElement, actionName: String) throws -> UIInputExecutionResult.Action
}

extension ActionInputDriving {
    func tryClick(
        element: AutomationElement,
        allowAccessibilityValueFallback: Bool,
        beforeMutation: @MainActor () throws -> Void) async throws -> UIInputExecutionResult.Action
    {
        guard allowAccessibilityValueFallback else {
            throw ActionInputError.unsupported(.actionUnsupported)
        }
        return try await self.tryClick(element: element, beforeMutation: beforeMutation)
    }

    func tryFocus(
        element _: any AutomationElementRepresenting,
        beforeMutation: @MainActor () throws -> Void) async throws -> UIInputExecutionResult.Action
    {
        throw ActionInputError.unsupported(.attributeUnsupported)
    }
}

/// Accessibility action implementation for action-first UI input.
@MainActor
struct ActionInputDriver: ActionInputDriving {
    private let observationDelay: @MainActor @Sendable () async throws -> Void
    private let processStartIdentity: @Sendable (pid_t) -> UInt64?
    private let nativeReader: AXMutationNativeReader

    init(
        observationDelay: @escaping @MainActor @Sendable () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(20))
        },
        processStartIdentity: @escaping @Sendable (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity,
        nativeReader: @escaping AXMutationNativeReader = DetachedAXMutationReader.read)
    {
        self.observationDelay = observationDelay
        self.processStartIdentity = processStartIdentity
        self.nativeReader = nativeReader
    }

    private static let accessibilityActionDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)
    private static let accessibilityValueDelivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityValue,
        mode: .background)

    func tryClick(
        element: AutomationElement,
        beforeMutation: @MainActor () throws -> Void = {}) async throws -> UIInputExecutionResult.Action
    {
        try await self.tryClick(element: element, allowAccessibilityValueFallback: true, beforeMutation: beforeMutation)
    }

    func tryClick(
        element: AutomationElement,
        allowAccessibilityValueFallback: Bool,
        beforeMutation: @MainActor () throws -> Void = {}) async throws -> UIInputExecutionResult.Action
    {
        do {
            return try self.performAction(AXActionNames.kAXPressAction, on: element, beforeMutation: beforeMutation)
        } catch let error as ActionInputError
            where error == .unsupported(.actionUnsupported) &&
            allowAccessibilityValueFallback &&
            Self.canFocusForClick(
                role: element.role,
                subrole: element.subrole,
                isValueSettable: element.isValueSettable,
                isFocusedSettable: element.isFocusedSettable)
        {
            return try await self.focusForClick(element, beforeMutation: beforeMutation)
        }
    }

    func tryFocus(
        element: any AutomationElementRepresenting,
        beforeMutation: @MainActor () throws -> Void = {}) async throws -> UIInputExecutionResult.Action
    {
        guard element.isFocusedSettable else {
            throw FocusedElementReceiptError.focusedAttributeNotSettable
        }
        return try await self.focusForClick(element, beforeMutation: beforeMutation)
    }

    func tryRightClick(element: any AutomationElementRepresenting) async throws -> UIInputExecutionResult.Action {
        do {
            return try await self.performShowMenuAction(on: element)
        } catch ActionInputError.targetUnavailable {
            throw ActionInputError.unsupported(.actionUnsupported)
        }
    }

    /// Issues `AXShowMenu` without waiting on the menu's tracking runloop.
    ///
    /// A successful `AXShowMenu` opens an NSMenu whose tracking loop is a nested runloop on the
    /// target app's main thread, so `AXUIElementPerformAction` does not return until the menu is
    /// dismissed. Awaiting it deadlocks the caller (and blocks a bridge host's main actor) until
    /// the client times out even though the menu is visibly open. The action is therefore issued
    /// from a detached thread; if it is still running after a short grace period, the menu is
    /// considered accepted but unverified and the right-click returns without blocking.
    private func performShowMenuAction(on element: any AutomationElementRepresenting) async throws
        -> UIInputExecutionResult.Action
    {
        // Attribute reads happen before the action while the target app is still responsive.
        let anchorPoint = element.anchorPoint
        let elementRole = element.role

        guard let axElement = element.underlyingAXElement else {
            // In-memory test elements have no AX identity and cannot block; act synchronously.
            return try self.performAction(AXActionNames.kAXShowMenuAction, on: element)
        }

        do {
            let outcome = try await DetachedAXActionRunner.perform(
                action: AXActionNames.kAXShowMenuAction,
                on: axElement,
                gracePeriod: DetachedAXActionRunner.showMenuGracePeriod)
            return UIInputExecutionResult.Action(
                outcome: outcome,
                actionName: AXActionNames.kAXShowMenuAction,
                anchorPoint: anchorPoint,
                elementRole: elementRole)
        } catch {
            throw Self.classify(error)
        }
    }

    func tryScroll(
        element: AutomationElement,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> UIInputExecutionResult.Action
    {
        try self.performScrollActions(element: element, direction: direction, pages: pages)
    }

    func trySetText(
        element: AutomationElement,
        text: String,
        replace: Bool,
        beforeMutation: @MainActor () throws -> Void = {}) async throws
        -> UIInputExecutionResult.Action
    {
        guard replace else {
            throw ActionInputError.unsupported(.attributeUnsupported)
        }
        return try await self.trySetValue(element: element, value: .string(text), beforeMutation: beforeMutation)
    }

    func tryHotkey(application: NSRunningApplication, keys: [String]) throws -> UIInputExecutionResult.Action {
        let chord = try MenuHotkeyChord(keys: keys)
        let appElement = AXApp(application).element
        guard let menuBar = appElement.menuBarWithTimeout(timeout: 1.0).map(AutomationElement.init) else {
            throw ActionInputError.unsupported(.missingElement)
        }

        guard let menuItem = self.findMenuItem(matching: chord, in: menuBar) else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }

        return try self.performAction(AXActionNames.kAXPressAction, on: menuItem)
    }

    func trySetValue(
        element: AutomationElement,
        value: UIElementValue,
        beforeMutation: @MainActor () throws -> Void = {}) async throws -> UIInputExecutionResult.Action
    {
        try await self.setValue(value, on: element, beforeMutation: beforeMutation)
    }

    func tryPerformAction(element: AutomationElement, actionName: String) throws -> UIInputExecutionResult.Action {
        try self.performAction(actionName, on: element)
    }

    nonisolated static func classify(_ error: any Error) -> ActionInputError {
        if let actionError = error as? ActionInputError {
            return actionError
        }

        if let systemError = error as? AccessibilitySystemError {
            return self.classify(systemError.axError)
        }

        return .failed(error.localizedDescription)
    }

    nonisolated static func classify(_ error: AXError) -> ActionInputError {
        switch error {
        case .actionUnsupported:
            .unsupported(.actionUnsupported)
        case .attributeUnsupported, .parameterizedAttributeUnsupported:
            .unsupported(.attributeUnsupported)
        case .invalidUIElement, .invalidUIElementObserver:
            .staleElement
        case .apiDisabled:
            .permissionDenied
        case .cannotComplete, .failure:
            .targetUnavailable
        default:
            .failed(error.localizedDescription)
        }
    }

    nonisolated static func setValueRejectionReason(
        role: String?,
        subrole: String?,
        isValueSettable: Bool,
        isSelectedSettable: Bool = false) -> ActionInputUnsupportedReason?
    {
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            return .secureValueNotAllowed
        }
        if !isValueSettable, !isSelectedSettable {
            return .valueNotSettable
        }
        return nil
    }

    nonisolated static func shouldContinueTryingScrollAction(after error: ActionInputError) -> Bool {
        error.isUnsupported
    }

    nonisolated static func canFocusForClick(
        role: String?,
        subrole: String?,
        isValueSettable: Bool,
        isFocusedSettable: Bool) -> Bool
    {
        guard isFocusedSettable else { return false }
        switch role {
        case "AXTextField", "AXTextArea", "AXComboBox":
            return true
        default:
            return subrole == "AXSearchField" || isValueSettable
        }
    }

    nonisolated static func tabPressDidNotSelect(
        subrole: String?,
        valueBefore: Int?,
        valueAfter: Int?) -> Bool
    {
        subrole == "AXTabButton" && valueBefore == 0 && valueAfter == 0
    }

    nonisolated static func scrollFallbackError(from error: ActionInputError?) -> ActionInputError {
        error ?? .unsupported(.actionUnsupported)
    }

    private nonisolated static func scrollFailureMayHaveDispatched(_ error: ActionInputError) -> Bool {
        switch error {
        case .targetUnavailable, .failed:
            true
        case .unsupported, .staleElement, .permissionDenied:
            false
        }
    }

    private nonisolated static func scrollProgressFailure(
        completedUnitCount: Int,
        currentUnitMayHaveDispatched: Bool,
        requestedUnitCount: Int,
        delivery: DesktopActionOutcome.Delivery,
        cause: ActionInputError) -> DesktopActionFailure
    {
        let possibleUnitCount = completedUnitCount + (currentUnitMayHaveDispatched ? 1 : 0)
        let message = "Scroll stopped after \(completedUnitCount) of \(requestedUnitCount) requested units"
        let hint = "Observe the target before taking another scroll action."
        if currentUnitMayHaveDispatched {
            return .indeterminate(
                delivery: delivery,
                evidence: .completionUnknown,
                unitCount: DesktopActionOutcome.DispatchUnitCount(possibleUnitCount),
                message: message,
                hint: hint,
                causeDescription: cause.localizedDescription)
        }
        return .partial(
            delivery: delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(completedUnitCount),
            message: message,
            hint: hint,
            causeDescription: cause.localizedDescription)
    }

    private func performAction(
        _ actionName: String,
        on element: any AutomationElementRepresenting,
        beforeMutation: @MainActor () throws -> Void = {}) throws -> UIInputExecutionResult.Action
    {
        if actionName == AXActionNames.kAXPressAction {
            try Task.checkCancellation()
        }
        guard element.supportsAction(actionName) else {
            throw ActionInputError.unsupported(.actionUnsupported)
        }
        try beforeMutation()
        if actionName == AXActionNames.kAXPressAction {
            try Task.checkCancellation()
        }

        do {
            try element.performAutomationAction(actionName)
            return UIInputExecutionResult.Action(
                outcome: .dispatchedUnverified(
                    delivery: Self.accessibilityActionDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                actionName: actionName,
                anchorPoint: element.anchorPoint,
                elementRole: element.role)
        } catch {
            throw Self.classify(error)
        }
    }

    private func focusForClick(
        _ element: any AutomationElementRepresenting,
        beforeMutation: @MainActor () throws -> Void = {}) async throws
        -> UIInputExecutionResult.Action
    {
        guard let wasFocused = element.focusedState else {
            throw FocusedElementReceiptError.focusedAttributeUnreadable
        }
        if wasFocused {
            guard let focusedElement = element.focusedElementIdentity else {
                throw FocusedElementReceiptError.missingWindowIdentifier
            }
            return UIInputExecutionResult.Action(
                outcome: .confirmedNoChange(),
                actionName: AXAttributeNames.kAXFocusedAttribute,
                anchorPoint: element.anchorPoint,
                elementRole: element.role,
                focusedElement: focusedElement)
        }
        let observationTarget = try await self.observationTarget(element)
        try Self.validateBeforeMutation(beforeMutation)
        do {
            try element.setAutomationFocused(true)
        } catch {
            throw Self.classify(error)
        }
        var confirmedIdentity: FocusedElementIdentity?
        guard await self.observeMutation(
            on: element,
            target: observationTarget,
            attribute: .focused,
            matches: { sample in
                if let sample {
                    confirmedIdentity = sample.identity
                    return sample.focused == true
                }
                confirmedIdentity = element.focusedElementIdentity
                return element.focusedState == true
            })
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: Self.accessibilityValueDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: FocusedElementReceiptError.focusNotConfirmed.localizedDescription,
                hint: "Observe the exact field before deciding whether to retry focus.")
        }
        guard let focusedElement = confirmedIdentity else {
            throw DesktopActionFailure.indeterminate(
                delivery: Self.accessibilityValueDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Native focus succeeded but its exact element receipt is incomplete.",
                hint: "Capture fresh exact-window UI state before retrying.")
        }
        return UIInputExecutionResult.Action(
            outcome: .confirmedChange(
                delivery: Self.accessibilityValueDelivery,
                unitCount: .one),
            actionName: AXAttributeNames.kAXFocusedAttribute,
            anchorPoint: CGPoint(x: focusedElement.frame.midX, y: focusedElement.frame.midY),
            elementRole: focusedElement.role,
            focusedElement: focusedElement)
    }

    private func setValue(
        _ value: UIElementValue,
        on element: any AutomationElementRepresenting,
        beforeMutation: @MainActor () throws -> Void = {})
        async throws -> UIInputExecutionResult.Action
    {
        if let rejectionReason = Self.setValueRejectionReason(
            role: element.role,
            subrole: element.subrole,
            isValueSettable: element.isValueSettable,
            isSelectedSettable: element.isSelectedSettable)
        {
            throw ActionInputError.unsupported(rejectionReason)
        }

        do {
            if !element.isValueSettable, element.isSelectedSettable {
                let requested = try ElementValueMutationSemantics.booleanValue(value, role: element.role)
                let selectedBefore = element.selectedValue
                if let selectedBefore, selectedBefore == requested {
                    return UIInputExecutionResult.Action(
                        outcome: .confirmedNoChange(),
                        actionName: kAXSelectedAttribute as String,
                        anchorPoint: element.anchorPoint,
                        elementRole: element.role,
                        valueVerification: .init(
                            attribute: .selected, resolvedKind: .bool, readback: .bool(selectedBefore)))
                }
                let observationTarget = try await self.observationTarget(element)
                try Self.validateBeforeMutation(beforeMutation)
                try element.setAutomationSelected(requested)
                var selectedAfter: Bool?
                var observedIdentity: FocusedElementIdentity?
                guard await self.observeMutation(
                    on: element,
                    target: observationTarget,
                    attribute: .selected,
                    matches: { sample in
                        observedIdentity = sample?.identity
                        selectedAfter = if let sample {
                            sample.selected
                        } else {
                            element.selectedValue
                        }
                        return selectedAfter == requested
                    }), let selectedAfter
                else {
                    throw Self.unverifiedValueMutationFailure(attribute: kAXSelectedAttribute as String)
                }
                let outcome = Self.dispatchedValueMutationOutcome(preStateKnown: selectedBefore != nil)
                return UIInputExecutionResult.Action(
                    outcome: outcome,
                    actionName: kAXSelectedAttribute as String,
                    anchorPoint: observedIdentity.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? element
                        .anchorPoint,
                    elementRole: observedIdentity?.role ?? element.role,
                    valueVerification: .init(
                        attribute: .selected, resolvedKind: .bool, readback: .bool(selectedAfter)))
            }

            let valueBefore = element.value
            let readbackBefore = ElementValueReadback(nativeValue: valueBefore)
            guard !(valueBefore is NSNumber) || readbackBefore != nil else {
                throw ActionInputError.failed("Native accessibility integer is outside the supported Int range")
            }
            let requested = try Self.coerceValue(value, currentValue: valueBefore, role: element.role)
            let alreadyMatched = ElementValueMutationSemantics.matches(readbackBefore, expected: requested)
            if alreadyMatched {
                guard let readbackBefore, readbackBefore.isFinite else {
                    throw ActionInputError.failed("Expected a finite native readback")
                }
                return UIInputExecutionResult.Action(
                    outcome: .confirmedNoChange(),
                    actionName: AXActionNames.kAXSetValueAction,
                    anchorPoint: element.anchorPoint,
                    elementRole: element.role,
                    valueVerification: .init(
                        attribute: .value,
                        resolvedKind: requested.comparisonKind,
                        readback: readbackBefore,
                        legacyPresentation: NativeElementValuePresentation.describe(valueBefore)))
            }
            let observationTarget = try await self.observationTarget(element)
            try Self.validateBeforeMutation(beforeMutation)
            try element.setAutomationValue(requested)
            var presentationAfter: String?
            var readbackAfter: ElementValueReadback?
            var observedIdentity: FocusedElementIdentity?
            guard await self.observeMutation(
                on: element,
                target: observationTarget,
                attribute: .value,
                matches: { sample in
                    if let sample {
                        observedIdentity = sample.identity
                        presentationAfter = sample.legacyPresentation
                        readbackAfter = sample.value
                    } else {
                        guard element.role != "AXSecureTextField", element.subrole != "AXSecureTextField" else {
                            return false
                        }
                        let valueAfter = element.value
                        presentationAfter = NativeElementValuePresentation.describe(valueAfter)
                        readbackAfter = ElementValueReadback(nativeValue: valueAfter)
                    }
                    return readbackAfter?.isFinite == true &&
                        ElementValueMutationSemantics.matches(readbackAfter, expected: requested)
                }), let readbackAfter
            else {
                throw Self.unverifiedValueMutationFailure(attribute: AXActionNames.kAXSetValueAction)
            }
            let outcome = Self.dispatchedValueMutationOutcome(preStateKnown: valueBefore != nil)
            return UIInputExecutionResult.Action(
                outcome: outcome,
                actionName: AXActionNames.kAXSetValueAction,
                anchorPoint: observedIdentity.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) } ?? element
                    .anchorPoint,
                elementRole: observedIdentity?.role ?? element.role,
                valueVerification: .init(
                    attribute: .value,
                    resolvedKind: requested.comparisonKind,
                    readback: readbackAfter,
                    legacyPresentation: presentationAfter))
        } catch let cancellation as CancellationError {
            throw cancellation
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw Self.classify(error)
        }
    }

    func performObservedMutation(
        on element: any AutomationElementRepresenting,
        attribute: AXMutationObservationAttribute,
        beforeMutation: @MainActor () throws -> Void = {},
        mutation: () throws -> FocusedTextKeyDispatch,
        matches: (AXMutationObservationSnapshot?) -> Bool) async throws -> FocusedTextKeyDispatch
    {
        let target = try await self.observationTarget(element)
        try Self.validateBeforeMutation(beforeMutation)
        let dispatch = try mutation()
        guard dispatch == .accessibilityValue else { return dispatch }
        guard await self.observeMutation(on: element, target: target, attribute: attribute, matches: matches) else {
            throw Self.unverifiedValueMutationFailure(attribute: String(describing: attribute))
        }
        return dispatch
    }

    private static func validateBeforeMutation(_ beforeMutation: @MainActor () throws -> Void) throws {
        try beforeMutation()
        try Task.checkCancellation()
    }

    private struct ObservationTarget {
        let element: FocusedElementIdentity
        let processGeneration: UInt64
    }

    private func observationTarget(_ element: any AutomationElementRepresenting) async throws -> ObservationTarget? {
        try Task.checkCancellation()
        if let native = element.underlyingAXElement {
            let unavailable = DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The native Accessibility target could not be revalidated before mutation.")
            do {
                var pid: pid_t = 0
                guard AXUIElementGetPid(native, &pid) == .success,
                      let generation = self.processStartIdentity(pid)
                else { throw unavailable }
                let sample = try await self.nativeReader(
                    RetainedFocusElement(element: native),
                    AXMutationObservationTarget(processIdentifier: pid, processStartIdentity: generation),
                    .identity,
                    .milliseconds(250))
                try Task.checkCancellation()
                guard let sample, self.processStartIdentity(pid) == generation else { throw unavailable }
                return ObservationTarget(element: sample.identity, processGeneration: generation)
            } catch let cancellation as CancellationError {
                throw cancellation
            } catch {
                try Task.checkCancellation()
                throw unavailable
            }
        }
        guard let identity = element.focusedElementIdentity,
              let generation = self.processStartIdentity(identity.processIdentifier)
        else { return nil }
        return ObservationTarget(element: identity, processGeneration: generation)
    }

    private func observationTargetIsCurrent(
        _ target: ObservationTarget,
        element: any AutomationElementRepresenting) -> Bool
    {
        guard self.processStartIdentity(target.element.processIdentifier) == target.processGeneration,
              let current = element.focusedElementIdentity,
              FocusedElementReceiptResolver.matches(current, expected: target.element, phase: .continuation)
        else { return false }
        return true
    }

    /// AX setters may acknowledge queued work before the app publishes its new tree.
    /// Re-observe the same element; never redispatch the mutation or resolve a replacement.
    private func observeMutation(
        on element: any AutomationElementRepresenting,
        target: ObservationTarget?,
        attribute: AXMutationObservationAttribute,
        matches: (AXMutationObservationSnapshot?) -> Bool) async -> Bool
    {
        let nativeElement = element.underlyingAXElement.map { RetainedFocusElement(element: $0) }
        guard nativeElement == nil || target != nil else { return false }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        for sampleIndex in 0..<14 {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return false }
            let matched: Bool
            if let nativeElement, let target {
                let remaining = ContinuousClock.now.duration(to: deadline)
                let sample: AXMutationObservationSnapshot?
                do {
                    sample = try await self.nativeReader(
                        nativeElement,
                        AXMutationObservationTarget(
                            processIdentifier: target.element.processIdentifier,
                            processStartIdentity: target.processGeneration,
                            expectedIdentity: target.element),
                        attribute,
                        remaining)
                } catch {
                    return false
                }
                guard !Task.isCancelled,
                      ContinuousClock.now < deadline,
                      self.processStartIdentity(target.element.processIdentifier) == target.processGeneration
                else { return false }
                matched = sample.map { matches($0) } ?? false
            } else {
                if let target, !self.observationTargetIsCurrent(target, element: element) {
                    return false
                }
                matched = matches(nil)
                if let target, !self.observationTargetIsCurrent(target, element: element) {
                    return false
                }
            }
            if matched {
                return true
            }
            guard target != nil, sampleIndex < 13,
                  ContinuousClock.now.advanced(by: .milliseconds(20)) < deadline
            else { return false }
            do {
                try await self.observationDelay()
            } catch {
                return false
            }
        }
        return false
    }

    private static func unverifiedValueMutationFailure(attribute: String) -> DesktopActionFailure {
        .indeterminate(
            delivery: self.accessibilityValueDelivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "The accessibility value write was accepted, but its requested result could not be verified.",
            hint: "Observe the exact target before deciding whether to retry; do not reuse the prior snapshot.",
            causeDescription: "Post-dispatch readback did not confirm \(attribute).")
    }

    private static func dispatchedValueMutationOutcome(preStateKnown: Bool) -> DesktopActionOutcome {
        if preStateKnown {
            return .confirmedChange(delivery: self.accessibilityValueDelivery)
        }
        return .dispatchedUnverified(
            delivery: self.accessibilityValueDelivery,
            evidence: .deliveryAccepted)
    }

    private nonisolated static func coerceValue(
        _ requested: UIElementValue,
        currentValue: Any?,
        role: String?) throws -> UIElementValue
    {
        let currentKind = ElementValueReadback(nativeValue: currentValue)?.kind
        if self.isTextRole(role) || currentValue is String {
            return try ElementValueMutationSemantics.coerce(requested, to: .string)
        }
        if self.isBooleanRole(role) || currentKind == .bool {
            return try ElementValueMutationSemantics.coerce(requested, to: .bool, role: role)
        }
        if self.isNumericRole(role) {
            return try ElementValueMutationSemantics.coerce(requested, to: .double)
        }

        switch currentKind {
        case .int:
            return try ElementValueMutationSemantics.coerce(requested, to: .int)
        case .double:
            return try ElementValueMutationSemantics.coerce(requested, to: .double)
        case .bool, .string:
            // Handled above.
            return requested
        case nil:
            return requested
        }
    }

    private nonisolated static func isTextRole(_ role: String?) -> Bool {
        switch role {
        case AXRoleNames.kAXTextFieldRole, AXRoleNames.kAXTextAreaRole, AXRoleNames.kAXComboBoxRole:
            true
        default:
            false
        }
    }

    private nonisolated static func isBooleanRole(_ role: String?) -> Bool {
        switch role {
        case AXRoleNames.kAXCheckBoxRole, AXRoleNames.kAXRadioButtonRole, "AXSwitch", "AXToggle":
            true
        default:
            false
        }
    }

    private nonisolated static func isNumericRole(_ role: String?) -> Bool {
        role == "AXSlider"
    }
}

extension ActionInputDriver {
    private func scrollActionNames(for direction: PeekabooFoundation.ScrollDirection) -> [String] {
        switch direction {
        case .up:
            ["AXScrollUpByPage", "AXPageUp"]
        case .down:
            ["AXScrollDownByPage", "AXPageDown"]
        case .left:
            ["AXScrollLeftByPage", "AXPageLeft"]
        case .right:
            ["AXScrollRightByPage", "AXPageRight"]
        }
    }

    private func performScrollActions(
        element: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> UIInputExecutionResult.Action
    {
        let scrollBar = self.findScrollBar(in: element, direction: direction)
        if let scrollBar,
           let change = Self.scrollBarValueChange(scrollBar, direction: direction, pages: pages)
        {
            // Some native scroll areas advertise page actions that fail even though their bar is writable.
            // Choose the verifiable value route before dispatch; never retry an ambiguous action through it.
            do {
                return try self.performScrollbarValueScroll(scrollBar, change: change)
            } catch let error as ActionInputError where Self.shouldContinueTryingScrollAction(after: error) {
                // A definitively rejected value write leaves the page and increment routes available.
            }
        }

        do {
            return try self.performPageScrollActions(
                element: element,
                direction: direction,
                pages: pages)
        } catch let error as ActionInputError where Self.shouldContinueTryingScrollAction(after: error) {
            guard let scrollBar else { throw error }
            return try self.performScrollbarActions(
                scrollBar,
                direction: direction,
                pages: pages,
                pageActionError: error)
        }
    }

    private func performPageScrollActions(
        element: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> UIInputExecutionResult.Action
    {
        let actions = self.scrollActionNames(for: direction)
        let requestedPages = max(1, pages)
        var lastError: ActionInputError?
        var performedActionName: String?
        var completedPages = 0

        for _ in 0..<requestedPages {
            var performed = false
            for action in actions {
                do {
                    _ = try self.performAction(action, on: element)
                    performedActionName = action
                    performed = true
                    completedPages += 1
                    break
                } catch let error as ActionInputError {
                    lastError = error
                    if Self.scrollFailureMayHaveDispatched(error) {
                        throw Self.scrollProgressFailure(
                            completedUnitCount: completedPages,
                            currentUnitMayHaveDispatched: true,
                            requestedUnitCount: requestedPages,
                            delivery: Self.accessibilityActionDelivery,
                            cause: error)
                    }
                    if !Self.shouldContinueTryingScrollAction(after: error) {
                        if completedPages > 0 {
                            throw Self.scrollProgressFailure(
                                completedUnitCount: completedPages,
                                currentUnitMayHaveDispatched: false,
                                requestedUnitCount: requestedPages,
                                delivery: Self.accessibilityActionDelivery,
                                cause: error)
                        }
                        throw error
                    }
                }
            }

            if !performed {
                let error = Self.scrollFallbackError(from: lastError)
                if completedPages > 0 {
                    throw Self.scrollProgressFailure(
                        completedUnitCount: completedPages,
                        currentUnitMayHaveDispatched: false,
                        requestedUnitCount: requestedPages,
                        delivery: Self.accessibilityActionDelivery,
                        cause: error)
                }
                throw error
            }
        }

        return UIInputExecutionResult.Action(
            outcome: .dispatchedUnverified(
                delivery: Self.accessibilityActionDelivery,
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(completedPages)),
            actionName: performedActionName,
            anchorPoint: element.anchorPoint,
            elementRole: element.role)
    }

    private func performScrollbarActions(
        _ scrollBar: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int,
        pageActionError: ActionInputError) throws -> UIInputExecutionResult.Action
    {
        let actionName: String = switch direction {
        case .down, .right:
            AXActionNames.kAXIncrementAction
        case .up, .left:
            AXActionNames.kAXDecrementAction
        }
        if scrollBar.supportsAction(actionName) {
            let requestedPages = max(1, pages)
            var completedPages = 0
            for _ in 0..<requestedPages {
                do {
                    _ = try self.performAction(actionName, on: scrollBar)
                    completedPages += 1
                } catch let error as ActionInputError {
                    if Self.scrollFailureMayHaveDispatched(error) {
                        throw Self.scrollProgressFailure(
                            completedUnitCount: completedPages,
                            currentUnitMayHaveDispatched: true,
                            requestedUnitCount: requestedPages,
                            delivery: Self.accessibilityActionDelivery,
                            cause: error)
                    }
                    if completedPages > 0 {
                        throw Self.scrollProgressFailure(
                            completedUnitCount: completedPages,
                            currentUnitMayHaveDispatched: false,
                            requestedUnitCount: requestedPages,
                            delivery: Self.accessibilityActionDelivery,
                            cause: error)
                    }
                    guard Self.shouldContinueTryingScrollAction(after: error) else { throw error }
                    break
                }
            }
            if completedPages == requestedPages {
                return UIInputExecutionResult.Action(
                    outcome: .dispatchedUnverified(
                        delivery: Self.accessibilityActionDelivery,
                        evidence: .deliveryAccepted,
                        unitCount: DesktopActionOutcome.DispatchUnitCount(completedPages)),
                    actionName: actionName,
                    anchorPoint: scrollBar.anchorPoint,
                    elementRole: scrollBar.role)
            }
        }

        throw Self.scrollFallbackError(from: pageActionError)
    }

    private struct ScrollBarValueChange {
        let currentValue: Double
        let requestedValue: Double
    }

    private static func scrollBarValueChange(
        _ scrollBar: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) -> ScrollBarValueChange?
    {
        guard scrollBar.isValueSettable,
              let currentValue = self.numericValue(scrollBar.value)
        else { return nil }

        let minimumValue = scrollBar.doubleAttribute(AXAttributeNames.kAXMinValueAttribute) ?? 0
        let maximumValue = scrollBar.doubleAttribute(AXAttributeNames.kAXMaxValueAttribute) ?? 1
        let range = maximumValue - minimumValue
        guard minimumValue.isFinite, maximumValue.isFinite, range.isFinite, range > 0,
              (minimumValue...maximumValue).contains(currentValue)
        else { return nil }

        let advertisedIncrement = scrollBar.doubleAttribute(AXAttributeNames.kAXValueIncrementAttribute)
        let singleStep = advertisedIncrement.flatMap { $0.isFinite && $0 > 0 ? min($0, range) : nil } ?? (range / 10)
        let signedStep: Double = switch direction {
        case .down, .right:
            singleStep
        case .up, .left:
            -singleStep
        }
        let requestedValue = min(
            maximumValue,
            max(minimumValue, currentValue + signedStep * Double(max(1, pages))))
        return ScrollBarValueChange(currentValue: currentValue, requestedValue: requestedValue)
    }

    private func performScrollbarValueScroll(
        _ scrollBar: any AutomationElementRepresenting,
        change: ScrollBarValueChange) throws -> UIInputExecutionResult.Action
    {
        let currentValue = change.currentValue
        let requestedValue = change.requestedValue
        let alreadyMatched = requestedValue == currentValue
        if !alreadyMatched {
            do {
                try scrollBar.setAutomationValue(.double(requestedValue))
            } catch {
                let classified = Self.classify(error)
                if Self.scrollFailureMayHaveDispatched(classified) {
                    throw Self.scrollProgressFailure(
                        completedUnitCount: 0,
                        currentUnitMayHaveDispatched: true,
                        requestedUnitCount: 1,
                        delivery: Self.accessibilityValueDelivery,
                        cause: classified)
                }
                throw classified
            }
        }

        let observedValue = Self.numericValue(scrollBar.value)
        if !alreadyMatched, observedValue == currentValue {
            throw DesktopActionFailure.indeterminate(
                delivery: Self.accessibilityValueDelivery,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Accessibility scroll bar value did not change after dispatch",
                hint: "Observe the target before taking another scroll action.")
        }

        let outcome: DesktopActionOutcome = if alreadyMatched {
            .confirmedNoChange()
        } else if observedValue != nil {
            .confirmedChange(delivery: Self.accessibilityValueDelivery, unitCount: .one)
        } else {
            .dispatchedUnverified(
                delivery: Self.accessibilityValueDelivery,
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
        return UIInputExecutionResult.Action(
            outcome: outcome,
            actionName: "AXSetValue",
            anchorPoint: scrollBar.anchorPoint,
            elementRole: scrollBar.role)
    }

    private func findScrollBar(
        in element: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection) -> (any AutomationElementRepresenting)?
    {
        let budget = 200
        var queue: [any AutomationElementRepresenting] = [element]
        var nextIndex = 0

        // Breadth-first traversal matters here. A scroll area may contain nested editors/lists with
        // their own scroll bars; the nearest axis-matching descendant belongs to the requested area.
        while nextIndex < queue.count, nextIndex < budget {
            let isRoot = nextIndex == 0
            let candidate = queue[nextIndex]
            nextIndex += 1
            if candidate.role == AXRoleNames.kAXScrollBarRole,
               Self.scrollBar(candidate, matches: direction)
            {
                return candidate
            }

            // A nested scroll area owns its own bars. Descending into it would mutate a different
            // receiver when the requested outer area has no bar for this axis.
            if !isRoot, candidate.role == AXRoleNames.kAXScrollAreaRole {
                continue
            }
            let remainingCapacity = budget - queue.count
            if remainingCapacity > 0 {
                queue.append(contentsOf: candidate.automationChildren.prefix(remainingCapacity))
            }
        }
        return nil
    }

    private static func scrollBar(
        _ element: any AutomationElementRepresenting,
        matches direction: PeekabooFoundation.ScrollDirection) -> Bool
    {
        let wantsVertical = switch direction {
        case .up, .down:
            true
        case .left, .right:
            false
        }
        switch element.stringAttribute(AXAttributeNames.kAXOrientationAttribute) {
        case kAXVerticalOrientationValue:
            return wantsVertical
        case kAXHorizontalOrientationValue:
            return !wantsVertical
        default:
            break
        }

        guard let frame = element.frame,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.size.width.isFinite, frame.size.height.isFinite,
              frame.size.width > 0, frame.size.height > 0,
              frame.size.width != frame.size.height
        else { return false }
        return (frame.size.height > frame.size.width) == wantsVertical
    }

    private static func numericValue(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            return nil
        }
        return number.doubleValue
    }

    private func findMenuItem(
        matching chord: MenuHotkeyChord,
        in menuBar: any AutomationElementRepresenting) -> (any AutomationElementRepresenting)?
    {
        var remainingBudget = 600

        for menuBarItem in menuBar.automationChildren {
            guard remainingBudget > 0 else { return nil }
            remainingBudget -= 1

            guard let menu = menuBarItem.automationChildren.first(where: { $0.role == AXRoleNames.kAXMenuRole }) else {
                continue
            }

            if let match = self.findMenuItem(
                matching: chord,
                inMenuChildren: menu.automationChildren,
                budget: &remainingBudget)
            {
                return match
            }
        }

        return nil
    }

    private func findMenuItem(
        matching chord: MenuHotkeyChord,
        inMenuChildren children: [any AutomationElementRepresenting],
        budget: inout Int) -> (any AutomationElementRepresenting)?
    {
        for child in children {
            guard budget > 0 else { return nil }
            budget -= 1

            if self.menuItem(child, matches: chord) {
                return child
            }

            if let submenu = child.automationChildren.first(where: { $0.role == AXRoleNames.kAXMenuRole }),
               let match = self.findMenuItem(
                   matching: chord,
                   inMenuChildren: submenu.automationChildren,
                   budget: &budget)
            {
                return match
            }
        }

        return nil
    }

    private func menuItem(_ element: any AutomationElementRepresenting, matches chord: MenuHotkeyChord) -> Bool {
        guard element.role == AXRoleNames.kAXMenuItemRole else { return false }
        guard element.isEnabled else { return false }

        guard let commandCharacter = element.stringAttribute("AXMenuItemCmdChar"),
              !commandCharacter.isEmpty
        else {
            return false
        }

        let modifiers = element.intAttribute("AXMenuItemCmdModifiers") ?? 0
        return MenuHotkeyChord.normalizedCommandCharacter(commandCharacter) == chord.key &&
            MenuHotkeyChord.modifiers(fromMenuItemModifiers: modifiers) == chord.modifiers
    }
}

extension ActionInputError {
    fileprivate var isUnsupported: Bool {
        if case .unsupported = self {
            return true
        }
        return false
    }
}

private struct MenuHotkeyChord: Equatable {
    let key: String
    let modifiers: Set<String>

    init(keys: [String]) throws {
        var primaryKey: String?
        var modifiers: Set<String> = []

        for key in keys.map(Self.normalizedKey(_:)) where !key.isEmpty {
            if let modifier = Self.modifierName(for: key) {
                modifiers.insert(modifier)
                continue
            }

            guard let commandCharacter = Self.commandCharacter(for: key) else {
                throw ActionInputError.unsupported(.menuShortcutUnavailable)
            }

            if primaryKey != nil {
                throw ActionInputError.unsupported(.menuShortcutUnavailable)
            }
            primaryKey = commandCharacter
        }

        guard let primaryKey else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }

        self.key = primaryKey
        self.modifiers = modifiers
    }

    static func normalizedCommandCharacter(_ raw: String) -> String {
        self.commandCharacter(for: raw) ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func modifiers(fromMenuItemModifiers modifiers: Int) -> Set<String> {
        var result: Set<String> = []
        if modifiers & (1 << 3) == 0 {
            result.insert("cmd")
        }
        if modifiers & (1 << 0) != 0 {
            result.insert("shift")
        }
        if modifiers & (1 << 1) != 0 {
            result.insert("alt")
        }
        if modifiers & (1 << 2) != 0 {
            result.insert("ctrl")
        }
        return result
    }

    private static func normalizedKey(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.aliases[key] ?? key
    }

    private static func modifierName(for key: String) -> String? {
        switch key {
        case "cmd", "shift", "alt", "ctrl":
            key
        default:
            nil
        }
    }

    private static func commandCharacter(for key: String) -> String? {
        let key = self.normalizedKey(key)
        if key.count == 1 {
            return key
        }
        return Self.namedCommandCharacters[key]
    }

    private static let aliases: [String: String] = [
        "command": "cmd",
        "control": "ctrl",
        "option": "alt",
        "opt": "alt",
        "spacebar": "space",
        "left_bracket": "leftbracket",
        "[": "leftbracket",
        "right_bracket": "rightbracket",
        "]": "rightbracket",
        "=": "equal",
        "-": "minus",
        "'": "quote",
        ";": "semicolon",
        "\\": "backslash",
        ",": "comma",
        "/": "slash",
        ".": "period",
        "`": "grave",
    ]

    private static let namedCommandCharacters: [String: String] = [
        "space": " ",
        "leftbracket": "[",
        "rightbracket": "]",
        "equal": "=",
        "minus": "-",
        "quote": "'",
        "semicolon": ";",
        "backslash": "\\",
        "comma": ",",
        "slash": "/",
        "period": ".",
        "grave": "`",
    ]
}

#if DEBUG
extension ActionInputDriver {
    func tryClickForTesting(
        element: any AutomationElementRepresenting,
        allowAccessibilityValueFallback: Bool = true,
        beforeMutation: @MainActor () throws -> Void = {}) async throws -> UIInputExecutionResult.Action
    {
        do {
            return try self.performAction(AXActionNames.kAXPressAction, on: element, beforeMutation: beforeMutation)
        } catch let error as ActionInputError
            where error == .unsupported(.actionUnsupported) &&
            allowAccessibilityValueFallback &&
            Self.canFocusForClick(
                role: element.role,
                subrole: element.subrole,
                isValueSettable: element.isValueSettable,
                isFocusedSettable: element.isFocusedSettable)
        {
            return try await self.focusForClick(element, beforeMutation: beforeMutation)
        }
    }

    func trySetValueForTesting(
        element: any AutomationElementRepresenting,
        value: UIElementValue, beforeMutation: @MainActor () throws -> Void = {}) async throws -> UIInputExecutionResult
        .Action
    {
        try await self.setValue(value, on: element, beforeMutation: beforeMutation)
    }

    func tryScrollForTesting(
        element: any AutomationElementRepresenting,
        direction: PeekabooFoundation.ScrollDirection,
        pages: Int) throws -> UIInputExecutionResult.Action
    {
        try self.performScrollActions(element: element, direction: direction, pages: pages)
    }

    func tryPerformActionForTesting(
        element: any AutomationElementRepresenting,
        actionName: String) throws -> UIInputExecutionResult.Action
    {
        try self.performAction(actionName, on: element)
    }

    func tryHotkeyForTesting(
        keys: [String],
        menuBar: any AutomationElementRepresenting) throws -> UIInputExecutionResult.Action
    {
        let chord = try MenuHotkeyChord(keys: keys)
        guard let menuItem = self.findMenuItem(matching: chord, in: menuBar) else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }
        return try self.performAction(AXActionNames.kAXPressAction, on: menuItem)
    }

    nonisolated static func menuHotkeyChordForTesting(_ keys: [String]) throws
        -> (key: String, modifiers: Set<String>)
    {
        let chord = try MenuHotkeyChord(keys: keys)
        return (chord.key, chord.modifiers)
    }

    nonisolated static func menuHotkeyModifiersForTesting(_ modifiers: Int) -> Set<String> {
        MenuHotkeyChord.modifiers(fromMenuItemModifiers: modifiers)
    }

    nonisolated static func setValueRejectionReasonForTesting(
        role: String?,
        subrole: String? = nil,
        isValueSettable: Bool) -> ActionInputUnsupportedReason?
    {
        self.setValueRejectionReason(role: role, subrole: subrole, isValueSettable: isValueSettable)
    }

    nonisolated static func canFocusForClickForTesting(
        role: String?,
        subrole: String? = nil,
        isValueSettable: Bool,
        isFocusedSettable: Bool) -> Bool
    {
        self.canFocusForClick(
            role: role,
            subrole: subrole,
            isValueSettable: isValueSettable,
            isFocusedSettable: isFocusedSettable)
    }

    nonisolated static func tabPressDidNotSelectForTesting(
        subrole: String?,
        valueBefore: Int?,
        valueAfter: Int?) -> Bool
    {
        self.tabPressDidNotSelect(
            subrole: subrole,
            valueBefore: valueBefore,
            valueAfter: valueAfter)
    }

    nonisolated static func shouldContinueTryingScrollActionForTesting(after error: ActionInputError) -> Bool {
        self.shouldContinueTryingScrollAction(after: error)
    }

    nonisolated static func scrollFallbackErrorForTesting(from error: ActionInputError?) -> ActionInputError {
        self.scrollFallbackError(from: error)
    }
}
#endif
