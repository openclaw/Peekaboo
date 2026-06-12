import CoreGraphics
import Foundation
import PeekabooAutomationKit

public enum PeekabooBridgeRequest: Codable, Sendable {
    case handshake(PeekabooBridgeHandshake)
    case permissionsStatus
    case requestPostEventPermission
    case daemonStatus
    case daemonStop
    case daemonStopIf(PeekabooBridgeDaemonStopRequest)
    case browserStatus(PeekabooBridgeBrowserChannelRequest)
    case browserConnect(PeekabooBridgeBrowserChannelRequest)
    case browserDisconnect
    case browserExecute(PeekabooBridgeBrowserExecuteRequest)
    case captureScreen(PeekabooBridgeCaptureScreenRequest)
    case captureWindow(PeekabooBridgeCaptureWindowRequest)
    case captureFrontmost(PeekabooBridgeCaptureFrontmostRequest)
    case captureArea(PeekabooBridgeCaptureAreaRequest)
    case detectElements(PeekabooBridgeDetectElementsRequest)
    case inspectAccessibilityTree(PeekabooBridgeInspectAccessibilityTreeRequest)
    case desktopObservation(DesktopObservationRequest)
    case click(PeekabooBridgeClickRequest)
    case type(PeekabooBridgeTypeRequest)
    case typeActions(PeekabooBridgeTypeActionsRequest)
    case targetedTypeActions(PeekabooBridgeTargetedTypeActionsRequest)
    case setValue(PeekabooBridgeSetValueRequest)
    case performAction(PeekabooBridgePerformActionRequest)
    case scroll(PeekabooBridgeScrollRequest)
    case hotkey(PeekabooBridgeHotkeyRequest)
    case targetedHotkey(PeekabooBridgeTargetedHotkeyRequest)
    case targetedClick(PeekabooBridgeTargetedClickRequest)
    case swipe(PeekabooBridgeSwipeRequest)
    case drag(PeekabooBridgeDragRequest)
    case moveMouse(PeekabooBridgeMoveMouseRequest)
    case waitForElement(PeekabooBridgeWaitRequest)
    case listWindows(PeekabooBridgeWindowTargetRequest)
    case focusWindow(PeekabooBridgeWindowTargetRequest)
    case moveWindow(PeekabooBridgeWindowMoveRequest)
    case resizeWindow(PeekabooBridgeWindowResizeRequest)
    case setWindowBounds(PeekabooBridgeWindowBoundsRequest)
    case closeWindow(PeekabooBridgeWindowTargetRequest)
    case minimizeWindow(PeekabooBridgeWindowTargetRequest)
    case maximizeWindow(PeekabooBridgeWindowTargetRequest)
    case getFocusedWindow
    case listApplications
    case findApplication(PeekabooBridgeAppIdentifierRequest)
    case getFrontmostApplication
    case isApplicationRunning(PeekabooBridgeAppIdentifierRequest)
    case launchApplication(PeekabooBridgeAppIdentifierRequest)
    case activateApplication(PeekabooBridgeAppIdentifierRequest)
    case quitApplication(PeekabooBridgeQuitAppRequest)
    case hideApplication(PeekabooBridgeAppIdentifierRequest)
    case unhideApplication(PeekabooBridgeAppIdentifierRequest)
    case hideOtherApplications(PeekabooBridgeAppIdentifierRequest)
    case showAllApplications
    case listMenus(PeekabooBridgeMenuListRequest)
    case listFrontmostMenus
    case clickMenuItem(PeekabooBridgeMenuClickRequest)
    case clickMenuItemByName(PeekabooBridgeMenuClickByNameRequest)
    case listMenuExtras
    case clickMenuExtra(PeekabooBridgeMenuBarClickByNameRequest)
    case menuExtraOpenMenuFrame(PeekabooBridgeMenuExtraOpenRequest)
    case listMenuBarItems(Bool)
    case clickMenuBarItemNamed(PeekabooBridgeMenuBarClickByNameRequest)
    case clickMenuBarItemIndex(PeekabooBridgeMenuBarClickByIndexRequest)
    case listDockItems(PeekabooBridgeDockListRequest)
    case launchDockItem(PeekabooBridgeDockLaunchRequest)
    case rightClickDockItem(PeekabooBridgeDockRightClickRequest)
    case hideDock
    case showDock
    case isDockHidden
    case findDockItem(PeekabooBridgeDockFindRequest)
    case dialogFindActive(PeekabooBridgeDialogFindRequest)
    case dialogClickButton(PeekabooBridgeDialogClickButtonRequest)
    case dialogEnterText(PeekabooBridgeDialogEnterTextRequest)
    case dialogHandleFile(PeekabooBridgeDialogHandleFileRequest)
    case dialogDismiss(PeekabooBridgeDialogDismissRequest)
    case dialogListElements(PeekabooBridgeDialogFindRequest)
    case createSnapshot(PeekabooBridgeCreateSnapshotRequest)
    case storeDetectionResult(PeekabooBridgeStoreDetectionRequest)
    case getDetectionResult(PeekabooBridgeGetDetectionRequest)
    case storeScreenshot(PeekabooBridgeStoreScreenshotRequest)
    case storeAnnotatedScreenshot(PeekabooBridgeStoreAnnotatedScreenshotRequest)
    case listSnapshots
    case getMostRecentSnapshot(PeekabooBridgeGetMostRecentSnapshotRequest)
    case cleanSnapshot(PeekabooBridgeCleanSnapshotRequest)
    case cleanSnapshotsOlderThan(PeekabooBridgeCleanSnapshotsOlderRequest)
    case cleanAllSnapshots
    case appleScriptProbe
}

extension PeekabooBridgeRequest {
    public var operation: PeekabooBridgeOperation {
        switch self {
        case .handshake: .permissionsStatus
        case .permissionsStatus: .permissionsStatus
        case .requestPostEventPermission: .requestPostEventPermission
        case .daemonStatus: .daemonStatus
        case .daemonStop: .daemonStop
        case .daemonStopIf: .daemonStop
        case .browserStatus: .browserStatus
        case .browserConnect: .browserConnect
        case .browserDisconnect: .browserDisconnect
        case .browserExecute: .browserExecute
        case .captureScreen: .captureScreen
        case .captureWindow: .captureWindow
        case .captureFrontmost: .captureFrontmost
        case .captureArea: .captureArea
        case .detectElements: .detectElements
        case .inspectAccessibilityTree: .inspectAccessibilityTree
        case .desktopObservation: .desktopObservation
        case .click: .click
        case .type: .type
        case .typeActions: .typeActions
        case .targetedTypeActions: .targetedTypeActions
        case .setValue: .setValue
        case .performAction: .performAction
        case .scroll: .scroll
        case .hotkey: .hotkey
        case .targetedHotkey: .targetedHotkey
        case .targetedClick: .targetedClick
        case .swipe: .swipe
        case .drag: .drag
        case .moveMouse: .moveMouse
        case .waitForElement: .waitForElement
        case .listWindows: .listWindows
        case .focusWindow: .focusWindow
        case .moveWindow: .moveWindow
        case .resizeWindow: .resizeWindow
        case .setWindowBounds: .setWindowBounds
        case .closeWindow: .closeWindow
        case .minimizeWindow: .minimizeWindow
        case .maximizeWindow: .maximizeWindow
        case .getFocusedWindow: .getFocusedWindow
        case .listApplications: .listApplications
        case .findApplication: .findApplication
        case .getFrontmostApplication: .getFrontmostApplication
        case .isApplicationRunning: .isApplicationRunning
        case .launchApplication: .launchApplication
        case .activateApplication: .activateApplication
        case .quitApplication: .quitApplication
        case .hideApplication: .hideApplication
        case .unhideApplication: .unhideApplication
        case .hideOtherApplications: .hideOtherApplications
        case .showAllApplications: .showAllApplications
        case .listMenus: .listMenus
        case .listFrontmostMenus: .listFrontmostMenus
        case .clickMenuItem: .clickMenuItem
        case .clickMenuItemByName: .clickMenuItemByName
        case .listMenuExtras: .listMenuExtras
        case .clickMenuExtra: .clickMenuExtra
        case .menuExtraOpenMenuFrame: .menuExtraOpenMenuFrame
        case .listMenuBarItems: .listMenuBarItems
        case .clickMenuBarItemNamed: .clickMenuBarItemNamed
        case .clickMenuBarItemIndex: .clickMenuBarItemIndex
        case .listDockItems: .listDockItems
        case .launchDockItem: .launchDockItem
        case .rightClickDockItem: .rightClickDockItem
        case .hideDock: .hideDock
        case .showDock: .showDock
        case .isDockHidden: .isDockHidden
        case .findDockItem: .findDockItem
        case .dialogFindActive: .dialogFindActive
        case .dialogClickButton: .dialogClickButton
        case .dialogEnterText: .dialogEnterText
        case .dialogHandleFile: .dialogHandleFile
        case .dialogDismiss: .dialogDismiss
        case .dialogListElements: .dialogListElements
        case .createSnapshot: .createSnapshot
        case .storeDetectionResult: .storeDetectionResult
        case .getDetectionResult: .getDetectionResult
        case .storeScreenshot: .storeScreenshot
        case .storeAnnotatedScreenshot: .storeAnnotatedScreenshot
        case .listSnapshots: .listSnapshots
        case .getMostRecentSnapshot: .getMostRecentSnapshot
        case .cleanSnapshot: .cleanSnapshot
        case .cleanSnapshotsOlderThan: .cleanSnapshotsOlderThan
        case .cleanAllSnapshots: .cleanAllSnapshots
        case .appleScriptProbe: ._appleScriptProbe
        }
    }
}

public enum PeekabooBridgeResponse: Codable, Sendable {
    case handshake(PeekabooBridgeHandshakeResponse)
    case permissionsStatus(PermissionsStatus)
    case daemonStatus(PeekabooDaemonStatus)
    case browserStatus(PeekabooBridgeBrowserStatus)
    case browserToolResponse(PeekabooBridgeBrowserToolResponse)
    case capture(CaptureResult)
    case elementDetection(ElementDetectionResult)
    case desktopObservation(DesktopObservationResult)
    case ok
    case waitResult(WaitForElementResult)
    case windows([ServiceWindowInfo])
    case window(ServiceWindowInfo?)
    case applications([ServiceApplicationInfo])
    case application(ServiceApplicationInfo)
    case bool(Bool)
    case typeResult(TypeResult)
    case elementActionResult(ElementActionResult)
    case clickResult(ClickResult)
    case menuStructure(MenuStructure)
    case menuExtras([MenuExtraInfo])
    case menuBarItems([MenuBarItemInfo])
    case dockItems([DockItem])
    case dockItem(DockItem?)
    case rect(CGRect?)
    case dialogInfo(DialogInfo)
    case dialogElements(DialogElements)
    case dialogResult(DialogActionResult)
    case snapshotId(String)
    case snapshots([SnapshotInfo])
    case detection(ElementDetectionResult)
    case int(Int)
    case error(PeekabooBridgeErrorEnvelope)
}
