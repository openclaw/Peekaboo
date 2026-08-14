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
        let panelAccessory = DetectedElement(
            id: "accessory",
            type: .group,
            label: "Accessory",
            bounds: .zero,
            attributes: [
                "role": "AXGroup",
                "identifier": "NSOpenPanelAccessory",
            ])
        let windowEvidence = DialogElementEvidence(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            roleDescription: "standard window",
            identifier: "Playground-AppWindow-1",
            title: "Playground")

        #expect(!DialogElementClassifier.isDialog(windowEvidence))
        #expect(!DialogElementClassifier.containsDialog(in: [window, savePanelHeading, panelAccessory]))
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
        ("AXWindow", "AXSheet"),
    ])
    func `native dialog roles remain dialog active`(role: String, subrole: String) {
        let evidence = DialogElementEvidence(
            role: role,
            subrole: subrole,
            roleDescription: "",
            identifier: "",
            title: "")

        #expect(DialogElementClassifier.isDialog(evidence))
        #expect(DialogElementClassifier.isStructuralDialog(evidence))
    }

    @Test
    func `legacy title and identifier heuristics never become prepared action identities`() {
        let titleOnly = DialogElementEvidence(
            role: "AXButton",
            subrole: "",
            roleDescription: "button",
            identifier: "",
            title: "Save")
        let identifierOnly = DialogElementEvidence(
            role: "AXGroup",
            subrole: "",
            roleDescription: "group",
            identifier: "NSOpenPanelAccessory",
            title: "")

        #expect(DialogElementClassifier.isDialog(titleOnly))
        #expect(DialogElementClassifier.isDialog(identifierOnly))
        #expect(!DialogElementClassifier.isStructuralDialog(titleOnly))
        #expect(!DialogElementClassifier.isStructuralDialog(identifierOnly))
        #expect(!DialogElementClassifier.permitsLegacyReadHeuristics(titleOnly))
        #expect(!DialogElementClassifier.permitsLegacyReadHeuristics(identifierOnly))

        let unknownWindow = DialogElementEvidence(
            role: "AXWindow",
            subrole: "AXUnknown",
            roleDescription: "dialog",
            identifier: "",
            title: "Save")
        #expect(!DialogElementClassifier.isStructuralDialog(unknownWindow))
        #expect(DialogElementClassifier.permitsLegacyReadHeuristics(unknownWindow))
        #expect(DialogElementClassifier.isDialog(unknownWindow))

        let unknownButton = DialogElementEvidence(
            role: "AXButton",
            subrole: "AXUnknown",
            roleDescription: "button",
            identifier: "",
            title: "Save")
        #expect(!DialogElementClassifier.permitsLegacyReadHeuristics(unknownButton))
    }

    @Test
    func `structural read candidates dominate heuristic fallback candidates`() {
        #expect(DialogElementClassifier.preferredReadCandidates(
            structural: ["sheet"],
            legacy: ["parent window"]) == ["sheet"])
        #expect(DialogElementClassifier.preferredReadCandidates(
            structural: [String](),
            legacy: ["unknown window"]) == ["unknown window"])
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
