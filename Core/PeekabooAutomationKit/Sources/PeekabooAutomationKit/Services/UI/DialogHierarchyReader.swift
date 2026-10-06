import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

struct DialogHierarchyNode: Sendable {
    let evidence: DialogElementEvidence
    let children: [Element]
}

enum DialogHierarchyReader {
    typealias AttributeRead = (value: CFTypeRef?, error: AXError)

    @MainActor
    static func read(
        _ element: Element,
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline) async throws -> DialogHierarchyNode
    {
        let identity = DialogAXReadIdentity(element: element.underlyingElement)
        let result = try await DialogAXReadRunner.run(owner: owner, budget: budget) {
            try self.readBatchedNode(
                budget: budget,
                copyAttributes: { names in
                    var values: CFArray?
                    let error = AXUIElementCopyMultipleAttributeValues(
                        identity.element, names as CFArray, [], &values)
                    return (values, error)
                },
                copyAttribute: { name in
                    var value: CFTypeRef?
                    let error = AXUIElementCopyAttributeValue(identity.element, name as CFString, &value)
                    return (value, error)
                })
        }
        var seen: Set<Element> = []
        let children = result.children.map { Element($0.element) }.filter { seen.insert($0).inserted }
        return DialogHierarchyNode(evidence: result.evidence, children: children)
    }

    static func readNode(
        budget: DialogOperationDeadline,
        readAttribute: (String) throws -> AttributeRead) throws -> RawNode
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

    static func readBatchedNode(
        budget: DialogOperationDeadline,
        copyAttributes: ([String]) -> AttributeRead,
        copyAttribute: (String) -> AttributeRead) throws -> RawNode
    {
        var reads = try self.readAttributes(
            [kAXRoleAttribute, kAXSubroleAttribute, "AXSheets", kAXChildrenAttribute],
            budget: budget,
            copyAttributes: copyAttributes,
            copyAttribute: copyAttribute)
        return try self.readNode(budget: budget) { name in
            if let read = reads[name] {
                return read
            }
            let descriptors = try self.readAttributes(
                [kAXRoleDescriptionAttribute, kAXIdentifierAttribute, kAXTitleAttribute, kAXModalAttribute],
                budget: budget,
                copyAttributes: copyAttributes,
                copyAttribute: copyAttribute)
            reads.merge(descriptors) { _, new in new }
            guard let read = reads[name] else { throw self.unreadable }
            return read
        }
    }

    private static func readAttributes(
        _ names: [String],
        budget: DialogOperationDeadline,
        copyAttributes: ([String]) -> AttributeRead,
        copyAttribute: (String) -> AttributeRead) throws -> [String: AttributeRead]
    {
        try budget.check()
        let batch = copyAttributes(names)
        try budget.check()
        let values: [AnyObject]? = if let value = batch.value, CFGetTypeID(value) == CFArrayGetTypeID() {
            value as? [AnyObject]
        } else {
            nil
        }
        if AXDescriptorReader.shouldFallbackToSingleAttributeReads(
            error: batch.error, hasExpectedValueShape: values?.count == names.count)
        {
            var reads: [String: AttributeRead] = [:]
            for name in names {
                try budget.check()
                reads[name] = copyAttribute(name)
                try budget.check()
            }
            return reads
        }
        guard batch.error == .success, let values, values.count == names.count else { throw self.unreadable }
        var reads: [String: AttributeRead] = [:]
        for (name, value) in zip(names, values) {
            try budget.check()
            if CFGetTypeID(value) == CFNullGetTypeID() {
                // Batch CFNull can mean unsupported; only a single read can distinguish that from malformed success.
                reads[name] = copyAttribute(name)
                try budget.check()
            } else if let error = AXAttributeReadCompletenessPolicy.embeddedError(in: value) {
                reads[name] = (nil, error)
            } else {
                reads[name] = (value, .success)
            }
        }
        return reads
    }

    private static func attribute<Value>(
        _ name: String,
        budget: DialogOperationDeadline,
        readAttribute: (String) throws -> AttributeRead) throws -> Value?
    {
        try budget.check()
        let (value, error) = try readAttribute(name)
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
