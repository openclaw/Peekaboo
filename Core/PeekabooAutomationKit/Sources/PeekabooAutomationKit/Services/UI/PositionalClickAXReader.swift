import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

/// Resolves positional AX actions without treating failed reads or truncated searches as unsupported.
@MainActor
struct PositionalClickAXReader {
    struct Access {
        var hit: (AXUIElement, CGPoint) -> (error: AXError, element: AXUIElement?) = { application, point in
            var element: AXUIElement?
            let error = AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &element)
            return (error, element)
        }

        var attribute: (AXUIElement, String) -> (error: AXError, value: CFTypeRef?) = { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        }

        var actions: (AXUIElement) -> (error: AXError, value: CFTypeRef?) = { element in
            var names: CFArray?
            let error = AXUIElementCopyActionNames(element, &names)
            return (error, names)
        }

        var settable: (AXUIElement, String) -> (error: AXError, value: Bool) = { element, name in
            var value: DarwinBoolean = false
            let error = AXUIElementIsAttributeSettable(element, name as CFString, &value)
            return (error, value.boolValue)
        }

        var processID: (AXUIElement) -> (error: AXError, value: pid_t) = { element in
            var value: pid_t = 0
            return (AXUIElementGetPid(element, &value), value)
        }
    }

    var access = Access()
    var maximumDescendants = 256
    var maximumDepth = 8
    var maximumAncestors = 8

    func resolve(at point: CGPoint, targetProcessIdentifier: pid_t) throws -> BackgroundInputDriver
        .PositionalClickResolution
    {
        try Task.checkCancellation()
        let application = AXUIElementCreateApplication(targetProcessIdentifier)
        let hitRead = self.access.hit(application, point)
        try Task.checkCancellation()
        // This API documents noValue as "no accessibility object at the specified position".
        if hitRead.error == .noValue, hitRead.element == nil {
            return .unsupported
        }
        guard hitRead.error == .success, let hit = hitRead.element else {
            throw Self.unreadable("hit test", error: hitRead.error)
        }
        var observations: [BackgroundInputDriver.PositionalClickObservation] = []
        var visited: [AXUIElement] = []
        func inspect(_ element: AXUIElement, authoritativeHit: Bool = false) throws
            -> BackgroundInputDriver.PositionalClickResolution?
        {
            try Task.checkCancellation()
            guard !visited.contains(where: { CFEqual($0, element) }) else {
                throw Self.unreadable("hierarchy cycle or repeated element")
            }
            visited.append(element)
            let observation = try self.observe(
                element, at: point, processIdentifier: targetProcessIdentifier, authoritativeHit: authoritativeHit)
            try Task.checkCancellation()
            observations.append(observation)
            if let target = BackgroundInputDriver.positionalClickTarget(
                inObservations: [observation], at: point, button: .left), target.action == .press
            {
                return .accessibility(element: target.element, action: target.action)
            }
            return nil
        }
        if let result = try inspect(hit, authoritativeHit: true) {
            return result
        }

        var queue = try self.children(of: hit).map { (element: $0, depth: 1) }
        var index = 0
        while index < queue.count {
            guard index < self.maximumDescendants else { throw Self.unreadable("descendant limit") }
            let node = queue[index]
            index += 1
            if let result = try inspect(node.element) {
                return result
            }
            let children = try self.children(of: node.element)
            guard children.isEmpty || node.depth < self.maximumDepth else {
                throw Self.unreadable("descendant depth limit")
            }
            queue.append(contentsOf: children.map { (element: $0, depth: node.depth + 1) })
        }

        var parent = try self.parent(of: hit)
        var ancestorCount = 0
        while let element = parent {
            guard ancestorCount < self.maximumAncestors else { throw Self.unreadable("ancestor limit") }
            ancestorCount += 1
            if let result = try inspect(element) {
                return result
            }
            parent = try self.parent(of: element)
        }
        try Task.checkCancellation()
        if let target = BackgroundInputDriver.positionalClickTarget(
            inObservations: observations, at: point, button: .left)
        {
            return .accessibility(element: target.element, action: target.action)
        }
        return .unsupported
    }

    private func observe(
        _ element: AXUIElement,
        at point: CGPoint,
        processIdentifier: pid_t,
        authoritativeHit: Bool) throws -> BackgroundInputDriver.PositionalClickObservation
    {
        let owner = self.access.processID(element)
        guard owner.error == .success, owner.value == processIdentifier else {
            throw Self.unreadable("element owner", error: owner.error)
        }
        let role = try self.string(kAXRoleAttribute, of: element, required: true)
        let frame = try self.frame(of: element)
        let eligible = authoritativeHit || frame?.contains(point) == true
        let actions = eligible ? try self.actions(of: element) : []
        let enabled = eligible ? try self.enabled(element) : false
        let pressable = enabled && actions.contains(kAXPressAction) && BackgroundInputDriver.isPositionalPressRole(role)
        let selectedSettable = eligible && !pressable && role == kAXRowRole
            ? try self.settable(kAXSelectedAttribute, of: element) : false
        let needsFocus = eligible && !pressable && !(enabled && selectedSettable)
        let subrole = needsFocus && !BackgroundInputDriver.isPositionalFocusRole(role, subrole: nil)
            ? try self.string(kAXSubroleAttribute, of: element) : nil
        let focusedSettable = needsFocus && BackgroundInputDriver.isPositionalFocusRole(role, subrole: subrole)
            ? try self.settable(kAXFocusedAttribute, of: element) : false
        return .init(
            element: AutomationElement(Element(element)),
            authoritativeHit: authoritativeHit,
            frame: frame,
            role: role,
            subrole: subrole,
            actions: actions,
            isEnabled: enabled,
            isSelectedSettable: selectedSettable,
            isFocusedSettable: focusedSettable)
    }

    private func attribute(_ name: String, of element: AXUIElement, required: Bool = false) throws -> CFTypeRef? {
        try Task.checkCancellation()
        let result = self.access.attribute(element, name)
        switch result.error {
        case .success:
            guard let value = result.value else { throw Self.unreadable(name) }
            return value
        case .attributeUnsupported, .noValue:
            guard !required else { throw Self.unreadable(name, error: result.error) }
            return nil
        default:
            throw Self.unreadable(name, error: result.error)
        }
    }

    private func string(_ name: String, of element: AXUIElement, required: Bool = false) throws -> String? {
        guard let value = try self.attribute(name, of: element, required: required) else { return nil }
        guard CFGetTypeID(value) == CFStringGetTypeID(), let string = value as? String, !required || !string.isEmpty
        else { throw Self.unreadable(name) }
        return string
    }

    private func enabled(_ element: AXUIElement) throws -> Bool {
        guard let value = try self.attribute(kAXEnabledAttribute, of: element) else { return true }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let enabled = value as? Bool else {
            throw Self.unreadable(kAXEnabledAttribute)
        }
        return enabled
    }

    private func actions(of element: AXUIElement) throws -> [String] {
        let result = self.access.actions(element)
        guard result.error == .success, let value = result.value,
              CFGetTypeID(value) == CFArrayGetTypeID(), let actions = value as? [String]
        else { throw Self.unreadable("action names", error: result.error) }
        return actions
    }

    private func settable(_ name: String, of element: AXUIElement) throws -> Bool {
        let result = self.access.settable(element, name)
        switch result.error {
        case .success: return result.value
        case .attributeUnsupported: return false
        default: throw Self.unreadable("settable \(name)", error: result.error)
        }
    }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try self.attribute(kAXChildrenAttribute, of: element) else { return [] }
        guard CFGetTypeID(value) == CFArrayGetTypeID(), let children = value as? [AXUIElement],
              children.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
        else { throw Self.unreadable(kAXChildrenAttribute) }
        return children
    }

    private func parent(of element: AXUIElement) throws -> AXUIElement? {
        guard let value = try self.attribute(kAXParentAttribute, of: element) else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { throw Self.unreadable(kAXParentAttribute) }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func frame(of element: AXUIElement) throws -> CGRect? {
        let position = try self.attribute(kAXPositionAttribute, of: element)
        let size = try self.attribute(kAXSizeAttribute, of: element)
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        if let position {
            guard CFGetTypeID(position) == AXValueGetTypeID() else { throw Self.unreadable(kAXPositionAttribute) }
            let value = unsafeDowncast(position, to: AXValue.self)
            guard AXValueGetType(value) == .cgPoint, AXValueGetValue(value, .cgPoint, &origin),
                  origin.x.isFinite, origin.y.isFinite
            else { throw Self.unreadable(kAXPositionAttribute) }
        }
        if let size {
            guard CFGetTypeID(size) == AXValueGetTypeID() else { throw Self.unreadable(kAXSizeAttribute) }
            let value = unsafeDowncast(size, to: AXValue.self)
            guard AXValueGetType(value) == .cgSize, AXValueGetValue(value, .cgSize, &dimensions),
                  dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width >= 0, dimensions.height >= 0
            else { throw Self.unreadable(kAXSizeAttribute) }
        }
        guard position != nil, size != nil else { return nil }
        return CGRect(origin: origin, size: dimensions)
    }

    private static func unreadable(_ stage: String, error: AXError? = nil) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: error == .apiDisabled ? .permissionDenied : .targetUnavailable,
            message: "Positional Accessibility observation is incomplete at \(stage).",
            hint: "Observe the exact target again; no click was dispatched.",
            causeDescription: error.map { "AX error \($0.rawValue)." })
    }
}
