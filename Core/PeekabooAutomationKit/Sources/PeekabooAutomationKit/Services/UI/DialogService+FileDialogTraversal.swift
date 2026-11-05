import AXorcist
import Foundation
import PeekabooFoundation

@MainActor
extension DialogService {
    func visitFileDialogTree(
        from root: Element,
        execution: FileExecution?,
        budget: DialogOperationDeadline,
        maximumDepth: Int? = nil,
        allowRootDialog: Bool = true,
        visit: (Element, DialogHierarchyNode) async throws -> Bool) async throws -> Bool
    {
        var visited: Set<Element> = []
        var stack = [(root, 0)]
        while let (element, depth) = stack.popLast() {
            try budget.check()
            guard visited.insert(element).inserted else { continue }
            // Legacy AX reads have no worker isolation; cap their traversal as well as their deadline.
            if execution == nil, visited.count > 4096 {
                throw PeekabooError.accessibilityIncomplete("File dialog traversal exceeded its node limit.")
            }
            let node: DialogHierarchyNode = if let execution {
                try await self.discoveryReaders.hierarchyNode(
                    element, execution.target.identity.processIdentity, budget)
            } else {
                DialogHierarchyNode(
                    evidence: DialogElementClassifier.evidence(for: element),
                    children: self.sheetFirstTraversalChildren(for: element))
            }
            if element != root || !allowRootDialog {
                if ["AXApplication", "AXWindow"].contains(node.evidence.role) ||
                    DialogElementClassifier.isStructuralDialog(node.evidence)
                {
                    continue
                }
            }
            let matched = try await visit(element, node)
            try budget.check()
            if matched {
                return true
            }
            if maximumDepth.map({ depth < $0 }) ?? true {
                stack.append(contentsOf: node.children.reversed().map { ($0, depth + 1) })
            }
        }
        return false
    }
}
