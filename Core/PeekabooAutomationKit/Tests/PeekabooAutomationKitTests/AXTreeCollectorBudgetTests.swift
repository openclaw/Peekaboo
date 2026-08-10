@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import XCTest
@testable @_spi(Testing) import PeekabooAutomationKit

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

    func testExpiredDeadlineIsReportedAsTruncationBeforeAXReads() {
        let application = Element(AXUIElementCreateApplication(getpid()))

        let result = AXTreeCollector().collect(
            window: application,
            deadline: Date(timeIntervalSince1970: 0))

        XCTAssertTrue(result.elements.isEmpty)
        XCTAssertEqual(result.truncationInfo?.deadlineReached, true)
        XCTAssertTrue(result.truncationInfo?.isTruncated == true)
    }

    func testDescriptorReadFailureIsReportedAsIncompleteAccessibility() {
        let element = Element(AXUIElementCreateApplication(getpid()))
        let collector = AXTreeCollector(descriptorReader: { _ in .incomplete })

        let result = collector.collect(window: element, deadline: Date().addingTimeInterval(1))

        XCTAssertTrue(result.elements.isEmpty)
        XCTAssertEqual(result.truncationInfo?.incompleteAccessibilityRead, true)
        XCTAssertTrue(result.truncationInfo?.isTruncated == true)
    }

    func testWindowContextDecodesPayloadWithoutFreshnessPolicy() throws {
        let data = Data(#"{"applicationProcessId":42,"windowID":7}"#.utf8)

        let context = try JSONDecoder().decode(WindowContext.self, from: data)

        XCTAssertEqual(context.applicationProcessId, 42)
        XCTAssertEqual(context.windowID, 7)
        XCTAssertNil(context.requiresFreshAccessibilityTree)
        XCTAssertNil(context.accessibilityTimeoutSeconds)
    }

    func testTruncationInfoDecodesPayloadWithoutDeadlineFlag() throws {
        let data = Data(
            #"{"maxDepthReached":false,"maxElementCountReached":true,"maxChildrenPerNodeReached":false}"#.utf8)

        let info = try JSONDecoder().decode(DetectionTruncationInfo.self, from: data)

        XCTAssertTrue(info.maxElementCountReached)
        XCTAssertFalse(info.deadlineReached)
        XCTAssertFalse(info.incompleteAccessibilityRead)
        XCTAssertTrue(info.isTruncated)
    }

    func testIncompleteAccessibilityReadRoundTripsAsTruncation() throws {
        let encoded = try JSONEncoder().encode(DetectionTruncationInfo(incompleteAccessibilityRead: true))
        let info = try JSONDecoder().decode(DetectionTruncationInfo.self, from: encoded)

        XCTAssertTrue(info.incompleteAccessibilityRead)
        XCTAssertTrue(info.isTruncated)
    }

    func testAutomationToolDeadlineRemediationNamesOnlyAvailableControls() {
        let info = DetectionTruncationInfo(maxDepthReached: true, deadlineReached: true)

        let message = info.automationToolRemediationMessage(budget: AXTraversalBudget(maxDepth: 4))

        XCTAssertTrue(message.contains("app_target"))
        XCTAssertTrue(message.contains("window_id"))
        XCTAssertTrue(message.contains("max_depth"))
        XCTAssertTrue(message.contains("does not expose a timeout argument"))
        XCTAssertFalse(message.contains("--depth"))
        XCTAssertFalse(message.contains("longer caller timeout"))
        XCTAssertFalse(message.contains(AXTraversalBudget.maxDepthEnvironmentKey))
    }

    func testAutomationToolIncompleteRemediationDoesNotInventTimeoutControl() {
        let info = DetectionTruncationInfo(incompleteAccessibilityRead: true)

        let message = info.automationToolRemediationMessage(budget: nil)

        XCTAssertTrue(message.contains("app_target"))
        XCTAssertTrue(message.contains("window_id"))
        XCTAssertFalse(message.contains("increase the timeout"))
        XCTAssertFalse(message.contains("--"))
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
        object.removeValue(forKey: "allowWebFocusFallback")
        let oldPayload = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DesktopDetectionOptions.self, from: oldPayload)

        XCTAssertEqual(decoded.traversalBudget, AXTraversalBudget())
        XCTAssertEqual(decoded.allowWebFocusFallback, false)
    }

    func testDesktopDetectionDefaultsExcludeApplicationMenuBar() {
        XCTAssertFalse(DesktopDetectionOptions().includeMenuBarElements)
        XCTAssertFalse(DesktopDetectionOptions().allowWebFocusFallback)
        XCTAssertEqual(DesktopCaptureOptions().focus, .background)
    }

    func testMenuBarCollectionRequiresExplicitRequestAndActiveApplication() {
        XCTAssertFalse(ElementDetectionService.shouldCollectMenuBarElements(requested: false, appIsActive: false))
        XCTAssertFalse(ElementDetectionService.shouldCollectMenuBarElements(requested: false, appIsActive: true))
        XCTAssertFalse(ElementDetectionService.shouldCollectMenuBarElements(requested: true, appIsActive: false))
        XCTAssertTrue(ElementDetectionService.shouldCollectMenuBarElements(requested: true, appIsActive: true))
    }

    func testElementCacheSeparatesMenuBarPolicies() throws {
        let cache = ElementDetectionCache()
        let withoutMenuBar = try XCTUnwrap(cache.key(
            windowID: 42,
            processID: 123,
            allowWebFocus: false,
            includeMenuBarElements: false))
        let withMenuBar = try XCTUnwrap(cache.key(
            windowID: 42,
            processID: 123,
            allowWebFocus: false,
            includeMenuBarElements: true))

        XCTAssertNotEqual(withoutMenuBar, withMenuBar)
    }

    func testElementCacheDoesNotStoreDeadlineResults() throws {
        let cache = ElementDetectionCache()
        let key = try XCTUnwrap(cache.key(windowID: 42, processID: 123, allowWebFocus: false))
        cache.store([], for: key)
        XCTAssertNotNil(cache.result(for: key))

        cache.store([], truncationInfo: DetectionTruncationInfo(deadlineReached: true), for: key)

        XCTAssertNil(cache.result(for: key))
    }

    func testElementCacheDoesNotStoreIncompleteAccessibilityResults() throws {
        let cache = ElementDetectionCache()
        let key = try XCTUnwrap(cache.key(windowID: 42, processID: 123, allowWebFocus: false))

        cache.store([], truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true), for: key)

        XCTAssertNil(cache.result(for: key))
    }

    func testElementCachePreservesStructuralLimitResults() throws {
        let cache = ElementDetectionCache()
        let key = try XCTUnwrap(cache.key(windowID: 42, processID: 123, allowWebFocus: false))
        let truncation = DetectionTruncationInfo(maxDepthReached: true)

        cache.store([], truncationInfo: truncation, for: key)

        XCTAssertEqual(cache.result(for: key)?.truncationInfo, truncation)
    }

    func testExactWindowResolutionDoesNotActivateBackgroundApplication() async throws {
        guard let originalFrontmost = NSWorkspace.shared.frontmostApplication else {
            throw XCTSkip("No frontmost application available")
        }

        let identity = WindowIdentityService()
        var target: (app: NSRunningApplication, windowID: Int)?
        for app in NSWorkspace.shared.runningApplications
            where app.processIdentifier != originalFrontmost.processIdentifier && app.activationPolicy == .regular
        {
            let windows = AXApp(app).element.windowsWithTimeout() ?? []
            if let windowID = windows.lazy.compactMap({ identity.getWindowID(from: $0).map(Int.init) }).first {
                target = (app, windowID)
                break
            }
        }

        guard let target else {
            throw XCTSkip("No accessible background application window available")
        }

        let resolver = ElementDetectionWindowResolver(applicationService: ApplicationService())
        _ = try await resolver.resolveWindow(
            for: target.app,
            context: WindowContext(
                applicationProcessId: target.app.processIdentifier,
                windowID: target.windowID))

        XCTAssertEqual(
            NSWorkspace.shared.frontmostApplication?.processIdentifier,
            originalFrontmost.processIdentifier,
            "Resolving an AX window for observation must not activate its application")
    }

    func testDesktopDetectionOptionsDecodesPayloadWithoutMenuBarPolicy() throws {
        let options = DesktopDetectionOptions(includeMenuBarElements: true)
        let encoded = try JSONEncoder().encode(options)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "includeMenuBarElements")
        let oldPayload = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DesktopDetectionOptions.self, from: oldPayload)

        XCTAssertFalse(decoded.includeMenuBarElements)
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

        let merged = ObservationOCRMapper.merge(
            ocrResult: OCRTextResult(observations: [], imageSize: CGSize(width: 10, height: 10)),
            ocrElements: [ocrElement],
            into: detection)

        XCTAssertEqual(merged.metadata.truncationInfo, truncationInfo)
        XCTAssertTrue(merged.metadata.warnings.contains("ax_truncated_count"))
    }

    func testOCRMergeRepairsOnlyGenericAXButtonLabels() {
        let weakButton = DetectedElement(
            id: "elem_1",
            type: .button,
            label: "permission deny",
            bounds: CGRect(x: 10, y: 10, width: 100, height: 30),
            attributes: [
                "role": "AXButton",
                "description": "button",
                "identifier": "permission-deny-button",
                "isActionable": "true",
            ])
        let strongButton = DetectedElement(
            id: "elem_2",
            type: .button,
            label: "Save",
            bounds: CGRect(x: 130, y: 10, width: 60, height: 30),
            attributes: [
                "role": "AXButton",
                "identifier": "save-primary",
                "isActionable": "true",
            ])
        let detection = ElementDetectionResult(
            snapshotId: "snapshot",
            screenshotPath: "",
            elements: DetectedElements(buttons: [weakButton, strongButton]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 2, method: "AX"))
        let ocrElements = [
            DetectedElement(
                id: "ocr_1",
                type: .staticText,
                label: "Don't Allow",
                bounds: CGRect(x: 25, y: 16, width: 70, height: 14),
                attributes: ["description": "ocr"]),
            DetectedElement(
                id: "ocr_2",
                type: .staticText,
                label: "Wrong",
                bounds: CGRect(x: 135, y: 16, width: 45, height: 14),
                attributes: ["description": "ocr"]),
        ]

        XCTAssertTrue(ObservationOCRMapper.needsSemanticLabelRecovery(in: detection))
        let recovered = ObservationOCRMapper.recoverSemanticLabels(
            in: detection.elements,
            from: ocrElements)

        XCTAssertEqual(recovered.buttons[0].label, "Don't Allow")
        XCTAssertEqual(recovered.buttons[0].attributes["labelSource"], "ocr")
        XCTAssertEqual(recovered.buttons[1].label, "Save")
        XCTAssertNil(recovered.buttons[1].attributes["labelSource"])
    }

    func testTargetedOCRMapsCropBoundsBackToFullImageCoordinates() {
        let mapped = OCRService.fullImageBoundingBox(
            CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            region: CGRect(x: 0.25, y: 0.5, width: 0.25, height: 0.25))

        XCTAssertEqual(mapped.origin.x, 0.275, accuracy: 0.000_001)
        XCTAssertEqual(mapped.origin.y, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(mapped.width, 0.075, accuracy: 0.000_001)
        XCTAssertEqual(mapped.height, 0.1, accuracy: 0.000_001)
    }
}
