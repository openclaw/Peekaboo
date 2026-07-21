import ApplicationServices
@preconcurrency import AXorcist
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogButtonResolutionTests {
    @Test
    func `button resolution uses the supplied snapshot`() {
        let service = DialogService()
        let cancelButton = makeButton(offset: 1, title: "Cancel", identifier: "CancelButton")
        let saveButton = makeButton(offset: 2, title: "Save…", identifier: "SaveButton")

        let resolved = service.resolveButton(
            in: [cancelButton, saveButton],
            requestedTitle: "Save",
            allowFallbackToDefaultAction: false)

        #expect(resolved == saveButton)
    }

    @Test
    func `button resolution preserves identifier fallbacks`() {
        let service = DialogService()
        let cancelButton = makeButton(offset: 3, title: "Abort", identifier: "CancelButton")
        let okButton = makeButton(offset: 4, title: "Continue", identifier: "OKButton")
        let buttons = [cancelButton, okButton]

        let defaultResolved = service.resolveButton(
            in: buttons,
            requestedTitle: "default",
            allowFallbackToDefaultAction: false)
        let cancelResolved = service.resolveButton(
            in: buttons,
            requestedTitle: "Dismiss",
            allowFallbackToDefaultAction: false)

        #expect(defaultResolved == okButton)
        #expect(cancelResolved == cancelButton)
    }
}

@MainActor
private func makeButton(offset: pid_t, title: String, identifier: String) -> Element {
    Element(
        AXUIElementCreateApplication(getpid() + offset),
        attributes: [
            "AXTitle": .string(title),
            "AXIdentifier": .string(identifier),
        ],
        children: nil,
        actions: nil)
}
