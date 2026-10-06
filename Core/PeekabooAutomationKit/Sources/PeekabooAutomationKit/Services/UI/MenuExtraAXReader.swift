import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooFoundation

/// Native identity leaves the read worker only after its read-scoped messaging timeout is restored.
struct MenuExtraAXIdentity: @unchecked Sendable, Hashable {
    let element: AXUIElement

    static func == (lhs: Self, rhs: Self) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(CFHash(self.element))
    }
}

struct MenuExtraAXSnapshot: Sendable {
    let identity: MenuExtraAXIdentity
    let processIdentity: ApplicationProcessIdentity
    let title: String?
    let help: String?
    let description: String?
    let identifier: String?
    let role: String
    let subrole: String?
    let frame: CGRect
    let actions: [String]
}

enum MenuExtraAXReader {
    typealias AttributeCopy = (AXUIElement, String) -> (CFTypeRef?, AXError)
    typealias ActionCopy = (AXUIElement) -> (CFArray?, AXError)
    typealias MessagingTimeoutSet = (AXUIElement, Float) -> AXError

    static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw self.timeout }
    }

    static var timeout: PeekabooError {
        .timeout("Menu-extra discovery exceeded its shared deadline")
    }

    static var incomplete: PeekabooError {
        .accessibilityIncomplete(self.incompleteMessage)
    }

    private static let incompleteMessage =
        "Menu-extra ownership, classification, or children could not be read completely."

    static func read(
        owner: ApplicationProcessIdentity,
        deadline: ContinuousClock.Instant) async throws -> [MenuExtraAXSnapshot]
    {
        try self.check(deadline)
        let remaining = ContinuousClock.now.duration(to: deadline).components
        do {
            let result = try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: owner.processIdentifier,
                targetProcessStartIdentity: owner.processStartIdentity,
                seconds: Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18,
                maximumPendingOperationCount: 1)
            {
                try self.readSynchronously(owner: owner, deadline: deadline)
            }
            try self.check(deadline)
            return result
        } catch CaptureError.detectionTimedOut {
            throw self.timeout
        }
    }

    static func readSynchronously(
        owner: ApplicationProcessIdentity,
        deadline: ContinuousClock.Instant,
        copyAttribute: AttributeCopy = Self.copyAttribute,
        copyActions: ActionCopy = Self.copyActions,
        processIdentifier: (AXUIElement) -> pid_t? = Self.processIdentifier,
        processGeneration: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity,
        setMessagingTimeout: MessagingTimeoutSet = AXUIElementSetMessagingTimeout) throws
        -> [MenuExtraAXSnapshot]
    {
        let root = AXUIElementCreateApplication(owner.processIdentifier)
        var nativeOwnerPID: pid_t? = owner.processIdentifier
        func failure(
            _ phase: String,
            node: String = "leaf",
            attribute: String = "none",
            error: AXError? = nil,
            expected: String = "none",
            actual: String = "none") -> PeekabooError
        {
            .accessibilityIncomplete(
                "\(self.incompleteMessage) [scope=application scan_pid=\(owner.processIdentifier) " +
                    "owner_pid=\(nativeOwnerPID.map { String($0) } ?? "none") " +
                    "node=\(node) phase=\(phase) attribute=\(attribute) " +
                    "native_error=\(error.map { String($0.rawValue) } ?? "none") " +
                    "expected=\(expected) actual=\(actual)]")
        }
        func value<Value>(_ name: String, on element: AXUIElement, node: String = "leaf") throws -> Value? {
            let (raw, nativeError) = try self.withReadTimeout(
                on: element,
                deadline: deadline,
                setMessagingTimeout: setMessagingTimeout,
                timeoutFailure: { restoring, error in
                    failure(
                        restoring ? "timeout_restore" : "timeout_install",
                        node: node,
                        attribute: name,
                        error: error)
                },
                read: {
                    copyAttribute(element, name)
                })
            do {
                return try self.attributeValue(raw, error: nativeError)
            } catch let error as PeekabooError {
                guard case .accessibilityIncomplete = error else { throw error }
                throw failure(
                    "attribute",
                    node: node,
                    attribute: name,
                    error: nativeError,
                    expected: self.expectedType(Value.self),
                    actual: self.valueType(raw))
            }
        }
        guard processGeneration(owner.processIdentifier) == owner.processStartIdentity else {
            throw failure("owner_before", node: "root")
        }
        let bar: AXUIElement? = try value("AXExtrasMenuBar", on: root, node: "root")
        guard let bar else {
            guard processGeneration(owner.processIdentifier) == owner.processStartIdentity else {
                throw failure("owner_after_absence", node: "root")
            }
            return []
        }
        let elements: [AXUIElement] = try value(kAXChildrenAttribute, on: bar, node: "bar") ?? []
        var seen: Set<MenuExtraAXIdentity> = []
        var snapshots: [MenuExtraAXSnapshot] = []
        for element in elements {
            try self.check(deadline)
            let identity = MenuExtraAXIdentity(element: element)
            guard seen.insert(identity).inserted else { continue }
            nativeOwnerPID = processIdentifier(element)
            guard let pid = nativeOwnerPID, pid > 0,
                  pid == owner.processIdentifier,
                  let generation = processGeneration(pid)
            else { throw failure("leaf_owner") }
            let role: String? = try value(kAXRoleAttribute, on: element)
            guard let role, !role.isEmpty else { throw failure("required_role", attribute: kAXRoleAttribute) }
            let subrole: String? = try value(kAXSubroleAttribute, on: element)
            let title: String? = try value(kAXTitleAttribute, on: element)
            let help: String? = try value(kAXHelpAttribute, on: element)
            let description: String? = try value(kAXDescriptionAttribute, on: element)
            let identifier: String? = try value(kAXIdentifierAttribute, on: element)
            let position: AXValue? = try value(kAXPositionAttribute, on: element)
            let size: AXValue? = try value(kAXSizeAttribute, on: element)
            var point = CGPoint.zero
            var dimensions = CGSize.zero
            guard let position, AXValueGetType(position) == .cgPoint,
                  AXValueGetValue(position, .cgPoint, &point)
            else {
                throw failure(
                    "geometry",
                    attribute: kAXPositionAttribute,
                    expected: "point",
                    actual: self.valueType(position))
            }
            guard let size, AXValueGetType(size) == .cgSize, AXValueGetValue(size, .cgSize, &dimensions) else {
                throw failure("geometry", attribute: kAXSizeAttribute, expected: "size", actual: self.valueType(size))
            }
            guard point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite else {
                throw failure("geometry_nonfinite")
            }
            guard dimensions.width > 0, dimensions.height > 0 else { throw failure("geometry_nonpositive_size") }
            let (rawActions, actionError) = try self.withReadTimeout(
                on: element,
                deadline: deadline,
                setMessagingTimeout: setMessagingTimeout,
                timeoutFailure: { restoring, error in
                    failure(restoring ? "timeout_restore" : "timeout_install", attribute: "action_names", error: error)
                },
                read: {
                    copyActions(element)
                })
            let actions: [String]
            do {
                actions = try self.attributeValue(rawActions, error: actionError) ?? []
            } catch let error as PeekabooError {
                guard case .accessibilityIncomplete = error else { throw error }
                throw failure(
                    "actions",
                    attribute: "action_names",
                    error: actionError,
                    expected: "string_array",
                    actual: self.valueType(rawActions))
            }
            guard processGeneration(pid) == generation else { throw failure("owner_after_leaf") }
            snapshots.append(MenuExtraAXSnapshot(
                identity: identity,
                processIdentity: .init(processIdentifier: pid, processStartIdentity: generation),
                title: title,
                help: help,
                description: description,
                identifier: identifier,
                role: role,
                subrole: subrole,
                frame: CGRect(origin: point, size: dimensions),
                actions: actions))
        }
        guard processGeneration(owner.processIdentifier) == owner.processStartIdentity else {
            throw failure("owner_after_scan", node: "root")
        }
        return snapshots
    }

    static func withReadTimeout<Output>(
        on element: AXUIElement,
        deadline: ContinuousClock.Instant,
        setMessagingTimeout: MessagingTimeoutSet,
        now: () -> ContinuousClock.Instant = { .now },
        timeoutFailure: (Bool, AXError) -> PeekabooError = { _, _ in Self.incomplete },
        read: () throws -> Output) throws -> Output
    {
        try Task.checkCancellation()
        let startedAt = now()
        guard startedAt < deadline else { throw self.timeout }
        let result: Output
        let remaining = startedAt.duration(to: deadline).components
        let seconds = min(0.1, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
        let rounded = Float(seconds)
        let timeout = Double(rounded) > seconds ? rounded.nextDown : rounded
        guard timeout > 0 else { throw self.timeout }
        var restoration = AXError.failure
        do {
            // This reader creates only application/child references, never the process-global system root.
            // Zero clears the private override before a reference can be retained for mutation.
            defer { restoration = setMessagingTimeout(element, 0) }
            let installed = setMessagingTimeout(element, timeout)
            guard installed == .success else { throw timeoutFailure(false, installed) }
            try Task.checkCancellation()
            guard now() < deadline else { throw self.timeout }
            result = try read()
        }
        guard restoration == .success else { throw timeoutFailure(true, restoration) }
        try Task.checkCancellation()
        guard now() < deadline else { throw self.timeout }
        return result
    }

    private static func expectedType(_ type: Any.Type) -> String {
        if type == String.self {
            return "string"
        }
        if type == AXUIElement.self {
            return "ax_element"
        }
        if type == AXValue.self {
            return "ax_value"
        }
        if type == [AXUIElement].self {
            return "ax_element_array"
        }
        return "typed_value"
    }

    private static func valueType(_ value: CFTypeRef?) -> String {
        guard let value else { return "none" }
        switch CFGetTypeID(value) {
        case AXUIElementGetTypeID(): return "ax_element"
        case AXValueGetTypeID(): return "ax_value"
        case CFArrayGetTypeID(): return "array"
        case CFStringGetTypeID(): return "string"
        case CFBooleanGetTypeID(): return "boolean"
        case CFNumberGetTypeID(): return "number"
        case CFNullGetTypeID(): return "null"
        default: return "other"
        }
    }

    static func attributeValue<Value>(_ value: CFTypeRef?, error: AXError) throws -> Value? {
        switch error {
        case .attributeUnsupported, .noValue:
            return nil
        case .success:
            guard let value else { throw self.incomplete }
            if Value.self == AXUIElement.self, CFGetTypeID(value) != AXUIElementGetTypeID() {
                throw self.incomplete
            }
            if Value.self == AXValue.self, CFGetTypeID(value) != AXValueGetTypeID() {
                throw self.incomplete
            }
            if Value.self == [AXUIElement].self {
                guard CFGetTypeID(value) == CFArrayGetTypeID(), let values = value as? [AnyObject],
                      values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
                else { throw self.incomplete }
            }
            guard let typed = value as? Value else { throw self.incomplete }
            return typed
        default:
            throw self.incomplete
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (value, error)
    }

    private static func copyActions(_ element: AXUIElement) -> (CFArray?, AXError) {
        var names: CFArray?
        let error = AXUIElementCopyActionNames(element, &names)
        return (names, error)
    }

    private static func processIdentifier(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }
}
