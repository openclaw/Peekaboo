import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
struct SeeCommandRemoteDetectionTimeoutTests {
    @Test
    func `Timeout-aware automation preserves explicit timeout above twenty seconds with a cushion`() async throws {
        let automation = MockTimeoutAwareAutomationService(minimumRequestTimeoutSec: 64)

        let result = try await SeeCommand.detectElements(
            automation: automation,
            imageData: Data([0xFF]),
            windowContext: nil,
            timeoutSeconds: 60
        )

        #expect(result.snapshotId == "remote")
        #expect(automation.recordedRequestTimeoutSec == 65)
        #expect(automation.baseDetectElementsCalls == 0)
        #expect(automation.timeoutAwareCalls == 1)
    }

    @Test
    func `Non-timeout-aware automation falls back to the shared bridge helper`() async throws {
        let automation = MockPlainAutomationService()

        let result = try await SeeCommand.detectElements(
            automation: automation,
            imageData: Data([0xAA]),
            windowContext: nil,
            timeoutSeconds: 5
        )

        #expect(result.snapshotId == "plain")
        #expect(automation.detectElementsCalls == 1)
    }
}

@MainActor
private final class MockTimeoutAwareAutomationService: DetectElementsRequestTimeoutAdjusting {
    let minimumRequestTimeoutSec: TimeInterval
    var recordedRequestTimeoutSec: TimeInterval?
    var timeoutAwareCalls = 0
    var baseDetectElementsCalls = 0

    init(minimumRequestTimeoutSec: TimeInterval) {
        self.minimumRequestTimeoutSec = minimumRequestTimeoutSec
    }

    func detectElements(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?
    ) async throws -> ElementDetectionResult {
        self.baseDetectElementsCalls += 1
        throw PeekabooError.operationError(message: "Base detectElements path should not be used")
    }

    func detectElements(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?,
        requestTimeoutSec: TimeInterval
    ) async throws -> ElementDetectionResult {
        self.timeoutAwareCalls += 1
        self.recordedRequestTimeoutSec = requestTimeoutSec
        try await Task.sleep(nanoseconds: 20_000_000)

        if requestTimeoutSec < self.minimumRequestTimeoutSec {
            throw PeekabooError.timeout("remote detectElements request timed out")
        }

        return makeDetectionResult(snapshotId: "remote")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}
    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?)
    async throws {}

    func typeActions(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?
    ) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}
    func hotkey(keys _: String, holdDuration _: Int) async throws {}
    func swipe(from _: CGPoint, to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile)
    async throws {}

    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
    -> WaitForElementResult {
        .init(found: false, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}
    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}
    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.elementNotFound("not implemented")
    }
}

@MainActor
private final class MockPlainAutomationService: UIAutomationServiceProtocol {
    var detectElementsCalls = 0

    func detectElements(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?
    ) async throws -> ElementDetectionResult {
        self.detectElementsCalls += 1
        return makeDetectionResult(snapshotId: "plain")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}
    func type(text _: String, target _: String?, clearExisting _: Bool, typingDelay _: Int, snapshotId _: String?)
    async throws {}

    func typeActions(
        _: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?
    ) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}
    func hotkey(keys _: String, holdDuration _: Int) async throws {}
    func swipe(from _: CGPoint, to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile)
    async throws {}

    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
    -> WaitForElementResult {
        .init(found: false, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}
    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}
    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.elementNotFound("not implemented")
    }
}

private func makeDetectionResult(snapshotId: String) -> ElementDetectionResult {
    ElementDetectionResult(
        snapshotId: snapshotId,
        screenshotPath: "/tmp/\(snapshotId).png",
        elements: DetectedElements(
            buttons: [],
            textFields: [],
            links: [],
            images: [],
            groups: [],
            sliders: [],
            checkboxes: [],
            menus: [],
            other: []
        ),
        metadata: DetectionMetadata(
            detectionTime: 0.01,
            elementCount: 0,
            method: "mock",
            warnings: []
        )
    )
}
