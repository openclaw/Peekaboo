import AXorcist

enum DialogTraversal {
    static func collectUniqueDepthFirst<Node: Hashable>(
        from root: Node,
        matching predicate: (Node) -> Bool,
        children: (Node) -> [Node]) -> [Node]
    {
        var matches: [Node] = []
        _ = self.visitUniqueDepthFirst(
            from: root,
            children: children,
            stopWhen: { node in
                if predicate(node) {
                    matches.append(node)
                }
                return false
            })
        return matches
    }

    static func firstUniqueDepthFirst<Node: Hashable>(
        from root: Node,
        matching predicate: (Node) -> Bool,
        children: (Node) -> [Node]) -> Node?
    {
        self.visitUniqueDepthFirst(
            from: root,
            children: children,
            stopWhen: predicate)
    }

    private static func visitUniqueDepthFirst<Node: Hashable>(
        from root: Node,
        children: (Node) -> [Node],
        stopWhen predicate: (Node) -> Bool) -> Node?
    {
        var visited: Set<Node> = []
        var stack = [root]

        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }

            if predicate(node) {
                return node
            }

            stack.append(contentsOf: children(node).reversed())
        }

        return nil
    }

    static func sheetFirstChildren<Node: Hashable>(
        children: [Node],
        attachedSheets: [Node],
        isSheet: (Node) -> Bool) -> [Node]
    {
        var childSheets: [Node] = []
        var ordinaryChildren: [Node] = []

        for child in children {
            if isSheet(child) {
                childSheets.append(child)
            } else {
                ordinaryChildren.append(child)
            }
        }

        var ordered: [Node] = []
        ordered.reserveCapacity(children.count + attachedSheets.count)
        var visited: Set<Node> = []

        for group in [childSheets, attachedSheets, ordinaryChildren] {
            for child in group where visited.insert(child).inserted {
                ordered.append(child)
            }
        }

        return ordered
    }
}

@MainActor
extension DialogService {
    func sheetFirstTraversalChildren(for element: Element) -> [Element] {
        let children = element.children() ?? []
        let attachedSheets = element.sheets() ?? []
        return DialogTraversal.sheetFirstChildren(
            children: children,
            attachedSheets: attachedSheets,
            isSheet: { $0.role() == "AXSheet" })
    }
}
