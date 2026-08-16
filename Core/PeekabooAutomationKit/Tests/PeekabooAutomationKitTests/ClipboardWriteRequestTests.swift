import AppKit
import PeekabooFoundation
import UniformTypeIdentifiers
import XCTest
@testable import PeekabooAutomationKit

@available(macOS 14.0, *)
@MainActor
final class ClipboardWriteRequestTests: XCTestCase {
    func testTextRepresentationsIncludePlainTextAndString() {
        let request = try? ClipboardPayloadBuilder.textRequest(text: "hello")
        let types = request?.representations.map(\.utiIdentifier) ?? []

        XCTAssertTrue(types.contains(UTType.plainText.identifier))
        XCTAssertTrue(types.contains(NSPasteboard.PasteboardType.string.rawValue))
        XCTAssertEqual(Set(types).count, types.count)
    }

    func testSetReturnsPreviewForUTF8PlainTextRepresentation() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let request = ClipboardWriteRequest(representations: [
            ClipboardRepresentation(utiIdentifier: UTType.utf8PlainText.identifier, data: Data("hello".utf8)),
        ])

        let result = try clipboard.set(request)

        XCTAssertEqual(result.textPreview, "hello")
    }

    func testSetCountsAlsoTextAgainstLargePayloadLimit() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard, sizeLimit: 4)
        let request = ClipboardWriteRequest(
            representations: [
                ClipboardRepresentation(utiIdentifier: "com.example.payload", data: Data([0x01])),
            ],
            alsoText: "oversized")

        XCTAssertThrowsError(try clipboard.set(request)) { error in
            guard case let ClipboardServiceError.sizeExceeded(current, limit) = error else {
                return XCTFail("Expected sizeExceeded, got \(error)")
            }
            XCTAssertGreaterThan(current, limit)
        }
    }

    func testResultAwareMutationsConfirmVerifiedPasteboardState() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let delivery = ClipboardMutationResultSemantics.delivery

        let set = try clipboard.setResult(ClipboardPayloadBuilder.textRequest(text: "stored"))
        XCTAssertEqual(set.outcome, .confirmedChange(delivery: delivery))

        try clipboard.save(slot: "fixture")
        _ = try clipboard.set(ClipboardPayloadBuilder.textRequest(text: "temporary"))
        let restore = try clipboard.restoreResult(slot: "fixture")
        XCTAssertEqual(restore.outcome, .confirmedChange(delivery: delivery))
        XCTAssertEqual(String(data: restore.payload.data, encoding: .utf8), "stored")

        let clear = try clipboard.clearResult()
        XCTAssertEqual(clear.outcome, .confirmedChange(delivery: delivery))
        XCTAssertNil(try clipboard.get(prefer: nil))
    }

    func testResultAwareSetValidationRefusesWithoutPasteboardDispatch() {
        let pasteboard = NSPasteboard.withUniqueName()
        let clipboard = ClipboardService(pasteboard: pasteboard)
        let initialChangeCount = pasteboard.changeCount

        XCTAssertThrowsError(try clipboard.setResult(ClipboardWriteRequest(representations: []))) { error in
            guard let failure = error as? DesktopActionFailure else {
                return XCTFail("Expected DesktopActionFailure, got \(error)")
            }
            XCTAssertEqual(failure.outcome, .refused(reason: .invalidRequest))
        }
        XCTAssertEqual(pasteboard.changeCount, initialChangeCount)
    }
}
