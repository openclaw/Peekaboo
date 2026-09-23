import ApplicationServices
import CoreGraphics

@_silgen_name("_AXUIElementGetWindow")
private func copyAXWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

enum AXWindowIDResolver {
    static func copyWindowID(_ element: AXUIElement, into windowID: inout CGWindowID) -> AXError {
        copyAXWindowID(element, &windowID)
    }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        var windowID: CGWindowID = 0
        return self.copyWindowID(element, into: &windowID) == .success ? windowID : nil
    }

    static func owningWindowID(
        of element: AXUIElement,
        windowID: (AXUIElement) -> CGWindowID? = AXWindowIDResolver.windowID(of:),
        windowAttribute: (AXUIElement) -> CFTypeRef? = AXWindowIDResolver.windowAttribute(of:)) -> CGWindowID?
    {
        if let direct = windowID(element), direct > 0 {
            return direct
        }
        // AX attributes contain native AXUIElement values, not AXorcist Element wrappers.
        guard let value = windowAttribute(element), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let window = unsafeDowncast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(window, 0.05)
        defer { AXUIElementSetMessagingTimeout(window, 0) }
        guard let linked = windowID(window), linked > 0 else { return nil }
        return linked
    }

    private static func windowAttribute(of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
