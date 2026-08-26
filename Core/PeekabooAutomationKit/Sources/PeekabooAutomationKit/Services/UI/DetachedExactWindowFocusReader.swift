import ApplicationServices
import CoreGraphics
import Foundation

struct ExactWindowFocusSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let windowID: Int?
    let frame: CGRect
    let role: String?
    let subrole: String?
    let title: String?
    let identifier: String?
    let value: String?

    init(
        processIdentifier: pid_t,
        windowID: Int?,
        frame: CGRect,
        role: String? = nil,
        subrole: String? = nil,
        title: String? = nil,
        identifier: String? = nil,
        value: String? = nil)
    {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.frame = frame
        self.role = role
        self.subrole = subrole
        self.title = title
        self.identifier = identifier
        self.value = value
    }
}

struct ExactKeyWindowSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let windowID: Int?
    let isSheet: Bool
    let hasAttachedSheet: Bool

    var hasSheet: Bool {
        self.isSheet || self.hasAttachedSheet
    }
}

enum DetachedExactWindowFocusReader {
    private static let messagingTimeout: Float = 0.05

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
        let role = self.stringAttribute(kAXRoleAttribute as String, of: focusedElement)
        let subrole = self.stringAttribute(kAXSubroleAttribute as String, of: focusedElement)
        return ExactWindowFocusSnapshot(
            processIdentifier: focusedProcessIdentifier,
            windowID: window.flatMap(AXWindowIDResolver.windowID(of:)).map(Int.init),
            frame: frame,
            role: role,
            subrole: subrole,
            title: self.stringAttribute(kAXTitleAttribute as String, of: focusedElement),
            identifier: self.stringAttribute(kAXIdentifierAttribute as String, of: focusedElement))
    }

    static func read(expected: FocusedElementIdentity) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError> {
        self.read(expected: expected, includesValue: false)
    }

    static func readValue(
        expected: FocusedElementIdentity) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
    {
        self.read(expected: expected, includesValue: true)
    }

    private static func read(
        expected: FocusedElementIdentity,
        includesValue: Bool) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
    {
        guard expected.processIdentifier > 0 else { return .failure(.missingProcessIdentifier) }
        guard expected.windowID > 0 else { return .failure(.missingWindowIdentifier) }
        guard !expected.frame.isEmpty else { return .failure(.missingElementFrame) }

        let application = AXUIElementCreateApplication(expected.processIdentifier)
        AXUIElementSetMessagingTimeout(application, self.messagingTimeout)
        let windows = self.elementArrayAttribute(kAXWindowsAttribute, of: application)
        guard let window = windows.first(where: {
            AXUIElementSetMessagingTimeout($0, self.messagingTimeout)
            return AXWindowIDResolver.windowID(of: $0).map(Int.init) == expected.windowID
        }) else {
            return .failure(.windowMismatch)
        }

        var queue = [window]
        var visited: [AXUIElement] = []
        var roleAndFrameMatches: [AXUIElement] = []
        var exactMatches: [AXUIElement] = []
        while let element = queue.first, visited.count < 4096 {
            queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, self.messagingTimeout)

            let observedRole = self.stringAttribute(kAXRoleAttribute as String, of: element)
            let observedFrame = self.frame(of: element)
            if observedRole == expected.role,
               observedFrame == expected.frame
            {
                roleAndFrameMatches.append(element)
                let candidate = FocusedElementIdentity(
                    processIdentifier: expected.processIdentifier,
                    windowID: expected.windowID,
                    role: observedRole ?? "",
                    title: self.stringAttribute(kAXTitleAttribute as String, of: element),
                    identifier: self.stringAttribute(kAXIdentifierAttribute as String, of: element),
                    frame: observedFrame ?? .zero)
                if FocusedElementReceiptResolver.matches(candidate, expected: expected) {
                    exactMatches.append(element)
                }
            }
            queue.append(contentsOf: self.elementArrayAttribute(kAXChildrenAttribute, of: element))
        }

        guard !roleAndFrameMatches.isEmpty else { return .failure(.frameMismatch) }
        guard !exactMatches.isEmpty else {
            return .failure(expected.identifier?.isEmpty == false ? .identifierMismatch : .titleMismatch)
        }
        guard exactMatches.count == 1, let element = exactMatches.first else {
            return .failure(.multipleFocusedElements)
        }
        guard let focused = self.boolAttribute(kAXFocusedAttribute, of: element) else {
            return .failure(.focusedAttributeUnreadable)
        }
        guard focused else { return .failure(.focusNotConfirmed) }

        let subrole = self.stringAttribute(kAXSubroleAttribute as String, of: element)
        return .success(ExactWindowFocusSnapshot(
            processIdentifier: expected.processIdentifier,
            windowID: expected.windowID,
            frame: expected.frame,
            role: expected.role,
            subrole: subrole,
            title: self.stringAttribute(kAXTitleAttribute as String, of: element),
            identifier: self.stringAttribute(kAXIdentifierAttribute as String, of: element),
            value: includesValue && self.allowsValueRead(role: expected.role, subrole: subrole)
                ? self.stringAttribute(kAXValueAttribute as String, of: element)
                : nil))
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
        return ExactKeyWindowSnapshot(
            processIdentifier: focusedProcessIdentifier,
            windowID: AXWindowIDResolver.windowID(of: focusedWindow).map(Int.init),
            isSheet: role == (kAXSheetRole as String),
            hasAttachedSheet: !self.elementArrayAttribute("AXSheets", of: focusedWindow).isEmpty)
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

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return self.focusedAttributeValue(value)
    }

    static func focusedAttributeValue(_ value: Any?) -> Bool? {
        AXDescriptorReader.boolValue(value)
    }

    static func allowsValueRead(role: String?, subrole: String?) -> Bool {
        role != "AXSecureTextField" && subrole != "AXSecureTextField"
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
