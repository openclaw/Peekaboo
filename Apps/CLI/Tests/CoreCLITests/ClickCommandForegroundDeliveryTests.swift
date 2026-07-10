import CoreGraphics
import PeekabooCore
import Testing
@testable import PeekabooCLI

/// `--foreground` is documented as "focus target and send a foreground mouse click". Element and
/// query targets must therefore be dispatched as real coordinate clicks once their screen point
/// is resolved, instead of silently degrading to an AX press that ignores focus entirely.
struct ClickCommandForegroundDeliveryTests {
    @Test
    @MainActor
    func `element target becomes a coordinate click at the resolved point`() {
        let converted = ClickCommand.foregroundMouseTarget(
            for: .elementId("B7"),
            resolvedPoint: CGPoint(x: 2396, y: 162)
        )

        guard case let .coordinates(point) = converted else {
            Issue.record("Expected coordinate click, got \(converted)")
            return
        }
        #expect(point == CGPoint(x: 2396, y: 162))
    }

    @Test
    @MainActor
    func `query target becomes a coordinate click at the resolved point`() {
        let converted = ClickCommand.foregroundMouseTarget(
            for: .query("Send"),
            resolvedPoint: CGPoint(x: 10, y: 20)
        )

        guard case let .coordinates(point) = converted else {
            Issue.record("Expected coordinate click, got \(converted)")
            return
        }
        #expect(point == CGPoint(x: 10, y: 20))
    }

    @Test
    @MainActor
    func `unresolved element point keeps the element target`() {
        let converted = ClickCommand.foregroundMouseTarget(
            for: .elementId("B7"),
            resolvedPoint: nil
        )

        guard case let .elementId(id) = converted else {
            Issue.record("Expected element click, got \(converted)")
            return
        }
        #expect(id == "B7")
    }

    @Test
    @MainActor
    func `coordinate targets pass through unchanged`() {
        let converted = ClickCommand.foregroundMouseTarget(
            for: .coordinates(CGPoint(x: 1, y: 2)),
            resolvedPoint: CGPoint(x: 99, y: 99)
        )

        guard case let .coordinates(point) = converted else {
            Issue.record("Expected coordinate click, got \(converted)")
            return
        }
        #expect(point == CGPoint(x: 1, y: 2))
    }
}
