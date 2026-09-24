import ApplicationServices
import AXorcist
import Foundation

struct DialogHierarchyNode: Sendable {
    let evidence: DialogElementEvidence
    let children: [Element]
}

struct DialogHierarchyBudget {
    var deadline = ContinuousClock.now.advanced(by: .seconds(3))
    var maximumNodeCount = 512
    var maximumDepth = 32

    func checkDeadline() throws {
        guard ContinuousClock.now < self.deadline else {
            throw DialogHierarchyReadError.deadlineExceeded
        }
    }
}

enum DialogHierarchyReadError: LocalizedError {
    case deadlineExceeded
    case unreadable
    case traversalLimit

    var errorDescription: String? {
        switch self {
        case .deadlineExceeded: "Dialog hierarchy discovery exceeded its deadline."
        case .unreadable: "Dialog hierarchy classification or children could not be read completely."
        case .traversalLimit: "Dialog hierarchy discovery exceeded its node or depth limit."
        }
    }
}

enum DialogHierarchyReader {
    @MainActor
    static func read(
        _ element: Element,
        owner: ApplicationProcessIdentity,
        deadline: ContinuousClock.Instant) async throws -> DialogHierarchyNode
    {
        let identity = ReadOnlyAXIdentity(element: element.underlyingElement)
        let result = try await self.run(owner: owner, deadline: deadline) {
            try self.readNode(identity.element, deadline: deadline)
        }
        var seen: Set<Element> = []
        let children = result.children.map { Element($0.element) }.filter { seen.insert($0).inserted }
        return DialogHierarchyNode(evidence: result.evidence, children: children)
    }

    static func run<Output: Sendable>(
        owner: ApplicationProcessIdentity,
        deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () throws -> Output) async throws -> Output
    {
        try Task.checkCancellation()
        let remaining = ContinuousClock.now.duration(to: deadline)
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        guard seconds > 0 else { throw DialogHierarchyReadError.deadlineExceeded }
        // Only C reads run here: no AXorcist caches, messaging-timeout changes, service state,
        // or mutation callbacks can outlive the caller.
        let result = try await ElementDetectionTimeoutRunner.runDetached(
            targetProcessIdentifier: owner.processIdentifier,
            targetProcessStartIdentity: owner.processStartIdentity,
            seconds: seconds,
            maximumPendingOperationCount: 1)
        {
            guard ContinuousClock.now < deadline else { throw DialogHierarchyReadError.deadlineExceeded }
            return try operation()
        }
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw DialogHierarchyReadError.deadlineExceeded }
        return result
    }

    private static func readNode(_ element: AXUIElement, deadline: ContinuousClock.Instant) throws -> RawNode {
        let role: String? = try self.attribute(kAXRoleAttribute, on: element, deadline: deadline)
        guard let role, !role.isEmpty else { throw DialogHierarchyReadError.unreadable }
        let subrole: String? = try self.attribute(kAXSubroleAttribute, on: element, deadline: deadline)
        let description: String? = try self.attribute(kAXRoleDescriptionAttribute, on: element, deadline: deadline)
        let identifier: String? = try self.attribute(kAXIdentifierAttribute, on: element, deadline: deadline)
        let title: String? = try self.attribute(kAXTitleAttribute, on: element, deadline: deadline)
        let modal: Bool? = try self.attribute(kAXModalAttribute, on: element, deadline: deadline)
        let sheets: [AXUIElement]? = try self.attribute("AXSheets", on: element, deadline: deadline)
        let children: [AXUIElement]? = try self.attribute(kAXChildrenAttribute, on: element, deadline: deadline)
        return RawNode(
            evidence: DialogElementEvidence(
                role: role,
                subrole: subrole ?? "",
                roleDescription: description ?? "",
                identifier: identifier ?? "",
                title: title ?? "",
                isModal: modal),
            children: ((sheets ?? []) + (children ?? [])).map { ReadOnlyAXIdentity(element: $0) })
    }

    private static func attribute<Value>(
        _ name: String,
        on element: AXUIElement,
        deadline: ContinuousClock.Instant) throws -> Value?
    {
        guard ContinuousClock.now < deadline else { throw DialogHierarchyReadError.deadlineExceeded }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        guard ContinuousClock.now < deadline else { throw DialogHierarchyReadError.deadlineExceeded }
        return try self.attributeValue(value, error: error)
    }

    static func attributeValue<Value>(_ value: CFTypeRef?, error: AXError) throws -> Value? {
        switch error {
        case .attributeUnsupported, .noValue:
            return nil
        case .success:
            guard let value else { throw DialogHierarchyReadError.unreadable }
            // CF reference array casts alone do not validate each element's runtime type.
            if Value.self == [AXUIElement].self {
                guard CFGetTypeID(value) == CFArrayGetTypeID(),
                      let elements = value as? [AnyObject],
                      elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
                else { throw DialogHierarchyReadError.unreadable }
            }
            if Value.self == Bool.self, CFGetTypeID(value) != CFBooleanGetTypeID() {
                throw DialogHierarchyReadError.unreadable
            }
            guard let typedValue = value as? Value else { throw DialogHierarchyReadError.unreadable }
            return typedValue
        default:
            throw DialogHierarchyReadError.unreadable
        }
    }

    private struct RawNode: Sendable {
        let evidence: DialogElementEvidence
        let children: [ReadOnlyAXIdentity]
    }

    /// The AX C API is thread-safe, but its CF identity is not annotated Sendable. These immutable
    /// retains are read-only even after cancellation: the worker never sets attributes or timeouts.
    /// AXorcist wrappers are accessed/created only on MainActor, after the worker result is admitted.
    private struct ReadOnlyAXIdentity: @unchecked Sendable {
        let element: AXUIElement
    }
}
