import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation

@_spi(Testing) public struct DetachedAXWindowIdentityCandidate: Sendable, Equatable {
    public let windowID: Int?
    public let bounds: CGRect?

    public init(windowID: Int?, bounds: CGRect?) {
        self.windowID = windowID
        self.bounds = bounds
    }
}

@_spi(Testing) public enum DetachedAXExactWindowSelectionPolicy {
    public static func uniqueExactIndex(
        windowID: Int,
        candidates: [DetachedAXWindowIdentityCandidate]) -> Int?
    {
        let matches = candidates.indices.filter { candidates[$0].windowID == windowID }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct DetachedAXObservationRequest: Sendable {
    let processIdentifier: Int32
    let expectedProcessStartIdentity: UInt64
    let windowID: Int?
    let windowTitle: String?
    let expectedWindowBounds: CGRect?
    let windowMutationIdentity: WindowMutationIdentity?
    let includeMenuBarElements: Bool
    let appIsActive: Bool
    let traversalBudget: AXTraversalBudget
    let timing: DetachedAXObservationTiming
}

struct DetachedAXObservationTiming: Sendable, Equatable {
    // AX calls are not cooperatively cancellable. Stop traversal early enough for one bounded
    // native call plus result publication before the caller's hard timeout abandons the lane.
    private static let maximumCompletionGrace: TimeInterval = 0.25
    private static let minimumCompletionGrace: TimeInterval = 0.01

    let cooperativeDeadlineSeconds: TimeInterval
    let hardTimeoutSeconds: TimeInterval

    init(hardTimeoutSeconds: TimeInterval) {
        let proportionalGrace = hardTimeoutSeconds * 0.1
        let completionGrace = min(
            Self.maximumCompletionGrace,
            max(Self.minimumCompletionGrace, proportionalGrace))
        self.cooperativeDeadlineSeconds = max(0.001, hardTimeoutSeconds - completionGrace)
        self.hardTimeoutSeconds = hardTimeoutSeconds
    }
}

struct DetachedAXObservationResult: Sendable {
    let elements: [DetectedElement]
    let windowID: Int?
    let windowTitle: String
    let windowBounds: CGRect?
    let isDialog: Bool
    let truncationInfo: DetectionTruncationInfo?
}

enum DetachedAXMultiAttributeReadDisposition: Equatable {
    case values
    case fallback
    case incomplete
}

enum DetachedAXNodeTraversalDisposition: Equatable {
    case emitAndTraverse
    case traverseOnly
    case stopIncomplete
}

enum DetachedAXPostChildStopReason: Equatable {
    case maxElementCount
    case deadline
}

/// A deliberately small read-only AX implementation for background observation workers.
/// It creates every AX reference inside the worker lane and returns only immutable Sendable values.
enum DetachedAXObservationWorker {
    private static let maximumPerCallTimeout = 0.2
    private static let childAttributeNames = [
        kAXChildrenAttribute,
        "AXVisibleChildren",
        "AXWebAreaChildren",
        "AXApplicationNavigation",
        "AXApplicationElements",
        "AXBodyArea",
        "AXSplitGroupContents",
        "AXLayoutAreaChildren",
        "AXGroupChildren",
        "AXContents",
        "AXChildrenInNavigationOrder",
        kAXSelectedChildrenAttribute,
        kAXRowsAttribute,
        kAXColumnsAttribute,
        "AXTabs",
    ]
    private static let descriptorAttributeNames = [
        kAXPositionAttribute,
        kAXSizeAttribute,
        kAXRoleAttribute,
        kAXTitleAttribute,
        "AXLabel",
        kAXValueAttribute,
        kAXDescriptionAttribute,
        kAXHelpAttribute,
        kAXRoleDescriptionAttribute,
        kAXIdentifierAttribute,
        kAXEnabledAttribute,
        kAXSelectedAttribute,
        kAXFocusedAttribute,
        "AXPlaceholderValue",
        "AXEditable",
        "AXKeyboardShortcut",
    ]
    private static let actionableRoles: Set<String> = [
        "axbutton", "axpopupbutton", "axtextfield", "axtextarea", "axsearchfield", "axsecuretextfield",
        "axlink", "axweblink", "axcheckbox", "axradiobutton", "axmenuitem", "axcombobox", "axslider", "axtab",
    ]
    private static let actionLookupRoles: Set<String> = [
        "axgroup", "aximage", "axcell", "axrow", "axoutlineitem",
    ]

    static var descriptorAttributeCount: Int {
        self.descriptorAttributeNames.count
    }

    static var descriptorAttributes: [String] {
        self.descriptorAttributeNames
    }

    static func descriptorAttributeIndex(_ name: String) -> Int? {
        self.descriptorAttributeNames.firstIndex(of: name)
    }

    static var childAttributeCount: Int {
        self.childAttributeNames.count
    }

    static func descriptorReadDisposition(error: AXError, values: [Any]?)
        -> DetachedAXMultiAttributeReadDisposition
    {
        if error == .success {
            guard let values, values.count == self.descriptorAttributeNames.count else { return .incomplete }
            return AXAttributeReadCompletenessPolicy.hasNodeInvalidatingErrorValue(
                names: self.descriptorAttributeNames,
                values: values) ? .incomplete : .values
        }
        return self.isUnsupported(error) ? .fallback : .incomplete
    }

    static func childrenReadDisposition(error: AXError, values: [Any]?)
        -> DetachedAXMultiAttributeReadDisposition
    {
        self.multiAttributeReadDisposition(
            error: error,
            values: values,
            expectedValueCount: self.childAttributeNames.count)
    }

    static func nodeTraversalDisposition(
        descriptorAvailable: Bool,
        readIncomplete: Bool) -> DetachedAXNodeTraversalDisposition
    {
        if readIncomplete {
            return .stopIncomplete
        }
        return descriptorAvailable ? .emitAndTraverse : .traverseOnly
    }

    static func postChildStopReason(
        elementCount: Int,
        maxElementCount: Int,
        deadlineExpired: Bool,
        hasRemainingWork: Bool) -> DetachedAXPostChildStopReason?
    {
        guard hasRemainingWork else { return nil }
        if elementCount >= maxElementCount {
            return .maxElementCount
        }
        return deadlineExpired ? .deadline : nil
    }

    static func valueSettableMetadata(error: AXError, isSettable: Bool) -> Bool? {
        error == .success ? isSettable : nil
    }

    static func exactWindowCandidates<Window>(
        windows: [Window],
        remainingTimeout: () -> Float?,
        applyTimeout: (Window, Float) -> Void,
        windowID: (Window) -> Int?) -> [DetachedAXWindowIdentityCandidate]
    {
        windows.map { window in
            guard let timeout = remainingTimeout() else {
                return DetachedAXWindowIdentityCandidate(windowID: nil, bounds: nil)
            }
            let resolvedID = AXChildWindowMessagingTimeout.perform(
                timeout: timeout,
                applyTimeout: { applyTimeout(window, $0) },
                operation: { windowID(window) })
            return DetachedAXWindowIdentityCandidate(windowID: resolvedID, bounds: nil)
        }
    }

    static func inspect(_ request: DetachedAXObservationRequest) throws -> DetachedAXObservationResult {
        try self.inspect(
            request,
            resolveWindow: { application, request, deadline in
                try self.resolveWindow(application: application, request: request, deadline: deadline)
            },
            exactWindowUnavailableResult: { request, deadlineReached in
                self.exactWindowUnavailableResult(request, deadlineReached: deadlineReached)
            },
            validateIdentity: { request in
                try self.validateIdentity(request)
            })
    }

    static func inspect(
        _ request: DetachedAXObservationRequest,
        resolveWindow: (
            _ application: AXUIElement,
            _ request: DetachedAXObservationRequest,
            _ deadline: ContinuousClock.Instant) throws -> AXUIElement,
        exactWindowUnavailableResult: (
            _ request: DetachedAXObservationRequest,
            _ deadlineReached: Bool) -> DetachedAXObservationResult?,
        validateIdentity: (_ request: DetachedAXObservationRequest) throws -> Void) throws
        -> DetachedAXObservationResult
    {
        try validateIdentity(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(request.timing.cooperativeDeadlineSeconds))
        let application = AXUIElementCreateApplication(request.processIdentifier)
        self.prepare(application, deadline: deadline)

        let window: AXUIElement
        do {
            window = try resolveWindow(application, request, deadline)
        } catch {
            if let fallback = exactWindowUnavailableResult(
                request,
                ContinuousClock.now >= deadline)
            {
                try validateIdentity(request)
                return fallback
            }
            throw error
        }
        self.prepare(window, deadline: deadline)
        let title = self.stringAttribute(kAXTitleAttribute, of: window) ?? request.windowTitle ?? "Untitled"
        let bounds = self.frame(of: window)
        let subrole = self.stringAttribute(kAXSubroleAttribute, of: window) ?? ""
        var state = TraversalState()
        self.process(
            window,
            request: TraversalRequest(
                depth: 0,
                deadline: deadline,
                budget: request.traversalBudget,
                source: nil),
            state: &state)

        if request.includeMenuBarElements, request.appIsActive, ContinuousClock.now < deadline,
           let menuBar = self.elementAttribute(kAXMenuBarAttribute, of: application)
        {
            self.process(
                menuBar,
                request: TraversalRequest(
                    depth: 0,
                    deadline: deadline,
                    budget: request.traversalBudget,
                    source: "applicationMenuBar"),
                state: &state)
        }

        let result = DetachedAXObservationResult(
            elements: state.elements,
            windowID: AXWindowIDResolver.windowID(of: window).map(Int.init) ?? request.windowID,
            windowTitle: title,
            windowBounds: bounds,
            isDialog: ["AXDialog", "AXSystemDialog", "AXSheet"].contains(subrole) || self.isFileDialogTitle(title),
            truncationInfo: state.truncationInfo)
        try validateIdentity(request)
        return result
    }

    static func validateIdentity(
        _ request: DetachedAXObservationRequest,
        processStartIdentityProvider: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity? = SystemIdentityResolver.windowIdentity,
        receiptValidator: (WindowMutationIdentity, CGRect) -> Bool = {
            SystemIdentityResolver.validateWindowMutationIdentity($0, expectedBounds: $1)
        }) throws
    {
        guard processStartIdentityProvider(request.processIdentifier) == request.expectedProcessStartIdentity else {
            throw PeekabooError.snapshotStale(
                "Target PID \(request.processIdentifier) changed process generation during AX observation")
        }
        guard let requestedWindowID = request.windowID else { return }
        guard requestedWindowID > 0,
              let windowID = CGWindowID(exactly: requestedWindowID)
        else {
            throw PeekabooError.snapshotStale("Exact AX observation window identifier is invalid")
        }

        if let receipt = request.windowMutationIdentity {
            guard receipt.windowID == requestedWindowID,
                  receipt.ownerProcessIdentifier == request.processIdentifier,
                  receipt.ownerProcessStartIdentity == request.expectedProcessStartIdentity,
                  let bounds = request.expectedWindowBounds,
                  receiptValidator(receipt, bounds)
            else {
                throw PeekabooError.snapshotStale(
                    "Exact AX observation window receipt changed during traversal")
            }
            return
        }

        guard let liveWindow = windowIdentityProvider(windowID),
              liveWindow.ownerProcessIdentifier == request.processIdentifier,
              request.expectedWindowBounds == nil || liveWindow.bounds == request.expectedWindowBounds
        else {
            throw PeekabooError.snapshotStale(
                "Legacy exact AX observation window changed during traversal")
        }
    }

    private static func exactWindowUnavailableResult(
        _ request: DetachedAXObservationRequest,
        deadlineReached: Bool) -> DetachedAXObservationResult?
    {
        guard let requestedID = request.windowID,
              let windowID = CGWindowID(exactly: requestedID),
              let identity = SystemIdentityResolver.windowIdentity(windowID),
              identity.ownerProcessIdentifier == request.processIdentifier
        else {
            return nil
        }
        return DetachedAXObservationResult(
            elements: [],
            windowID: requestedID,
            windowTitle: identity.title,
            windowBounds: identity.bounds,
            isDialog: self.isFileDialogTitle(identity.title),
            truncationInfo: self.exactWindowResolutionFailureTruncation(
                deadlineReached: deadlineReached))
    }

    static func exactWindowResolutionFailureTruncation(
        deadlineReached: Bool) -> DetectionTruncationInfo
    {
        if deadlineReached {
            return DetectionTruncationInfo(deadlineReached: true)
        }
        return DetectionTruncationInfo(incompleteAccessibilityRead: true)
    }

    private static func resolveWindow(
        application: AXUIElement,
        request: DetachedAXObservationRequest,
        deadline: ContinuousClock.Instant) throws -> AXUIElement
    {
        if let requestedID = request.windowID {
            guard requestedID > 0,
                  let cgWindowID = CGWindowID(exactly: requestedID),
                  let identity = SystemIdentityResolver.windowIdentity(cgWindowID),
                  identity.ownerProcessIdentifier == request.processIdentifier
            else {
                throw PeekabooError.windowNotFound(
                    criteria: "window id \(requestedID) owned by PID \(request.processIdentifier)")
            }

            let windows = self.elementsAttribute(kAXWindowsAttribute, of: application)
            let candidates = self.exactWindowCandidates(
                windows: windows,
                remainingTimeout: { self.remainingMessagingTimeout(until: deadline) },
                applyTimeout: { AXUIElementSetMessagingTimeout($0, $1) },
                windowID: { AXWindowIDResolver.windowID(of: $0).map(Int.init) })
            if let exactIndex = DetachedAXExactWindowSelectionPolicy.uniqueExactIndex(
                windowID: Int(cgWindowID),
                candidates: candidates)
            {
                return windows[exactIndex]
            }
            throw PeekabooError.windowNotFound(
                criteria: "accessible window id \(requestedID) owned by PID \(request.processIdentifier)")
        }

        let windows = self.elementsAttribute(kAXWindowsAttribute, of: application)
        if let title = request.windowTitle,
           let match = windows.first(where: {
               self.prepare($0, deadline: deadline)
               return self.stringAttribute(kAXTitleAttribute, of: $0)?.localizedCaseInsensitiveContains(title) == true
           })
        {
            return match
        }
        if let focused = self.elementAttribute(kAXFocusedWindowAttribute, of: application) {
            return focused
        }
        if let main = self.elementAttribute(kAXMainWindowAttribute, of: application) {
            return main
        }
        guard let first = windows.first else {
            throw PeekabooError.windowNotFound(criteria: "accessible window for PID \(request.processIdentifier)")
        }
        return first
    }

    private static func process(
        _ element: AXUIElement,
        request: TraversalRequest,
        state: inout TraversalState)
    {
        guard ContinuousClock.now < request.deadline else {
            state.deadlineReached = true
            return
        }
        guard request.depth < request.budget.maxDepth else {
            state.maxDepthReached = true
            return
        }
        guard state.elements.count < request.budget.maxElementCount else {
            state.maxElementCountReached = true
            return
        }
        guard !state.visited.contains(where: { CFEqual($0, element) }) else { return }
        state.visited.append(element)

        self.prepare(element, deadline: request.deadline)
        let descriptorRead = self.descriptor(of: element)
        switch self.nodeTraversalDisposition(
            descriptorAvailable: descriptorRead.descriptor != nil,
            readIncomplete: descriptorRead.isIncomplete)
        {
        case .stopIncomplete:
            state.incompleteAccessibilityRead = true
            return
        case .traverseOnly:
            self.processChildren(of: element, request: request, state: &state)
            return
        case .emitAndTraverse:
            break
        }
        guard let descriptor = descriptorRead.descriptor else { return }
        let normalizedRole = descriptor.role.lowercased()
        let baseType = self.elementType(role: normalizedRole, isEditable: descriptor.isEditable)
        let elementTypeInput = ElementTypeAdjustmentInput(
            role: descriptor.role,
            roleDescription: descriptor.roleDescription,
            title: descriptor.title,
            label: descriptor.label,
            placeholder: descriptor.placeholder,
            isEditable: descriptor.isEditable)
        let elementType = ElementTypeAdjuster.resolve(
            baseType: baseType,
            input: elementTypeInput,
            hasTextFieldDescendant: false)
        let identifier = ElementTypeAdjuster.resolveIdentifier(
            descriptor.identifier,
            baseType: baseType,
            resolvedType: elementType)
        let exposesAction = self.actionableRoles.contains(normalizedRole) ||
            (self.actionLookupRoles.contains(normalizedRole) && self.actions(of: element).contains(kAXPressAction))
        let isValueSettable = self.valueSettable(
            of: element,
            role: descriptor.role,
            recoveredType: elementType,
            deadline: request.deadline)
        let isActionable = exposesAction || isValueSettable == true
        let elementID = request.source == nil ?
            "elem_\(state.elements.count)" : "menuitem_\(state.elements.count)"
        var attributes = ["role": descriptor.role, "axEnabledKnown": String(descriptor.isEnabled != nil)]
        if let title = descriptor.title {
            attributes["title"] = title
        }
        if let description = descriptor.description {
            attributes["description"] = description
        }
        if let help = descriptor.help {
            attributes["help"] = help
        }
        if let roleDescription = descriptor.roleDescription {
            attributes["roleDescription"] = roleDescription
        }
        if let identifier {
            attributes["identifier"] = identifier
        }
        if let placeholder = descriptor.placeholder {
            attributes["placeholder"] = placeholder
        }
        if let shortcut = descriptor.keyboardShortcut {
            attributes["keyboardShortcut"] = shortcut
        }
        if isActionable {
            attributes["isActionable"] = "true"
        }
        if let isValueSettable {
            attributes["isValueSettable"] = String(isValueSettable)
        }
        if let isFocused = descriptor.isFocused {
            attributes["isFocused"] = String(isFocused)
        }
        if let source = request.source {
            attributes["source"] = source
        }

        state.elements.append(DetectedElement(
            id: elementID,
            type: elementType,
            label: self.label(for: descriptor),
            value: descriptor.value,
            bounds: descriptor.frame,
            isEnabled: descriptor.isEnabled ?? false,
            isSelected: descriptor.isSelected,
            attributes: attributes))

        self.processChildren(of: element, request: request, state: &state)
    }

    private static func processChildren(
        of element: AXUIElement,
        request: TraversalRequest,
        state: inout TraversalState)
    {
        let childrenRead = self.children(of: element)
        state.incompleteAccessibilityRead = state.incompleteAccessibilityRead || childrenRead.isIncomplete
        let children = childrenRead.elements
        if children.count > request.budget.maxChildrenPerNode {
            state.maxChildrenPerNodeReached = true
        }
        let limitedChildren = Array(children.prefix(request.budget.maxChildrenPerNode))
        for (index, child) in limitedChildren.enumerated() {
            self.process(
                child,
                request: TraversalRequest(
                    depth: request.depth + 1,
                    deadline: request.deadline,
                    budget: request.budget,
                    source: request.source),
                state: &state)
            let stopReason = self.postChildStopReason(
                elementCount: state.elements.count,
                maxElementCount: request.budget.maxElementCount,
                deadlineExpired: ContinuousClock.now >= request.deadline,
                hasRemainingWork: index < limitedChildren.count - 1)
            switch stopReason {
            case .maxElementCount:
                state.maxElementCountReached = true
                return
            case .deadline:
                state.deadlineReached = true
                return
            case nil:
                break
            }
        }
    }

    private static func descriptor(of element: AXUIElement) -> DescriptorReadResult {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            self.descriptorAttributeNames as CFArray,
            [],
            &rawValues)
        let values = rawValues as? [Any]
        switch self.descriptorReadDisposition(error: error, values: values) {
        case .fallback:
            return self.descriptorWithSingleReads(of: element)
        case .incomplete:
            return .incomplete
        case .values:
            break
        }
        guard let values else { return .incomplete }

        let byName = Dictionary(uniqueKeysWithValues: zip(self.descriptorAttributeNames, values))
        let frame = CGRect(
            origin: self.pointValue(byName[kAXPositionAttribute]) ?? .zero,
            size: self.sizeValue(byName[kAXSizeAttribute]) ?? .zero)
        guard frame.width > 5, frame.height > 5 else { return .absent }
        let role = self.stringValue(byName[kAXRoleAttribute]) ?? "Unknown"
        return .value(Descriptor(
            frame: frame,
            role: role,
            title: self.stringValue(byName[kAXTitleAttribute]),
            label: self.stringValue(byName["AXLabel"]),
            value: AXDescriptorReader.displayValue(byName[kAXValueAttribute]),
            description: self.stringValue(byName[kAXDescriptionAttribute]),
            help: self.stringValue(byName[kAXHelpAttribute]),
            roleDescription: self.stringValue(byName[kAXRoleDescriptionAttribute]),
            identifier: self.stringValue(byName[kAXIdentifierAttribute]),
            isEnabled: self.boolValue(byName[kAXEnabledAttribute]),
            isSelected: self.boolValue(byName[kAXSelectedAttribute]) ??
                self.booleanSelectionValue(role: role, rawValue: byName[kAXValueAttribute]),
            isFocused: self.boolValue(byName[kAXFocusedAttribute]),
            placeholder: self.stringValue(byName["AXPlaceholderValue"]),
            isEditable: self.boolValue(byName["AXEditable"]) ?? false,
            keyboardShortcut: self.stringValue(byName["AXKeyboardShortcut"])))
    }

    private static func descriptorWithSingleReads(of element: AXUIElement) -> DescriptorReadResult {
        var valuesByName: [String: Any] = [:]
        for name in self.descriptorAttributeNames {
            let read = self.rawAttributeRead(name, of: element)
            if read.invalidatesNode(attribute: name) {
                return .incomplete
            }
            if let value = read.value {
                valuesByName[name] = value
            }
        }

        let frame = CGRect(
            origin: self.pointValue(valuesByName[kAXPositionAttribute]) ?? .zero,
            size: self.sizeValue(valuesByName[kAXSizeAttribute]) ?? .zero)
        guard frame.width > 5, frame.height > 5 else { return .absent }
        let role = self.stringValue(valuesByName[kAXRoleAttribute]) ?? "Unknown"
        return .value(Descriptor(
            frame: frame,
            role: role,
            title: self.stringValue(valuesByName[kAXTitleAttribute]),
            label: self.stringValue(valuesByName["AXLabel"]),
            value: AXDescriptorReader.displayValue(valuesByName[kAXValueAttribute]),
            description: self.stringValue(valuesByName[kAXDescriptionAttribute]),
            help: self.stringValue(valuesByName[kAXHelpAttribute]),
            roleDescription: self.stringValue(valuesByName[kAXRoleDescriptionAttribute]),
            identifier: self.stringValue(valuesByName[kAXIdentifierAttribute]),
            isEnabled: self.boolValue(valuesByName[kAXEnabledAttribute]),
            isSelected: self.boolValue(valuesByName[kAXSelectedAttribute]) ??
                self.booleanSelectionValue(role: role, rawValue: valuesByName[kAXValueAttribute]),
            isFocused: self.boolValue(valuesByName[kAXFocusedAttribute]),
            placeholder: self.stringValue(valuesByName["AXPlaceholderValue"]),
            isEditable: self.boolValue(valuesByName["AXEditable"]) ?? false,
            keyboardShortcut: self.stringValue(valuesByName["AXKeyboardShortcut"])))
    }

    private static func children(of element: AXUIElement) -> ChildrenReadResult {
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            self.childAttributeNames as CFArray,
            [],
            &rawValues)
        let values = rawValues as? [Any]
        switch self.childrenReadDisposition(error: error, values: values) {
        case .fallback:
            return self.fallbackChildren(of: element, alreadyIncomplete: false)
        case .incomplete:
            return self.fallbackChildren(of: element, alreadyIncomplete: true)
        case .values:
            break
        }
        guard let values else { return ChildrenReadResult(elements: [], isIncomplete: true) }

        var result: [AXUIElement] = []
        for value in values {
            guard let elements = value as? [AXUIElement] else { continue }
            for child in elements where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return ChildrenReadResult(elements: result, isIncomplete: false)
    }

    private static func fallbackChildren(
        of element: AXUIElement,
        alreadyIncomplete: Bool) -> ChildrenReadResult
    {
        let read = self.rawAttributeRead(kAXChildrenAttribute, of: element)
        return ChildrenReadResult(
            elements: read.value as? [AXUIElement] ?? [],
            isIncomplete: alreadyIncomplete || read.isIncomplete)
    }

    private static func actions(of element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func valueSettable(
        of element: AXUIElement,
        role: String,
        recoveredType: ElementType,
        deadline: ContinuousClock.Instant) -> Bool?
    {
        guard recoveredType == .textField || ElementClassifier.supportsValueMetadata(for: role) else { return nil }
        guard let timeout = self.remainingMessagingTimeout(until: deadline) else { return nil }
        AXUIElementSetMessagingTimeout(element, timeout)
        var isSettable = DarwinBoolean(false)
        let error = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isSettable)
        return self.valueSettableMetadata(error: error, isSettable: isSettable.boolValue)
    }

    private static func prepare(_ element: AXUIElement, deadline: ContinuousClock.Instant) {
        let timeout = self.remainingMessagingTimeout(until: deadline) ?? 0.01
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static func remainingMessagingTimeout(until deadline: ContinuousClock.Instant) -> Float? {
        let duration = ContinuousClock.now.duration(to: deadline)
        let components = duration.components
        let remaining = Double(components.seconds) +
            Double(components.attoseconds) / 1_000_000_000_000_000_000
        guard remaining > 0 else { return nil }
        let timeout = Float(min(self.maximumPerCallTimeout, remaining))
        return timeout > 0 ? timeout : nil
    }

    private static func rawAttribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        self.rawAttributeRead(name, of: element).value
    }

    private static func rawAttributeRead(_ name: String, of element: AXUIElement) -> AXAttributeReadResult {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return AXAttributeReadResult(error: error, value: value)
    }

    private static func elementAttribute(_ name: String, of element: AXUIElement) -> AXUIElement? {
        guard let value = self.rawAttribute(name, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func elementsAttribute(_ name: String, of element: AXUIElement) -> [AXUIElement] {
        self.rawAttribute(name, of: element) as? [AXUIElement] ?? []
    }

    private static func stringAttribute(_ name: String, of element: AXUIElement) -> String? {
        self.rawAttribute(name, of: element) as? String
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        self.booleanAttributeValue(self.rawAttribute(name, of: element))
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = self.pointValue(self.rawAttribute(kAXPositionAttribute, of: element)),
              let size = self.sizeValue(self.rawAttribute(kAXSizeAttribute, of: element))
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    static func booleanAttributeValue(_ value: Any?) -> Bool? {
        self.boolValue(value)
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        AXDescriptorReader.boolValue(value)
    }

    private static func pointValue(_ value: Any?) -> CGPoint? {
        guard let axValue = self.axValue(value), AXValueGetType(axValue) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ value: Any?) -> CGSize? {
        guard let axValue = self.axValue(value), AXValueGetType(axValue) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
    }

    private static func axValue(_ value: Any?) -> AXValue? {
        guard let value else { return nil }
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == AXValueGetTypeID() else { return nil }
        return unsafeDowncast(cfValue, to: AXValue.self)
    }

    private static func booleanSelectionValue(role: String, rawValue: Any?) -> Bool? {
        guard ["axcheckbox", "axradiobutton", "axswitch"].contains(role.lowercased()) else { return nil }
        return self.boolValue(rawValue)
    }

    private static func elementType(role: String, isEditable: Bool) -> ElementType {
        switch role {
        case "axbutton", "axpopupbutton": .button
        case "axtextfield", "axtextarea", "axsearchfield", "axsecuretextfield": .textField
        case "axlink", "axweblink": .link
        case "aximage": .image
        case "axcheckbox", "axradiobutton": .checkbox
        case "axslider": .slider
        case "axmenu", "axmenubar": .menu
        case "axgroup" where isEditable: .textField
        case "axgroup": .group
        default: .other
        }
    }

    private static func label(for descriptor: Descriptor) -> String? {
        ElementLabelResolver.resolve(
            info: ElementLabelInfo(
                role: descriptor.role,
                label: descriptor.label,
                title: descriptor.title,
                value: descriptor.value,
                roleDescription: descriptor.roleDescription,
                description: descriptor.description,
                identifier: descriptor.identifier,
                placeholder: descriptor.placeholder),
            childTexts: [],
            identifierCleaner: {
                $0.replacingOccurrences(of: "-button", with: "")
                    .replacingOccurrences(of: "-", with: " ")
            })
    }

    private static func isFileDialogTitle(_ title: String) -> Bool {
        ["Open", "Save", "Export", "Import"].contains(title) || title.hasPrefix("Save As")
    }

    private static func multiAttributeReadDisposition(
        error: AXError,
        values: [Any]?,
        expectedValueCount: Int) -> DetachedAXMultiAttributeReadDisposition
    {
        if error == .success {
            guard let values, values.count == expectedValueCount else { return .incomplete }
            return AXAttributeReadCompletenessPolicy.hasIncompleteErrorValue(in: values) ? .incomplete : .values
        }
        if self.isUnsupported(error) {
            return .fallback
        }
        return .incomplete
    }

    private static func isUnsupported(_ error: AXError) -> Bool {
        error == .attributeUnsupported || error == .parameterizedAttributeUnsupported || error == .notImplemented
    }
}

private struct TraversalRequest {
    let depth: Int
    let deadline: ContinuousClock.Instant
    let budget: AXTraversalBudget
    let source: String?
}

private struct Descriptor {
    let frame: CGRect
    let role: String
    let title: String?
    let label: String?
    let value: String?
    let description: String?
    let help: String?
    let roleDescription: String?
    let identifier: String?
    let isEnabled: Bool?
    let isSelected: Bool?
    let isFocused: Bool?
    let placeholder: String?
    let isEditable: Bool
    let keyboardShortcut: String?
}

private enum DescriptorReadResult {
    case value(Descriptor)
    case absent
    case incomplete

    var descriptor: Descriptor? {
        guard case let .value(descriptor) = self else { return nil }
        return descriptor
    }

    var isIncomplete: Bool {
        if case .incomplete = self {
            return true
        }
        return false
    }
}

private struct ChildrenReadResult {
    let elements: [AXUIElement]
    let isIncomplete: Bool
}

private struct AXAttributeReadResult {
    let error: AXError
    let value: CFTypeRef?

    var isIncomplete: Bool {
        AXAttributeReadCompletenessPolicy.isIncomplete(error: self.error)
    }

    func invalidatesNode(attribute: String) -> Bool {
        AXAttributeReadCompletenessPolicy.attributeErrorInvalidatesNode(self.error, attribute: attribute)
    }
}

private struct TraversalState {
    var elements: [DetectedElement] = []
    var visited: [AXUIElement] = []
    var maxDepthReached = false
    var maxElementCountReached = false
    var maxChildrenPerNodeReached = false
    var deadlineReached = false
    var incompleteAccessibilityRead = false

    var truncationInfo: DetectionTruncationInfo? {
        guard self.maxDepthReached || self.maxElementCountReached || self.maxChildrenPerNodeReached ||
            self.deadlineReached || self.incompleteAccessibilityRead
        else {
            return nil
        }
        return DetectionTruncationInfo(
            maxDepthReached: self.maxDepthReached,
            maxElementCountReached: self.maxElementCountReached,
            maxChildrenPerNodeReached: self.maxChildrenPerNodeReached,
            deadlineReached: self.deadlineReached,
            incompleteAccessibilityRead: self.incompleteAccessibilityRead)
    }
}
