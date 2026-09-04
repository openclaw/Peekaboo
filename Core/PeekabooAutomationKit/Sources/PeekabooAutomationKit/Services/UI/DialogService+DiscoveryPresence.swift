import AXorcist
import Foundation

@MainActor
extension DialogService {
    func discoveredDialogPresence(_ entry: DialogPreparedActionStore.Entry) -> DialogPresence {
        let expected = entry.receipt.target
        let presence = self.discoveryReaders.windowPresence(expected.identity)
        guard presence == .present else { return presence }
        guard let owner = self.discoveryReaders.currentApplication(expected.identity.ownerProcessIdentifier),
              owner.processIdentity == expected.identity.processIdentity
        else { return .unreadable }
        let windows = self.discoveryReaders.windows(owner.processIdentifier)
        guard windows.readable, windows.elements.count <= 16,
              let window = windows.elements.first(where: { Self.sameElement($0, entry.window) }),
              let receipt = self.discoveryReaders.windowReceipt(window, owner, 0),
              receipt.mutationIdentity?.hasSameStableReceipt(as: expected.identity) == true,
              receipt.bounds == expected.bounds
        else { return .unreadable }
        let tree = self.discoveryTree(
            window,
            owner: owner.processIdentifier,
            deadline: self.discoveryReaders.now().addingTimeInterval(0.2))
        if tree.elements.contains(where: { Self.sameElement($0, entry.dialog) }) {
            return .present
        }
        return tree.readable ? .absent : .unreadable
    }

    func discoveredDialogList(_ scan: DiscoveryScan) throws -> DialogElements {
        guard let first = scan.candidates.first else {
            throw self.discoveryRefusal(
                scan,
                message: "No active dialog found in incomplete discovery.")
        }
        let elements = first.elements
        return DialogElements(
            dialogInfo: elements.dialogInfo,
            buttons: elements.buttons,
            textFields: elements.textFields,
            staticTexts: elements.staticTexts,
            otherElements: elements.otherElements,
            resolvedTarget: scan.candidates.count == 1 ? elements.resolvedTarget : nil,
            discovery: scan.inventory)
    }
}
