import AXorcist
import CoreGraphics
import Foundation
@testable import PeekabooAutomationKit

@MainActor
final class DialogDiscoveryFocusRecorder: DialogFocusManaging {
    var focusCalls = 0
    var spaceSwitchCalls = 0

    func focusWindowWithOwnedLane(
        windowID: CGWindowID,
        options: FocusManagementService.FocusOptions,
        expectedIdentity: WindowMutationIdentity?) async throws
    {
        self.record(options)
    }

    func focusDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        options: FocusManagementService.FocusOptions) async throws
    {
        self.record(options)
    }

    func requireDialogWindowFocusWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        timeout: TimeInterval) async throws
    {
        self.focusCalls += 1
    }

    func requireDialogDispatchFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element,
        field: Element) throws
    {
        self.focusCalls += 1
    }

    func requireDialogGlobalKeyboardFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element) throws
    {
        self.focusCalls += 1
    }

    private func record(_ options: FocusManagementService.FocusOptions) {
        self.focusCalls += 1
        if options.switchSpace || options.bringToCurrentSpace {
            self.spaceSwitchCalls += 1
        }
    }
}
