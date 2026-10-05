import AXorcist
import Foundation

@MainActor
extension DialogService {
    static func filePanelElements(
        in dialogs: FreshDialogElements,
        window: Element,
        matching isFilePanel: (Element) -> Bool) -> [Element]
    {
        // File operations retain compatible panels even when an unrelated structural alert is present.
        let panels = (dialogs.structural + dialogs.legacy).filter(isFilePanel)
        return DialogTraversal.preferredStructuralDialogs(in: window, candidates: panels)
    }
}
