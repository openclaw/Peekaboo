import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

struct DialogHierarchyNode: Sendable {
    let evidence: DialogElementEvidence
    let children: [Element]
}

enum DialogHierarchyReader {
    @MainActor
    static func read(
        _ element: Element,
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline) async throws -> DialogHierarchyNode
    {
        let identity = DialogAXReadIdentity(element: element.underlyingElement)
        let result = try await DialogAXReadRunner.run(owner: owner, budget: budget) {
            try self.readNode(budget: budget) { name in
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(identity.element, name as CFString, &value)
                return (value, error)
            }
        }
        var seen: Set<Element> = []
        let children = result.children.map { Element($0.element) }.filter { seen.insert($0).inserted }
        return DialogHierarchyNode(evidence: result.evidence, children: children)
    }

    static func readNode(
        budget: DialogOperationDeadline,
        readAttribute: (String) -> (CFTypeRef?, AXError)) throws -> RawNode
    {
        let role: String? = try self.attribute(kAXRoleAttribute, budget: budget, readAttribute: readAttribute)
        guard let role, !role.isEmpty else { throw self.unreadable }
        let subrole: String? = try self.attribute(kAXSubroleAttribute, budget: budget, readAttribute: readAttribute)
        var evidence = DialogElementEvidence(
            role: role, subrole: subrole ?? "", roleDescription: "", identifier: "", title: "")
        // Ineligible controls cannot become dialog candidates, but their descendants still can.
        if DialogElementClassifier.permitsLegacyReadHeuristics(evidence) {
            let description: String? = try self.attribute(
                kAXRoleDescriptionAttribute, budget: budget, readAttribute: readAttribute)
            let identifier: String? = try self.attribute(
                kAXIdentifierAttribute,
                budget: budget,
                readAttribute: readAttribute)
            let title: String? = try self.attribute(kAXTitleAttribute, budget: budget, readAttribute: readAttribute)
            let modal: Bool? = try self.attribute(kAXModalAttribute, budget: budget, readAttribute: readAttribute)
            evidence = DialogElementEvidence(
                role: role,
                subrole: subrole ?? "",
                roleDescription: description ?? "",
                identifier: identifier ?? "",
                title: title ?? "",
                isModal: modal)
        }
        let sheets: [AXUIElement]? = try self.attribute("AXSheets", budget: budget, readAttribute: readAttribute)
        let children: [AXUIElement]? = try self.attribute(
            kAXChildrenAttribute,
            budget: budget,
            readAttribute: readAttribute)
        return RawNode(
            evidence: evidence,
            children: ((sheets ?? []) + (children ?? [])).map { DialogAXReadIdentity(element: $0) })
    }

    private static func attribute<Value>(
        _ name: String,
        budget: DialogOperationDeadline,
        readAttribute: (String) -> (CFTypeRef?, AXError)) throws -> Value?
    {
        try budget.check()
        let (value, error) = readAttribute(name)
        try budget.check()
        return try self.attributeValue(value, error: error)
    }

    static func attributeValue<Value>(_ value: CFTypeRef?, error: AXError) throws -> Value? {
        switch error {
        case .attributeUnsupported, .noValue:
            return nil
        case .success:
            guard let value else { throw self.unreadable }
            // CF reference array casts alone do not validate each element's runtime type.
            if Value.self == [AXUIElement].self {
                guard CFGetTypeID(value) == CFArrayGetTypeID(),
                      let elements = value as? [AnyObject],
                      elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
                else { throw self.unreadable }
            }
            if Value.self == Bool.self, CFGetTypeID(value) != CFBooleanGetTypeID() {
                throw self.unreadable
            }
            guard let typedValue = value as? Value else { throw self.unreadable }
            return typedValue
        default:
            throw self.unreadable
        }
    }

    private static var unreadable: PeekabooError {
        .accessibilityIncomplete("Dialog hierarchy classification or children could not be read completely.")
    }

    struct RawNode: Sendable {
        let evidence: DialogElementEvidence
        let children: [DialogAXReadIdentity]
    }
}
