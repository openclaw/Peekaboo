import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct TextInputRouteTests {
    private typealias Node = TextInputRoute.Node<Int>
    private static let processIdentifier: pid_t = 42

    @Test(arguments: ["AXWindow", "AXApplication"])
    func `complete native ancestry retains AX editing`(rootRole: String) throws {
        let route = Self.resolve([
            0: Node(role: "AXTextField", processIdentifier: Self.processIdentifier, parent: 1),
            1: Node(role: "AXGroup", processIdentifier: Self.processIdentifier, parent: 2),
            2: Node(role: rootRole, processIdentifier: Self.processIdentifier, parent: nil),
        ])
        #expect(route == .nativeAX)
        #expect(try route.permitsAccessibilityEditing())
    }

    @Test(arguments: [0, 1, 8])
    func `web ancestry selects keyboard instead of AX editing`(depth: Int) throws {
        var nodes: [Int: Node] = [:]
        for index in 0..<depth {
            nodes[index] = Node(role: "AXGroup", processIdentifier: Self.processIdentifier, parent: index + 1)
        }
        nodes[depth] = Node(role: "AXWebArea", processIdentifier: Self.processIdentifier, parent: nil)

        let route = Self.resolve(nodes)

        #expect(route == .webKeyboard)
        #expect(try !route.permitsAccessibilityEditing())
    }

    @Test(arguments: ["AXWindow", "AXApplication", "AXWebArea"])
    func `foreign process boundary cannot authorize either route`(role: String) {
        #expect(Self.resolve([
            0: Node(role: "AXTextField", processIdentifier: Self.processIdentifier, parent: 1),
            1: Node(role: role, processIdentifier: 73, parent: nil),
        ]) == .unproven)
    }

    @Test
    func `unreadable node empty role and incomplete ancestry refuse`() {
        #expect(Self.resolve([:]) == .unproven)
        #expect(Self.resolve([
            0: Node(role: "", processIdentifier: Self.processIdentifier, parent: 1),
            1: Node(role: "AXWindow", processIdentifier: Self.processIdentifier, parent: nil),
        ]) == .unproven)
        #expect(Self.resolve([
            0: Node(role: "AXTextField", processIdentifier: Self.processIdentifier, parent: nil),
        ]) == .unproven)
    }

    @Test(arguments: [0, 1])
    func `identity cycles refuse without exhausting the visit cap`(cycleStart: Int) {
        var reads: [Int] = []
        let nodes = [
            0: Node(role: "AXTextField", processIdentifier: Self.processIdentifier, parent: 1),
            1: Node(role: "AXGroup", processIdentifier: Self.processIdentifier, parent: cycleStart),
        ]
        let route = TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            readNode: { element, _ in
                reads.append(element)
                return nodes[element]
            },
            sameElement: ==,
            validateReceiver: { _ in true })

        #expect(route == .unproven)
        #expect(reads == [0, 1])
    }

    @Test(arguments: [0, 1, 2])
    func `node budget never accepts a truncated nonweb prefix`(maxNodes: Int) {
        var readCount = 0
        let route = TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            maxNodes: maxNodes,
            readNode: { element, _ in
                readCount += 1
                return Node(
                    role: element == 1 ? "AXWindow" : "AXTextField",
                    processIdentifier: Self.processIdentifier,
                    parent: element == 1 ? nil : 1)
            },
            sameElement: ==,
            validateReceiver: { _ in true })

        #expect(route == (maxNodes == 2 ? .nativeAX : .unproven))
        #expect(readCount == maxNodes)
    }

    @Test(arguments: ["AXWindow", "AXWebArea"])
    func `receiver drift after classification refuses both routes`(role: String) {
        #expect(Self.resolve([
            0: Node(role: role, processIdentifier: Self.processIdentifier, parent: nil),
        ], receiverMatches: false) == .unproven)
    }

    @Test
    func `deadline during role read refuses even a terminal node`() {
        var clock: TimeInterval = 0
        var receiverValidationCount = 0
        let route = TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            now: { clock },
            readNode: { _, timeout in
                #expect(timeout > 0 && timeout <= 0.05)
                clock = 0.25
                return Node(role: "AXWebArea", processIdentifier: Self.processIdentifier, parent: nil)
            },
            sameElement: ==,
            validateReceiver: { _ in
                receiverValidationCount += 1
                return true
            })

        #expect(route == .unproven)
        #expect(receiverValidationCount == 0)
    }

    @Test
    func `deadline during receiver recheck refuses the classified route`() {
        var clock: TimeInterval = 0
        let route = TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            now: { clock },
            readNode: { _, _ in
                Node(role: "AXWebArea", processIdentifier: Self.processIdentifier, parent: nil)
            },
            sameElement: ==,
            validateReceiver: { _ in
                clock = 0.25
                return true
            })
        #expect(route == .unproven)
    }

    @Test(arguments: [false, true])
    func `cancellation before or during traversal refuses`(cancelDuringRead: Bool) {
        var cancelled = !cancelDuringRead
        var readCount = 0
        let route = TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            isCancelled: { cancelled },
            readNode: { _, _ in
                readCount += 1
                cancelled = true
                return Node(role: "AXWebArea", processIdentifier: Self.processIdentifier, parent: nil)
            },
            sameElement: ==,
            validateReceiver: { _ in true })

        #expect(route == .unproven)
        #expect(readCount == (cancelDuringRead ? 1 : 0))
    }

    @Test
    func `unknown route is a refusal not the keyboard fallback signal`() throws {
        do {
            _ = try TextInputRoute.unproven.permitsAccessibilityEditing()
            Issue.record("Expected route refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }
    }

    @Test
    func `focus confirmation accepts native and numeric AX booleans`() {
        #expect(TextInputRoute.confirmsFocus(true))
        #expect(TextInputRoute.confirmsFocus(NSNumber(value: 1)))
        #expect(!TextInputRoute.confirmsFocus(false))
        #expect(!TextInputRoute.confirmsFocus(NSNumber(value: 0)))
        #expect(!TextInputRoute.confirmsFocus(nil))
        #expect(!TextInputRoute.confirmsFocus("true"))
    }

    @Test(arguments: [false, true])
    func `failed timeout arm or reset prevents route authorization`(failsReset: Bool) {
        var timeoutCalls: [Float] = []
        var readCount = 0
        var receiverValidationCount = 0
        let route = TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            readNode: { _, timeout in
                TextInputRoute.readWithTimeout(
                    timeout: timeout,
                    applyTimeout: { value in
                        timeoutCalls.append(value)
                        return (value == 0) == failsReset ? .cannotComplete : .success
                    },
                    read: {
                        readCount += 1
                        return Node(role: "AXWindow", processIdentifier: Self.processIdentifier, parent: nil)
                    })
            },
            sameElement: ==,
            validateReceiver: { _ in
                receiverValidationCount += 1
                return true
            })
        #expect(route == .unproven)
        #expect(readCount == (failsReset ? 1 : 0))
        #expect(timeoutCalls.count == (failsReset ? 2 : 1))
        #expect(receiverValidationCount == 0)
    }

    @Test(arguments: [false, true])
    func `read timeout resets after readable and unreadable observations`(readable: Bool) {
        var timeoutCalls: [Float] = []
        let value = TextInputRoute.readWithTimeout(
            timeout: 0.05,
            applyTimeout: { timeoutCalls.append($0); return .success },
            read: { readable ? 7 : nil })
        #expect(value == (readable ? 7 : nil))
        #expect(timeoutCalls == [0.05, 0])
    }

    private static func resolve(_ nodes: [Int: Node], receiverMatches: Bool = true) -> TextInputRoute {
        TextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: self.processIdentifier,
            readNode: { element, _ in nodes[element] },
            sameElement: ==,
            validateReceiver: { _ in receiverMatches })
    }
}
