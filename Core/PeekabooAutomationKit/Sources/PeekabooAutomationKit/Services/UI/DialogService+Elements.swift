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

    func highlightDialogElement(
        element: DialogElementType,
        bounds: CGRect,
        action: DialogActionType) async
    {
        guard bounds != .zero else { return }
        _ = await self.feedbackClient.showDialogInteraction(
            element: element,
            elementRect: bounds,
            action: action)
    }

    func focusTextField(_ field: Element) {
        let elementDescription = field.briefDescription(option: ValueFormatOption.smart)
        self.logger.debug("Focusing text field: \(elementDescription)")

        if field.isAttributeSettable(named: AXAttributeNames.kAXFocusedAttribute),
           field.setValue(true, forAttribute: AXAttributeNames.kAXFocusedAttribute)
        {
            return
        }

        if field.isActionSupported(AXActionNames.kAXPressAction) {
            do {
                try field.performAction(.press)
                return
            } catch {
                self.logger.debug("Failed to focus text field via press: \(String(describing: error))")
            }
        }

        if let position = field.position(),
           let size = field.size(),
           size.width > 0,
           size.height > 0
        {
            let point = CGPoint(x: position.x + size.width / 2.0, y: position.y + size.height / 2.0)
            try? InputDriver.click(at: point)
            return
        }

        self.logger.debug("Text field is not focusable (focused attribute not settable; press/click unavailable).")
    }

    func clearFieldIfNeeded(_ field: Element, shouldClear: Bool) throws {
        guard shouldClear else { return }
        self.logger.debug("Clearing existing text")
        try? InputDriver.hotkey(keys: ["cmd", "a"])
        try? InputDriver.tapKey(.delete)
        usleep(50000)
    }

    func typeTextValue(_ text: String, delay: useconds_t) throws {
        self.logger.debug("Typing text into field")
        try InputDriver.type(text, delayPerCharacter: Double(delay) / 1_000_000.0)
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
        let axStaticTexts = dialog.children()?.filter { $0.role() == "AXStaticText" } ?? []
        let staticTexts = axStaticTexts.compactMap { $0.value() as? String }
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

    func pressOrClick(_ element: Element) throws {
        do {
            try element.performAction(.press)
            return
        } catch {
            guard let position = element.position(),
                  let size = element.size(),
                  size.width > 0,
                  size.height > 0
            else {
                throw error
            }

            let point = CGPoint(x: position.x + size.width / 2.0, y: position.y + size.height / 2.0)
            try InputDriver.click(at: point)
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
