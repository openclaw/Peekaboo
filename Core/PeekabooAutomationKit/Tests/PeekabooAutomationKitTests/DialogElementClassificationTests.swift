import Testing
@testable import PeekabooAutomationKit

struct DialogElementClassificationTests {
    @Test
    func `collected sheet makes its standard window observation dialog active`() {
        let window = DetectedElement(
            id: "window",
            type: .window,
            label: "Playground",
            bounds: .zero,
            attributes: [
                "role": "AXWindow",
                "roleDescription": "standard window",
                "title": "Playground",
            ])
        let sheet = DetectedElement(
            id: "sheet",
            type: .other,
            label: "alert",
            bounds: .zero,
            attributes: [
                "role": "AXSheet",
                "roleDescription": "sheet",
            ])
        let savePanelHeading = DetectedElement(
            id: "heading",
            type: .other,
            label: "Save Panel",
            bounds: .zero,
            attributes: [
                "role": "AXHeading",
                "title": "Save Panel",
            ])
        let windowEvidence = DialogElementEvidence(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            roleDescription: "standard window",
            identifier: "Playground-AppWindow-1",
            title: "Playground")

        #expect(!DialogElementClassifier.isDialog(windowEvidence))
        #expect(!DialogElementClassifier.containsDialog(in: [window, savePanelHeading]))
        #expect(DialogElementClassifier.containsDialog(in: [window, sheet]))
    }

    @Test
    func `ordinary standard window is not a dialog`() {
        let evidence = DialogElementEvidence(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            roleDescription: "standard window",
            identifier: "Editor-AppWindow-1",
            title: "Editor")

        #expect(!DialogElementClassifier.isDialog(evidence))
    }

    @Test(arguments: [
        ("AXSheet", ""),
        ("AXDialog", ""),
        ("AXWindow", "AXDialog"),
        ("AXWindow", "AXSystemDialog"),
        ("AXWindow", "AXAlert"),
    ])
    func `native dialog roles remain dialog active`(role: String, subrole: String) {
        let evidence = DialogElementEvidence(
            role: role,
            subrole: subrole,
            roleDescription: "",
            identifier: "",
            title: "")

        #expect(DialogElementClassifier.isDialog(evidence))
    }

    @Test(arguments: ["Open Questions", "Saved Draft", "Choose Theme", "Replacement Parts"])
    func `ordinary substring titles are not observation dialogs`(title: String) {
        let evidence = DialogElementEvidence(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            roleDescription: "standard window",
            identifier: "",
            title: title)

        #expect(!DialogElementClassifier.isObservationDialog(evidence))
    }

    @Test(arguments: ["Open", "Save", "Export", "Import", "Save As Document"])
    func `exact native file dialog titles remain observation dialogs`(title: String) {
        let evidence = DialogElementEvidence(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            roleDescription: "standard window",
            identifier: "",
            title: title)

        #expect(DialogElementClassifier.isObservationDialog(evidence))
    }
}
