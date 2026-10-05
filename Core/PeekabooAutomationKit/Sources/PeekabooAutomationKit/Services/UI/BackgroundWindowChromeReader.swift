import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation

struct BackgroundWindowChromeAdmission: Sendable {
    let window: RetainedFocusElement
    let point: CGPoint
}

/// A bounded, read-only admission for clicking blank standard-window chrome.
/// Geometry alone never authorizes input: the PID-scoped native hit must be the retained window itself.
enum BackgroundWindowChromeReader {
    struct Access {
        var attribute: (AXUIElement, String) -> (error: AXError, value: CFTypeRef?) = { element, name in
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return (error, value)
        }

        var names: (AXUIElement) -> [String]? = { element in
            var names: CFArray?
            guard AXUIElementCopyAttributeNames(element, &names) == .success else { return nil }
            return names as? [String]
        }

        var childCount: (AXUIElement) -> Int? = { element in
            var count: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success
            else { return nil }
            return count
        }

        var children: (AXUIElement, Int) -> [AXUIElement]? = { element, count in
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, count, &values) ==
                .success
            else { return nil }
            return values as? [AXUIElement]
        }

        var windowID: (AXUIElement) -> Int? = { AXWindowIDResolver.windowID(of: $0).map(Int.init) }
        var processID: (AXUIElement) -> pid_t? = { element in
            var pid: pid_t = 0
            return AXUIElementGetPid(element, &pid) == .success ? pid : nil
        }

        var hit: (AXUIElement, CGPoint) -> AXUIElement? = { application, point in
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success
            else { return nil }
            return hit
        }

        var setTimeout: (AXUIElement, Float) -> AXError = { AXUIElementSetMessagingTimeout($0, $1) }
        var windowIsCurrent: (UIAutomationTarget.ExactWindow) -> Bool = BackgroundWindowChromeReader
            .nativeWindowIsCurrent
    }

    static func read(
        target: UIAutomationTarget.ExactWindow,
        retained: BackgroundWindowChromeAdmission? = nil,
        access: Access = Access(),
        now: @escaping () -> ContinuousClock.Instant = { .now }) throws -> BackgroundWindowChromeAdmission
    {
        try Reader(target: target, access: access, now: now, deadline: now().advanced(by: .milliseconds(200)))
            .read(retained: retained)
    }

    static func optionalAttributeIsAbsent(advertised: Bool, error: AXError) -> Bool {
        error == .noValue || (!advertised && error == .attributeUnsupported)
    }

    private struct ControlExclusion: Equatable {
        let control: RetainedFocusElement
        let bounds: CGRect
    }

    private struct TraversalNode: Equatable {
        let reference: RetainedFocusElement
        let exclusion: ControlExclusion?
    }

    private struct Reader {
        let target: UIAutomationTarget.ExactWindow
        let access: Access
        let now: () -> ContinuousClock.Instant
        let deadline: ContinuousClock.Instant
        private let nodeLimit = 256

        func read(retained: BackgroundWindowChromeAdmission?) throws -> BackgroundWindowChromeAdmission {
            try self.validateWindowServer()
            let application = AXUIElementCreateApplication(self.target.identity.ownerProcessIdentifier)
            let windows = try self.elements(kAXWindowsAttribute, of: application)
            guard windows.count <= self.nodeLimit
            else { throw Self.refusal("The native window count exceeds the bound.") }
            var matches: [AXUIElement] = []
            for window in windows {
                if try self.windowID(window) == self.target.identity.windowID {
                    matches.append(window)
                }
            }
            guard matches.count == 1, let window = matches.first,
                  retained.map({ CFEqual($0.window.element, window) }) ?? true
            else { throw Self.refusal("There is no unique matching retained native window.") }
            try self.validateWindow(window)
            let names: [String] = try self.call(window) {
                guard let result = self.access.names(window) else {
                    throw Self.refusal("Window attribute names could not be read.")
                }
                return result
            }

            var references: [AXUIElement] = []
            var controls: [CGRect] = []
            for name in [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] {
                let control = try self.element(name, of: window)
                guard !references.contains(where: { CFEqual($0, control) }),
                      try self.string(kAXRoleAttribute, of: control) == kAXButtonRole
                else { throw Self.refusal("The standard window controls are not distinct native buttons.") }
                references.append(control)
                try controls.append(self.frame(control))
            }
            let controlReferences = references
            // AXFullScreenButton legitimately aliases AXZoomButton on standard AppKit windows.
            for name in [kAXTitleUIElementAttribute, "AXProxy", "AXFullScreenButton", "AXToolbarButton"] {
                let result = try self.attribute(name, of: window)
                if BackgroundWindowChromeReader.optionalAttributeIsAbsent(
                    advertised: names.contains(name), error: result.error)
                {
                    // A root-window hit cannot exclude a drawn title whose geometry AX omitted.
                    if name == kAXTitleUIElementAttribute,
                       try !self.string(kAXTitleAttribute, of: window).isEmpty
                    {
                        throw Self.refusal("A nonempty window title has no native title geometry.")
                    }
                    continue
                }
                guard result.error == .success, let value = result.value,
                      CFGetTypeID(value) == AXUIElementGetTypeID()
                else {
                    throw Self
                        .refusal("Optional window element is unavailable: \(name) (AX error \(result.error.rawValue)).")
                }
                references.append(unsafeDowncast(value, to: AXUIElement.self))
            }
            let sheets = try self.attribute("AXSheets", of: window)
            if !BackgroundWindowChromeReader.optionalAttributeIsAbsent(
                advertised: names.contains("AXSheets"), error: sheets.error)
            {
                guard sheets.error == .success, let elements = sheets.value as? [AXUIElement], elements.isEmpty
                else { throw Self.refusal("The attached-sheet list is unavailable or not empty.") }
            }

            // Optional absence is accepted only alongside a complete, sheet-free hierarchy.
            var queue = ([window] + references).map {
                TraversalNode(reference: RetainedFocusElement(element: $0), exclusion: nil)
            }
            var visited: [TraversalNode] = []
            var occupied: [CGRect] = []
            var index = 0
            while index < queue.count {
                let node = queue[index]
                let element = node.reference.element
                index += 1
                // An alias reached outside an excluded control still needs strict ownership validation.
                guard !visited.contains(node) else { continue }
                guard visited.count < self.nodeLimit
                else { throw Self.refusal("The native hierarchy exceeds its node bound.") }
                visited.append(node)
                let controlIndex = controlReferences.firstIndex { CFEqual($0, element) }
                try self.validateOwner(
                    element, allowsAuxiliaryWindow: node.exclusion != nil && controlIndex == nil)
                let role = try self.string(kAXRoleAttribute, of: element)
                guard role != kAXSheetRole, role != "AXDialog",
                      CFEqual(element, window) || role != kAXWindowRole
                else { throw Self.refusal("The hierarchy contains a sheet, dialog, or another window.") }
                if !CFEqual(element, window) {
                    let frame = try self.frame(element)
                    guard node.exclusion.map({ $0.bounds.contains(frame) }) ?? true,
                          controlIndex.map({ controls[$0] == frame }) ?? true
                    else { throw Self.refusal("A control changed geometry or a descendant escaped its exclusion.") }
                    occupied.append(frame)
                } else if node.exclusion != nil {
                    throw Self.refusal("The window appeared inside an excluded control subtree.")
                }
                let children = try self.children(element)
                guard queue.count + children.count <= self.nodeLimit * 2 else {
                    throw Self.refusal("The native hierarchy exceeds its edge bound.")
                }
                // AppKit can host a fullscreen-button child in a separate native surface. It is only
                // exclusion geometry: every descendant must remain inside the already-excluded control.
                let exclusion = controlIndex.map {
                    ControlExclusion(control: node.reference, bounds: controls[$0])
                } ?? node.exclusion
                queue.append(contentsOf: children.map {
                    TraversalNode(reference: RetainedFocusElement(element: $0), exclusion: exclusion)
                })
            }
            let geometry = BackgroundWindowChromeGeometry(
                bounds: self.target.bounds, windowControls: controls, occupiedFrames: occupied)
            let point: CGPoint
            if let retained {
                guard geometry.admits(retained.point) else {
                    throw Self.refusal("The retained blank chrome point is no longer admitted by current geometry.")
                }
                point = retained.point
            } else {
                guard let candidate = geometry.candidatePoint() else {
                    throw Self.refusal("No blank standard-window chrome point meets the required clearance.")
                }
                point = candidate
            }
            let hit: AXUIElement = try self.call(application) {
                guard let hit = self.access.hit(application, point), CFEqual(hit, window)
                else { throw Self.refusal("The blank chrome hit did not resolve to the retained window.") }
                return hit
            }
            try self.validateOwner(hit)
            try self.validateWindow(window)
            try self.validateWindowServer()
            return BackgroundWindowChromeAdmission(window: RetainedFocusElement(element: window), point: point)
        }

        private func validateWindowServer() throws {
            try Task.checkCancellation()
            guard self.now() < self.deadline else { throw Self.refusal("Chrome observation deadline exceeded.") }
            guard self.access.windowIsCurrent(self.target) else {
                throw Self.refusal("WindowServer identity, bounds, or visibility could not be confirmed.")
            }
            guard self.now() < self.deadline else { throw Self.refusal("Chrome observation deadline exceeded.") }
            try Task.checkCancellation()
        }

        private func validateWindow(_ window: AXUIElement) throws {
            try self.validateOwner(window)
            guard try self.string(kAXRoleAttribute, of: window) == kAXWindowRole,
                  try self.string(kAXSubroleAttribute, of: window) == kAXStandardWindowSubrole,
                  try self.frame(window) == self.target.bounds
            else { throw Self.refusal("The standard-window role, subrole, or bounds no longer matches.") }
            for name in [kAXMinimizedAttribute, "AXFullScreen", kAXModalAttribute] {
                let result = try self.attribute(name, of: window)
                guard result.error == .success, AXDescriptorReader.boolValue(result.value) == false else {
                    throw Self
                        .refusal("The expected non-minimized, non-fullscreen, non-modal state is unavailable: \(name).")
                }
            }
        }

        private func validateOwner(_ element: AXUIElement, allowsAuxiliaryWindow: Bool = false) throws {
            let pid = try self.call(element) {
                guard let pid = self.access.processID(element) else {
                    throw Self.refusal("The native element process ID could not be read.")
                }
                return pid
            }
            let windowID = try self.windowID(element)
            guard pid == self.target.identity.ownerProcessIdentifier, windowID > 0,
                  allowsAuxiliaryWindow || windowID == self.target.identity.windowID
            else { throw Self.refusal("The native element process or window owner does not match.") }
        }

        private func windowID(_ element: AXUIElement) throws -> Int {
            try self.call(element) {
                guard let result = self.access.windowID(element) else {
                    throw Self.refusal("The native window ID could not be read.")
                }
                return result
            }
        }

        private func children(_ element: AXUIElement) throws -> [AXUIElement] {
            let count = try self.childCount(element)
            guard (0...self.nodeLimit).contains(count)
            else { throw Self.refusal("The native child count is outside its bound.") }
            if count == 0 {
                return []
            }
            let children: [AXUIElement] = try self.call(element) {
                guard let children = self.access.children(element, count), children.count == count
                else { throw Self.refusal("The complete native child array could not be read.") }
                return children
            }
            guard try self.childCount(element) == count else { throw Self.refusal("The native child count changed.") }
            return children
        }

        private func childCount(_ element: AXUIElement) throws -> Int {
            try self.call(element) {
                guard let count = self.access.childCount(element) else {
                    throw Self.refusal("The native child count could not be read.")
                }
                return count
            }
        }

        private func attribute(_ name: String, of element: AXUIElement) throws -> (error: AXError, value: CFTypeRef?) {
            try self.call(element) { self.access.attribute(element, name) }
        }

        private func element(_ name: String, of element: AXUIElement) throws -> AXUIElement {
            let result = try self.attribute(name, of: element)
            guard result.error == .success, let value = result.value,
                  CFGetTypeID(value) == AXUIElementGetTypeID()
            else {
                throw Self
                    .refusal("Expected element attribute is unavailable: \(name) (AX error \(result.error.rawValue)).")
            }
            return unsafeDowncast(value, to: AXUIElement.self)
        }

        private func elements(_ name: String, of element: AXUIElement) throws -> [AXUIElement] {
            let result = try self.attribute(name, of: element)
            guard result.error == .success, let values = result.value as? [AXUIElement] else {
                throw Self
                    .refusal("Expected element array is unavailable: \(name) (AX error \(result.error.rawValue)).")
            }
            return values
        }

        private func string(_ name: String, of element: AXUIElement) throws -> String {
            let result = try self.attribute(name, of: element)
            guard result.error == .success, let value = result.value as? String else {
                throw Self
                    .refusal("Expected string attribute is unavailable: \(name) (AX error \(result.error.rawValue)).")
            }
            return value
        }

        private func frame(_ element: AXUIElement) throws -> CGRect {
            let position = try self.attribute(kAXPositionAttribute, of: element)
            let size = try self.attribute(kAXSizeAttribute, of: element)
            guard position.error == .success, size.error == .success,
                  let pointValue = position.value, CFGetTypeID(pointValue) == AXValueGetTypeID(),
                  let sizeValue = size.value, CFGetTypeID(sizeValue) == AXValueGetTypeID()
            else {
                throw Self.refusal("Native frame is unavailable (AX position error \(position.error.rawValue), " +
                    "size error \(size.error.rawValue)).")
            }
            let pointAX = unsafeDowncast(pointValue, to: AXValue.self)
            let sizeAX = unsafeDowncast(sizeValue, to: AXValue.self)
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard AXValueGetType(pointAX) == .cgPoint, AXValueGetType(sizeAX) == .cgSize,
                  AXValueGetValue(pointAX, .cgPoint, &point), AXValueGetValue(sizeAX, .cgSize, &dimensions)
            else { throw Self.refusal("The native frame contains malformed position or size values.") }
            return CGRect(origin: point, size: dimensions)
        }

        private func call<Value>(_ element: AXUIElement, _ operation: () throws -> Value) throws -> Value {
            try Task.checkCancellation()
            let remaining = self.now().duration(to: self.deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { throw Self.refusal("Chrome observation deadline exceeded.") }
            guard self.access.setTimeout(element, Float(min(seconds, 0.05))) == .success else {
                throw Self.refusal("The bounded Accessibility messaging timeout could not be established.")
            }
            defer { _ = self.access.setTimeout(element, 0) }
            let result = try operation()
            guard self.now() < self.deadline else { throw Self.refusal("Chrome observation deadline exceeded.") }
            try Task.checkCancellation()
            return result
        }

        private static func refusal(_ causeDescription: String) -> DesktopActionFailure {
            .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Cannot prove a blank, unchanged standard-window chrome point for background keyboard preparation.",
                hint: "Observe the exact window again; no foreground fallback or guessed click is permitted.",
                causeDescription: causeDescription)
        }
    }

    private static func nativeWindowIsCurrent(_ target: UIAutomationTarget.ExactWindow) -> Bool {
        guard let windowID = CGWindowID(exactly: target.identity.windowID),
              SystemIdentityResolver.validateWindowMutationIdentity(target.identity),
              let window = SystemIdentityResolver.windowIdentity(windowID),
              window.windowID == windowID, window.ownerProcessIdentifier == target.identity.ownerProcessIdentifier,
              window.bounds == target.bounds, window.layer == Int(CGWindowLevelForKey(.normalWindow)),
              window.isOnScreen, window.alpha > 0,
              SystemIdentityResolver.processStartIdentity(window.ownerProcessIdentifier) ==
              target.identity.ownerProcessStartIdentity
        else { return false }
        return true
    }
}
