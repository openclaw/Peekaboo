import ApplicationServices
import Foundation
import PeekabooFoundation

/// Selects text delivery; receiver and target ownership remain the caller's responsibility.
enum TextInputRoute: Equatable {
    case nativeAX
    case webKeyboard
    case unproven

    struct Node<Element> {
        let role: String
        let processIdentifier: pid_t
        let parent: Element?
    }

    func permitsAccessibilityEditing() throws -> Bool {
        switch self {
        case .nativeAX:
            return true
        case .webKeyboard:
            return false
        case .unproven:
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Text input could not prove the focused control's delivery route.",
                hint: "Observe the exact target again before retrying; no input was sent by this unit.")
        }
    }

    static func resolve(focusedElement: AXUIElement) -> Self {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success, processIdentifier > 0 else {
            return .unproven
        }
        return self.resolve(
            focusedElement: focusedElement,
            application: AXUIElementCreateApplication(processIdentifier),
            targetProcessIdentifier: processIdentifier)
    }

    static func resolve(
        focusedElement: AXUIElement,
        application: AXUIElement,
        targetProcessIdentifier: pid_t) -> Self
    {
        self.resolve(
            from: focusedElement,
            targetProcessIdentifier: targetProcessIdentifier,
            readNode: self.readNode,
            sameElement: { CFEqual($0, $1) },
            validateReceiver: { timeout in
                self.isCurrentFocusedReceiver(focusedElement, application: application, timeout: timeout)
            })
    }

    static func resolve<Element>(
        from element: Element,
        targetProcessIdentifier: pid_t,
        maxNodes: Int = 32,
        timeBudget: TimeInterval = 0.25,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        isCancelled: () -> Bool = { Task.isCancelled },
        readNode: (Element, Float) -> Node<Element>?,
        sameElement: (Element, Element) -> Bool,
        validateReceiver: (Float) -> Bool) -> Self
    {
        guard targetProcessIdentifier > 0, maxNodes > 0, timeBudget.isFinite, timeBudget > 0 else {
            return .unproven
        }
        let deadline = now() + timeBudget
        var current = element
        var visited: [Element] = []
        while visited.count < maxNodes {
            let remaining = deadline - now()
            guard remaining > 0, !isCancelled(), !visited.contains(where: { sameElement($0, current) }) else {
                return .unproven
            }
            visited.append(current)
            guard let node = readNode(current, Float(min(0.05, remaining / 2))),
                  now() < deadline, !isCancelled(),
                  node.processIdentifier == targetProcessIdentifier, !node.role.isEmpty
            else { return .unproven }

            if let route = self.terminalRoute(for: node.role) {
                let remaining = deadline - now()
                guard remaining > 0,
                      validateReceiver(Float(min(0.05, remaining / 2))),
                      now() < deadline, !isCancelled()
                else { return .unproven }
                return route
            }
            guard let parent = node.parent else { return .unproven }
            current = parent
        }
        return .unproven
    }

    private static func terminalRoute(for role: String) -> Self? {
        switch role {
        case "AXWebArea": .webKeyboard
        case "AXWindow", "AXApplication": .nativeAX
        default: nil
        }
    }

    private static func readNode(_ element: AXUIElement, timeout: Float) -> Node<AXUIElement>? {
        self.readWithTimeout(on: element, timeout: timeout) {
            var processIdentifier: pid_t = 0
            guard AXUIElementGetPid(element, &processIdentifier) == .success,
                  let role = self.attribute(kAXRoleAttribute, of: element) as? String
            else { return nil }
            let parent: AXUIElement?
            if self.terminalRoute(for: role) != nil {
                parent = nil
            } else {
                guard let value = self.attribute(kAXParentAttribute, of: element),
                      CFGetTypeID(value) == AXUIElementGetTypeID()
                else { return nil }
                parent = unsafeDowncast(value, to: AXUIElement.self)
            }
            return Node(role: role, processIdentifier: processIdentifier, parent: parent)
        }
    }

    private static func isCurrentFocusedReceiver(
        _ element: AXUIElement,
        application: AXUIElement,
        timeout: Float) -> Bool
    {
        let focused = self.readWithTimeout(on: application, timeout: timeout) {
            self.attribute(kAXFocusedUIElementAttribute, of: application)
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID(), CFEqual(focused, element)
        else { return false }
        return self.readWithTimeout(on: element, timeout: timeout) {
            self.confirmsFocus(self.attribute(kAXFocusedAttribute, of: element))
        } == true
    }

    static func confirmsFocus(_ value: Any?) -> Bool {
        AXDescriptorReader.boolValue(value) == true
    }

    private static func readWithTimeout<Value>(
        on element: AXUIElement,
        timeout: Float,
        read: () -> Value?) -> Value?
    {
        self.readWithTimeout(
            timeout: timeout,
            applyTimeout: { AXUIElementSetMessagingTimeout(element, $0) },
            read: read)
    }

    static func readWithTimeout<Value>(
        timeout: Float,
        applyTimeout: (Float) -> AXError,
        read: () -> Value?) -> Value?
    {
        guard timeout.isFinite, timeout > 0, applyTimeout(timeout) == .success else { return nil }
        let result = read()
        // A native edit must never inherit the short observation timeout after a failed reset.
        guard applyTimeout(0) == .success else { return nil }
        return result
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
}
