import AXorcist
import CoreGraphics
import Foundation

/// Keeps all foreground dialog operations observable independently of read-only discovery.
@MainActor
protocol DialogFocusManaging {
    func focusWindowWithOwnedLane(
        windowID: CGWindowID,
        options: FocusManagementService.FocusOptions,
        expectedIdentity: WindowMutationIdentity?) async throws
    func focusDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        options: FocusManagementService.FocusOptions) async throws
    func focusFileDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        window: Element,
        dialog: Element,
        options: FocusManagementService.FocusOptions,
        onDispatch: @escaping (FocusDispatchRecord) -> Void) async throws
    func requireFileDialogWindowFocusWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        window: Element,
        dialog: Element,
        timeout: TimeInterval) async throws
    func requireFileDialogDispatchFocus(
        target: UIAutomationTarget.ExactWindow,
        window: Element,
        dialog: Element,
        field: Element?) throws
    func requireDialogWindowFocusWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        timeout: TimeInterval) async throws
    func requireDialogDispatchFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element,
        field: Element) throws
    func requireDialogGlobalKeyboardFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element) throws
}

extension FocusManagementService: DialogFocusManaging {
    func focusDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        options: FocusOptions) async throws
    {
        try await self.focusDialogWindowWithOwnedLane(
            target: target, dialog: dialog, options: options, onDispatch: nil)
    }

    func focusWindowWithOwnedLane(
        windowID: CGWindowID,
        options: FocusOptions,
        expectedIdentity: WindowMutationIdentity?) async throws
    {
        try await self.focusWindowWithOwnedLane(
            windowID: windowID,
            options: options,
            expectedIdentity: expectedIdentity,
            dispatchGuard: nil,
            onDispatch: nil)
    }
}
