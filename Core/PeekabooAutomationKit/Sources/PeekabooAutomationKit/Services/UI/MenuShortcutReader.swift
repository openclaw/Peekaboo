import ApplicationServices
import AXorcist
import Foundation

/// Menu hierarchy and shortcut reads must not guess missing metadata or search unrelated AX containers.
@MainActor
struct MenuShortcutReader {
    struct AttributeRead {
        let error: AXError
        let value: CFTypeRef?
    }

    typealias NativeRead = @MainActor @Sendable (AXUIElement, String) -> AttributeRead

    private let nativeRead: NativeRead

    init(nativeRead: @escaping NativeRead = Self.readNativeAttribute) {
        self.nativeRead = nativeRead
    }

    func children(of element: any AutomationElementRepresenting) throws -> [any AutomationElementRepresenting] {
        guard element.underlyingAXElement != nil else { return element.automationChildren }
        guard let value = try self.attribute(kAXChildrenAttribute, of: element) else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID(),
              let children = value as? [AXUIElement],
              children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
        else {
            throw Self.invalidAttribute(kAXChildrenAttribute)
        }
        return children.map { AutomationElement(Element($0)) }
    }

    func role(of element: any AutomationElementRepresenting) throws -> String? {
        guard element.underlyingAXElement != nil else { return element.role }
        guard let role = try self.string(kAXRoleAttribute, of: element) else {
            throw ActionInputError.unsupported(.attributeUnsupported)
        }
        return role
    }

    func commandCharacter(of element: any AutomationElementRepresenting) throws -> String? {
        guard element.underlyingAXElement != nil else { return element.stringAttribute(kAXMenuItemCmdCharAttribute) }
        return try self.string(kAXMenuItemCmdCharAttribute, of: element)
    }

    func modifiers(of element: any AutomationElementRepresenting) throws -> Int {
        guard element.underlyingAXElement != nil else {
            guard let modifiers = element.intAttribute(kAXMenuItemCmdModifiersAttribute) else {
                throw ActionInputError.unsupported(.menuShortcutUnavailable)
            }
            return modifiers
        }
        guard let value = try self.attribute(kAXMenuItemCmdModifiersAttribute, of: element) else {
            throw ActionInputError.unsupported(.menuShortcutUnavailable)
        }
        guard CFGetTypeID(value) == CFNumberGetTypeID(), let number = value as? NSNumber,
              let modifiers = Int(exactly: number.doubleValue), modifiers >= 0, modifiers <= 15
        else {
            throw Self.invalidAttribute(kAXMenuItemCmdModifiersAttribute)
        }
        return modifiers
    }

    func isEnabled(_ element: any AutomationElementRepresenting) throws -> Bool {
        guard element.underlyingAXElement != nil else { return element.isEnabled }
        guard let value = try self.attribute(kAXEnabledAttribute, of: element) else {
            throw ActionInputError.unsupported(.attributeUnsupported)
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let enabled = value as? Bool else {
            throw Self.invalidAttribute(kAXEnabledAttribute)
        }
        return enabled
    }

    private func string(_ name: String, of element: any AutomationElementRepresenting) throws -> String? {
        guard let value = try self.attribute(name, of: element) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String else {
            throw Self.invalidAttribute(name)
        }
        return string
    }

    private func attribute(_ name: String, of element: any AutomationElementRepresenting) throws -> CFTypeRef? {
        guard let nativeElement = element.underlyingAXElement else {
            throw ActionInputError.unsupported(.missingElement)
        }
        let result = self.nativeRead(nativeElement, name)
        switch result.error {
        case .success:
            guard let value = result.value else { throw Self.invalidAttribute(name) }
            return value
        case .attributeUnsupported, .noValue:
            return nil
        default:
            throw ActionInputDriver.classify(result.error)
        }
    }

    private static func invalidAttribute(_ name: String) -> ActionInputError {
        .failed("Menu shortcut attribute \(name) is malformed")
    }

    private static func readNativeAttribute(_ element: AXUIElement, _ name: String) -> AttributeRead {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return AttributeRead(error: error, value: value)
    }
}
