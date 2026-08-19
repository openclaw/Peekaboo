import Foundation

extension PeekabooBridgeOperation {
    /// Whether Peekaboo's concrete native service retains desktop-lane ownership through its dispatch leaf.
    ///
    /// Bridge routing consults this policy together with the service provider's ownership claim. Keeping the
    /// exhaustive operation list here prevents native host assemblies and request routing from drifting apart.
    public var nativeServiceOwnsDesktopOperationLane: Bool {
        PeekabooBridgeOperationResultSemantics.operationPolicy(for: self)
            .lane.nativeOwnership == .service
    }

    public static let nativeDesktopOperationLaneOperations: Set<PeekabooBridgeOperation> =
        Set(Self.allCases.filter(\.nativeServiceOwnsDesktopOperationLane))

    var responseCarriesPostMutationWindowState: Bool {
        PeekabooBridgeOperationResultSemantics.operationPolicy(for: self)
            .windowResponseProof == .postMutationState
    }

    /// TCC permissions an operation relies on. Used to gate advertisement/handling.
    public var requiredPermissions: Set<PeekabooBridgePermissionKind> {
        switch self {
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea, .detectElements,
             .desktopObservation:
            [.screenRecording]
        case .targetedHotkey, .targetedTypeActions, .click, .scroll, .swipe, .drag, .moveMouse,
             .beginExactWindowHeldPointer:
            [.postEvent]
        case .exactWindowTargetedHotkey, .exactWindowTargetedTypeActions,
             .exactDialogForceDismiss, .clickMenuBarItemIndex:
            [.postEvent, .accessibility]
        case .inspectAccessibilityTree,
             .getFocusedElement,
             .type, .typeActions, .setValue, .performAction, .hotkey,
             .waitForElement, .listWindows, .focusWindow, .moveWindow, .resizeWindow, .setWindowBounds, .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow, .restoreWindow, .maximizeWindow, .getFocusedWindow, .listMenus, .listFrontmostMenus,
             .clickMenuItem, .clickMenuItemByName, .listMenuExtras, .clickMenuExtra, .menuExtraOpenMenuFrame,
             .listMenuBarItems, .clickMenuBarItemNamed, .listDockItems, .launchDockItem,
             .rightClickDockItem, .hideDock, .showDock, .isDockHidden, .findDockItem, .dialogFindActive,
             .dialogClickButton, .backgroundDialogClickButton, .dialogEnterText, .dialogHandleFile, .dialogDismiss,
             .dialogListElements, .targetedDialogListElements, .prepareDialogAction,
             .exactDialogClickButton, .exactDialogDismiss, .exactDialogEnterText:
            [.accessibility]
        case .targetedClick, .exactWindowTargetedClick, .targetedScroll:
            [.accessibility]
        case ._appleScriptProbe,
             .agentExecutionTrace,
             .createExactWindowHeldPointerOwner,
             .releaseExactWindowHeldPointer,
             .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner,
             .permissionsStatus,
             .requestPostEventPermission,
             .daemonStatus,
             .daemonStop,
             .browserStatus,
             .browserConnect,
             .browserDisconnect,
             .browserExecute,
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
             .listApplications,
             .findApplication,
             .getFrontmostApplication,
             .isApplicationRunning,
             .launchApplication,
             .launchApplicationWithOptions,
             .relaunchApplicationWithOptions,
             .activateApplication,
             .quitApplication,
             .hideApplication,
             .unhideApplication,
             .hideOtherApplications,
             .showAllApplications:
            []
        }
    }

    /// Operations enabled by default for remote helper hosts.
    public static let remoteDefaultAllowlist: Set<PeekabooBridgeOperation> = [
        .permissionsStatus,
        .requestPostEventPermission,
        .daemonStatus,
        .daemonStop,
        .agentExecutionTrace,
        .browserStatus,
        .browserConnect,
        .browserDisconnect,
        .browserExecute,
        .captureScreen,
        .captureWindow,
        .captureFrontmost,
        .captureArea,
        .detectElements,
        .inspectAccessibilityTree,
        .getFocusedElement,
        .desktopObservation,
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
        .createExactWindowHeldPointerOwner,
        .beginExactWindowHeldPointer,
        .releaseExactWindowHeldPointer,
        .revokeExactWindowHeldPointer,
        .disconnectExactWindowHeldPointerOwner,
        .targetedTypeActions,
        .exactWindowTargetedTypeActions,
        .targetedClick,
        .exactWindowTargetedClick,
        .swipe,
        .drag,
        .moveMouse,
        .waitForElement,
        .listWindows,
        .focusWindow,
        .moveWindow,
        .resizeWindow,
        .setWindowBounds,
        .closeWindow,
        .backgroundCloseWindow,
        .minimizeWindow,
        .restoreWindow,
        .maximizeWindow,
        .getFocusedWindow,
        .listApplications,
        .findApplication,
        .getFrontmostApplication,
        .isApplicationRunning,
        .launchApplication,
        .launchApplicationWithOptions,
        .relaunchApplicationWithOptions,
        .activateApplication,
        .quitApplication,
        .hideApplication,
        .hideOtherApplications,
        .showAllApplications,
        .listMenus,
        .listFrontmostMenus,
        .clickMenuItem,
        .clickMenuItemByName,
        .listMenuExtras,
        .clickMenuExtra,
        .menuExtraOpenMenuFrame,
        .listMenuBarItems,
        .clickMenuBarItemNamed,
        .clickMenuBarItemIndex,
        .listDockItems,
        .launchDockItem,
        .rightClickDockItem,
        .hideDock,
        .showDock,
        .isDockHidden,
        .findDockItem,
        .dialogFindActive,
        .dialogClickButton,
        .backgroundDialogClickButton,
        .dialogEnterText,
        .dialogHandleFile,
        .dialogDismiss,
        .dialogListElements,
        .targetedDialogListElements,
        .prepareDialogAction,
        .exactDialogClickButton,
        .exactDialogDismiss,
        .exactDialogEnterText,
        .exactDialogForceDismiss,
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
    ]

    /// Native operations exposed by an embedded host.
    ///
    /// Embedded hosts intentionally do not acquire browser, daemon-control, or interactive permission-prompt
    /// responsibilities. The containing app remains the owner of those product-specific surfaces.
    public static let embeddedDefaultAllowlist: Set<PeekabooBridgeOperation> =
        PeekabooBridgeOperation.remoteDefaultAllowlist.subtracting([
            .agentExecutionTrace,
            .requestPostEventPermission,
            .daemonStatus,
            .daemonStop,
            .browserStatus,
            .browserConnect,
            .browserDisconnect,
            .browserExecute,
        ])
}
