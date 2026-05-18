@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class AXTreeCollectorBudgetTests: XCTestCase {
    override func tearDown() {
        unsetenv(AXTraversalBudget.maxDepthEnvironmentKey)
        unsetenv(AXTraversalBudget.maxElementCountEnvironmentKey)
        unsetenv(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey)
        super.tearDown()
    }

    private func frontmostWindowElement() -> Element? {
        guard let appAX = AXUIElement.frontmostApplication() else {
            return nil
        }
        let appElement = Element(appAX)
        return appElement.windows()?.first
    }

    func testDefaultBudgetCollectsMultipleElementsWhenWindowExposesChildren() throws {
        guard let window = self.frontmostWindowElement() else {
            throw XCTSkip("No frontmost window available for AX testing")
        }

        let collector = AXTreeCollector()
        let result = collector.collect(window: window, deadline: Date().addingTimeInterval(5.0))

        guard result.elements.count > 1 else {
            throw XCTSkip("Frontmost window does not expose child AX elements")
        }
        guard result.truncationInfo == nil else {
            throw XCTSkip("Frontmost window exceeds the default AX traversal budget")
        }

        XCTAssertNil(result.truncationInfo, "Default budget should not trigger truncation on a small AX tree")
    }

    func testMaxDepthOneStopsAtRoot() throws {
        guard let window = self.frontmostWindowElement() else {
            throw XCTSkip("No frontmost window available for AX testing")
        }

        let collector = AXTreeCollector()
        let defaultResult = collector.collect(window: window, deadline: Date().addingTimeInterval(5.0))
        guard defaultResult.elements.count > 1 else {
            throw XCTSkip("Frontmost window does not expose child AX elements")
        }

        let budget = AXTraversalBudget(maxDepth: 1, maxElementCount: 400, maxChildrenPerNode: 50)
        let result = collector.collect(
            window: window,
            deadline: Date().addingTimeInterval(5.0),
            budget: budget)

        XCTAssertEqual(result.elements.count, 1, "Depth 1 should only collect the root window")
        XCTAssertTrue(result.truncationInfo?.maxDepthReached == true, "Should flag maxDepthReached")
    }

    func testMaxElementCountStopsEarly() throws {
        guard let window = self.frontmostWindowElement() else {
            throw XCTSkip("No frontmost window available for AX testing")
        }

        let collector = AXTreeCollector()
        let defaultResult = collector.collect(window: window, deadline: Date().addingTimeInterval(5.0))
        guard defaultResult.elements.count > 2 else {
            throw XCTSkip("Frontmost window does not expose enough AX elements")
        }

        let budget = AXTraversalBudget(maxDepth: 12, maxElementCount: 2, maxChildrenPerNode: 50)
        let result = collector.collect(
            window: window,
            deadline: Date().addingTimeInterval(5.0),
            budget: budget)

        XCTAssertLessThanOrEqual(result.elements.count, 2, "Budget of 2 elements should collect at most 2")
        XCTAssertTrue(result.truncationInfo?.maxElementCountReached == true, "Should flag maxElementCountReached")
    }

    func testMaxChildrenPerNodeLimitsTraversal() throws {
        guard let window = self.frontmostWindowElement() else {
            throw XCTSkip("No frontmost window available for AX testing")
        }

        let collector = AXTreeCollector()
        let defaultResult = collector.collect(window: window, deadline: Date().addingTimeInterval(5.0))
        guard defaultResult.elements.count > 1 else {
            throw XCTSkip("Frontmost window does not expose child AX elements")
        }

        let collector2 = AXTreeCollector()
        let budget = AXTraversalBudget(maxDepth: 12, maxElementCount: 400, maxChildrenPerNode: 0)
        let limitedResult = collector2.collect(
            window: window,
            deadline: Date().addingTimeInterval(5.0),
            budget: budget)

        XCTAssertEqual(limitedResult.elements.count, 1, "Children budget 0 should only collect the root")
        XCTAssertTrue(
            limitedResult.truncationInfo?.maxChildrenPerNodeReached == true,
            "Should flag maxChildrenPerNodeReached")
    }

    func testNegativeBudgetValuesAreClampedBeforeTraversal() throws {
        guard let window = self.frontmostWindowElement() else {
            throw XCTSkip("No frontmost window available for AX testing")
        }

        let collector = AXTreeCollector()
        let budget = AXTraversalBudget(maxDepth: -1, maxElementCount: -1, maxChildrenPerNode: -1)
        let result = collector.collect(
            window: window,
            deadline: Date().addingTimeInterval(5.0),
            budget: budget)

        XCTAssertTrue(result.elements.isEmpty, "Negative depth/count budgets should clamp to zero")
        XCTAssertTrue(result.truncationInfo?.maxDepthReached == true, "Should flag maxDepthReached")
    }

    func testDesktopDetectionOptionsDecodesOldPayloadWithoutTraversalBudget() throws {
        let options = DesktopDetectionOptions(
            mode: .accessibility,
            allowWebFocusFallback: false,
            includeMenuBarElements: true,
            preferOCR: false)
        let encoded = try JSONEncoder().encode(options)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "traversalBudget")
        let oldPayload = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DesktopDetectionOptions.self, from: oldPayload)

        XCTAssertEqual(decoded.traversalBudget, AXTraversalBudget())
        XCTAssertEqual(decoded.allowWebFocusFallback, false)
    }

    func testMissingBudgetNormalizationAppliesEnvironmentOverrides() {
        setenv(AXTraversalBudget.maxDepthEnvironmentKey, "15", 1)
        setenv(AXTraversalBudget.maxElementCountEnvironmentKey, "1600", 1)
        setenv(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey, "550", 1)

        let budget = AXTraversalBudget.normalizedForTraversal(nil)

        XCTAssertEqual(budget.maxDepth, 15)
        XCTAssertEqual(budget.maxElementCount, 1600)
        XCTAssertEqual(budget.maxChildrenPerNode, 550)
    }

    func testExplicitDefaultBudgetNormalizationIgnoresEnvironmentOverrides() {
        setenv(AXTraversalBudget.maxDepthEnvironmentKey, "15", 1)
        setenv(AXTraversalBudget.maxElementCountEnvironmentKey, "1600", 1)
        setenv(AXTraversalBudget.maxChildrenPerNodeEnvironmentKey, "550", 1)

        let budget = AXTraversalBudget.normalizedForTraversal(AXTraversalBudget())

        XCTAssertEqual(budget, AXTraversalBudget())
    }

    func testOCRMergePreservesTruncationMetadata() {
        let truncationInfo = DetectionTruncationInfo(maxElementCountReached: true)
        let detection = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "elem_1",
                    type: .button,
                    label: "OK",
                    bounds: CGRect(x: 1, y: 1, width: 10, height: 10)),
            ]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "AXorcist",
                warnings: ["ax_truncated_count"],
                truncationInfo: truncationInfo))
        let ocrElement = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "OCR",
            bounds: CGRect(x: 2, y: 2, width: 10, height: 10))

        let merged = ObservationOCRMapper.merge(ocrElements: [ocrElement], into: detection)

        XCTAssertEqual(merged.metadata.truncationInfo, truncationInfo)
        XCTAssertTrue(merged.metadata.warnings.contains("ax_truncated_count"))
    }
}
