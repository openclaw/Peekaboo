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
}
