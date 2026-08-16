import ApplicationServices
import AXorcist
import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DialogOverwriteConfirmationTests {
    @Test
    func `multiple dialogs cannot redirect Replace away from the retained file dialog`() throws {
        let retained = try Self.target(windowID: 700)
        let otherDialog = try Self.target(windowID: 701)
        let wrongButton = Self.element(offset: 1)
        let retainedButton = Self.element(offset: 2)
        let candidates = [
            DialogService.OverwriteConfirmationCandidate(
                target: otherDialog,
                dialog: Self.element(offset: 3),
                button: wrongButton),
            DialogService.OverwriteConfirmationCandidate(
                target: retained,
                dialog: Self.element(offset: 4),
                button: retainedButton),
        ]

        let candidate = try DialogService.pinnedOverwriteConfirmation(
            candidates,
            retainedTarget: retained)
        let selected = try #require(candidate)

        #expect(DialogService.sameElement(selected.button, retainedButton))
        #expect(!DialogService.sameElement(selected.button, wrongButton))
        #expect(selected.target == retained)
    }

    @Test
    func `overwrite target coalescing rejects another window or process generation`() throws {
        let retained = try Self.target(windowID: 700)
        #expect(try DialogService.coalescedOverwriteTarget(
            retained: retained,
            confirmation: retained) == retained)

        for replacement in try [
            Self.target(windowID: 701),
            Self.target(windowID: 700, processStartIdentity: 9002),
        ] {
            do {
                _ = try DialogService.coalescedOverwriteTarget(
                    retained: retained,
                    confirmation: replacement)
                Issue.record("Expected contradictory overwrite confirmation identity to fail closed")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.refusalReason == .targetUnavailable)
                #expect(failure.outcome.dispatchState == .none)
            }
        }
    }

    private static func target(
        windowID: Int,
        processStartIdentity: UInt64 = 9001) throws -> UIAutomationTarget.ExactWindow
    {
        let bounds = CGRect(x: 10, y: 20, width: 500, height: 400)
        return try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: 42,
                ownerProcessStartIdentity: processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
    }

    private static func element(offset: pid_t) -> Element {
        Element(AXUIElementCreateApplication(getpid() + offset))
    }
}
