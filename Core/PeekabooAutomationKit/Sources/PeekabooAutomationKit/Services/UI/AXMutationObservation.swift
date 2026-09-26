import ApplicationServices
import Foundation
import PeekabooFoundation

enum AXMutationObservationAttribute: Sendable {
    case identity
    case focused
    case value
    case selected
    case selectedTextRange
}

struct AXMutationTextRange: Equatable, Sendable {
    let location: Int
    let length: Int
}

struct AXMutationObservationTarget: Sendable {
    let processIdentifier: pid_t
    let processStartIdentity: UInt64
    let expectedIdentity: FocusedElementIdentity?

    init(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        expectedIdentity: FocusedElementIdentity? = nil)
    {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.expectedIdentity = expectedIdentity
    }
}

struct AXMutationObservationSnapshot: Sendable {
    let identity: FocusedElementIdentity
    let focused: Bool?
    let value: ElementValueReadback?
    let legacyPresentation: String?
    let selected: Bool?
    let selectedTextRange: AXMutationTextRange?

    init(
        identity: FocusedElementIdentity,
        focused: Bool? = nil,
        value: ElementValueReadback? = nil,
        legacyPresentation: String? = nil,
        selected: Bool? = nil,
        selectedTextRange: AXMutationTextRange? = nil)
    {
        self.identity = identity
        self.focused = focused
        self.value = value
        self.legacyPresentation = legacyPresentation
        self.selected = selected
        self.selectedTextRange = selectedTextRange
    }
}

typealias AXMutationNativeReader = @Sendable (
    RetainedFocusElement,
    AXMutationObservationTarget,
    AXMutationObservationAttribute,
    Duration) async throws -> AXMutationObservationSnapshot?

enum DetachedAXMutationReader {
    static func read(
        element: RetainedFocusElement,
        target: AXMutationObservationTarget,
        attribute: AXMutationObservationAttribute,
        timeout: Duration) async throws -> AXMutationObservationSnapshot?
    {
        guard timeout > .zero else { return nil }
        let processIdentifier = target.processIdentifier
        let processStartIdentity = target.processStartIdentity
        let expectedIdentity = target.expectedIdentity
        let components = timeout.components
        let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
        // The existing lane retains occupied capacity after a timeout until the native RPC returns.
        // It bounds caller latency without joining blocked AX work or accumulating new readers.
        return try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: processIdentifier,
            targetProcessStartIdentity: processStartIdentity,
            seconds: seconds,
            maximumPendingOperationCount: 1)
        { () -> AXMutationObservationSnapshot? in
            guard SystemIdentityResolver.processStartIdentity(processIdentifier) == processStartIdentity,
                  let before = DetachedExactWindowFocusReader.read(
                      element: element.element, processIdentifier: processIdentifier),
                  let beforeIdentity = self.identity(before),
                  expectedIdentity.map({
                      FocusedElementReceiptResolver.matches(beforeIdentity, expected: $0, phase: .continuation)
                  }) ?? true
            else { return nil }

            AXUIElementSetMessagingTimeout(element.element, 0.05)
            defer { AXUIElementSetMessagingTimeout(element.element, 0) }
            var focused: Bool?
            var value: ElementValueReadback?
            var legacyPresentation: String?
            var selected: Bool?
            var selectedTextRange: AXMutationTextRange?
            switch attribute {
            case .identity:
                break
            case .focused:
                focused = self.boolAttribute(kAXFocusedAttribute, element: element.element)
            case .selected:
                selected = self.boolAttribute(kAXSelectedAttribute, element: element.element)
            case .value:
                if !self.isSecure(before) {
                    let nativeValue = self.attribute(kAXValueAttribute, element: element.element)
                    if let readback = ElementValueReadback(nativeValue: nativeValue), readback.isFinite {
                        value = readback
                        legacyPresentation = NativeElementValuePresentation.describe(nativeValue)
                    }
                }
            case .selectedTextRange:
                if !self.isSecure(before) {
                    selectedTextRange = self.textRange(element.element)
                }
            }

            guard let after = DetachedExactWindowFocusReader.read(
                element: element.element, processIdentifier: processIdentifier),
                let afterIdentity = self.identity(after),
                FocusedElementReceiptResolver.matches(
                    afterIdentity, expected: expectedIdentity ?? beforeIdentity, phase: .continuation),
                SystemIdentityResolver.processStartIdentity(processIdentifier) == processStartIdentity
            else { return nil }
            let secure = self.isSecure(after)
            return AXMutationObservationSnapshot(
                identity: afterIdentity,
                focused: focused,
                value: secure ? nil : value,
                legacyPresentation: secure ? nil : legacyPresentation,
                selected: selected,
                selectedTextRange: secure ? nil : selectedTextRange)
        }
    }

    private static func identity(_ snapshot: ExactWindowFocusSnapshot) -> FocusedElementIdentity? {
        guard let windowID = snapshot.windowID, windowID > 0,
              let role = snapshot.role,
              !snapshot.frame.isEmpty,
              snapshot.frame.origin.x.isFinite, snapshot.frame.origin.y.isFinite,
              snapshot.frame.width.isFinite, snapshot.frame.height.isFinite
        else { return nil }
        return FocusedElementIdentity(
            processIdentifier: snapshot.processIdentifier,
            windowID: windowID,
            role: role,
            title: snapshot.title,
            identifier: snapshot.identifier,
            frame: snapshot.frame)
    }

    private static func isSecure(_ snapshot: ExactWindowFocusSnapshot) -> Bool {
        snapshot.role == "AXSecureTextField" || snapshot.subrole == "AXSecureTextField"
    }

    private static func attribute(_ name: String, element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func boolAttribute(_ name: String, element: AXUIElement) -> Bool? {
        guard let value = self.attribute(name, element: element),
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return value as? Bool
    }

    private static func textRange(_ element: AXUIElement) -> AXMutationTextRange? {
        guard let value = self.attribute(kAXSelectedTextRangeAttribute, element: element),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeDowncast(value, to: AXValue.self), .cfRange, &range),
              range.location >= 0, range.length >= 0
        else { return nil }
        return AXMutationTextRange(location: range.location, length: range.length)
    }
}
