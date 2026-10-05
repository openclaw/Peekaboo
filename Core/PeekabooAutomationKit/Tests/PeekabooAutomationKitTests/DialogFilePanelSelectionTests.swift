import ApplicationServices
import AXorcist
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("File panel selection")
struct DialogFilePanelSelectionTests {
    private let window = Element(AXUIElementCreateApplication(946_001))
    private let sheet = Element(AXUIElementCreateApplication(946_002))
    private let alert = Element(AXUIElementCreateApplication(946_003))
    private let secondPanel = Element(AXUIElementCreateApplication(946_004))

    @Test(arguments: ["open-panel", "save-panel"])
    func `native panel evidence avoids a second descriptor and button traversal`(identifier: String) {
        let evidence = DialogElementEvidence(
            role: "AXWindow", subrole: "AXUnknown", roleDescription: "", identifier: identifier, title: "Öffnen")
        let result = DialogService.filePanelElements(
            in: .init(structural: [], legacy: [self.sheet], evidence: [self.sheet: evidence]),
            window: self.window,
            matching: { _ in
                Issue.record("Recognized native panel must use its fresh classification snapshot")
                return false
            })
        #expect(result == [self.sheet])
        #expect(DialogElementClassifier.isDialog(evidence))
        #expect(!DialogElementClassifier.isStructuralDialog(evidence))
    }

    @Test
    func `file panel classification is not retained across discovery passes`() {
        let original = DialogElementEvidence(
            role: "AXSheet", subrole: "", roleDescription: "", identifier: "save-panel", title: "")
        let replacement = DialogElementEvidence(
            role: "AXSheet", subrole: "", roleDescription: "", identifier: "unrelated-alert", title: "Warning")
        let initial = DialogService.filePanelElements(
            in: .init(structural: [self.sheet], legacy: [], evidence: [self.sheet: original]),
            window: self.window,
            matching: { _ in false })
        let refreshed = DialogService.filePanelElements(
            in: .init(structural: [self.sheet], legacy: [], evidence: [self.sheet: replacement]),
            window: self.window,
            matching: { _ in false })
        #expect(initial == [self.sheet])
        #expect(refreshed.isEmpty)
    }

    @Test(arguments: ["Open Questions", "Saved Draft", "Choose Theme", "Replacement Parts"])
    func `ordinary document titles cannot make a real file panel ambiguous`(title: String) {
        let document = self.element(946_010, title: title, subrole: "AXStandardWindow")
        let panel = self.element(946_011, title: "Save", subrole: "AXUnknown")
        let service = DialogService()
        let result = DialogService.filePanelElements(
            in: .init(structural: [], legacy: [panel, document]),
            window: document,
            matching: service.isTargetedFilePanelElement)
        #expect(result == [panel])
    }

    @Test
    func `actual classifier preserves localized identified panels beside unrelated alerts`() {
        let panel = self.element(946_012, title: "Öffnen", subrole: "AXUnknown", identifier: "NSOpenPanel")
        let alert = self.element(946_013, title: "Warning", subrole: "AXDialog")
        let service = DialogService()
        let result = DialogService.filePanelElements(
            in: .init(structural: [alert], legacy: [panel]),
            window: self.window,
            matching: service.isTargetedFilePanelElement)
        #expect(result == [panel])
    }

    private func element(_ pid: Int32, title: String, subrole: String, identifier: String = "") -> Element {
        Element(
            AXUIElementCreateApplication(pid),
            attributes: [
                "AXRole": .string("AXWindow"), "AXSubrole": .string(subrole),
                "AXTitle": .string(title), "AXIdentifier": .string(identifier),
                "AXRoleDescription": .string(""), "AXModal": .bool(false),
            ],
            children: [],
            actions: [])
    }

    @Test
    func `file panel filtering precedes uniqueness even alongside an unrelated alert`() {
        let result = DialogService.filePanelElements(
            in: .init(structural: [self.alert, self.sheet], legacy: []),
            window: self.window,
            matching: { $0 == self.sheet })
        #expect(result == [self.sheet])
    }

    @Test
    func `compatible file panel is not hidden by structural alert precedence`() {
        let result = DialogService.filePanelElements(
            in: .init(structural: [self.alert], legacy: [self.sheet]),
            window: self.window,
            matching: { $0 == self.sheet })
        #expect(result == [self.sheet])
    }

    @Test
    func `mixed structural and compatible file panels remain ambiguous`() {
        let result = DialogService.filePanelElements(
            in: .init(structural: [self.sheet], legacy: [self.secondPanel]),
            window: self.window,
            matching: { _ in true })
        #expect(result == [self.sheet, self.secondPanel])
    }

    @Test
    func `file sheet retains its own element instead of a matching parent document`() {
        let result = DialogService.filePanelElements(
            in: .init(structural: [self.sheet], legacy: [self.window]),
            window: self.window,
            matching: { _ in true })
        #expect(result == [self.sheet])
    }

    @Test
    func `standalone compatible file panel keeps its owning window element`() {
        let result = DialogService.filePanelElements(
            in: .init(structural: [], legacy: [self.window]),
            window: self.window,
            matching: { _ in true })
        #expect(result == [self.window])
    }

    @Test
    func `absence of a file panel cannot select an unrelated dialog`() {
        let result = DialogService.filePanelElements(
            in: .init(structural: [self.alert], legacy: [self.window]),
            window: self.window,
            matching: { _ in false })
        #expect(result.isEmpty)
    }
}
