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
             .showDock,
             .dialogFindActive,
             .dialogClickButton,
             .backgroundDialogClickButton,
             .dialogEnterText,
             .dialogHandleFile,
             .dialogDismiss,
             .dialogListElements,
             .desktopObservation:
            true
        default:
            false
        }
    }

    var desktopOperationScope: DesktopOperationScope {
        switch self {
        case let .exactWindowTargetedTypeActions(payload):
            .process(ApplicationProcessIdentity(
                processIdentifier: payload.expectedWindowIdentity.ownerProcessIdentifier,
                processStartIdentity: payload.expectedWindowIdentity.ownerProcessStartIdentity))
        case let .exactWindowTargetedHotkey(payload):
            .process(ApplicationProcessIdentity(
                processIdentifier: payload.expectedWindowIdentity.ownerProcessIdentifier,
                processStartIdentity: payload.expectedWindowIdentity.ownerProcessStartIdentity))
        case let .targetedHotkey(payload):
            payload.expectedProcessIdentity.map(DesktopOperationScope.process) ?? .global
        case let .targetedTypeActions(payload):
            payload.expectedProcessIdentity.map(DesktopOperationScope.process) ?? .global
        case let .targetedClick(payload):
            if let targetWindowID = payload.targetWindowID,
               let identity = payload.expectedWindowIdentity,
               payload.expectedWindowBounds != nil,
               identity.windowID == targetWindowID
            {
                .process(ApplicationProcessIdentity(
                    processIdentifier: identity.ownerProcessIdentifier,
                    processStartIdentity: identity.ownerProcessStartIdentity))
            } else {
                payload.expectedProcessIdentity.map(DesktopOperationScope.process) ?? .global
            }
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

    /// Bridge-owned coordination for native desktop reads and mutation paths whose concrete
    /// service provider does not own a leaf lease. Unresolved reads take the exclusive global
    /// lane so they cannot observe a partially completed scoped mutation.
    var desktopReadOperationLane: (scope: DesktopOperationScope, access: DesktopOperationAccess)? {
        guard !self.mayMutateDesktop else { return nil }
        switch self {
        case .detectElements:
            // Detection publishes into the requested snapshot before returning. Keep the whole
            // operation globally exclusive so a generation-drift retry cannot expose stale data.
            return (.global, .write)
        case let .inspectAccessibilityTree(request):
            return Self.exactWindowReadLane(for: request.windowContext)
        case .captureScreen,
             .captureWindow,
             .captureFrontmost,
             .captureArea,
             .desktopObservation,
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
             .dialogListElements:
            return (.global, .write)
        default:
            return nil
        }
    }

    var exactWindowReadIdentity: WindowMutationIdentity? {
        let context: WindowContext? = switch self {
        case let .inspectAccessibilityTree(request): request.windowContext
        default: nil
        }
        guard let context,
              let identity = context.windowMutationIdentity,
              let windowID = context.windowID,
              let processID = context.applicationProcessId,
              windowID == identity.windowID,
              processID == identity.ownerProcessIdentifier
        else {
            return nil
        }
        return identity
    }

    private static func exactWindowReadLane(
        for context: WindowContext?) -> (scope: DesktopOperationScope, access: DesktopOperationAccess)
    {
        guard let context,
              let identity = context.windowMutationIdentity,
              let windowID = context.windowID,
              let processID = context.applicationProcessId,
              windowID == identity.windowID,
              processID == identity.ownerProcessIdentifier
        else {
            return (.global, .write)
        }
        return (.window(identity), .read)
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
        if case let .projectedAction(payload) = self {
            return payload.request.mayMutateDesktop
        }
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
        if case let .launchApplicationWithOptions(request) = self {
            return request.activates
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
             .storeObservationSnapshot,
             .storeAnnotatedScreenshot,
             .listSnapshots,
             .getMostRecentSnapshot,
             .invalidateImplicitLatestSnapshot,
             .beginSnapshotMutation,
             .finishSnapshotMutation,
             .cleanSnapshot,
             .cleanSnapshotsOlderThan,
             .cleanAllSnapshots,
             ._appleScriptProbe:
            false
        }
    }
}
