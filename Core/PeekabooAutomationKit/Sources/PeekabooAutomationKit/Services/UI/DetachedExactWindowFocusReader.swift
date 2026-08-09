import ApplicationServices
import CoreGraphics
import Foundation

struct ExactWindowFocusSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let windowID: Int?
    let frame: CGRect
    let role: String?
    let title: String?
    let identifier: String?

    init(
        processIdentifier: pid_t,
        windowID: Int?,
        frame: CGRect,
        role: String? = nil,
        title: String? = nil,
        identifier: String? = nil)
    {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.frame = frame
        self.role = role
        self.title = title
        self.identifier = identifier
    }
}

struct ExactKeyWindowSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let windowID: Int?
    let hasSheet: Bool
}

enum DetachedExactWindowFocusReader {
    private static let messagingTimeout: Float = 0.05

    @_silgen_name("_AXUIElementGetWindow")
    private static func copyWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

    static func read(processIdentifier: pid_t) -> ExactWindowFocusSnapshot? {
        guard processIdentifier > 0 else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, self.messagingTimeout)
        guard let focusedElement = self.elementAttribute(kAXFocusedUIElementAttribute, of: application) else {
            return nil
        }

        AXUIElementSetMessagingTimeout(focusedElement, self.messagingTimeout)
        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &focusedProcessIdentifier) == .success,
              focusedProcessIdentifier == processIdentifier
        else {
            return nil
        }

        let frame = self.frame(of: focusedElement) ?? .zero
        let window = self.elementAttribute(kAXWindowAttribute, of: focusedElement)
        if let window {
            AXUIElementSetMessagingTimeout(window, self.messagingTimeout)
        }
        return ExactWindowFocusSnapshot(
            processIdentifier: focusedProcessIdentifier,
            windowID: window.flatMap(self.windowID(of:)).map(Int.init),
            frame: frame,
            role: self.stringAttribute(kAXRoleAttribute as String, of: focusedElement),
            title: self.stringAttribute(kAXTitleAttribute as String, of: focusedElement),
            identifier: self.stringAttribute(kAXIdentifierAttribute as String, of: focusedElement))
    }

    static func readKeyWindow(processIdentifier: pid_t) -> ExactKeyWindowSnapshot? {
        guard processIdentifier > 0 else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, self.messagingTimeout)
        guard let focusedWindow = self.elementAttribute(kAXFocusedWindowAttribute, of: application) else {
            return nil
        }

        AXUIElementSetMessagingTimeout(focusedWindow, self.messagingTimeout)
        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedWindow, &focusedProcessIdentifier) == .success,
              focusedProcessIdentifier == processIdentifier
        else {
            return nil
        }

        let role = self.stringAttribute(kAXRoleAttribute, of: focusedWindow)
        let hasSheet = role == (kAXSheetRole as String) ||
            !self.elementArrayAttribute("AXSheets", of: focusedWindow).isEmpty
        return ExactKeyWindowSnapshot(
            processIdentifier: focusedProcessIdentifier,
            windowID: self.windowID(of: focusedWindow).map(Int.init),
            hasSheet: hasSheet)
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elementArrayAttribute(_ name: String, of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else {
            return []
        }
        return elements
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue) == .success,
            let position = self.pointValue(positionValue),
            let size = self.sizeValue(sizeValue)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        return self.copyWindowID(element, &windowID) == .success ? windowID : nil
    }

    private static func pointValue(_ value: CFTypeRef?) -> CGPoint? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ value: CFTypeRef?) -> CGSize? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeDowncast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }
}
