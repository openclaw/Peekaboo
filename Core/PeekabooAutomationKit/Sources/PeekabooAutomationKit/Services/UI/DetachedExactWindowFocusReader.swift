import ApplicationServices
import CoreGraphics
import Foundation

/// AX references use the thread-safe CF API; this immutable handle crosses only the focus-reader boundary.
struct RetainedFocusElement: @unchecked Sendable, Equatable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
}

struct ExactWindowFocusSnapshot: Sendable, Equatable {
    let processIdentifier: pid_t
    let windowID: Int?
    let frame: CGRect
    let role: String?
    let subrole: String?
    let subroleIsReadable: Bool
    let title: String?
    let identifier: String?
    let value: String?
    let nativeElement: RetainedFocusElement?

    init(
        processIdentifier: pid_t,
        windowID: Int?,
        frame: CGRect,
        role: String? = nil,
        subrole: String? = nil,
        subroleIsReadable: Bool = true,
        title: String? = nil,
        identifier: String? = nil,
        value: String? = nil,
        nativeElement: RetainedFocusElement? = nil)
    {
        self.processIdentifier = processIdentifier
        self.windowID = windowID
        self.frame = frame
        self.role = role
        self.subrole = subrole
        self.subroleIsReadable = subroleIsReadable
        self.title = title
        self.identifier = identifier
        self.value = value
        self.nativeElement = nativeElement
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

    static func focusedElementReference(of application: AXUIElement) -> AXUIElement? {
        self.elementAttribute(kAXFocusedUIElementAttribute, of: application)
    }

    static func read(processIdentifier: pid_t) -> ExactWindowFocusSnapshot? {
        guard processIdentifier > 0 else { return nil }
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, self.messagingTimeout)
        guard let focusedElement = self.focusedElementReference(of: application) else {
            return nil
        }
        return self.read(element: focusedElement, processIdentifier: processIdentifier)
    }

    static func read(
        element focusedElement: AXUIElement,
        processIdentifier: pid_t,
        deadline: ContinuousClock.Instant? = nil) -> ExactWindowFocusSnapshot?
    {
        guard deadline.map({ ContinuousClock.now < $0 }) ?? true else { return nil }
        if deadline == nil {
            AXUIElementSetMessagingTimeout(focusedElement, self.messagingTimeout)
        }
        defer { AXUIElementSetMessagingTimeout(focusedElement, 0) }
        var focusedProcessIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &focusedProcessIdentifier) == .success,
              focusedProcessIdentifier == processIdentifier
        else {
            return nil
        }

        guard let metadata = self.readMetadata(
            copyAttributes: { names in
                self.readBeforeDeadline(
                    deadline,
                    applyTimeout: { AXUIElementSetMessagingTimeout(focusedElement, $0) == .success },
                    read: {
                        var values: CFArray?
                        let error = AXUIElementCopyMultipleAttributeValues(
                            focusedElement, names as CFArray, [], &values)
                        return (error, values as? [Any])
                    })
            },
            copyAttribute: { self.attributeRead($0, of: focusedElement, deadline: deadline) })
        else { return nil }
        let snapshot = self.snapshot(
            element: focusedElement,
            processIdentifier: focusedProcessIdentifier,
            metadata: metadata,
            resolveWindowID: { window in
                if deadline == nil {
                    AXUIElementSetMessagingTimeout(window, self.messagingTimeout)
                }
                defer {
                    if deadline != nil {
                        AXUIElementSetMessagingTimeout(window, 0)
                    }
                }
                return self.readBeforeDeadline(
                    deadline,
                    applyTimeout: { AXUIElementSetMessagingTimeout(window, $0) == .success },
                    read: { AXWindowIDResolver.windowID(of: window).map(Int.init) })
            })
        guard deadline.map({ ContinuousClock.now < $0 }) ?? true else { return nil }
        return snapshot
    }

    static func snapshot(
        element: AXUIElement,
        processIdentifier: pid_t,
        metadata: [String: AXDescriptorReader.SingleAttributeRead],
        resolveWindowID: (AXUIElement) -> Int?) -> ExactWindowFocusSnapshot
    {
        let value: (String) -> CFTypeRef? = { name in
            guard let read = metadata[name], read.error == .success, let value = read.value else { return nil }
            return value as CFTypeRef
        }
        let frame: CGRect = if let position = self.pointValue(value(kAXPositionAttribute)),
                               let size = self.sizeValue(value(kAXSizeAttribute))
        {
            CGRect(origin: position, size: size)
        } else {
            .zero
        }
        let windowID = value(kAXWindowAttribute).flatMap { window -> Int? in
            guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
            return resolveWindowID(unsafeDowncast(window, to: AXUIElement.self))
        }
        let role = value(kAXRoleAttribute) as? String
        let subrole = self.subroleObservation(metadata[kAXSubroleAttribute])
        let title = value(kAXTitleAttribute) as? String
        let identifier = value(kAXIdentifierAttribute) as? String
        return ExactWindowFocusSnapshot(
            processIdentifier: processIdentifier,
            windowID: windowID,
            frame: frame,
            role: role,
            subrole: subrole.value,
            subroleIsReadable: subrole.isReadable,
            title: title,
            identifier: identifier,
            nativeElement: RetainedFocusElement(element: element))
    }

    static func readMetadata(
        copyAttributes: ([String]) -> (error: AXError, values: [Any]?)?,
        copyAttribute: (String) -> AXDescriptorReader.SingleAttributeRead?)
        -> [String: AXDescriptorReader.SingleAttributeRead]?
    {
        // Never include AXValue: secure-subrole admission happens after these identity reads.
        let names = [
            kAXPositionAttribute,
            kAXSizeAttribute,
            kAXWindowAttribute,
            kAXRoleAttribute,
            kAXSubroleAttribute,
            kAXTitleAttribute,
            kAXIdentifierAttribute,
        ]
        guard let batch = copyAttributes(names) else { return nil }
        // Providers can reject a combined request while still serving the same individual attributes.
        if batch.error == .failure || AXDescriptorReader.shouldFallbackToSingleAttributeReads(
            error: batch.error, hasExpectedValueShape: batch.values?.count == names.count)
        {
            var metadata: [String: AXDescriptorReader.SingleAttributeRead] = [:]
            for name in names {
                guard let read = copyAttribute(name) else { return nil }
                metadata[name] = read
            }
            return metadata
        }
        guard batch.error == .success, let values = batch.values else { return nil }
        return Dictionary(uniqueKeysWithValues: zip(names, values).map { name, value in
            let error = AXAttributeReadCompletenessPolicy.embeddedError(in: value) ?? .success
            return (name, AXDescriptorReader.SingleAttributeRead(
                error: error, value: error == .success ? value : nil))
        })
    }

    static func read(expected: FocusedElementIdentity) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError> {
        self.read(expected: expected, phase: .initial)
    }

    static func readContinuation(
        expected: FocusedElementIdentity) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
    {
        self.read(expected: expected, phase: .continuation)
    }

    static func readValue(
        expected: FocusedElementIdentity,
        retainedElement: RetainedFocusElement? = nil) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
    {
        let initialSnapshot: ExactWindowFocusSnapshot
        if let retainedElement {
            guard let snapshot = self.read(
                element: retainedElement.element, processIdentifier: expected.processIdentifier)
            else { return .failure(.processMismatch) }
            initialSnapshot = snapshot
        } else {
            switch self.read(expected: expected) {
            case let .success(snapshot): initialSnapshot = snapshot
            case let .failure(error): return .failure(error)
            }
        }
        guard let receiver = initialSnapshot.nativeElement else { return .failure(.focusNotConfirmed) }
        let element = receiver.element
        return self.readValue(
            observation: (
                expected: expected,
                initialSnapshot: initialSnapshot,
                phase: retainedElement == nil ? .initial : .continuation),
            readSnapshot: { self.read(element: element, processIdentifier: expected.processIdentifier) },
            readFocusedState: {
                AXUIElementSetMessagingTimeout(element, self.messagingTimeout)
                defer { AXUIElementSetMessagingTimeout(element, 0) }
                return self.boolAttribute(kAXFocusedAttribute, of: element)
            },
            readValue: {
                AXUIElementSetMessagingTimeout(element, self.messagingTimeout)
                defer { AXUIElementSetMessagingTimeout(element, 0) }
                return self.stringAttribute(kAXValueAttribute as String, of: element)
            })
    }

    static func readValue(
        observation: (
            expected: FocusedElementIdentity,
            initialSnapshot: ExactWindowFocusSnapshot,
            phase: KeyboardFocusValidationPhase),
        readSnapshot: () -> ExactWindowFocusSnapshot?,
        readFocusedState: () -> Bool?,
        readValue: () -> String?) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
    {
        let (expected, initialSnapshot, phase) = observation
        do {
            try self.validateValueSnapshot(initialSnapshot, expected: expected, phase: phase)
            guard let focused = readFocusedState() else { return .failure(.focusedAttributeUnreadable) }
            guard focused else { return .failure(.focusNotConfirmed) }
            let value = self.allowsValueRead(initialSnapshot)
                ? readValue() : nil
            // AXValue is a separate RPC; never attach its result to pre-read receiver authority.
            guard let current = readSnapshot() else { return .failure(.processMismatch) }
            try self.validateValueSnapshot(current, expected: expected, phase: phase)
            guard current.nativeElement == initialSnapshot.nativeElement else { return .failure(.focusNotConfirmed) }
            guard let focused = readFocusedState() else { return .failure(.focusedAttributeUnreadable) }
            guard focused else { return .failure(.focusNotConfirmed) }
            return .success(ExactWindowFocusSnapshot(
                processIdentifier: current.processIdentifier,
                windowID: current.windowID,
                frame: current.frame,
                role: current.role,
                subrole: current.subrole,
                subroleIsReadable: current.subroleIsReadable,
                title: current.title,
                identifier: current.identifier,
                value: self.allowsValueRead(current) ? value : nil,
                nativeElement: current.nativeElement))
        } catch let error as FocusedElementReceiptError {
            return .failure(error)
        } catch {
            return .failure(.focusNotConfirmed)
        }
    }

    private static func validateValueSnapshot(
        _ snapshot: ExactWindowFocusSnapshot,
        expected: FocusedElementIdentity,
        phase: KeyboardFocusValidationPhase) throws
    {
        guard let windowID = snapshot.windowID else { throw FocusedElementReceiptError.missingWindowIdentifier }
        guard let role = snapshot.role else { throw FocusedElementReceiptError.roleMismatch }
        guard !snapshot.frame.isEmpty else { throw FocusedElementReceiptError.missingElementFrame }
        guard snapshot.nativeElement != nil else { throw FocusedElementReceiptError.focusNotConfirmed }
        let actual = FocusedElementIdentity(
            processIdentifier: snapshot.processIdentifier,
            windowID: windowID,
            role: role,
            title: snapshot.title,
            identifier: snapshot.identifier,
            frame: snapshot.frame)
        switch phase {
        case .initial: try FocusedElementReceiptResolver.validate(actual, matches: expected)
        case .continuation: try FocusedElementReceiptResolver.validateContinuation(actual, matches: expected)
        }
    }

    private static func read(
        expected: FocusedElementIdentity,
        phase: KeyboardFocusValidationPhase) -> Result<ExactWindowFocusSnapshot, FocusedElementReceiptError>
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
        var exactMatchFrames: [CGRect] = []
        while let element = queue.first, visited.count < 4096 {
            queue.removeFirst()
            guard !visited.contains(where: { CFEqual($0, element) }) else { continue }
            visited.append(element)
            AXUIElementSetMessagingTimeout(element, self.messagingTimeout)

            if let candidate = self.candidateIdentity(
                observedRole: self.stringAttribute(kAXRoleAttribute as String, of: element),
                expected: expected,
                phase: phase,
                frame: self.frame(of: element),
                metadata: (
                    title: self.stringAttribute(kAXTitleAttribute as String, of: element),
                    identifier: self.stringAttribute(kAXIdentifierAttribute as String, of: element)))
            {
                roleAndFrameMatches.append(element)
                if FocusedElementReceiptResolver.matches(candidate, expected: expected, phase: phase) {
                    exactMatches.append(element)
                    exactMatchFrames.append(candidate.frame)
                }
            }
            queue.append(contentsOf: self.elementArrayAttribute(kAXChildrenAttribute, of: element))
        }

        // A window whose AX tree exceeds the visit cap can still yield a unique focused match in the
        // scanned prefix; receiver selection below disambiguates matches among what was seen. Do not
        // fail a large tree outright, or exact-window type/press would refuse in deep-hierarchy apps.
        guard !roleAndFrameMatches.isEmpty else { return .failure(.frameMismatch) }
        guard !exactMatches.isEmpty else {
            return .failure(expected.identifier?.isEmpty == false ? .identifierMismatch : .titleMismatch)
        }
        let element: AXUIElement
        if phase == .continuation, exactMatches.count > 1 {
            let candidateFocused = exactMatches.map { self.boolAttribute(kAXFocusedAttribute, of: $0) == true }
            guard let index = self.selectContinuationReceiver(
                candidateFrames: exactMatchFrames,
                candidateFocused: candidateFocused,
                expectedFrame: expected.frame)
            else {
                return .failure(.multipleFocusedElements)
            }
            element = exactMatches[index]
        } else {
            guard exactMatches.count == 1, let match = exactMatches.first else {
                return .failure(.multipleFocusedElements)
            }
            element = match
        }
        guard let focused = self.boolAttribute(kAXFocusedAttribute, of: element) else {
            return .failure(.focusedAttributeUnreadable)
        }
        guard focused else { return .failure(.focusNotConfirmed) }

        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier == expected.processIdentifier
        else { return .failure(.processMismatch) }
        let owningWindow = CFEqual(element, window) ? window : self.elementAttribute(kAXWindowAttribute, of: element)
        guard let owningWindow,
              AXWindowIDResolver.windowID(of: owningWindow).map(Int.init) == expected.windowID
        else { return .failure(.windowMismatch) }
        guard let frame = self.frame(of: element), !frame.isEmpty else {
            return .failure(.missingElementFrame)
        }

        let subrole = self.subroleObservation(self.attributeRead(kAXSubroleAttribute, of: element))
        return .success(ExactWindowFocusSnapshot(
            processIdentifier: expected.processIdentifier,
            windowID: expected.windowID,
            frame: frame,
            role: expected.role,
            subrole: subrole.value,
            subroleIsReadable: subrole.isReadable,
            title: self.stringAttribute(kAXTitleAttribute as String, of: element),
            identifier: self.stringAttribute(kAXIdentifierAttribute as String, of: element),
            nativeElement: RetainedFocusElement(element: element)))
    }

    static func candidateIdentity(
        observedRole: String?,
        expected: FocusedElementIdentity,
        phase: KeyboardFocusValidationPhase,
        frame: @autoclosure () -> CGRect?,
        metadata: @autoclosure () -> (title: String?, identifier: String?)) -> FocusedElementIdentity?
    {
        // Most scanned nodes cannot receive this input; avoid their two frame AX calls.
        guard observedRole == expected.role else { return nil }
        let observedFrame = frame()
        guard phase == .continuation || observedFrame == expected.frame else { return nil }
        let metadata = metadata()
        return FocusedElementIdentity(
            processIdentifier: expected.processIdentifier,
            windowID: expected.windowID,
            role: expected.role,
            title: metadata.title,
            identifier: metadata.identifier,
            frame: observedFrame ?? .zero)
    }

    static func selectContinuationReceiver(
        candidateFrames: [CGRect],
        candidateFocused: [Bool],
        expectedFrame: CGRect) -> Int?
    {
        guard candidateFrames.count == candidateFocused.count, !candidateFrames.isEmpty else { return nil }
        if candidateFrames.count == 1 {
            return 0
        }

        // Preserve the captured receiver's position before allowing focus to disambiguate reflow.
        let frameMatches = candidateFrames.indices.filter { candidateFrames[$0] == expectedFrame }
        if frameMatches.count == 1 {
            return frameMatches.first
        }

        let focusedMatches = candidateFocused.indices.filter { candidateFocused[$0] }
        return focusedMatches.count == 1 ? focusedMatches.first : nil
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

    private static func elementAttribute(
        _ name: String,
        of element: AXUIElement,
        deadline: ContinuousClock.Instant? = nil) -> AXUIElement?
    {
        guard let value = self.attribute(name, of: element, deadline: deadline),
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

    private static func stringAttribute(
        _ name: String,
        of element: AXUIElement,
        deadline: ContinuousClock.Instant? = nil) -> String?
    {
        self.attribute(name, of: element, deadline: deadline) as? String
    }

    static func attribute(
        _ name: String,
        of element: AXUIElement,
        deadline: ContinuousClock.Instant? = nil) -> CFTypeRef?
    {
        guard let read = self.attributeRead(name, of: element, deadline: deadline), read.error == .success,
              let value = read.value else { return nil }
        return value as CFTypeRef
    }

    private static func attributeRead(
        _ name: String,
        of element: AXUIElement,
        deadline: ContinuousClock.Instant? = nil) -> AXDescriptorReader.SingleAttributeRead?
    {
        defer {
            if deadline != nil {
                AXUIElementSetMessagingTimeout(element, 0)
            }
        }
        return self.readBeforeDeadline(
            deadline,
            applyTimeout: { AXUIElementSetMessagingTimeout(element, $0) == .success },
            read: {
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                return AXDescriptorReader.SingleAttributeRead(error: error, value: value)
            })
    }

    static func subroleObservation(_ read: AXDescriptorReader
        .SingleAttributeRead?) -> (value: String?, isReadable: Bool)
    {
        guard let read else { return (nil, false) }
        switch read.error {
        case .noValue, .attributeUnsupported:
            return (nil, true)
        case .success:
            guard let value = read.value as? String else { return (nil, false) }
            return (value, true)
        default:
            return (nil, false)
        }
    }

    static func readBeforeDeadline<Value>(
        _ deadline: ContinuousClock.Instant?,
        now: () -> ContinuousClock.Instant = { .now },
        applyTimeout: (Float) -> Bool,
        read: () -> Value?) -> Value?
    {
        guard let deadline else { return read() }
        let remaining = now().duration(to: deadline).components
        let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
        guard seconds > 0,
              applyTimeout(min(self.messagingTimeout, Float(seconds))), now() < deadline
        else { return nil }
        let value = read()
        return now() < deadline ? value : nil
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

    static func allowsValueRead(_ snapshot: ExactWindowFocusSnapshot) -> Bool {
        snapshot.subroleIsReadable && self.allowsValueRead(role: snapshot.role, subrole: snapshot.subrole)
    }

    private static func frame(of element: AXUIElement, deadline: ContinuousClock.Instant? = nil) -> CGRect? {
        guard let position = self.pointValue(self.attribute(kAXPositionAttribute, of: element, deadline: deadline)),
              let size = self.sizeValue(self.attribute(kAXSizeAttribute, of: element, deadline: deadline))
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
