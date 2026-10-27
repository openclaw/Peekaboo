import ApplicationServices
import CoreGraphics

/// Resolves fresh application-local AX references without treating focus or title as window identity.
struct AXWindowLookup {
    let application: AXUIElement
    let processIdentifier: pid_t
    var messagingTimeout: () -> Float? = { 1 }
    var readAttribute: (AXUIElement, String) -> CFTypeRef? = { element, name in
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    var windowID: (AXUIElement) -> CGWindowID? = AXWindowIDResolver.windowID(of:)
    var ownerPID: (AXUIElement) -> pid_t? = { element in
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    func findWindow(byID requestedID: CGWindowID, among windows: [AXUIElement] = []) -> AXUIElement? {
        guard requestedID > 0 else { return nil }
        for window in windows where self.ownedWindowID(window) == requestedID {
            return window
        }
        var match: AXUIElement?
        self.visitFallbackWindows { window, windowID in
            guard windowID == requestedID else { return false }
            match = window
            return true
        }
        return match
    }

    /// Inventory may enrich only IDs absent from its primary AXWindows descriptors.
    func additionalWindows(excluding windowIDs: Set<CGWindowID>) -> [AXUIElement] {
        var seen = windowIDs
        var windows: [AXUIElement] = []
        self.visitFallbackWindows { window, windowID in
            if seen.insert(windowID).inserted {
                windows.append(window)
            }
            return false
        }
        return windows
    }

    private func visitFallbackWindows(_ visit: (AXUIElement, CGWindowID) -> Bool) {
        for name in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            guard let timeout = self.messagingTimeout() else { return }
            let value = AXChildWindowMessagingTimeout.perform(on: self.application, timeout: timeout) {
                self.readAttribute($0, name)
            }
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = unsafeDowncast(value, to: AXUIElement.self)
            guard let windowID = self.ownedWindowID(window) else { continue }
            if visit(window, windowID) {
                return
            }
        }
    }

    private func ownedWindowID(_ window: AXUIElement) -> CGWindowID? {
        guard let timeout = self.messagingTimeout() else { return nil }
        return AXChildWindowMessagingTimeout.perform(on: window, timeout: timeout) { element in
            guard self.ownerPID(element) == self.processIdentifier,
                  let windowID = self.windowID(element), windowID > 0
            else { return nil }
            return windowID
        }
    }
}
