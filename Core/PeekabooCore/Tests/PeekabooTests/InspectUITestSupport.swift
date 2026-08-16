import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
class InspectUITestAutomationService: UIAutomationServiceProtocol {
    private let accessibilityGranted: Bool
    private let detectionResult: ElementDetectionResult?
    private let inspectError: (any Error)?
    private(set) var lastDetectImageDataCount: Int?
    private(set) var lastDetectSnapshotId: String?
    private(set) var lastWindowContext: WindowContext?
    private(set) var lastInspectWindowContext: WindowContext?

    init(
        accessibilityGranted: Bool,
        detectionResult: ElementDetectionResult? = nil,
        inspectError: (any Error)? = nil)
    {
        self.accessibilityGranted = accessibilityGranted
        self.detectionResult = detectionResult
        self.inspectError = inspectError
    }

    func detectElements(in imageData: Data, snapshotId: String?, windowContext: WindowContext?) async throws
        -> ElementDetectionResult
    {
        self.lastDetectImageDataCount = imageData.count
        self.lastDetectSnapshotId = snapshotId
        self.lastWindowContext = windowContext
        if let detectionResult = self.detectionResult {
            return detectionResult
        }
        throw PeekabooError.notImplemented("mock detectElements")
    }

    func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        self.lastInspectWindowContext = windowContext
        self.lastWindowContext = windowContext
        if let inspectError {
            throw inspectError
        }
        if let detectionResult = self.detectionResult {
            return detectionResult
        }
        throw PeekabooError.notImplemented("mock inspectAccessibilityTree")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}

    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?) async
    throws {}

    func typeActions(_: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}

    func hotkey(keys _: String, holdDuration _: Int) async throws {}

    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws {}

    func hasAccessibilityPermission() async -> Bool {
        self.accessibilityGranted
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        WaitForElementResult(found: false, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}

    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}

    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.elementNotFound("mock findElement")
    }
}
