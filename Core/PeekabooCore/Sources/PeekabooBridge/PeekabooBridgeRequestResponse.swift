import CoreGraphics
import Foundation
import PeekabooAutomationKit

public enum PeekabooBridgeRequest: Codable, Sendable {
    indirect case attestedOperation(PeekabooBridgeAttestedOperationRequest)
    indirect case projectedAction(PeekabooBridgeProjectedActionRequest)
    case handshake(PeekabooBridgeHandshake)
    case permissionsStatus
    case requestPostEventPermission
    case daemonStatus
    case daemonStop
    case daemonStopIf(PeekabooBridgeDaemonStopRequest)
    case agentExecutionTrace(PeekabooBridgeAgentExecutionTraceRequest)
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
    case getFocusedElement(PeekabooBridgeFocusedElementRequest)
    case desktopObservation(DesktopObservationRequest)
    case click(PeekabooBridgeClickRequest)
    case type(PeekabooBridgeTypeRequest)
    case typeActions(PeekabooBridgeTypeActionsRequest)
    case targetedTypeActions(PeekabooBridgeTargetedTypeActionsRequest)
    case exactWindowTargetedTypeActions(PeekabooBridgeExactWindowTypeActionsRequest)
    case setValue(PeekabooBridgeSetValueRequest)
    case performAction(PeekabooBridgePerformActionRequest)
    case scroll(PeekabooBridgeScrollRequest)
    case targetedScroll(PeekabooBridgeScrollRequest)
    case hotkey(PeekabooBridgeHotkeyRequest)
    case targetedHotkey(PeekabooBridgeTargetedHotkeyRequest)
    case exactWindowTargetedHotkey(PeekabooBridgeExactWindowHotkeyRequest)
    case createExactWindowHeldPointerOwner
    case beginExactWindowHeldPointer(PeekabooBridgeBeginHeldPointerRequest)
    case releaseExactWindowHeldPointer(PeekabooBridgeFinishHeldPointerRequest)
    case revokeExactWindowHeldPointer(PeekabooBridgeFinishHeldPointerRequest)
    case disconnectExactWindowHeldPointerOwner(PeekabooBridgeHeldPointerOwnerRequest)
    case targetedClick(PeekabooBridgeTargetedClickRequest)
    case swipe(PeekabooBridgeSwipeRequest)
    case drag(PeekabooBridgeDragRequest)
    case moveMouse(PeekabooBridgeMoveMouseRequest)
    case waitForElement(PeekabooBridgeWaitRequest)
    case listWindows(PeekabooBridgeWindowTargetRequest)
    case listWindowMutationInventory(PeekabooBridgeWindowTargetRequest)
    case focusWindow(PeekabooBridgeWindowTargetRequest)
    case moveWindow(PeekabooBridgeWindowMoveRequest)
    case resizeWindow(PeekabooBridgeWindowResizeRequest)
    case setWindowBounds(PeekabooBridgeWindowBoundsRequest)
    case closeWindow(PeekabooBridgeWindowTargetRequest)
    case backgroundCloseWindow(PeekabooBridgeWindowTargetRequest)
    case minimizeWindow(PeekabooBridgeWindowTargetRequest)
    case restoreWindow(PeekabooBridgeWindowTargetRequest)
    case maximizeWindow(PeekabooBridgeWindowTargetRequest)
    case getFocusedWindow
    case listApplications
    case listApplicationMutationInventory
    case findApplication(PeekabooBridgeAppIdentifierRequest)
    case getFrontmostApplication
    case isApplicationRunning(PeekabooBridgeAppIdentifierRequest)
    case launchApplication(PeekabooBridgeAppIdentifierRequest)
    case launchApplicationWithOptions(ApplicationLaunchRequest)
    case relaunchApplicationWithOptions(ApplicationRelaunchRequest)
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
    case backgroundDialogClickButton(PeekabooBridgeDialogClickButtonRequest)
    case dialogEnterText(PeekabooBridgeDialogEnterTextRequest)
    case dialogHandleFile(PeekabooBridgeDialogHandleFileRequest)
    case dialogDismiss(PeekabooBridgeDialogDismissRequest)
    case dialogListElements(PeekabooBridgeDialogFindRequest)
    case targetedDialogListElements(DialogTargetSelector)
    case prepareDialogAction(DialogActionPreparationRequest)
    case exactDialogClickButton(PreparedDialogActionReceipt)
    case exactDialogDismiss(PreparedDialogActionReceipt)
    case exactDialogEnterText(DialogInputExecutionRequest)
    case exactDialogForceDismiss(DialogForcedDismissExecutionRequest)
    case createSnapshot(PeekabooBridgeCreateSnapshotRequest)
    case storeDetectionResult(PeekabooBridgeStoreDetectionRequest)
    case getDetectionResult(PeekabooBridgeGetDetectionRequest)
    case storeScreenshot(PeekabooBridgeStoreScreenshotRequest)
    case storeObservationSnapshot(PeekabooBridgeStoreObservationSnapshotRequest)
    case storeAnnotatedScreenshot(PeekabooBridgeStoreAnnotatedScreenshotRequest)
    case listSnapshots
    case getMostRecentSnapshot(PeekabooBridgeGetMostRecentSnapshotRequest)
    case invalidateImplicitLatestSnapshot(PeekabooBridgeInvalidateImplicitLatestSnapshotRequest)
    case beginSnapshotMutation(PeekabooBridgeBeginSnapshotMutationRequest)
    case finishSnapshotMutation(PeekabooBridgeFinishSnapshotMutationRequest)
    case cleanSnapshot(PeekabooBridgeCleanSnapshotRequest)
    case cleanSnapshotsOlderThan(PeekabooBridgeCleanSnapshotsOlderRequest)
    case cleanAllSnapshots
    case appleScriptProbe
}

extension PeekabooBridgeRequest {
    public var operation: PeekabooBridgeOperation {
        switch self {
        case let .attestedOperation(payload): payload.request.operation
        case let .projectedAction(payload): payload.request.operation
        case .handshake: .permissionsStatus
        case .permissionsStatus: .permissionsStatus
        case .requestPostEventPermission: .requestPostEventPermission
        case .daemonStatus: .daemonStatus
        case .daemonStop: .daemonStop
        case .daemonStopIf: .daemonStop
        case .agentExecutionTrace: .agentExecutionTrace
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
        case .getFocusedElement: .getFocusedElement
        case .desktopObservation: .desktopObservation
        case .click: .click
        case .type: .type
        case .typeActions: .typeActions
        case .targetedTypeActions: .targetedTypeActions
        case .exactWindowTargetedTypeActions: .exactWindowTargetedTypeActions
        case .setValue: .setValue
        case .performAction: .performAction
        case .scroll: .scroll
        case .targetedScroll: .targetedScroll
        case .hotkey: .hotkey
        case .targetedHotkey: .targetedHotkey
        case .exactWindowTargetedHotkey: .exactWindowTargetedHotkey
        case .createExactWindowHeldPointerOwner: .createExactWindowHeldPointerOwner
        case .beginExactWindowHeldPointer: .beginExactWindowHeldPointer
        case .releaseExactWindowHeldPointer: .releaseExactWindowHeldPointer
        case .revokeExactWindowHeldPointer: .revokeExactWindowHeldPointer
        case .disconnectExactWindowHeldPointerOwner: .disconnectExactWindowHeldPointerOwner
        case let .targetedClick(payload):
            payload.targetWindowID == nil ? .targetedClick : .exactWindowTargetedClick
        case .swipe: .swipe
        case .drag: .drag
        case .moveMouse: .moveMouse
        case .waitForElement: .waitForElement
        case .listWindows, .listWindowMutationInventory: .listWindows
        case .focusWindow: .focusWindow
        case .moveWindow: .moveWindow
        case .resizeWindow: .resizeWindow
        case .setWindowBounds: .setWindowBounds
        case .closeWindow: .closeWindow
        case .backgroundCloseWindow: .backgroundCloseWindow
        case .minimizeWindow: .minimizeWindow
        case .restoreWindow: .restoreWindow
        case .maximizeWindow: .maximizeWindow
        case .getFocusedWindow: .getFocusedWindow
        case .listApplications, .listApplicationMutationInventory: .listApplications
        case .findApplication: .findApplication
        case .getFrontmostApplication: .getFrontmostApplication
        case .isApplicationRunning: .isApplicationRunning
        case .launchApplication: .launchApplication
        case .launchApplicationWithOptions: .launchApplicationWithOptions
        case .relaunchApplicationWithOptions: .relaunchApplicationWithOptions
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
        case .backgroundDialogClickButton: .backgroundDialogClickButton
        case .dialogEnterText: .dialogEnterText
        case .dialogHandleFile: .dialogHandleFile
        case .dialogDismiss: .dialogDismiss
        case .dialogListElements: .dialogListElements
        case .targetedDialogListElements: .targetedDialogListElements
        case .prepareDialogAction: .prepareDialogAction
        case .exactDialogClickButton: .exactDialogClickButton
        case .exactDialogDismiss: .exactDialogDismiss
        case .exactDialogEnterText: .exactDialogEnterText
        case .exactDialogForceDismiss: .exactDialogForceDismiss
        case .createSnapshot: .createSnapshot
        case .storeDetectionResult: .storeDetectionResult
        case .getDetectionResult: .getDetectionResult
        case .storeScreenshot: .storeScreenshot
        case .storeObservationSnapshot: .storeObservationSnapshot
        case .storeAnnotatedScreenshot: .storeAnnotatedScreenshot
        case .listSnapshots: .listSnapshots
        case .getMostRecentSnapshot: .getMostRecentSnapshot
        case .invalidateImplicitLatestSnapshot: .invalidateImplicitLatestSnapshot
        case .beginSnapshotMutation: .beginSnapshotMutation
        case .finishSnapshotMutation: .finishSnapshotMutation
        case .cleanSnapshot: .cleanSnapshot
        case .cleanSnapshotsOlderThan: .cleanSnapshotsOlderThan
        case .cleanAllSnapshots: .cleanAllSnapshots
        case .appleScriptProbe: ._appleScriptProbe
        }
    }
}

public enum PeekabooBridgeResponse: Codable, Sendable {
    indirect case attestedOperation(PeekabooBridgeAttestedOperationResponse)
    case operationSessionRollover(PeekabooBridgeOperationSessionRefusal)
    indirect case projectedAction(PeekabooBridgeProjectedActionResponse)
    case handshake(PeekabooBridgeHandshakeResponse)
    case permissionsStatus(PermissionsStatus)
    case daemonStatus(PeekabooDaemonStatus)
    case agentExecutionTrace(PeekabooBridgeAgentExecutionTraceResponse)
    case browserStatus(PeekabooBridgeBrowserStatus)
    case browserToolResponse(PeekabooBridgeBrowserToolResponse)
    case capture(CaptureResult)
    case elementDetection(ElementDetectionResult)
    case focusedElement(UIFocusInfo?)
    case desktopObservation(DesktopObservationResult)
    case ok
    case waitResult(WaitForElementResult)
    case windows([ServiceWindowInfo])
    case windowMutationInventory(DesktopTargetPlanning.Inventory<ServiceWindowInfo>)
    case window(ServiceWindowInfo?)
    case applications([ServiceApplicationInfo])
    case applicationMutationInventory(DesktopTargetPlanning.Inventory<ServiceApplicationInfo>)
    case application(ServiceApplicationInfo)
    case bool(Bool)
    case typeResult(TypeResult)
    case exactWindowHeldPointerOwner(ExactWindowHeldPointerOwner)
    case exactWindowHeldPointerReceipt(ExactWindowHeldPointerReceipt)
    case exactWindowHeldPointerTermination(ExactWindowHeldPointerTermination?)
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
    case preparedDialogAction(PreparedDialogActionReceipt)
    case snapshotId(String)
    case snapshotMutationLease(SnapshotMutationLease)
    case snapshots([SnapshotInfo])
    case detection(ElementDetectionResult)
    case int(Int)
    case error(PeekabooBridgeErrorEnvelope)
}

extension PeekabooBridgeResponse {
    private static let fallbackErrorData = Data(
        #"{"error":{"_0":{"code":"internalError","message":"Failed to encode bridge error response"}}}"#.utf8)

    /// Encode an error envelope for the bridge wire format.
    ///
    /// Never returns empty `Data`. An empty payload cannot be decoded as
    /// `PeekabooBridgeResponse` and leaves clients with a confusing decode
    /// failure instead of the original error.
    static func encodeError(
        _ envelope: PeekabooBridgeErrorEnvelope,
        using encoder: JSONEncoder = .peekabooBridgeEncoder()) -> Data
    {
        self.encodeError(envelope) { response in
            try encoder.encode(response)
        }
    }

    static func encodeError(
        _ envelope: PeekabooBridgeErrorEnvelope,
        encodeWith encode: (Self) throws -> Data) -> Data
    {
        guard let data = try? encode(.error(envelope)), !data.isEmpty else {
            return self.fallbackErrorData
        }
        return data
    }
}
