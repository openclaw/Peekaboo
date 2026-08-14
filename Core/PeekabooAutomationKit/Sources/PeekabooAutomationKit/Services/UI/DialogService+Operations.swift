import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    public func findActiveDialog(windowTitle: String?, appName: String?) async throws -> DialogInfo {
        try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
            try await self.findActiveDialogWithOwnedLane(windowTitle: windowTitle, appName: appName)
        }
    }

    func findActiveDialogWithOwnedLane(windowTitle: String?, appName: String?) async throws -> DialogInfo {
        self.logger.info("Finding active dialog")
        if let title = windowTitle {
            self.logger.debug("Looking for window with title: \(title)")
        }

        let element = try await self.resolveDialogElement(windowTitle: windowTitle, appName: appName)
        let title = element.title() ?? "Untitled Dialog"
        let role = element.role() ?? "Unknown"
        let subrole = element.subrole()
        let isFileDialog = self.isFileDialogElement(element)
        let position = element.position() ?? .zero
        let size = element.size() ?? .zero

        let info = DialogInfo(
            title: title,
            role: role,
            subrole: subrole,
            isFileDialog: isFileDialog,
            bounds: CGRect(origin: position, size: size))

        self.logger.info("\(AgentDisplayTokens.Status.success) Found dialog: \(title), file dialog: \(isFileDialog)")
        return info
    }

    public func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?) async throws -> DialogActionResult
    {
        try await self.clickButton(
            buttonText: buttonText,
            windowTitle: windowTitle,
            appName: appName,
            allowGlobalFallback: false)
    }

    public func clickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool) async throws -> DialogActionResult
    {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Clicking button: \(buttonText)")
            if let title = windowTitle {
                self.logger.debug("In window: \(title)")
            }

            let dialog = try await self.resolveDialogElement(windowTitle: windowTitle, appName: appName)
            return try await self.clickButton(
                in: dialog,
                buttonText: buttonText,
                allowFallbackToDefaultAction: false,
                allowGlobalFallback: allowGlobalFallback)
        }
    }

    public func dismissDialog(force: Bool, windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        if force {
            return try await self.forceDismissDialog(windowTitle: windowTitle, appName: appName)
        }

        return try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Dismissing dialog (force: \(force))")

            self.logger.debug("Looking for dismiss button")
            let dialog = try await self.resolveDialogElement(windowTitle: windowTitle, appName: appName)
            let buttons = dialog.children()?.filter { $0.role() == "AXButton" } ?? []
            self.logger.debug("Found \(buttons.count) buttons in dialog")

            let dismissButtons = ["Cancel", "Close", "Dismiss", "No", "Don't Save"]
            self.logger.debug("Looking for dismiss buttons: \(dismissButtons.joined(separator: ", "))")

            for buttonName in dismissButtons {
                if let button = buttons.first(where: { $0.title() == buttonName }) {
                    self.logger.debug("Found dismiss button: \(buttonName)")
                    try button.performAction(.press)

                    self.logger.info("\(AgentDisplayTokens.Status.success) Dialog dismissed by clicking: \(buttonName)")
                    return DialogActionResult(
                        success: true,
                        action: .dismiss,
                        details: [
                            "method": "button",
                            "button": buttonName,
                        ])
                }
            }

            self.logger.error("No dismiss button found in dialog")
            throw DialogError.noDismissButton
        }
    }

    public func listDialogElements(windowTitle: String?, appName: String?) async throws -> DialogElements {
        try await self.operationLaneCoordinator.run(scope: .global, access: .read) {
            self.logger.info("Listing dialog elements")
            if let title = windowTitle {
                self.logger.debug("For window: \(title)")
            }

            let dialog = try await self.resolveDialogElement(windowTitle: windowTitle, appName: appName)

            let elements = self.dialogElements(for: dialog)

            try self.validateDialogElementList(
                DialogElementListValidation(
                    dialog: dialog,
                    dialogInfo: elements.dialogInfo,
                    windowTitle: windowTitle,
                    buttons: elements.buttons,
                    textFields: elements.textFields,
                    staticTexts: elements.staticTexts,
                    otherElements: elements.otherElements))

            let summary = "\(AgentDisplayTokens.Status.success) Listed \(elements.buttons.count) buttons, " +
                "\(elements.textFields.count) fields, \(elements.staticTexts.count) texts"
            self.logger.info("\(summary, privacy: .public)")
            return elements
        }
    }

    func textField(in dialog: Element, identifier: String?) throws -> Element {
        let textFields = self.collectTextFields(from: dialog)
        self.logger.debug("Found \(textFields.count) text fields")

        guard !textFields.isEmpty else {
            self.logger.error("No text fields found in dialog")
            throw DialogError.noTextFields
        }

        return try self.selectTextField(
            in: textFields,
            identifier: identifier)
    }

    private func validateDialogElementList(_ validation: DialogElementListValidation) throws {
        let accessoryRoles: Set = [
            "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider", "AXDisclosureTriangle",
        ]
        let hasAccessoryElements = validation.otherElements.contains { accessoryRoles.contains($0.role) }
        let looksLikeDialog = self.isDialogElement(validation.dialog, matching: validation.windowTitle)
        let hasContent = !validation.buttons.isEmpty ||
            !validation.textFields.isEmpty ||
            !validation.staticTexts.isEmpty ||
            hasAccessoryElements

        let isSuspiciousUnknown = validation.dialogInfo.role == "AXWindow" &&
            validation.dialogInfo.subrole == "AXUnknown"
        if !hasContent, !looksLikeDialog || isSuspiciousUnknown {
            // A normal front window with no dialog controls should fail, not look like a valid empty dialog.
            self.logger.error(
                """
                Active window '\(validation.dialogInfo.title)' (role: \(validation.dialogInfo.role)) is not a \
                dialog and \
                contains no interactive elements
                """)
            throw DialogError.noActiveDialog
        }
    }
}

private struct DialogElementListValidation {
    let dialog: Element
    let dialogInfo: DialogInfo
    let windowTitle: String?
    let buttons: [DialogButton]
    let textFields: [DialogTextField]
    let staticTexts: [String]
    let otherElements: [DialogElement]
}
