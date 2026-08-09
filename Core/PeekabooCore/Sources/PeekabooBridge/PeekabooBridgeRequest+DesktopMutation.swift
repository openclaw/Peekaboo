import Foundation
import PeekabooAutomationKit

enum PeekabooBridgeRequestContext {
    @TaskLocal static var clientConnectionProbe: (@Sendable () -> Bool)?

    static func checkRequestIsActive() throws {
        try Task.checkCancellation()
        guard self.clientConnectionProbe?() != false else {
            throw CancellationError()
        }
    }
}

actor PeekabooBridgeMutationGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var locked = false
    private var waiters: [Waiter] = []

    var waitingCount: Int {
        self.waiters.count
    }

    func acquire() async throws {
        try Task.checkCancellation()

        let waiterID = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.enqueue(waiterID, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }

        guard acquired else {
            throw CancellationError()
        }
        if Task.isCancelled {
            self.release()
            throw CancellationError()
        }
    }

    func release() {
        guard !self.waiters.isEmpty else {
            self.locked = false
            return
        }
        self.waiters.removeFirst().continuation.resume(returning: true)
    }

    private func enqueue(_ id: UUID, continuation: CheckedContinuation<Bool, Never>) {
        guard self.locked else {
            self.locked = true
            continuation.resume(returning: true)
            return
        }
        self.waiters.append(Waiter(id: id, continuation: continuation))
    }

    private func cancel(_ id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        self.waiters.remove(at: index).continuation.resume(returning: false)
    }
}

extension PeekabooBridgeRequest {
    /// Native services own these leases after resolving and revalidating their exact target.
    /// Remote callers and the Bridge router must not acquire a second copy of the same lane.
    var nativeLeafOwnsDesktopOperationLane: Bool {
        switch self {
        case .click,
             .type,
             .typeActions,
             .targetedTypeActions,
             .exactWindowTargetedTypeActions,
             .setValue,
             .performAction,
             .scroll,
             .targetedScroll,
             .hotkey,
             .targetedHotkey,
             .exactWindowTargetedHotkey,
             .targetedClick,
             .swipe,
             .drag,
             .moveMouse,
             .focusWindow,
             .moveWindow,
             .resizeWindow,
             .setWindowBounds,
             .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow,
             .restoreWindow,
             .maximizeWindow,
             .launchApplication,
             .launchApplicationWithOptions,
             .relaunchApplicationWithOptions,
             .activateApplication,
             .quitApplication,
             .hideApplication,
             .unhideApplication,
             .hideOtherApplications,
             .showAllApplications,
             .clickMenuItem,
             .clickMenuItemByName,
             .clickMenuExtra,
             .clickMenuBarItemNamed,
             .clickMenuBarItemIndex,
             .launchDockItem,
             .rightClickDockItem,
             .hideDock,
             .showDock:
            true
        default:
            false
        }
    }

    var desktopOperationScope: DesktopOperationScope {
        switch self {
        case let .exactWindowTargetedTypeActions(payload):
            .window(payload.expectedWindowIdentity)
        case let .exactWindowTargetedHotkey(payload):
            .window(payload.expectedWindowIdentity)
        case let .targetedClick(payload):
            payload.expectedWindowIdentity.map(DesktopOperationScope.window) ?? .global
        case let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .moveWindow(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .resizeWindow(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .setWindowBounds(payload):
            payload.expectedIdentity.map(DesktopOperationScope.window) ?? .global
        case let .quitApplication(payload):
            payload.expectedIdentity.map(DesktopOperationScope.process) ?? .global
        default:
            .global
        }
    }

    var requiresPinnedWindowMutationReceipt: Bool {
        switch self {
        case .moveWindow,
             .resizeWindow,
             .setWindowBounds,
             .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow,
             .restoreWindow,
             .maximizeWindow:
            true
        default:
            false
        }
    }

    var pinnedWindowMutation: (target: WindowTarget, identity: WindowMutationIdentity)? {
        switch self {
        case let .moveWindow(payload):
            payload.expectedIdentity.map { (payload.target, $0) }
        case let .resizeWindow(payload):
            payload.expectedIdentity.map { (payload.target, $0) }
        case let .setWindowBounds(payload):
            payload.expectedIdentity.map { (payload.target, $0) }
        case let .closeWindow(payload),
             let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            payload.expectedIdentity.map { (payload.target, $0) }
        default:
            nil
        }
    }

    var mayMutateDesktop: Bool {
        if case let .dialogFindActive(request) = self {
            return request.windowTitle != nil
        }
        if case let .dialogListElements(request) = self {
            return request.windowTitle != nil
        }
        if case let .desktopObservation(request) = self {
            let mayOpenMenuBarPopover = if case let .menubarPopover(_, openIfNeeded) = request.target {
                openIfNeeded != nil
            } else {
                false
            }
            return request.capture.focus != .background ||
                (request.detection.mode != .none && request.detection.allowWebFocusFallback) ||
                mayOpenMenuBarPopover
        }
        if case let .detectElements(request) = self {
            return request.windowContext?.shouldFocusWebContent == true
        }
        if case let .inspectAccessibilityTree(request) = self {
            return request.windowContext?.shouldFocusWebContent == true
        }
        return self.operation.mutatesDesktop
    }
}

extension PeekabooBridgeOperation {
    fileprivate var mutatesDesktop: Bool {
        switch self {
        case .requestPostEventPermission,
             .browserExecute,
             .click,
             .type,
             .typeActions,
             .setValue,
             .performAction,
             .scroll,
             .targetedScroll,
             .hotkey,
             .targetedHotkey,
             .exactWindowTargetedHotkey,
             .targetedTypeActions,
             .exactWindowTargetedTypeActions,
             .targetedClick,
             .exactWindowTargetedClick,
             .swipe,
             .drag,
             .moveMouse,
             .focusWindow,
             .moveWindow,
             .resizeWindow,
             .setWindowBounds,
             .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow,
             .restoreWindow,
             .maximizeWindow,
             .launchApplication,
             .launchApplicationWithOptions,
             .relaunchApplicationWithOptions,
             .activateApplication,
             .quitApplication,
             .hideApplication,
             .unhideApplication,
             .hideOtherApplications,
             .showAllApplications,
             .clickMenuItem,
             .clickMenuItemByName,
             .clickMenuExtra,
             .clickMenuBarItemNamed,
             .clickMenuBarItemIndex,
             .launchDockItem,
             .rightClickDockItem,
             .hideDock,
             .showDock,
             .dialogClickButton,
             .backgroundDialogClickButton,
             .dialogEnterText,
             .dialogHandleFile,
             .dialogDismiss:
            true
        case .permissionsStatus,
             .daemonStatus,
             .daemonStop,
             .browserStatus,
             .browserConnect,
             .browserDisconnect,
             .captureScreen,
             .captureWindow,
             .captureFrontmost,
             .captureArea,
             .desktopObservation,
             .detectElements,
             .inspectAccessibilityTree,
             .getFocusedElement,
             .waitForElement,
             .listWindows,
             .getFocusedWindow,
             .listApplications,
             .findApplication,
             .getFrontmostApplication,
             .isApplicationRunning,
             .listMenus,
             .listFrontmostMenus,
             .listMenuExtras,
             .menuExtraOpenMenuFrame,
             .listMenuBarItems,
             .listDockItems,
             .isDockHidden,
             .findDockItem,
             .dialogFindActive,
             .dialogListElements,
             .createSnapshot,
             .storeDetectionResult,
             .getDetectionResult,
             .storeScreenshot,
             .storeAnnotatedScreenshot,
             .listSnapshots,
             .getMostRecentSnapshot,
             .invalidateImplicitLatestSnapshot,
             .cleanSnapshot,
             .cleanSnapshotsOlderThan,
             .cleanAllSnapshots,
             ._appleScriptProbe:
            false
        }
    }
}
