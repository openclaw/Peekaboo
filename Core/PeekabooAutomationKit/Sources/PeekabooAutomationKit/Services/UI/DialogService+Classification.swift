import AXorcist
import Foundation

@MainActor
extension DialogService {
    func isDialogElement(_ element: Element, matching title: String?) -> Bool {
        let role = element.role() ?? ""
        let subrole = element.subrole() ?? ""
        let roleDescription = element.attribute(Attribute<String>("AXRoleDescription")) ?? ""
        let identifier = element.attribute(Attribute<String>("AXIdentifier")) ?? ""
        let windowTitle = element.title() ?? ""

        if let expectedTitle = title, !windowTitle.elementsEqual(expectedTitle) {
            return false
        }

        if role == "AXSheet" || role == "AXDialog" {
            return true
        }

        if subrole == "AXDialog" || subrole == "AXSystemDialog" || subrole == "AXAlert" {
            return true
        }

        if roleDescription.localizedCaseInsensitiveContains("dialog") {
            return true
        }

        if identifier.contains("NSOpenPanel") || identifier.contains("NSSavePanel") {
            return true
        }

        if self.dialogTitleHints.contains(where: { windowTitle.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        // Some apps expose sheets as AXWindow/AXUnknown instead of AXSheet. Avoid treating every AXUnknown
        // window as a dialog (TextEdit's main document window can be AXUnknown), and instead require at
        // least one dialog-ish signal.
        if subrole == "AXUnknown", title != nil {
            let buttonTitles = Set(self.collectButtons(from: element).compactMap { $0.title()?.lowercased() })
            let hasCancel = buttonTitles.contains("cancel")
            let hasDialogButton = hasCancel ||
                buttonTitles.contains("ok") ||
                buttonTitles.contains("open") ||
                buttonTitles.contains("save") ||
                buttonTitles.contains("choose") ||
                buttonTitles.contains("replace") ||
                buttonTitles.contains("export") ||
                buttonTitles.contains("import") ||
                buttonTitles.contains("don't save")

            if hasDialogButton {
                return true
            }
        }

        return false
    }

    func isFileDialogElement(_ element: Element) -> Bool {
        let identifier = element.attribute(Attribute<String>("AXIdentifier")) ?? ""
        let windowTitle = element.title() ?? ""

        if identifier.contains("NSOpenPanel") || identifier.contains("NSSavePanel") {
            return true
        }

        if self.dialogTitleHints.contains(where: { windowTitle.localizedCaseInsensitiveContains($0) }) {
            return true
        }

        // Some sheets (e.g. TextEdit's Save sheet) expose no useful title/identifier but do expose canonical buttons.
        let buttons = self.collectButtons(from: element)
        let buttonTitles = Set(buttons.compactMap { $0.title()?.lowercased() })
        let buttonIdentifiers = Set(buttons.compactMap { $0.attribute(Attribute<String>("AXIdentifier")) })

        let hasCancel = buttonTitles.contains("cancel") || buttonIdentifiers.contains("CancelButton")
        let hasPrimaryTitle = ["save", "open", "choose", "replace", "export", "import"]
            .contains { buttonTitles.contains($0) }
        let hasPrimaryIdentifier = buttonIdentifiers.contains("OKButton")

        return hasCancel && (hasPrimaryTitle || hasPrimaryIdentifier)
    }
}
