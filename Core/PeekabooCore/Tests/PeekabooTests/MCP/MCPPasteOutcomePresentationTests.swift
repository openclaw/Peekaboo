import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime

struct MCPPasteOutcomePresentationTests {
    @Test(arguments: [nil, .notNeeded, .restored, .preservedNewerContents] as [ClipboardTemporaryCleanupStatus?])
    func `temporary cleanup status never supplies missing receiver evidence`(
        cleanupStatus: ClipboardTemporaryCleanupStatus?)
    {
        let text = PasteTool.explicitClipboardMessage(
            outcome: nil,
            cleanupStatus: cleanupStatus,
            restoreErrorDescription: nil,
            executionTime: 0.25)

        #expect(text.hasPrefix(ActionOutcomeHumanRenderer.statusLine(for: nil, operation: "Paste") + "\n"))
        #expect(text.contains("\n" + ClipboardTemporaryCleanupStatus.humanDescription(for: cleanupStatus) + "\n"))
        #expect(text.hasSuffix("Completed in 0.25s"))
        #expect(!text.contains("✅"))
        #expect(!text.contains("Pasted"))
        #expect(text.contains("Clipboard restored.") == (cleanupStatus == .restored))
        #expect(text.contains("Clipboard cleanup was not needed.") == (cleanupStatus == .notNeeded))
        #expect(text.contains("Newer clipboard contents preserved.") == (cleanupStatus == .preservedNewerContents))
        #expect(text.contains("Clipboard cleanup status was not reported.") == (cleanupStatus == nil))
    }

    @Test(arguments: [nil, .notNeeded, .restored, .preservedNewerContents] as [ClipboardTemporaryCleanupStatus?])
    func `temporary cleanup does not turn an unverified paste into confirmed consumption`(
        cleanupStatus: ClipboardTemporaryCleanupStatus?)
    {
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .init(2))
        let text = PasteTool.explicitClipboardMessage(
            outcome: outcome,
            cleanupStatus: cleanupStatus,
            restoreErrorDescription: nil,
            executionTime: 0.25)

        #expect(text.hasPrefix(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Paste") + "\n"))
        #expect(text.contains("\n" + ClipboardTemporaryCleanupStatus.humanDescription(for: cleanupStatus) + "\n"))
        #expect(!text.contains("✅"))
        #expect(!text.contains("Pasted"))
    }

    @Test
    func `restoration failure is separate from the reported receiver effect and cleanup status`() {
        let outcome = DesktopActionOutcome.partial(
            delivery: .init(mechanism: .clipboardTransaction, mode: .foreground),
            unitCount: .one)
        let text = PasteTool.explicitClipboardMessage(
            outcome: outcome,
            cleanupStatus: nil,
            restoreErrorDescription: "Synthetic clipboard restore failure",
            executionTime: 0.25)

        #expect(text.hasPrefix(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Paste") + "\n"))
        #expect(text.contains("Clipboard cleanup status was not reported."))
        #expect(text.contains("Clipboard restoration failed: Synthetic clipboard restore failure."))
        #expect(text.contains("Do not retry the paste"))
        #expect(!text.contains("Clipboard restored."))
        #expect(!text.contains("✅"))
    }
}
