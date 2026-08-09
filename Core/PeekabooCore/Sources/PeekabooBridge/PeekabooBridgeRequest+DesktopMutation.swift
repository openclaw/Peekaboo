import Foundation

actor PeekabooBridgeMutationGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard self.locked else {
            self.locked = true
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }

    func release() {
        guard !self.waiters.isEmpty else {
            self.locked = false
            return
        }
        self.waiters.removeFirst().resume()
    }
}

extension PeekabooBridgeRequest {
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
             .targetedTypeActions,
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
