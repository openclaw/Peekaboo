@preconcurrency import AXorcist
import Foundation
import os.log
import PeekabooFoundation

/// Traverses an AX element subtree and converts it into Peekaboo detection elements.
@MainActor
struct AXTreeCollector {
    struct Result {
        let elements: [DetectedElement]
        let elementIdMap: [String: DetectedElement]
        let truncationInfo: DetectionTruncationInfo?
    }

    private struct TraversalState {
        var elements: [DetectedElement]
        var elementIdMap: [String: DetectedElement]
        var visitedElements: Set<Element>
        var truncationFlags: TruncationFlags

        @MainActor
        init() {
            self.elements = []
            self.elementIdMap = [:]
            self.visitedElements = Set<Element>()
            self.truncationFlags = TruncationFlags()
        }
    }

    private struct TruncationFlags {
        var maxDepthReached = false
        var maxElementCountReached = false
        var maxChildrenPerNodeReached = false

        var isEmpty: Bool {
            !self.maxDepthReached && !self.maxElementCountReached && !self.maxChildrenPerNodeReached
        }

        func toInfo() -> DetectionTruncationInfo {
            DetectionTruncationInfo(
                maxDepthReached: self.maxDepthReached,
                maxElementCountReached: self.maxElementCountReached,
                maxChildrenPerNodeReached: self.maxChildrenPerNodeReached)
        }
    }

    private static let textualRoles: Set<String> = [
        "axstatictext",
        "axtext",
        "axbutton",
        "axlink",
        "axdescription",
        "axunknown",
    ]
    private static let textFieldRoles: Set<String> = [
        "axtextfield",
        "axtextarea",
        "axsearchfield",
        "axsecuretextfield",
    ]

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "AXTreeCollector")

    func collect(window: Element, deadline: Date, budget: AXTraversalBudget? = nil) -> Result {
        var state = TraversalState()
        let resolvedBudget = AXTraversalBudget.normalizedForTraversal(budget)

        // Traverse only the captured window. Walking the app root also visits sibling windows,
        // which makes `see --app` slower and returns elements outside the screenshot.
        self.processElement(
            window,
            depth: 0,
            deadline: deadline,
            budget: resolvedBudget,
            state: &state)

        let truncationInfo: DetectionTruncationInfo? = state.truncationFlags.isEmpty
            ? nil
            : state.truncationFlags.toInfo()
        return Result(
            elements: state.elements,
            elementIdMap: state.elementIdMap,
            truncationInfo: truncationInfo)
    }

    private func processElement(
        _ element: Element,
        depth: Int,
        deadline: Date,
        budget: AXTraversalBudget,
        state: inout TraversalState)
    {
        guard depth < budget.maxDepth else {
            state.truncationFlags.maxDepthReached = true
            return
        }
        guard !Task.isCancelled else { return }
        guard Date() < deadline else { return }
        guard state.elements.count < budget.maxElementCount else {
            state.truncationFlags.maxElementCountReached = true
            return
        }
        guard state.visitedElements.insert(element).inserted else { return }
        guard let descriptor = AXDescriptorReader.describe(element) else { return }

        self.logButtonDebugInfoIfNeeded(descriptor)

        let elementId = "elem_\(state.elements.count)"
        let baseType = ElementClassifier.elementType(for: descriptor.role)
        let elementType = self.adjustedElementType(element: element, descriptor: descriptor, baseType: baseType)
        let isActionable = self.isElementActionable(element, role: descriptor.role)
        let keyboardShortcut = isActionable ? self.extractKeyboardShortcut(element, role: descriptor.role) : nil
        let label = self.effectiveLabel(for: element, descriptor: descriptor)

        let attributes = ElementClassifier.attributes(
            from: ElementClassifier.AttributeInput(
                role: descriptor.role,
                title: descriptor.title,
                description: descriptor.description,
                help: descriptor.help,
                roleDescription: descriptor.roleDescription,
                identifier: descriptor.identifier,
                isActionable: isActionable,
                keyboardShortcut: keyboardShortcut,
                placeholder: descriptor.placeholder))

        let detectedElement = DetectedElement(
            id: elementId,
            type: elementType,
            label: label,
            value: descriptor.value,
            bounds: descriptor.frame,
            isEnabled: descriptor.isEnabled,
            isSelected: nil,
            attributes: attributes)

        state.elements.append(detectedElement)
        state.elementIdMap[elementId] = detectedElement

        self.processChildren(
            of: element,
            depth: depth + 1,
            deadline: deadline,
            budget: budget,
            state: &state)
    }

    private func processChildren(
        of element: Element,
        depth: Int,
        deadline: Date,
        budget: AXTraversalBudget,
        state: inout TraversalState)
    {
        guard !Task.isCancelled else { return }
        guard let children = element.children() else { return }
        if children.count > budget.maxChildrenPerNode {
            state.truncationFlags.maxChildrenPerNodeReached = true
        }
        let limitedChildren = children.prefix(budget.maxChildrenPerNode)
        for child in limitedChildren {
            guard state.elements.count < budget.maxElementCount else {
                state.truncationFlags.maxElementCountReached = true
                break
            }
            self.processElement(
                child,
                depth: depth,
                deadline: deadline,
                budget: budget,
                state: &state)
        }
    }

    private func logButtonDebugInfoIfNeeded(_ descriptor: AXDescriptorReader.Descriptor) {
        guard descriptor.role.lowercased() == "axbutton" else { return }
        let parts = [
            "title: '\(descriptor.title ?? "nil")'",
            "label: '\(descriptor.label ?? "nil")'",
            "value: '\(descriptor.value ?? "nil")'",
            "roleDescription: '\(descriptor.roleDescription ?? "nil")'",
            "description: '\(descriptor.description ?? "nil")'",
            "identifier: '\(descriptor.identifier ?? "nil")'",
        ]
        self.logger.debug("🔍 Button debug - \(parts.joined(separator: ", "))")
    }

    private func effectiveLabel(for element: Element, descriptor: AXDescriptorReader.Descriptor) -> String? {
        let info = ElementLabelInfo(
            role: descriptor.role,
            label: descriptor.label,
            title: descriptor.title,
            value: descriptor.value,
            roleDescription: descriptor.roleDescription,
            description: descriptor.description,
            identifier: descriptor.identifier,
            placeholder: descriptor.placeholder)

        let childTexts = ElementLabelResolver.needsChildTexts(info: info)
            ? self.textualDescendants(of: element)
            : []
        return ElementLabelResolver.resolve(
            info: info,
            childTexts: childTexts,
            identifierCleaner: self.cleanedIdentifier)
    }

    private func textualDescendants(of element: Element, depth: Int = 0, limit: Int = 4) -> [String] {
        guard depth < 3, limit > 0, !Task.isCancelled,
              let children = element.children(), !children.isEmpty
        else {
            return []
        }

        var results: [String] = []
        for child in children {
            if let role = child.role()?.lowercased(),
               Self.textualRoles.contains(role)
            {
                if let candidate = child.title() ?? child.label() ?? child.stringValue() ?? child.descriptionText() {
                    let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !normalized.isEmpty {
                        results.append(normalized)
                        if results.count >= limit { break }
                    }
                }
            }

            if results.count >= limit { break }

            let remaining = limit - results.count
            let nested = self.textualDescendants(of: child, depth: depth + 1, limit: remaining)
            results.append(contentsOf: nested)
            if results.count >= limit { break }
        }

        return results
    }

    private func cleanedIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "-button", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    private func adjustedElementType(
        element: Element,
        descriptor: AXDescriptorReader.Descriptor,
        baseType: ElementType) -> ElementType
    {
        let input = ElementTypeAdjustmentInput(
            role: descriptor.role,
            roleDescription: descriptor.roleDescription,
            title: descriptor.title,
            label: descriptor.label,
            placeholder: descriptor.placeholder,
            isEditable: baseType == .group && element.isEditable() == true)
        let hasTextFieldDescendant = ElementTypeAdjuster.shouldScanForTextFieldDescendant(
            baseType: baseType,
            input: input) && self.containsTextFieldDescendant(element, remainingDepth: 2)

        return ElementTypeAdjuster.resolve(
            baseType: baseType,
            input: input,
            hasTextFieldDescendant: hasTextFieldDescendant)
    }

    private func containsTextFieldDescendant(_ element: Element, remainingDepth: Int) -> Bool {
        guard !Task.isCancelled else { return false }
        guard remainingDepth >= 0 else { return false }
        guard let children = element.children(strict: true) else { return false }

        for child in children {
            if let role = child.role()?.lowercased(),
               Self.textFieldRoles.contains(role)
            {
                return true
            }

            if child.isEditable() == true {
                return true
            }

            if self.containsTextFieldDescendant(child, remainingDepth: remainingDepth - 1) {
                return true
            }
        }

        return false
    }

    private func isElementActionable(_ element: Element, role: String) -> Bool {
        if ElementClassifier.roleIsActionable(role) {
            return true
        }

        guard ElementClassifier.shouldLookupActions(for: role) else {
            return false
        }

        // Action lookup is another AX round-trip; only pay it for container-ish roles that can hide AXPress.
        return element.supportedActions()?.contains("AXPress") == true
    }

    private func extractKeyboardShortcut(_ element: Element, role: String) -> String? {
        guard ElementClassifier.supportsKeyboardShortcut(for: role) else {
            return nil
        }

        if let shortcut = element.keyboardShortcut() {
            return shortcut
        }

        if let description = element.descriptionText(),
           description.contains("⌘") || description.contains("⌥") || description.contains("⌃")
        {
            return description
        }

        return nil
    }
}

extension AXTraversalBudget {
    static func normalizedForTraversal(_ budget: AXTraversalBudget?) -> AXTraversalBudget {
        (budget ?? AXTraversalBudget.resolved()).normalizedForTraversal
    }

    var normalizedForTraversal: AXTraversalBudget {
        AXTraversalBudget(
            maxDepth: max(0, self.maxDepth),
            maxElementCount: max(0, self.maxElementCount),
            maxChildrenPerNode: max(0, self.maxChildrenPerNode))
    }
}
