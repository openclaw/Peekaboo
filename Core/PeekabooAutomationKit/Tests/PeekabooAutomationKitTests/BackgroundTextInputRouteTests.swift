import ApplicationServices
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct BackgroundTextInputRouteTests {
    private typealias Node = BackgroundTextInputRoute.Node<Int>
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
        let route = BackgroundTextInputRoute.resolve(
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
        let route = BackgroundTextInputRoute.resolve(
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
        let route = BackgroundTextInputRoute.resolve(
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
        let route = BackgroundTextInputRoute.resolve(
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
        let route = BackgroundTextInputRoute.resolve(
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
            _ = try BackgroundTextInputRoute.unproven.permitsAccessibilityEditing()
            Issue.record("Expected route refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }
    }

    @Test
    func `focus confirmation accepts native and numeric AX booleans`() {
        #expect(BackgroundTextInputRoute.confirmsFocus(true))
        #expect(BackgroundTextInputRoute.confirmsFocus(NSNumber(value: 1)))
        #expect(!BackgroundTextInputRoute.confirmsFocus(false))
        #expect(!BackgroundTextInputRoute.confirmsFocus(NSNumber(value: 0)))
        #expect(!BackgroundTextInputRoute.confirmsFocus(nil))
        #expect(!BackgroundTextInputRoute.confirmsFocus("true"))
    }

    @Test(arguments: [false, true])
    func `failed timeout arm or reset prevents route authorization`(failsReset: Bool) {
        var timeoutCalls: [Float] = []
        var readCount = 0
        var receiverValidationCount = 0
        let route = BackgroundTextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: Self.processIdentifier,
            readNode: { _, timeout in
                BackgroundTextInputRoute.readWithTimeout(
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
        let value = BackgroundTextInputRoute.readWithTimeout(
            timeout: 0.05,
            applyTimeout: { timeoutCalls.append($0); return .success },
            read: { readable ? 7 : nil })
        #expect(value == (readable ? 7 : nil))
        #expect(timeoutCalls == [0.05, 0])
    }

    @Test(arguments: [SpecialKey.return, .tab, .escape, .upArrow, .f1])
    func `event only keys never resolve a focused AX receiver`(key: SpecialKey) throws {
        // An invalid PID would fail target validation if the AX editing path were entered.
        #expect(try BackgroundInputDriver.performFocusedTextKey(key, targetProcessIdentifier: -1) == .unsupported)
    }

    private static func resolve(_ nodes: [Int: Node], receiverMatches: Bool = true) -> BackgroundTextInputRoute {
        BackgroundTextInputRoute.resolve(
            from: 0,
            targetProcessIdentifier: self.processIdentifier,
            readNode: { element, _ in nodes[element] },
            sameElement: ==,
            validateReceiver: { _ in receiverMatches })
    }
}

@MainActor
struct BackgroundTextRouteRefusalTests {
    @Test(arguments: [TypeAction.text("x"), .key(.delete), .clear])
    func `known first unit routing refusal remains retry safe`(action: TypeAction) async throws {
        var keyTapCount = 0
        let service = Self.service(keyTap: { keyTapCount += 1 })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [action], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
            Issue.record("Expected route refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.projection.retrySafe)
        }
        #expect(keyTapCount == 0)
    }

    @Test(arguments: [TypeAction.text("x"), .key(.delete), .clear])
    func `routing refusal after a delivered prefix stays retry unsafe`(action: TypeAction) async throws {
        var keyTapCount = 0
        let service = Self.service(keyTap: { keyTapCount += 1 })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.text("a"), action], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
            Issue.record("Expected partial delivery failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == 1)
            #expect(!error.retrySafe)
            #expect(error.delivery == .init(mechanism: .processTargetedEvents, mode: .background))
        }
        #expect(keyTapCount == 0)
    }

    @Test
    func `unknown driver failure is not reclassified as a safe refusal`() async throws {
        let service = TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { _, _, _ in throw TestFailure.unknown })

        do {
            _ = try await service.typeActionsTrackingSecureInput(
                [.text("x")], cadence: .fixed(milliseconds: 0), snapshotId: nil, targetProcessIdentifier: 42)
            Issue.record("Expected unknown delivery failure")
        } catch let error as InputDeliveryIndeterminateError {
            #expect(error.emittedUnitCount == nil)
            #expect(!error.retrySafe)
        }
    }

    private enum TestFailure: Error {
        case unknown
    }

    private static func service(keyTap: @escaping @MainActor () -> Void) -> TypeService {
        TypeService(
            randomSource: SystemTypingCadenceRandomSource(),
            focusedElementSecurityProbe: { _ in false },
            targetedCharacterTyper: { character, _, delivery in
                if character == "a" {
                    return .dispatched(delivery: delivery, keyPressCount: 1)
                }
                _ = try BackgroundTextInputRoute.unproven.permitsAccessibilityEditing()
                return .noChange
            },
            targetedSpecialKeyTyper: { _, _, _ in
                _ = try BackgroundTextInputRoute.unproven.permitsAccessibilityEditing()
                return .noChange
            },
            targetedKeyTapper: { _, _, _ in keyTap() },
            targetedTextReplacer: { _, _ in try BackgroundTextInputRoute.unproven.permitsAccessibilityEditing() })
    }
}
