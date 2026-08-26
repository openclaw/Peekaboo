import Foundation

extension PeekabooBridgeOperation {
    var mutatesDesktop: Bool {
        PeekabooBridgeOperationResultSemantics.contract(for: self).completion.mutatesDesktop
    }

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

    /// The operation's static/current TCC permissions. Protocol- and request-specific modifiers stay server-owned.
    public var requiredPermissions: Set<PeekabooBridgePermissionKind> {
        PeekabooBridgeOperationResultSemantics.operationPolicy(for: self).requiredPermissions
    }

    /// Operations enabled by default for remote helper hosts.
    public static let remoteDefaultAllowlist: Set<PeekabooBridgeOperation> = [
        .permissionsStatus,
        .requestPostEventPermission,
        .daemonStatus,
        .daemonStop,
        .agentExecutionTrace,
        .observeProcessGeneration,
        .certificationProducerAttestation,
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
        .exactWindowPixelFocusType,
        .foregroundModifierClick,
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
        .ownsSnapshot,
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
