import AXorcist
import Foundation

struct DialogElementEvidence: Equatable, Sendable {
    let role: String
    let subrole: String
    let roleDescription: String
    let identifier: String
    let title: String
    let isModal: Bool?

    init(
        role: String,
        subrole: String,
        roleDescription: String,
        identifier: String,
        title: String,
        isModal: Bool? = nil)
    {
        self.role = role
        self.subrole = subrole
        self.roleDescription = roleDescription
        self.identifier = identifier
        self.title = title
        self.isModal = isModal
    }
}

enum DialogElementClassifier {
    static let titleHints = ["open", "save", "export", "import", "choose", "replace"]

    @MainActor
    static func evidence(for element: Element) -> DialogElementEvidence {
        DialogElementEvidence(
            role: element.role() ?? "",
            subrole: element.subrole() ?? "",
            roleDescription: element.attribute(Attribute<String>("AXRoleDescription")) ?? "",
            identifier: element.attribute(Attribute<String>("AXIdentifier")) ?? "",
            title: element.title() ?? "",
            isModal: element.attribute(Attribute<Bool>("AXModal")))
    }

    static func isDialog(
        _ evidence: DialogElementEvidence,
        matching expectedTitle: String? = nil,
        titleHints: [String] = Self.titleHints) -> Bool
    {
        if let expectedTitle, !evidence.title.elementsEqual(expectedTitle) {
            return false
        }
        if self.hasIntrinsicDialogRole(
            role: evidence.role,
            subrole: evidence.subrole)
        {
            return true
        }
        if evidence.roleDescription.localizedCaseInsensitiveContains("dialog") {
            return true
        }
        if self.hasFilePanelIdentifier(evidence.identifier) {
            return true
        }
        return titleHints.contains { evidence.title.localizedCaseInsensitiveContains($0) }
    }

    static func isFileDialog(
        _ evidence: DialogElementEvidence,
        titleHints: [String] = Self.titleHints) -> Bool
    {
        self.hasFilePanelIdentifier(evidence.identifier) ||
            titleHints.contains { evidence.title.localizedCaseInsensitiveContains($0) }
    }

    static func isObservationDialog(_ evidence: DialogElementEvidence) -> Bool {
        if self.hasFilePanelIdentifier(evidence.identifier) || self.isObservationFileDialogTitle(evidence.title) {
            return true
        }
        // SwiftUI WindowGroup windows can expose AXWindow/AXDialog while explicitly reporting AXModal=false.
        // Require the WindowGroup identity too; modality alone does not distinguish modeless native panels.
        if evidence.role == "AXWindow",
           evidence.subrole == "AXDialog",
           evidence.isModal == false,
           self.isSwiftUIWindowGroupIdentifier(evidence.identifier)
        {
            return false
        }
        return ["AXDialog", "AXSystemDialog", "AXSheet"].contains(evidence.subrole)
    }

    static func isStructuralDialog(_ evidence: DialogElementEvidence) -> Bool {
        self.hasIntrinsicDialogRole(role: evidence.role, subrole: evidence.subrole)
    }

    static func permitsLegacyReadHeuristics(_ evidence: DialogElementEvidence) -> Bool {
        self.isStructuralDialog(evidence) ||
            ["AXWindow", "AXUnknown"].contains(evidence.role)
    }

    static func preferredReadCandidates<Candidate>(
        structural: [Candidate],
        legacy: [Candidate]) -> [Candidate]
    {
        structural.isEmpty ? legacy : structural
    }

    static func containsDialog(in elements: [DetectedElement]) -> Bool {
        elements.contains { element in
            let role = element.attributes["role"] ?? ""
            let subrole = element.attributes["subrole"] ?? ""
            return self.hasIntrinsicDialogRole(role: role, subrole: subrole)
        }
    }

    private static func hasIntrinsicDialogRole(role: String, subrole: String) -> Bool {
        ["AXSheet", "AXDialog"].contains(role) ||
            ["AXSheet", "AXDialog", "AXSystemDialog", "AXAlert"].contains(subrole)
    }

    private static func isObservationFileDialogTitle(_ title: String) -> Bool {
        ["Open", "Save", "Export", "Import"].contains(title) || title.hasPrefix("Save As")
    }

    private static func hasFilePanelIdentifier(_ identifier: String) -> Bool {
        identifier.contains("NSOpenPanel") || identifier.contains("NSSavePanel")
    }

    private static func isSwiftUIWindowGroupIdentifier(_ identifier: String) -> Bool {
        identifier.hasPrefix("SwiftUI.WindowGroup-AppWindow-")
    }
}
