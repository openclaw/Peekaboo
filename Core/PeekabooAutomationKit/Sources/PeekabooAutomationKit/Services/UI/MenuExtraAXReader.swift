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
        .accessibilityIncomplete("Menu-extra ownership, classification, or children could not be read completely.")
    }

    static func read(
        owner: ApplicationProcessIdentity,
        systemWide: Bool = false,
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
                try self.readSynchronously(owner: owner, systemWide: systemWide, deadline: deadline)
            }
            try self.check(deadline)
            return result
        } catch CaptureError.detectionTimedOut {
            throw self.timeout
        }
    }

    static func readSynchronously(
        owner: ApplicationProcessIdentity,
        systemWide: Bool = false,
        deadline: ContinuousClock.Instant,
        copyAttribute: AttributeCopy = Self.copyAttribute,
        copyActions: ActionCopy = Self.copyActions,
        processIdentifier: (AXUIElement) -> pid_t? = Self.processIdentifier,
        processGeneration: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity,
        setMessagingTimeout: MessagingTimeoutSet = AXUIElementSetMessagingTimeout) throws
        -> [MenuExtraAXSnapshot]
    {
        let root = systemWide ? AXUIElementCreateSystemWide() : AXUIElementCreateApplication(owner.processIdentifier)
        func value<Value>(_ name: String, on element: AXUIElement) throws -> Value? {
            let (raw, error) = try self.withReadTimeout(
                on: element,
                systemWideRoot: systemWide ? root : nil,
                deadline: deadline,
                setMessagingTimeout: setMessagingTimeout)
            {
                copyAttribute(element, name)
            }
            return try self.attributeValue(raw, error: error)
        }
        guard processGeneration(owner.processIdentifier) == owner.processStartIdentity else {
            throw self.incomplete
        }
        let bar: AXUIElement? = try value(systemWide ? kAXMenuBarAttribute : "AXExtrasMenuBar", on: root)
        guard let bar else {
            guard processGeneration(owner.processIdentifier) == owner.processStartIdentity else {
                throw self.incomplete
            }
            return []
        }
        let barChildren: [AXUIElement] = try value(kAXChildrenAttribute, on: bar) ?? []
        var elements: [AXUIElement] = []
        if systemWide {
            for child in barChildren {
                let role: String? = try value(kAXRoleAttribute, on: child)
                guard let role else { throw self.incomplete }
                if role == "AXGroup" {
                    let children: [AXUIElement] = try value(kAXChildrenAttribute, on: child) ?? []
                    elements.append(contentsOf: children)
                }
            }
        } else {
            elements = barChildren
        }
        var seen: Set<MenuExtraAXIdentity> = []
        var snapshots: [MenuExtraAXSnapshot] = []
        for element in elements {
            try self.check(deadline)
            let identity = MenuExtraAXIdentity(element: element)
            guard seen.insert(identity).inserted else { continue }
            guard let pid = processIdentifier(element), pid > 0,
                  systemWide || pid == owner.processIdentifier,
                  let generation = processGeneration(pid)
            else { throw self.incomplete }
            let role: String? = try value(kAXRoleAttribute, on: element)
            guard let role, !role.isEmpty else { throw self.incomplete }
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
                  AXValueGetValue(position, .cgPoint, &point),
                  let size, AXValueGetType(size) == .cgSize,
                  AXValueGetValue(size, .cgSize, &dimensions),
                  point.x.isFinite, point.y.isFinite,
                  dimensions.width.isFinite, dimensions.height.isFinite,
                  dimensions.width > 0, dimensions.height > 0
            else { throw self.incomplete }
            let (rawActions, actionError) = try self.withReadTimeout(
                on: element,
                systemWideRoot: systemWide ? root : nil,
                deadline: deadline,
                setMessagingTimeout: setMessagingTimeout)
            {
                copyActions(element)
            }
            let actions: [String] = try self.attributeValue(rawActions, error: actionError) ?? []
            guard processGeneration(pid) == generation else { throw self.incomplete }
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
            throw self.incomplete
        }
        return snapshots
    }

    static func withReadTimeout<Output>(
        on element: AXUIElement,
        systemWideRoot: AXUIElement? = nil,
        deadline: ContinuousClock.Instant,
        setMessagingTimeout: MessagingTimeoutSet,
        now: () -> ContinuousClock.Instant = { .now },
        read: () throws -> Output) throws -> Output
    {
        try Task.checkCancellation()
        let startedAt = now()
        guard startedAt < deadline else { throw self.timeout }
        let result: Output
        if let systemWideRoot, CFEqual(element, systemWideRoot) {
            // A timeout on this root changes process-global policy. Only this read relies on the
            // outer deadline/occupied-worker bound; an abandoned RPC retains its slot until it returns.
            result = try read()
        } else {
            let remaining = startedAt.duration(to: deadline).components
            let seconds = min(0.1, Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18)
            let rounded = Float(seconds)
            let timeout = Double(rounded) > seconds ? rounded.nextDown : rounded
            guard timeout > 0 else { throw self.timeout }
            var restoration = AXError.failure
            do {
                // These references are created/returned inside this reader. Zero removes only this
                // object's override, so retained mutation references inherit the unchanged global default.
                defer { restoration = setMessagingTimeout(element, 0) }
                guard setMessagingTimeout(element, timeout) == .success else { throw self.incomplete }
                try Task.checkCancellation()
                guard now() < deadline else { throw self.timeout }
                result = try read()
            }
            guard restoration == .success else { throw self.incomplete }
        }
        try Task.checkCancellation()
        guard now() < deadline else { throw self.timeout }
        return result
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
