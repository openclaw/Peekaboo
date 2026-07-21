import Testing
@testable import PeekabooAutomationKit

struct DialogElementTraversalTests {
    @Test
    func `cycles and shared nodes are visited once in pre-order`() {
        let dialog = TraversalNode(name: "dialog")
        let firstGroup = TraversalNode(name: "first group")
        let secondGroup = TraversalNode(name: "second group")
        let primaryButton = TraversalNode(name: "primary button", isMatch: true)
        let sharedButton = TraversalNode(name: "shared button", isMatch: true)
        let secondaryButton = TraversalNode(name: "secondary button", isMatch: true)

        dialog.children = [firstGroup, secondGroup]
        firstGroup.children = [primaryButton, sharedButton]
        primaryButton.children = [dialog]
        secondGroup.children = [sharedButton, secondaryButton]

        let matches = collectUniqueDepthFirst(
            from: dialog,
            matching: { $0.isMatch },
            children: { $0.children })

        #expect(matches.map(\.name) == ["primary button", "shared button", "secondary button"])
    }

    @Test
    func `first match terminates a cyclic traversal in pre-order`() {
        let dialog = TraversalNode(name: "dialog")
        let firstGroup = TraversalNode(name: "first group")
        let secondGroup = TraversalNode(name: "second group")
        let primaryButton = TraversalNode(name: "primary button", isMatch: true)
        let secondaryButton = TraversalNode(name: "secondary button", isMatch: true)
        var inspected: [String] = []

        dialog.children = [firstGroup, secondGroup]
        firstGroup.children = [dialog, primaryButton]
        secondGroup.children = [secondaryButton]

        let match = firstUniqueDepthFirst(
            from: dialog,
            matching: {
                inspected.append($0.name)
                return $0.isMatch
            },
            children: { $0.children })

        #expect(match === primaryButton)
        #expect(inspected == ["dialog", "first group", "primary button"])
    }

    @Test
    func `deep hierarchies do not consume the call stack`() {
        let root = TraversalNode(name: "0")
        var nodes = [root]
        var current = root

        for index in 1...20000 {
            let child = TraversalNode(name: "\(index)", isMatch: index == 20000)
            current.children = [child]
            nodes.append(child)
            current = child
        }

        let matches = collectUniqueDepthFirst(
            from: root,
            matching: { $0.isMatch },
            children: { $0.children })

        #expect(matches.count == 1)
        #expect(matches.first === current)

        for node in nodes {
            node.children.removeAll()
        }
    }
}

private final class TraversalNode: Hashable {
    let name: String
    let isMatch: Bool
    var children: [TraversalNode] = []

    init(name: String, isMatch: Bool = false) {
        self.name = name
        self.isMatch = isMatch
    }

    static func == (lhs: TraversalNode, rhs: TraversalNode) -> Bool {
        lhs === rhs
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}
