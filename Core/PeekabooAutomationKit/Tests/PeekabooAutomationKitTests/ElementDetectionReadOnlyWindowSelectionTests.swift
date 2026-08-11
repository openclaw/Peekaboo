import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

final class ElementDetectionReadOnlyWindowSelectionTests: XCTestCase {
    func testRequestedTitleSelectsExactSiblingInsteadOfBestWindow() throws {
        let bestWindow = Self.window(
            id: 100,
            title: "Large Dashboard",
            bounds: CGRect(x: 0, y: 0, width: 1600, height: 1000),
            isMainWindow: true,
            index: 0)
        let requestedWindow = Self.window(
            id: 200,
            title: "Private Notes",
            bounds: CGRect(x: 100, y: 100, width: 700, height: 500),
            index: 1)

        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: "Private Notes",
            windows: [bestWindow, requestedWindow],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, requestedWindow.windowID)
    }

    func testRequestedTitleUsesUniqueCaseInsensitivePartialMatch() throws {
        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: "notes",
            windows: [
                Self.window(id: 100, title: "Dashboard", index: 0),
                Self.window(id: 200, title: "Private Notes - Edited", index: 1),
            ],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, 200)
    }

    func testExactTitleWinsOverPartialSiblingMatch() throws {
        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: "Quarterly Report",
            windows: [
                Self.window(id: 100, title: "Quarterly Report - Copy", index: 0),
                Self.window(id: 200, title: "Quarterly Report", index: 1),
            ],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, 200)
    }

    func testRequestedTitleRejectsAmbiguousSiblingWindows() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "Quarterly Report",
                windows: [
                    Self.window(id: 100, title: "Quarterly Report - East", index: 0),
                    Self.window(id: 200, title: "Quarterly Report - West", index: 1),
                ],
                applicationIdentifier: "Fixture"))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("is ambiguous"))
            XCTAssertTrue(error.localizedDescription.contains("id=100"))
            XCTAssertTrue(error.localizedDescription.contains("id=200"))
        }
    }

    func testRequestedTitleRejectsDuplicateExactSiblingWindows() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "Untitled",
                windows: [
                    Self.window(id: 100, title: "Untitled", index: 0),
                    Self.window(id: 200, title: "Untitled", index: 1),
                ],
                applicationIdentifier: "Fixture"))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("is ambiguous"))
        }
    }

    func testRequestedTitleRejectsMissingWindowInsteadOfChoosingBestWindow() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "Missing Document",
                windows: [
                    Self.window(id: 100, title: "Dashboard", index: 0),
                    Self.window(id: 200, title: "Private Notes", index: 1),
                ],
                applicationIdentifier: "Fixture"))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("Missing Document"))
            XCTAssertFalse(error.localizedDescription.contains("ambiguous"))
        }
    }

    func testMissingUntitledWindowDoesNotTreatEmptyTitleAsWildcard() {
        XCTAssertThrowsError(
            try ElementDetectionService.selectReadOnlyWindow(
                requestedTitle: "",
                windows: [Self.window(id: 100, title: "Dashboard", index: 0)],
                applicationIdentifier: "Fixture"))
    }

    func testMissingTitleSelectorUsesBestWindow() throws {
        let smallWindow = Self.window(
            id: 100,
            title: "Small",
            bounds: CGRect(x: 0, y: 0, width: 400, height: 300),
            index: 0)
        let mainWindow = Self.window(
            id: 200,
            title: "Main",
            bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
            isMainWindow: true,
            index: 1)

        let selected = try ElementDetectionService.selectReadOnlyWindow(
            requestedTitle: nil,
            windows: [smallWindow, mainWindow],
            applicationIdentifier: "Fixture")

        XCTAssertEqual(selected?.windowID, mainWindow.windowID)
    }

    func testMissingCaptureReceiptRemainsReadOnlyAndCannotBecomeActionCapable() throws {
        XCTAssertNil(try ElementDetectionService.validatedExactWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            receipt: nil,
            requiresActionCapability: false,
            validator: { _, _ in XCTFail("Missing receipt must not invoke validator"); return false }))

        XCTAssertThrowsError(try ElementDetectionService.validatedExactWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: CGRect(x: 1, y: 2, width: 300, height: 200),
            receipt: nil,
            requiresActionCapability: true,
            validator: { _, _ in false }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("capture-time process-generation receipt"))
        }
    }

    func testExactReadOnlyObservationCapturesActionableReceiptWhenCallerHasNone() throws {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 123, bounds: bounds)
        var captureCount = 0
        var validationCount = 0

        let resolved = try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: nil,
            receipt: nil,
            receiptProvider: { windowID in
                captureCount += 1
                XCTAssertEqual(windowID, 42)
                return receipt
            },
            validator: { candidate, candidateBounds in
                validationCount += 1
                return candidate == receipt && candidateBounds == bounds
            })

        XCTAssertEqual(resolved.identity, receipt)
        XCTAssertEqual(resolved.bounds, bounds)
        XCTAssertEqual(captureCount, 1)
        XCTAssertEqual(validationCount, 1)
    }

    func testExistingReadOnlyObservationReceiptIsPreservedAndRevalidated() throws {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 123, bounds: bounds)

        let resolved = try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in
                XCTFail("An existing capture receipt must not be replaced")
                return nil
            },
            validator: { candidate, candidateBounds in
                candidate == receipt && candidateBounds == bounds
            })

        XCTAssertEqual(resolved.identity, receipt)
        XCTAssertEqual(resolved.bounds, bounds)
    }

    func testReadOnlyObservationReceiptDriftFailsClosed() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 123, bounds: bounds)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in receipt },
            validator: { _, _ in false }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("changed before AX traversal"))
        }
    }

    func testReadOnlyObservationRejectsReceiptForAnotherProcess() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = Self.receipt(windowID: 42, processIdentifier: 999, bounds: bounds)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: nil,
            receiptProvider: { _ in receipt },
            validator: { _, _ in true }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("changed before AX traversal"))
        }
    }

    func testReadOnlyObservationRejectsLegacyReceiptWithoutEmbeddedBounds() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 7,
            capturedBounds: nil)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in receipt },
            validator: { _, _ in true }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("could not capture"))
        }
    }

    func testReadOnlyObservationRejectsZeroProcessGeneration() {
        let bounds = CGRect(x: 1, y: 2, width: 300, height: 200)
        let receipt = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 0,
            capturedBounds: bounds)

        XCTAssertThrowsError(try ElementDetectionService.resolveActionableWindowReceipt(
            windowID: 42,
            processIdentifier: 123,
            capturedBounds: bounds,
            receipt: receipt,
            receiptProvider: { _ in receipt },
            validator: { _, _ in true }))
        { error in
            XCTAssertTrue(error.localizedDescription.contains("could not capture"))
        }
    }

    private static func window(
        id: Int,
        title: String,
        bounds: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        isMainWindow: Bool = false,
        index: Int) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMinimized: false,
            isMainWindow: isMainWindow,
            windowLevel: 0,
            alpha: 1,
            index: index,
            layer: 0,
            isOnScreen: true,
            sharingState: .readOnly,
            isExcludedFromWindowsMenu: false)
    }

    private static func receipt(
        windowID: Int,
        processIdentifier: pid_t,
        bounds: CGRect) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 7,
            capturedBounds: bounds)
    }
}
