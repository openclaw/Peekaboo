import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class GestureServiceTests: XCTestCase {
    func testDragModifierKeysNormalizeAliasesAndIgnoreUnknownValues() {
        let keys = GestureService.heldModifierKeys(for: " command, cmd, shift, alt, ctrl, fn, unknown ")

        XCTAssertEqual(keys.map(\.name), ["command", "shift", "option", "control", "function"])
        XCTAssertEqual(keys.map(\.keyCode), [0x37, 0x38, 0x3A, 0x3B, 0x3F])
        XCTAssertEqual(
            keys.map(\.flag),
            [.maskCommand, .maskShift, .maskAlternate, .maskControl, .maskSecondaryFn])
    }

    func testHumanMousePathUsesBoundedEasedSamplesAndExactEndpoint() throws {
        let start = CGPoint(x: 40, y: 80)
        let target = CGPoint(x: 1040, y: 680)
        let path = HumanMousePathGenerator(
            start: start,
            target: target,
            distance: hypot(target.x - start.x, target.y - start.y),
            duration: 1200,
            stepsHint: 500,
            configuration: HumanMouseProfileConfiguration(
                jitterAmplitude: 0,
                overshootProbability: 0,
                randomSeed: 42))
            .generate()

        XCTAssertEqual(path.points.count, 96)
        XCTAssertEqual(try XCTUnwrap(path.points.last), target)

        let firstStep = try Self.distance(start, XCTUnwrap(path.points.first))
        let middle = path.points.count / 2
        let middleStep = Self.distance(path.points[middle - 1], path.points[middle])
        let finalStep = Self.distance(path.points[path.points.count - 2], target)
        XCTAssertLessThan(firstStep, middleStep)
        XCTAssertLessThan(finalStep, middleStep)
    }

    func testHumanMousePathHonorsExplicitSampleCountAndCurves() {
        let start = CGPoint(x: 0, y: 0)
        let target = CGPoint(x: 500, y: 0)
        let path = HumanMousePathGenerator(
            start: start,
            target: target,
            distance: 500,
            duration: 600,
            stepsHint: 8,
            configuration: HumanMouseProfileConfiguration(
                jitterAmplitude: 0,
                overshootProbability: 0,
                randomSeed: 7))
            .generate()

        XCTAssertEqual(path.points.count, 8)
        XCTAssertEqual(path.points.last, target)
        XCTAssertGreaterThan(path.points.map { abs($0.y) }.max() ?? 0, 1)
        XCTAssertLessThan(path.points.map { abs($0.y) }.max() ?? .infinity, 50)
    }

    func testHumanMousePathHonorsZeroDuration() {
        let path = HumanMousePathGenerator(
            start: .zero,
            target: CGPoint(x: 100, y: 100),
            distance: hypot(100, 100),
            duration: 0,
            stepsHint: 8,
            configuration: HumanMouseProfileConfiguration(randomSeed: 7))
            .generate()

        XCTAssertEqual(path.duration, 0)
        XCTAssertEqual(path.points.last, CGPoint(x: 100, y: 100))
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }
}
