import CoreGraphics
import Foundation
import PeekabooFoundation
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
    func `targeted background interactions suppress global visualizer feedback`() async throws {
        let feedback = RecordingAutomationFeedbackClient()
        let service = UIAutomationService(feedbackClient: feedback)

        try await service.visualizeClick(
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
    func `untargeted foreground interactions preserve global visualizer feedback`() async throws {
        let feedback = RecordingAutomationFeedbackClient()
        let service = UIAutomationService(feedbackClient: feedback)

        try await service.visualizeClick(
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

    @Test
    @MainActor
    func `background dialog and window close actions suppress global feedback`() {
        #expect(!DialogService.shouldShowButtonFeedback(allowGlobalFallback: false))
        #expect(!WindowManagementService.shouldShowWindowOperationFeedback(
            operation: .close,
            hasForegroundConsent: false))
        #expect(DialogService.shouldShowButtonFeedback(allowGlobalFallback: true))
        #expect(WindowManagementService.shouldShowWindowOperationFeedback(
            operation: .close,
            hasForegroundConsent: true))
    }

    @Test
    @MainActor
    func `background window state and geometry operations suppress feedback`() {
        let backgroundOperations: [WindowOperationKind] = [
            .minimize,
            .maximize,
            .move,
            .resize,
            .setBounds,
        ]
        for operation in backgroundOperations {
            #expect(!WindowManagementService.shouldShowWindowOperationFeedback(
                operation: operation,
                hasForegroundConsent: false))
            #expect(WindowManagementService.shouldShowWindowOperationFeedback(
                operation: operation,
                hasForegroundConsent: true))
        }
        #expect(WindowManagementService.shouldShowWindowOperationFeedback(
            operation: .focus,
            hasForegroundConsent: false))
    }

    @Test
    @MainActor
    func `background app quit and menu traversal suppress global feedback`() {
        #expect(!ApplicationService.shouldShowQuitFeedback(hasForegroundConsent: false))
        #expect(!MenuService.shouldShowMenuNavigation(hasForegroundConsent: false))
        #expect(ApplicationService.shouldShowQuitFeedback(hasForegroundConsent: true))
        #expect(MenuService.shouldShowMenuNavigation(hasForegroundConsent: true))
    }
}

@MainActor
private final class RecordingAutomationFeedbackClient: AutomationFeedbackClient {
    private(set) var clickCount = 0
    private(set) var typingCount = 0
    private(set) var hotkeyCount = 0
    private(set) var scrollCount = 0

    func showClickFeedback(at _: CGPoint, type _: ClickType) async -> Bool {
        self.clickCount += 1
        return true
    }

    func showTypingFeedback(
        keys _: [String],
        duration _: TimeInterval,
        cadence _: TypingCadence,
        masksTypedText _: Bool) async -> Bool
    {
        self.typingCount += 1
        return true
    }

    func showHotkeyDisplay(keys _: [String], duration _: TimeInterval) async -> Bool {
        self.hotkeyCount += 1
        return true
    }

    func showScrollFeedback(at _: CGPoint, direction _: ScrollDirection, amount _: Int) async -> Bool {
        self.scrollCount += 1
        return true
    }
}
