import AppKit
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import XCTest

@MainActor
final class ClipboardSlotFidelityTests: XCTestCase {
    func testRestoreUsesNewerSaveFromAnotherServiceInstance() throws {
        try self.withOwnedBoards { board, slot in
            let original = ClipboardService(pasteboard: board)
            let other = ClipboardService(pasteboard: board)
            _ = try original.set(ClipboardPayloadBuilder.textRequest(text: "original"))
            try original.save(slot: "proof")
            _ = try other.set(ClipboardPayloadBuilder.textRequest(text: "newer"))
            try other.save(slot: "proof")
            original.clear()

            _ = try original.restore(slot: "proof")

            XCTAssertEqual(board.string(forType: .string), "newer")
            XCTAssertTrue(slot.types?.isEmpty != false)
        }
    }

    func testConsumedSlotCannotBeRestoredFromAnOlderInstanceCache() throws {
        try self.withOwnedBoards { board, _ in
            let original = ClipboardService(pasteboard: board)
            let other = ClipboardService(pasteboard: board)
            _ = try original.set(ClipboardPayloadBuilder.textRequest(text: "saved"))
            try original.save(slot: "proof")
            _ = try other.restore(slot: "proof")
            _ = try other.set(ClipboardPayloadBuilder.textRequest(text: "current"))
            let generation = board.changeCount

            XCTAssertThrowsError(try original.restoreActionResult(slot: "proof")) { error in
                guard let failure = error as? DesktopActionFailure else {
                    return XCTFail("Expected a canonical pre-dispatch refusal, got \(error)")
                }
                XCTAssertEqual(failure.outcome.state, .refused)
                XCTAssertFalse(failure.outcome.dispatchState.mutationDispatched)
            }
            XCTAssertEqual(board.changeCount, generation)
            XCTAssertEqual(board.string(forType: .string), "current")
        }
    }

    func testRestorePreservesSeparateItemsAndTheirRepresentations() throws {
        try self.withOwnedBoards { board, slot in
            let binary = NSPasteboard.PasteboardType("dev.peekaboo.owned-slot-data")
            let objects = ["first", "second"].map { value in
                let item = NSPasteboardItem()
                XCTAssertTrue(item.setString(value, forType: .string))
                XCTAssertTrue(item.setData(Data(value.utf8), forType: binary))
                return item
            }
            XCTAssertTrue(board.writeObjects(objects))
            let writer = ClipboardService(pasteboard: board)
            try writer.save(slot: "proof")
            writer.clear()
            let reader = ClipboardService(pasteboard: board)

            let restored = try reader.restoreActionResult(slot: "proof")

            XCTAssertEqual(restored.outcome?.state, .confirmedChange)
            let restoredItems = board.pasteboardItems ?? []
            XCTAssertEqual(restoredItems.count, 2)
            for (item, value) in zip(restoredItems, ["first", "second"]) {
                XCTAssertEqual(item.string(forType: .string), value)
                XCTAssertEqual(item.data(forType: binary), Data(value.utf8))
            }
            XCTAssertTrue(slot.types?.isEmpty != false)
        }
    }

    func testSingleItemRestoreKeepsTheExistingReturnValueAndConsumption() throws {
        try self.withOwnedBoards { board, slot in
            let writer = ClipboardService(pasteboard: board)
            _ = try writer.set(ClipboardPayloadBuilder.textRequest(text: "saved"))
            try writer.save(slot: "proof")
            writer.clear()

            let restored = try ClipboardService(pasteboard: board).restore(slot: "proof")

            XCTAssertEqual(restored.data, Data("saved".utf8))
            XCTAssertEqual(restored.textPreview, "saved")
            XCTAssertEqual(board.string(forType: .string), "saved")
            XCTAssertTrue(slot.types?.isEmpty != false)
        }
    }

    func testSizeRefusalPreservesCurrentClipboardAndTheSavedSlot() throws {
        try self.withOwnedBoards { board, slot in
            let writer = ClipboardService(pasteboard: board)
            _ = try writer.set(ClipboardPayloadBuilder.textRequest(text: "larger saved contents"))
            try writer.save(slot: "proof")
            _ = try writer.set(ClipboardPayloadBuilder.textRequest(text: "current"))
            let generation = board.changeCount

            XCTAssertThrowsError(try ClipboardService(pasteboard: board, sizeLimit: 1)
                .restore(slot: "proof"))
            { error in
                guard case ClipboardServiceError.sizeExceeded = error else {
                    return XCTFail("Expected size refusal, got \(error)")
                }
            }

            XCTAssertEqual(board.changeCount, generation)
            XCTAssertEqual(board.string(forType: .string), "current")
            XCTAssertEqual(slot.string(forType: .string), "larger saved contents")
        }
    }

    func testPlainTextOnlyRestoreKeepsTheExistingStringCompanion() throws {
        try self.checkPlainTextRestore("plain-text only")
    }

    func testPlainTextCRLFRestoreKeepsRawBytesAndNormalizedDefaultReadback() throws {
        try self.checkPlainTextRestore("first\r\nsecond\rthird")
    }

    private func checkPlainTextRestore(_ text: String) throws {
        try self.withOwnedBoards { board, slot in
            let plain = NSPasteboard.PasteboardType("public.plain-text")
            let payload = Data(text.utf8)
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setData(payload, forType: plain))
            XCTAssertTrue(board.writeObjects([item]))
            let writer = ClipboardService(pasteboard: board)
            try writer.save(slot: "proof")
            XCTAssertNil(slot.string(forType: .string))
            writer.clear()
            let reader = ClipboardService(pasteboard: board)

            let restored = try reader.restoreActionResult(slot: "proof")

            XCTAssertEqual(restored.outcome?.state, .confirmedChange)
            XCTAssertEqual(restored.payload.data, payload)
            XCTAssertEqual(restored.payload.textPreview, text)
            XCTAssertEqual(board.data(forType: plain), payload)
            XCTAssertEqual(board.string(forType: .string), text)
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            XCTAssertEqual(try reader.get(prefer: nil)?.data, Data(normalized.utf8))
            XCTAssertTrue(slot.types?.isEmpty != false)
        }
    }

    private func withOwnedBoards(_ operation: (NSPasteboard, NSPasteboard) throws -> Void) throws {
        let board = NSPasteboard.withUniqueName()
        let slot = NSPasteboard(name: .init("\(board.name.rawValue).boo.peekaboo.clipboard.slot.proof"))
        XCTAssertNotEqual(board.name, .general)
        defer {
            board.clearContents()
            slot.clearContents()
            board.releaseGlobally()
            slot.releaseGlobally()
        }
        try operation(board, slot)
    }
}
