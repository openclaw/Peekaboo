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
    let selectedTextRange: TextSelectionRange?

    init(
        identity: FocusedElementIdentity,
        focused: Bool? = nil,
        value: ElementValueReadback? = nil,
        legacyPresentation: String? = nil,
        selected: Bool? = nil,
        selectedTextRange: TextSelectionRange? = nil)
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
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let components = timeout.components
        let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
        // Admission retains the occupied lane until a noncooperative native read actually returns.
        return try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: target.processIdentifier,
            targetProcessStartIdentity: target.processStartIdentity,
            seconds: seconds,
            maximumPendingOperationCount: 1)
        {
            self.readSynchronously(element: element, target: target, attribute: attribute, deadline: deadline)
        }
    }

    /// The caller must already own the process AX lane; never nest the async reader inside it.
    static func readSynchronously(
        element: RetainedFocusElement,
        target: AXMutationObservationTarget,
        attribute: AXMutationObservationAttribute,
        deadline: ContinuousClock.Instant,
        requiresFocusedReceiver: Bool = false) -> AXMutationObservationSnapshot?
    {
        self.readSynchronously(
            request: (target: target, attribute: attribute, deadline: deadline),
            requiresFocusedReceiver: requiresFocusedReceiver,
            processStartIdentity: { SystemIdentityResolver.processStartIdentity(target.processIdentifier) },
            readSnapshot: {
                DetachedExactWindowFocusReader.read(
                    element: element.element,
                    processIdentifier: target.processIdentifier,
                    deadline: $0)
            },
            readAttribute: { name, deadline in
                DetachedExactWindowFocusReader.attribute(name, of: element.element, deadline: deadline)
            })
    }

    static func readSynchronously(
        request: (
            target: AXMutationObservationTarget,
            attribute: AXMutationObservationAttribute,
            deadline: ContinuousClock.Instant),
        requiresFocusedReceiver: Bool = false,
        now: () -> ContinuousClock.Instant = { .now },
        processStartIdentity: () -> UInt64?,
        readSnapshot: (ContinuousClock.Instant) -> ExactWindowFocusSnapshot?,
        readAttribute: (String, ContinuousClock.Instant) -> CFTypeRef?) -> AXMutationObservationSnapshot?
    {
        let (target, attribute, deadline) = request
        guard now() < deadline, processStartIdentity() == target.processStartIdentity, now() < deadline,
              let before = readSnapshot(deadline), now() < deadline,
              let beforeIdentity = self.identity(before),
              target.expectedIdentity.map({
                  FocusedElementReceiptResolver.matches(beforeIdentity, expected: $0, phase: .continuation)
              }) ?? true
        else { return nil }
        if requiresFocusedReceiver {
            guard DetachedExactWindowFocusReader.allowsValueRead(before), before.nativeElement != nil, now() < deadline,
                  self.boolean(readAttribute(kAXFocusedAttribute, deadline)) == true, now() < deadline
            else { return nil }
        }

        var focused: Bool?
        var value: ElementValueReadback?
        var legacyPresentation: String?
        var selected: Bool?
        var selectedTextRange: TextSelectionRange?
        switch attribute {
        case .identity:
            break
        case .focused:
            focused = self.boolean(readAttribute(kAXFocusedAttribute, deadline))
        case .selected:
            selected = self.boolean(readAttribute(kAXSelectedAttribute, deadline))
        case .value:
            if DetachedExactWindowFocusReader.allowsValueRead(before) {
                let nativeValue = readAttribute(kAXValueAttribute, deadline)
                if let readback = ElementValueReadback(nativeValue: nativeValue), readback.isFinite {
                    value = readback
                    legacyPresentation = NativeElementValuePresentation.describe(nativeValue)
                }
            }
        case .selectedTextRange:
            if DetachedExactWindowFocusReader.allowsValueRead(before) {
                selectedTextRange = TextSelectionRange(nativeValue: readAttribute(
                    kAXSelectedTextRangeAttribute,
                    deadline))
            }
        }

        if requiresFocusedReceiver, attribute == .selectedTextRange, selectedTextRange == nil {
            return nil
        }

        guard now() < deadline, let after = readSnapshot(deadline), now() < deadline,
              let afterIdentity = self.identity(after),
              FocusedElementReceiptResolver.matches(
                  afterIdentity,
                  expected: target.expectedIdentity ?? beforeIdentity,
                  phase: .continuation)
        else { return nil }
        if requiresFocusedReceiver {
            guard after.nativeElement == before.nativeElement,
                  self.boolean(readAttribute(kAXFocusedAttribute, deadline)) == true, now() < deadline
            else { return nil }
            focused = true
        }
        guard processStartIdentity() == target.processStartIdentity, now() < deadline else { return nil }
        let readable = DetachedExactWindowFocusReader.allowsValueRead(after)
        return AXMutationObservationSnapshot(
            identity: afterIdentity,
            focused: focused,
            value: readable ? value : nil,
            legacyPresentation: readable ? legacyPresentation : nil,
            selected: selected,
            selectedTextRange: readable ? selectedTextRange : nil)
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

    private static func boolean(_ value: CFTypeRef?) -> Bool? {
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }
}
