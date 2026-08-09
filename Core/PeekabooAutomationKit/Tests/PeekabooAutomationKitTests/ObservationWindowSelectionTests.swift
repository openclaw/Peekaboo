import CoreGraphics
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class ObservationWindowSelectionTests: XCTestCase {
    func testCaptureCandidatesDropNonShareableWindows() {
        let windows = [
            Self.window(
                id: 1,
                title: "Overlay",
                bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                sharingState: .none),
            Self.window(
                id: 2,
                title: "Editor",
                bounds: CGRect(x: 0, y: 0, width: 1200, height: 900),
                sharingState: .readWrite),
        ]

        let filtered = ObservationTargetResolver.captureCandidates(from: windows)

        XCTAssertEqual(filtered.map(\.title), ["Editor"])
    }

    func testCaptureCandidateSummaryIncludesRejectedReasons() {
        let windows = [
            Self.window(
                id: 1,
                title: "",
                bounds: CGRect(x: 0, y: 0, width: 60, height: 30)),
            Self.window(
                id: 2,
                title: "Overlay",
                bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                sharingState: .none),
        ]

        let summary = ObservationTargetResolver.captureCandidateSummary(from: windows)

        XCTAssertTrue(summary.contains("#0 id=1 '<untitled>' 60x30"))
        XCTAssertTrue(summary.contains("window too small"))
        XCTAssertTrue(summary.contains("#0 id=2 'Overlay' 400x400"))
        XCTAssertTrue(summary.contains("window marked non-shareable"))
    }

    func testListFilteringKeepsMinimizedWindows() {
        let windows = [
            Self.window(
                id: 3,
                title: "Hidden",
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                isMinimized: true,
                isOnScreen: false),
            Self.window(
                id: 4,
                title: "Visible",
                bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
                isOnScreen: true),
        ]

        let filtered = ObservationTargetResolver.filteredWindows(from: windows, mode: .list)

        XCTAssertEqual(filtered.count, 2)
    }

    func testCaptureCandidatesDeduplicateWindowIDs() {
        let first = Self.window(
            id: 10,
            title: "Document",
            bounds: CGRect(x: 0, y: 0, width: 800, height: 600),
            index: 0)
        let duplicate = Self.window(
            id: 10,
            title: "Document Copy",
            bounds: CGRect(x: 20, y: 20, width: 800, height: 600),
            index: 1)

        let filtered = ObservationTargetResolver.captureCandidates(from: [first, duplicate])

        XCTAssertEqual(filtered.map(\.index), [0])
    }

    func testTitleSelectionRejectsAmbiguousExactMatches() {
        let windows = [
            Self.window(id: 20, title: "Document", bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            Self.window(id: 21, title: "document", bounds: CGRect(x: 20, y: 20, width: 800, height: 600), index: 1),
        ]

        XCTAssertThrowsError(try ObservationTargetResolver.window(matchingTitle: "Document", from: windows)) {
            guard case DesktopObservationError.ambiguousWindowTitle = $0 else {
                return XCTFail("Expected ambiguous title error, got \($0)")
            }
        }
    }

    func testTitleSelectionRejectsAmbiguousPartialMatchesButPrefersUniqueExactMatch() throws {
        let windows = [
            Self.window(id: 22, title: "Project Alpha", bounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
            Self.window(id: 23, title: "Project Beta", bounds: CGRect(x: 20, y: 20, width: 800, height: 600), index: 1),
        ]

        XCTAssertThrowsError(try ObservationTargetResolver.window(matchingTitle: "Project", from: windows))
        XCTAssertEqual(
            try ObservationTargetResolver.window(matchingTitle: "Project Alpha", from: windows).windowID,
            22)
    }

    func testMenuBarBoundsUsesPrimaryScreenVisibleFrameGap() {
        let screen = ScreenInfo(
            index: 0,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)

        let bounds = ObservationTargetResolver.menuBarBounds(for: screen)

        XCTAssertEqual(bounds, CGRect(x: 0, y: 1080, width: 1728, height: 37))
    }

    private static func window(
        id: Int,
        title: String,
        bounds: CGRect,
        isMinimized: Bool = false,
        index: Int = 0,
        isOnScreen: Bool = true,
        sharingState: WindowSharingState = .readOnly) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMinimized: isMinimized,
            isMainWindow: false,
            windowLevel: 0,
            alpha: 1,
            index: index,
            layer: 0,
            isOnScreen: isOnScreen,
            sharingState: sharingState,
            isExcludedFromWindowsMenu: false)
    }
}
