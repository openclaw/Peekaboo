import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

struct DialogFileSelectionMetadata: Sendable {
    let isSelected: Bool
    let names: [String]
    let selectedItems: [Element]

    @MainActor
    static func readDirect(_ element: Element) -> Self {
        let selected = ["AXSelectedChildren", "AXSelectedRows"].flatMap {
            element.attribute(Attribute<[AXUIElement]>($0))?.map(Element.init) ?? []
        }
        return Self(
            isSelected: element.attribute(Attribute<Bool>("AXSelected")) == true,
            names: ["AXValue", "AXTitle", "AXDescription"].compactMap {
                element.attribute(Attribute<String>($0))
            },
            selectedItems: selected)
    }
}

enum DialogFileSelectionReader {
    @MainActor
    static func read(
        _ element: Element,
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline) async throws -> DialogFileSelectionMetadata
    {
        let identity = DialogAXReadIdentity(element: element.underlyingElement)
        let raw = try await DialogAXReadRunner.run(owner: owner, budget: budget) {
            try self.readAttributes(budget: budget) { name in
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(identity.element, name as CFString, &value)
                return (value, error)
            }
        }
        return DialogFileSelectionMetadata(
            isSelected: raw.isSelected,
            names: raw.names,
            selectedItems: raw.selectedItems.map { Element($0.element) })
    }

    static func readAttributes(
        budget: DialogOperationDeadline,
        copyAttribute: (String) -> DialogHierarchyReader.AttributeRead) throws -> RawMetadata
    {
        func value(_ name: String) throws -> CFTypeRef? {
            try budget.check()
            let result = copyAttribute(name)
            try budget.check()
            return result.error == .success ? result.value : nil
        }
        var names: [String] = []
        for name in ["AXValue", "AXTitle", "AXDescription"] {
            if let raw = try value(name), CFGetTypeID(raw) == CFStringGetTypeID(), let text = raw as? String {
                names.append(text)
            }
        }
        var selectedItems: [DialogAXReadIdentity] = []
        for name in ["AXSelectedChildren", "AXSelectedRows"] {
            if let raw = try value(name), CFGetTypeID(raw) == CFArrayGetTypeID(),
               let items = raw as? [AnyObject], items.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
            {
                selectedItems += items.map {
                    DialogAXReadIdentity(element: unsafeDowncast($0, to: AXUIElement.self))
                }
            }
        }
        let selected = try value("AXSelected")
        return RawMetadata(
            isSelected: selected.map { CFGetTypeID($0) == CFBooleanGetTypeID() && ($0 as? Bool) == true } ?? false,
            names: names,
            selectedItems: selectedItems)
    }

    struct RawMetadata: Sendable {
        let isSelected: Bool
        let names: [String]
        let selectedItems: [DialogAXReadIdentity]
    }
}
