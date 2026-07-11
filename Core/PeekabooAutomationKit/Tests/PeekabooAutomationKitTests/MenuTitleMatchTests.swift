import XCTest
@_spi(Testing) import PeekabooAutomationKit

final class MenuTitleMatchTests: XCTestCase {
    func testMenuTitleCandidatesContainNormalizedMatchesTrimmy() {
        let normalized = normalizedMenuTitle("Trimmy")
        XCTAssertNotNil(normalized)
        let matches = menuTitleCandidatesContainNormalized(
            ["Trimmy Settings", "Quit Trimmy"],
            normalizedTarget: normalized ?? "")
        XCTAssertTrue(matches)
    }

    func testMenuTitleCandidatesContainNormalizedRejectsUnrelated() {
        let normalized = normalizedMenuTitle("Trimmy")
        XCTAssertNotNil(normalized)
        let matches = menuTitleCandidatesContainNormalized(
            ["Settings", "Quit"],
            normalizedTarget: normalized ?? "")
        XCTAssertFalse(matches)
    }

    func testMenuExtraTitlesMatchIgnoresHyphenVariants() {
        XCTAssertTrue(menuExtraTitlesMatch(candidate: "WiFi", target: "Wi-Fi"))
        XCTAssertTrue(menuExtraTitlesMatch(candidate: "Wi‑Fi", target: "WiFi"))
    }

    func testApplicationMenuTitlesKeepHyphensSignificant() {
        XCTAssertFalse(titlesMatch(candidate: "Re-sign", target: "Resign"))
    }
}
