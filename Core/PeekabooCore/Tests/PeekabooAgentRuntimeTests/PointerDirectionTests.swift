import CoreGraphics
import Testing
@testable import PeekabooAgentRuntime

struct PointerDirectionTests {
    @Test(arguments: [
        (10.0, 0.0, "E"), (10.0, 10.0, "SE"), (0.0, 10.0, "S"), (-10.0, 10.0, "SW"),
        (-10.0, 0.0, "W"), (-10.0, -10.0, "NW"), (0.0, -10.0, "N"), (10.0, -10.0, "NE"),
    ])
    func `screen deltas have the correct compass direction`(_ vector: (Double, Double, String)) {
        let start = CGPoint(x: 100, y: 200)
        let end = CGPoint(x: start.x + vector.0, y: start.y + vector.1)
        #expect(pointerDirection(from: start, to: end) == vector.2)
    }

    @Test
    func `stationary and sub point moves have no direction`() {
        #expect(pointerDirection(from: .zero, to: .zero) == nil)
        #expect(pointerDirection(from: .zero, to: CGPoint(x: 0.2, y: 0.2)) == nil)
    }
}
