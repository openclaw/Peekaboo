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
}
