import ApplicationServices
import AXorcist
import Foundation
import PeekabooFoundation

struct DialogHierarchyNode: Sendable {
    let evidence: DialogElementEvidence
    let children: [Element]
}

enum DialogHierarchyReader {
    @MainActor
    static func read(
        _ element: Element,
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline) async throws -> DialogHierarchyNode
    {
        let identity = ReadOnlyAXIdentity(element: element.underlyingElement)
        let result = try await self.run(owner: owner, budget: budget) {
            try self.readNode(identity.element, budget: budget)
        }
        var seen: Set<Element> = []
        let children = result.children.map { Element($0.element) }.filter { seen.insert($0).inserted }
        return DialogHierarchyNode(evidence: result.evidence, children: children)
    }

    static func run<Output: Sendable>(
        owner: ApplicationProcessIdentity,
        budget: DialogOperationDeadline,
        operation: @escaping @Sendable () throws -> Output) async throws -> Output
    {
        try budget.check()
        // Only C reads run here: no AXorcist caches, messaging-timeout changes, service state,
        // or mutation callbacks can outlive the caller.
        do {
            let result = try await ElementDetectionTimeoutRunner.runDetached(
                targetProcessIdentifier: owner.processIdentifier,
                targetProcessStartIdentity: owner.processStartIdentity,
                seconds: budget.remainingSeconds,
                maximumPendingOperationCount: 1)
            {
                try budget.check()
                return try operation()
            }
            try budget.check()
            return result
        } catch CaptureError.detectionTimedOut {
            throw budget.timeoutError
        }
    }

    private static func readNode(_ element: AXUIElement, budget: DialogOperationDeadline) throws -> RawNode {
        let role: String? = try self.attribute(kAXRoleAttribute, on: element, budget: budget)
        guard let role, !role.isEmpty else { throw self.unreadable }
        let subrole: String? = try self.attribute(kAXSubroleAttribute, on: element, budget: budget)
        let description: String? = try self.attribute(kAXRoleDescriptionAttribute, on: element, budget: budget)
        let identifier: String? = try self.attribute(kAXIdentifierAttribute, on: element, budget: budget)
        let title: String? = try self.attribute(kAXTitleAttribute, on: element, budget: budget)
        let modal: Bool? = try self.attribute(kAXModalAttribute, on: element, budget: budget)
        let sheets: [AXUIElement]? = try self.attribute("AXSheets", on: element, budget: budget)
        let children: [AXUIElement]? = try self.attribute(kAXChildrenAttribute, on: element, budget: budget)
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
        budget: DialogOperationDeadline) throws -> Value?
    {
        try budget.check()
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        try budget.check()
        return try self.attributeValue(value, error: error)
    }

    static func attributeValue<Value>(_ value: CFTypeRef?, error: AXError) throws -> Value? {
        switch error {
        case .attributeUnsupported, .noValue:
            return nil
        case .success:
            guard let value else { throw self.unreadable }
            // CF reference array casts alone do not validate each element's runtime type.
            if Value.self == [AXUIElement].self {
                guard CFGetTypeID(value) == CFArrayGetTypeID(),
                      let elements = value as? [AnyObject],
                      elements.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() })
                else { throw self.unreadable }
            }
            if Value.self == Bool.self, CFGetTypeID(value) != CFBooleanGetTypeID() {
                throw self.unreadable
            }
            guard let typedValue = value as? Value else { throw self.unreadable }
            return typedValue
        default:
            throw self.unreadable
        }
    }

    private static var unreadable: PeekabooError {
        .accessibilityIncomplete("Dialog hierarchy classification or children could not be read completely.")
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
