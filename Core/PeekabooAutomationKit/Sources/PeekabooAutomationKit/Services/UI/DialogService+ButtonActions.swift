import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    func isSaveLikeAction(_ actionButton: String) -> Bool {
        let normalized = actionButton.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("save") || normalized.contains("export")
    }

    func normalizedDialogButtonTitle(_ title: String) -> String {
        title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "…", with: "")
            .replacingOccurrences(of: "...", with: "")
            .lowercased()
    }

    func clickButton(
        in dialog: Element,
        buttonText: String,
        allowFallbackToDefaultAction: Bool) async throws -> DialogActionResult
    {
        let buttons = self.collectButtons(from: dialog)
        self.logger.debug("Found \(buttons.count) buttons in dialog")

        guard let targetButton = self.resolveButton(
            in: buttons,
            requestedTitle: buttonText,
            allowFallbackToDefaultAction: allowFallbackToDefaultAction)
        else {
            throw DialogError.buttonNotFound(buttonText)
        }

        let identifierAttribute = Attribute<String>("AXIdentifier")
        let resolvedButtonTitle = targetButton.title() ?? buttonText
        let resolvedButtonIdentifier = targetButton.attribute(identifierAttribute)

        let buttonBounds: CGRect = if let position = targetButton.position(), let size = targetButton.size() {
            CGRect(origin: position, size: size)
        } else {
            .zero
        }

        if buttonBounds != .zero {
            _ = await self.feedbackClient.showDialogInteraction(
                element: .button,
                elementRect: buttonBounds,
                action: .clickButton)
        }

        self.logger.debug("Clicking button: \(resolvedButtonTitle)")
        try self.pressOrClick(targetButton)

        var clickDetails: [String: String] = [
            "button": resolvedButtonTitle,
            "window": dialog.title() ?? "Dialog",
        ]
        if let resolvedButtonIdentifier, !resolvedButtonIdentifier.isEmpty {
            clickDetails["button_identifier"] = resolvedButtonIdentifier
        }

        let result = DialogActionResult(
            success: true,
            action: .clickButton,
            details: clickDetails)

        self.logger.info("\(AgentDisplayTokens.Status.success) Successfully clicked button: \(resolvedButtonTitle)")
        return result
    }

    func resolveButton(
        in buttons: [Element],
        requestedTitle: String,
        allowFallbackToDefaultAction: Bool) -> Element?
    {
        let identifierAttribute = Attribute<String>("AXIdentifier")
        let normalizedRequested = self.normalizedDialogButtonTitle(requestedTitle)

        if normalizedRequested != "default",
           let match = buttons.first(where: { btn in
               guard let title = btn.title() else { return false }
               return self.dialogButtonTitleMatches(title, requested: requestedTitle)
           })
        {
            return match
        }

        if normalizedRequested == "default",
           let okButton = buttons.first(where: { $0.attribute(identifierAttribute) == "OKButton" })
        {
            return okButton
        }

        if self.isSaveLikeAction(requestedTitle),
           let okButton = buttons.first(where: { $0.attribute(identifierAttribute) == "OKButton" })
        {
            return okButton
        }

        if normalizedRequested == "cancel" || normalizedRequested == "close" || normalizedRequested == "dismiss",
           let cancelButton = buttons.first(where: { $0.attribute(identifierAttribute) == "CancelButton" })
        {
            return cancelButton
        }

        guard allowFallbackToDefaultAction else { return nil }
        if normalizedRequested != "default" {
            guard self.isSaveLikeAction(requestedTitle) else { return nil }
        }

        if let defaultButton = buttons.first(where: { btn in
            (btn.attribute(Attribute<Bool>("AXDefault")) ?? false) && (btn.isEnabled() ?? true)
        }) {
            return defaultButton
        }

        let enabledNonCancel = buttons.filter { btn in
            (btn.isEnabled() ?? true) && !self.isCancelLikeButtonTitle(btn.title())
        }

        if enabledNonCancel.count == 1 {
            return enabledNonCancel[0]
        }

        // Prefer the visually rightmost enabled non-cancel button (common in NSOpenPanel/NSSavePanel).
        let positioned = enabledNonCancel.compactMap { button -> (element: Element, x: CGFloat)? in
            guard let position = button.position() else { return nil }
            return (element: button, x: position.x)
        }
        return positioned.max(by: { $0.x < $1.x })?.element
    }

    private func dialogButtonTitleMatches(_ candidate: String, requested: String) -> Bool {
        if candidate == requested {
            return true
        }
        if candidate.contains(requested) {
            return true
        }

        let normalizedCandidate = self.normalizedDialogButtonTitle(candidate)
        let normalizedRequested = self.normalizedDialogButtonTitle(requested)

        if normalizedCandidate == normalizedRequested {
            return true
        }
        if normalizedCandidate.contains(normalizedRequested) {
            return true
        }

        return false
    }

    private func isCancelLikeButtonTitle(_ title: String?) -> Bool {
        guard let title else { return false }
        let normalized = self.normalizedDialogButtonTitle(title)
        return normalized == "cancel" || normalized == "close" || normalized == "dismiss"
    }
}
