import AppKit
import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    func collectTextFields(from element: Element) -> [Element] {
        DialogTraversal.collectUniqueDepthFirst(
            from: element,
            matching: {
                let role = $0.role()
                return role == "AXTextField" || role == "AXTextArea"
            },
            children: { $0.children() ?? [] })
    }

    func selectTextField(in textFields: [Element], identifier: String?) throws -> Element {
        guard let identifier else {
            return textFields[0]
        }

        if let index = Int(identifier) {
            guard textFields.indices.contains(index) else {
                throw DialogError.invalidFieldIndex
            }
            return textFields[index]
        }

        guard let field = textFields.first(where: { field in
            field.title() == identifier ||
                field.attribute(Attribute<String>("AXPlaceholderValue")) == identifier ||
                field.descriptionText()?.contains(identifier) == true
        }) else {
            throw DialogError.fieldNotFound
        }

        return field
    }

    func elementBounds(for element: Element) -> CGRect {
        guard let position = element.position(), let size = element.size() else {
            return .zero
        }
        return CGRect(origin: position, size: size)
    }

    func focusTextField(_ field: Element) throws -> DesktopActionOutcome {
        let elementDescription = field.briefDescription(option: ValueFormatOption.smart)
        self.logger.debug("Focusing text field: \(elementDescription)")

        if field.attribute(Attribute<Bool>(AXAttributeNames.kAXFocusedAttribute)) == true {
            return .confirmedNoChange()
        }

        if field.isAttributeSettable(named: AXAttributeNames.kAXFocusedAttribute) {
            guard field.setValue(true, forAttribute: AXAttributeNames.kAXFocusedAttribute) else {
                throw DesktopActionFailure.indeterminate(
                    delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
                    evidence: .completionUnknown,
                    unitCount: .one,
                    message: "File-dialog field focus returned without acceptance evidence.",
                    hint: "Observe the file dialog and field before retrying.")
            }
            return .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }

        if field.isActionSupported(AXActionNames.kAXPressAction) {
            return try self.fileDialogAccessibilityAction(
                operation: "focus the file-dialog text field")
            {
                try field.performAction(.press)
            }
        }

        if let position = field.position(),
           let size = field.size(),
           size.width > 0,
           size.height > 0
        {
            let point = CGPoint(x: position.x + size.width / 2.0, y: position.y + size.height / 2.0)
            return try self.fileDialogGlobalPointerClick(
                at: point,
                operation: "focus the file-dialog text field")
        }

        throw DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "File-dialog text field has no focusable AX or pointer target.",
            hint: "Refresh the file dialog before retrying.")
    }

    func clearFieldIfNeeded(_ field: Element, shouldClear: Bool) throws {
        guard shouldClear else { return }
        self.logger.debug("Clearing existing text")
        try? InputDriver.hotkey(keys: ["cmd", "a"])
        try? InputDriver.tapKey(.delete)
        usleep(50000)
    }

    func typeTextValue(_ text: String, delay: useconds_t) throws -> DesktopActionOutcome {
        self.logger.debug("Typing text into field")
        guard !text.isEmpty else { return .confirmedNoChange() }
        return try self.fileDialogGlobalInput(
            operation: "type file-dialog text",
            unitCount: text.count)
        {
            try self.syntheticInputDriver.type(
                text,
                delayPerCharacter: Double(delay) / 1_000_000.0)
        }
    }

    func collectButtons(from element: Element) -> [Element] {
        DialogTraversal.collectUniqueDepthFirst(
            from: element,
            matching: { $0.role() == "AXButton" },
            children: { $0.children() ?? [] })
    }

    func dialogButtons(from dialog: Element) -> [DialogButton] {
        let axButtons = self.collectButtons(from: dialog)
        self.logger.debug("Found \(axButtons.count) buttons")

        return axButtons.compactMap { btn -> DialogButton? in
            guard let title = btn.title() else { return nil }
            let isEnabled = btn.isEnabled() ?? true
            let isDefault = btn.attribute(Attribute<Bool>("AXDefault")) ?? false

            return DialogButton(
                title: title,
                isEnabled: isEnabled,
                isDefault: isDefault)
        }
    }

    func dialogTextFields(from dialog: Element) -> [DialogTextField] {
        let axTextFields = self.collectTextFields(from: dialog)
        self.logger.debug("Found \(axTextFields.count) text fields")

        return axTextFields.indexed().map { index, field in
            DialogTextField(
                title: field.title(),
                value: field.value() as? String,
                placeholder: field.attribute(Attribute<String>("AXPlaceholderValue")),
                index: index,
                isEnabled: field.isEnabled() ?? true)
        }
    }

    func dialogStaticTexts(from dialog: Element) -> [String] {
        let axStaticTexts = DialogTraversal.collectUniqueDepthFirst(
            from: dialog,
            matching: { $0.role() == "AXStaticText" },
            children: { element in
                let role = element.role()
                guard element == dialog || (role != "AXApplication" && role != "AXWindow") else { return [] }
                // Only follow structural children within the resolved dialog, not AX navigation alternatives.
                return element.children(strict: true) ?? []
            })
        let staticTexts = axStaticTexts.compactMap { element in
            [element.value() as? String, element.title(), element.label(), element.descriptionText()]
                .compactMap(\.self)
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        self.logger.debug("Found \(staticTexts.count) static texts")
        return staticTexts
    }

    func dialogOtherElements(from dialog: Element) -> [DialogElement] {
        let otherAxElements = dialog.children()?.filter { element in
            let role = element.role() ?? ""
            return role != "AXButton" && role != "AXTextField" &&
                role != "AXTextArea" && role != "AXStaticText"
        } ?? []

        return otherAxElements.compactMap { element -> DialogElement? in
            guard let role = element.role() else { return nil }
            return DialogElement(
                role: role,
                title: element.title(),
                value: element.value() as? String)
        }
    }

    func pressOrClick(
        _ element: Element,
        allowGlobalFallback: Bool = false) throws -> DesktopActionOutcome
    {
        if element.isActionSupported(AXActionNames.kAXPressAction) {
            return try self.fileDialogAccessibilityAction(operation: "press the dialog control") {
                try element.performAction(.press)
            }
        }

        guard allowGlobalFallback,
              let position = element.position(),
              let size = element.size(),
              size.width > 0,
              size.height > 0
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Dialog control does not expose AXPress or a permitted pointer fallback.",
                hint: "Refresh the dialog and choose a supported control.")
        }

        let point = CGPoint(x: position.x + size.width / 2.0, y: position.y + size.height / 2.0)
        return try self.fileDialogGlobalPointerClick(at: point, operation: "click the dialog control")
    }

    func fileDialogGlobalInput(
        operation: String,
        unitCount: Int = 1,
        dispatch: () throws -> Void) throws -> DesktopActionOutcome
    {
        guard let count = DesktopActionOutcome.DispatchUnitCount(unitCount) else {
            return .confirmedNoChange()
        }
        do {
            try dispatch()
            return .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: count)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as PeekabooError {
            if case .permissionDeniedEventSynthesizing = error {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .permissionDenied,
                    message: "Cannot \(operation) without Event Synthesizing permission.",
                    hint: "Grant Event Synthesizing permission before retrying.",
                    causeDescription: error.localizedDescription)
            }
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: count,
                message: "File-dialog input returned without reliable dispatch evidence.",
                hint: "Observe the file dialog before retrying.",
                causeDescription: error.localizedDescription)
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: count,
                message: "File-dialog input returned without reliable dispatch evidence.",
                hint: "Observe the file dialog before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    func fileDialogGlobalPointerClick(
        at point: CGPoint,
        operation: String) throws -> DesktopActionOutcome
    {
        do {
            return try self.syntheticInputDriver.click(at: point, button: .left, count: 1)
        } catch {
            return try self.fileDialogGlobalInput(operation: operation) { throw error }
        }
    }

    private func fileDialogAccessibilityAction(
        operation: String,
        dispatch: () throws -> Void) throws -> DesktopActionOutcome
    {
        do {
            try dispatch()
            return .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Accessibility could not reliably \(operation).",
                hint: "Observe the file dialog before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    func typeCharacter(_ char: Character) throws {
        try DialogService.typeCharacterHandler(String(char))
    }
}

#if DEBUG
extension DialogService {
    private static var isRunningUnderTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            ProcessInfo.processInfo.arguments.contains("--test-mode") ||
            NSClassFromString("XCTest") != nil
    }

    private static let defaultTypeCharacterHandler: (String) throws -> Void = { text in
        guard !DialogService.isRunningUnderTests else {
            throw DialogError.inputSuppressedUnderTests
        }
        try InputDriver.type(text, delayPerCharacter: 0)
    }

    /// Test hook to override character typing without sending real events.
    static var typeCharacterHandler: (String) throws -> Void = DialogService.defaultTypeCharacterHandler

    static func resetTypeCharacterHandlerForTesting() {
        self.typeCharacterHandler = self.defaultTypeCharacterHandler
    }
}
#else
extension DialogService {
    fileprivate static var typeCharacterHandler: (String) throws -> Void {
        { text in try InputDriver.type(
            text,
            delayPerCharacter: 0) }
    }
}
#endif
