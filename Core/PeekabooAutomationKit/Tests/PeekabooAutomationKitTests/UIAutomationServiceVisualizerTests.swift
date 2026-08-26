import CoreGraphics
import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

struct UIAutomationServiceVisualizerTests {
    @Test
    @MainActor
    func `visual feedback point prefers action anchor over coordinate fallback`() {
        let actionAnchor = CGPoint(x: 20, y: 30)
        let fallback = CGPoint(x: 1, y: 2)

        let point = UIAutomationService.visualFeedbackPoint(actionAnchor: actionAnchor, fallbackPoint: fallback)

        #expect(point == actionAnchor)
    }

    @Test
    @MainActor
    func `visual feedback point uses fallback when action anchor is missing`() {
        let fallback = CGPoint(x: 1, y: 2)

        let point = UIAutomationService.visualFeedbackPoint(actionAnchor: nil, fallbackPoint: fallback)

        #expect(point == fallback)
    }

    @Test
    @MainActor
    func `targeted background interactions suppress visualizer feedback`() async {
        let feedback = RecordingAutomationFeedbackClient()
        let service = UIAutomationService(feedbackClient: feedback)

        await service.visualizeClick(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            actionAnchor: CGPoint(x: 10, y: 20),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 42)
        await service.visualizeTypeActions(
            [.text("background"), .key(.return)],
            cadence: .fixed(milliseconds: 0),
            typedIntoSecureField: true,
            targetProcessIdentifier: 42)
        await service.visualizeHotkey(keys: "cmd,shift,p", targetProcessIdentifier: 42)
        await service.visualizeScroll(
            ScrollRequest(
                direction: .down,
                amount: 3,
                target: "Results",
                snapshotId: "snapshot",
                foreground: false),
            actionAnchor: CGPoint(x: 30, y: 40))

        #expect(feedback.clickCount == 0)
        #expect(feedback.typingCount == 0)
        #expect(feedback.hotkeyCount == 0)
        #expect(feedback.scrollCount == 0)
    }

    @Test
    @MainActor
    func `targeted background interactions stay silent with a resolved target window`() async throws {
        let feedback = RecordingAutomationFeedbackClient()
        let snapshotID = SnapshotReferenceFixtures.first.rawValue
        let target = VisualizerTargetWindow(
            processIdentifier: 42,
            windowID: 7,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/resolved-target.png",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "test",
                windowContext: WindowContext(
                    applicationProcessId: target.processIdentifier,
                    windowID: Int(target.windowID),
                    windowBounds: target.frame)))
        let service = try await UIAutomationService(
            snapshotManager: InMemorySnapshotManager.containing(detectionResult),
            feedbackClient: feedback)

        await service.visualizeClick(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            actionAnchor: CGPoint(x: 10, y: 20),
            clickType: .single,
            snapshotId: detectionResult.snapshotId,
            targetProcessIdentifier: target.processIdentifier)
        await service.visualizeTypeActions(
            [.text("background")],
            cadence: .fixed(milliseconds: 0),
            targetProcessIdentifier: target.processIdentifier,
            visualizerTarget: target)
        await service.visualizeHotkey(
            keys: "cmd,shift,p",
            targetProcessIdentifier: target.processIdentifier,
            visualizerTarget: target)

        #expect(feedback.clickCount == 0)
        #expect(feedback.typingCount == 0)
        #expect(feedback.hotkeyCount == 0)
    }

    @Test
    @MainActor
    func `explicit foreground untargeted interactions preserve visualizer feedback`() async {
        let feedback = RecordingAutomationFeedbackClient()
        let service = UIAutomationService(feedbackClient: feedback)

        await service.visualizeClick(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            actionAnchor: CGPoint(x: 10, y: 20),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: nil)
        await service.visualizeTypeActions(
            [.text("foreground"), .key(.return)],
            cadence: .fixed(milliseconds: 0),
            typedIntoSecureField: true,
            targetProcessIdentifier: nil)
        await service.visualizeHotkey(keys: "cmd,shift,p", targetProcessIdentifier: nil)
        await service.visualizeScroll(
            ScrollRequest(direction: .down, amount: 3, foreground: true),
            actionAnchor: CGPoint(x: 30, y: 40))

        #expect(feedback.clickCount == 1)
        #expect(feedback.typingCount == 1)
        #expect(feedback.hotkeyCount == 1)
        #expect(feedback.scrollCount == 1)
    }
}

@MainActor
private final class RecordingAutomationFeedbackClient: AutomationFeedbackClient {
    private(set) var clickCount = 0
    private(set) var typingCount = 0
    private(set) var hotkeyCount = 0
    private(set) var scrollCount = 0

    func showClickFeedback(
        at _: CGPoint,
        type _: ClickType,
        target _: VisualizerTargetWindow?) async -> Bool
    {
        self.clickCount += 1
        return true
    }

    func showTypingFeedback(
        keys _: [String],
        duration _: TimeInterval,
        cadence _: TypingCadence,
        masksTypedText _: Bool,
        target _: VisualizerTargetWindow?) async -> Bool
    {
        self.typingCount += 1
        return true
    }

    func showHotkeyDisplay(
        keys _: [String],
        duration _: TimeInterval,
        target _: VisualizerTargetWindow?) async -> Bool
    {
        self.hotkeyCount += 1
        return true
    }

    func showScrollFeedback(
        at _: CGPoint,
        direction _: ScrollDirection,
        amount _: Int,
        target _: VisualizerTargetWindow?) async -> Bool
    {
        self.scrollCount += 1
        return true
    }
}
