import Foundation
import PeekabooFoundation

extension PeekabooBridgeOperationResultSemantics {
    // The single exhaustive owner for static Bridge operation semantics.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func operationDescriptor(for operation: PeekabooBridgeOperation) -> OperationDescriptor {
        let axForeground = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .foreground)
        let axBackground = DesktopActionOutcome.Delivery(mechanism: .accessibilityAction, mode: .background)
        let valueBackground = DesktopActionOutcome.Delivery(mechanism: .accessibilityValue, mode: .background)
        let globalForeground = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
        let processBackground = DesktopActionOutcome.Delivery(mechanism: .processTargetedEvents, mode: .background)
        let windowBackground = DesktopActionOutcome.Delivery(mechanism: .windowTargetedEvents, mode: .background)
        let nativeForeground = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .foreground)
        let nativeBackground = DesktopActionOutcome.Delivery(mechanism: .nativeFramework, mode: .background)
        let compositeForeground = DesktopActionOutcome.Delivery(mechanism: .composite, mode: .foreground)
        let compositeBackground = DesktopActionOutcome.Delivery(mechanism: .composite, mode: .background)
        let clipboardForeground = DesktopActionOutcome.Delivery(
            mechanism: .clipboardTransaction,
            mode: .foreground)
        let browserForeground = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .foreground)
        let browserBackground = DesktopActionOutcome.Delivery(mechanism: .browserProtocol, mode: .background)

        func descriptor(
            ownership: NativeLaneOwnership = .bridge,
            read: ReadLanePolicy = .none,
            pinnedWindow: PinnedWindowPolicy = .unavailable,
            typedResponse: TypedResponseBinding = .familyOnly,
            requiredPermissions: Set<PeekabooBridgePermissionKind> = [],
            completion: Completion,
            targetPolicy: TargetPolicy,
            responseFamilies: Set<ResponseFamily>,
            responseTargetEvidence: ResponseTargetEvidenceSource = .none) -> OperationDescriptor
        {
            OperationDescriptor(
                operation: operation,
                requiredPermissions: requiredPermissions,
                lane: .init(nativeOwnership: ownership, readPolicy: read),
                pinnedWindow: pinnedWindow,
                typedResponse: typedResponse,
                windowResponseProof: typedResponse == .postMutationWindow ? .postMutationState : .none,
                contract: .init(completion: completion, targetPolicy: targetPolicy),
                responseFamilies: responseFamilies,
                responseTargetEvidence: responseTargetEvidence)
        }

        return switch operation {
        case .permissionsStatus:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.permissionsStatus])
        case .requestPostEventPermission:
            descriptor(
                completion: .dispatchedUnverified(nativeForeground),
                targetPolicy: .global,
                responseFamilies: [.bool])
        case .daemonStatus:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.daemonStatus])
        case .daemonStop:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.bool])
        case .agentExecutionTrace:
            descriptor(
                typedResponse: .agentExecutionTrace,
                completion: .externalProcessDispatch(nativeBackground),
                targetPolicy: .responseResolved,
                responseFamilies: [.agentExecutionTrace],
                responseTargetEvidence: .agentProcess)
        case .observeProcessGeneration:
            descriptor(
                typedResponse: .processGenerationObservation,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.processGenerationObservation])
        case .certificationProducerAttestation:
            descriptor(
                typedResponse: .certificationProducerAttestation,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.certificationProducerAttestation])
        case .browserStatus:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.browserStatus])
        case .browserConnect:
            descriptor(
                completion: .dispatchedUnverified(browserForeground),
                targetPolicy: .external,
                responseFamilies: [.browserStatus],
                responseTargetEvidence: .browserConnection)
        case .browserDisconnect:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.ok])
        case .browserExecute:
            descriptor(
                completion: .dispatchedUnverified(browserBackground),
                targetPolicy: .external,
                responseFamilies: [.browserToolResponse],
                responseTargetEvidence: .browserConnection)
        case .browserSessionBootstrap:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.browserSessionBootstrap])
        case .browserSessionControl:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.ok])
        case .captureScreen, .captureFrontmost, .captureArea:
            descriptor(
                read: .globalExclusive,
                typedResponse: .capture,
                requiredPermissions: [.screenRecording],
                completion: .requestDependent(mutatesDesktop: false),
                targetPolicy: .requestDependent,
                responseFamilies: [.capture],
                responseTargetEvidence: .capture)
        case .captureWindow:
            descriptor(
                read: .exactTargetOrGlobalExclusive,
                typedResponse: .capture,
                requiredPermissions: [.screenRecording],
                completion: .requestDependent(mutatesDesktop: false),
                targetPolicy: .requestDependent,
                responseFamilies: [.capture],
                responseTargetEvidence: .capture)
        case .detectElements:
            descriptor(
                read: .globalExclusive,
                typedResponse: .elementDetection,
                requiredPermissions: [.screenRecording],
                completion: .requestDependent(mutatesDesktop: false),
                targetPolicy: .requestDependent,
                responseFamilies: [.elementDetection])
        case .inspectAccessibilityTree:
            descriptor(
                read: .exactTargetOrGlobalExclusive,
                typedResponse: .elementDetection,
                requiredPermissions: [.accessibility],
                completion: .requestDependent(mutatesDesktop: false),
                targetPolicy: .requestDependent,
                responseFamilies: [.elementDetection],
                responseTargetEvidence: .inspectWindowContext)
        case .getFocusedElement:
            descriptor(
                read: .globalExclusive,
                typedResponse: .focusedElement,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.focusedElement])
        case .desktopObservation:
            descriptor(
                ownership: .service,
                read: .exactTargetOrGlobalExclusive,
                typedResponse: .desktopObservation,
                requiredPermissions: [.screenRecording],
                completion: .requestDependent(mutatesDesktop: false),
                targetPolicy: .requestDependent,
                responseFamilies: [.desktopObservation],
                responseTargetEvidence: .desktopObservation)
        case .click, .scroll:
            descriptor(
                ownership: .service,
                requiredPermissions: [.postEvent],
                completion: .requestDependent(mutatesDesktop: true),
                targetPolicy: .requestDependent,
                responseFamilies: [.ok])
        case .type:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .requestDependent(mutatesDesktop: true),
                targetPolicy: .requestDependent,
                responseFamilies: [.ok])
        case .typeActions:
            descriptor(
                ownership: .service,
                typedResponse: .typeActions,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .global,
                responseFamilies: [.typeResult])
        case .targetedTypeActions:
            descriptor(
                ownership: .service,
                typedResponse: .typeActions,
                requiredPermissions: [.postEvent],
                completion: .dispatchedUnverified(processBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.typeResult])
        case .exactWindowTargetedTypeActions:
            descriptor(
                ownership: .service,
                typedResponse: .typeActions,
                requiredPermissions: [.accessibility, .postEvent],
                completion: .dispatchedUnverified(windowBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.typeResult])
        case .exactWindowPixelFocusType:
            descriptor(
                ownership: .service,
                typedResponse: .typeActions,
                requiredPermissions: [.accessibility, .postEvent],
                completion: .dispatchedUnverified(compositeBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.typeResult])
        case .foregroundModifierClick:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility, .postEvent],
                completion: .dispatchedUnverified(compositeForeground),
                targetPolicy: .requestPinned,
                responseFamilies: [.modifierClickResult])
        case .setValue:
            descriptor(
                ownership: .service,
                typedResponse: .setValue,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(valueBackground),
                targetPolicy: .handlerRequired,
                responseFamilies: [.elementActionResult])
        case .performAction:
            descriptor(
                ownership: .service,
                typedResponse: .performAction,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .handlerRequired,
                responseFamilies: [.elementActionResult])
        case .targetedScroll:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .hotkey:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .global,
                responseFamilies: [.ok])
        case .swipe, .drag, .moveMouse:
            descriptor(
                ownership: .service,
                requiredPermissions: [.postEvent],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .global,
                responseFamilies: [.ok])
        case .targetedHotkey:
            descriptor(
                ownership: .service,
                requiredPermissions: [.postEvent],
                completion: .dispatchedUnverified(processBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .exactWindowTargetedHotkey:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility, .postEvent],
                completion: .dispatchedUnverified(windowBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .createExactWindowHeldPointerOwner:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.heldPointerOwner])
        case .beginExactWindowHeldPointer:
            descriptor(
                ownership: .service,
                requiredPermissions: [.postEvent],
                completion: .dispatchedUnverified(windowBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.heldPointerReceipt])
        case .releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer:
            descriptor(
                ownership: .service,
                completion: .requestDependent(mutatesDesktop: true),
                targetPolicy: .requestPinned,
                responseFamilies: [.heldPointerTermination],
                responseTargetEvidence: .heldPointerTermination)
        case .disconnectExactWindowHeldPointerOwner:
            descriptor(
                ownership: .service,
                completion: .requestDependent(mutatesDesktop: true),
                targetPolicy: .handlerResolvedOrGlobal,
                responseFamilies: [.heldPointerTermination],
                responseTargetEvidence: .heldPointerTermination)
        case .targetedClick, .exactWindowTargetedClick:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .waitForElement:
            descriptor(
                read: .globalExclusive,
                typedResponse: .waitElementSelector,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.waitResult])
        case .listWindows:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.windows])
        case .focusWindow:
            descriptor(
                ownership: .service,
                pinnedWindow: .legacyOptionalCurrentRequired,
                typedResponse: .postMutationWindow,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(compositeForeground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok, .window],
                responseTargetEvidence: .window)
        case .moveWindow, .resizeWindow, .setWindowBounds, .minimizeWindow, .restoreWindow, .maximizeWindow:
            descriptor(
                ownership: .service,
                pinnedWindow: .required,
                typedResponse: .postMutationWindow,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(valueBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok, .window],
                responseTargetEvidence: .window)
        case .closeWindow:
            descriptor(
                ownership: .service,
                pinnedWindow: .required,
                typedResponse: .postMutationWindow,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(compositeForeground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok, .window],
                responseTargetEvidence: .window)
        case .backgroundCloseWindow:
            descriptor(
                ownership: .service,
                pinnedWindow: .required,
                typedResponse: .postMutationWindow,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok, .window],
                responseTargetEvidence: .window)
        case .getFocusedWindow:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.window],
                responseTargetEvidence: .window)
        case .listApplications:
            descriptor(
                read: .globalExclusive,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.applications])
        case .findApplication:
            descriptor(
                read: .globalExclusive,
                typedResponse: .applicationIdentifier,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.application],
                responseTargetEvidence: .application)
        case .getFrontmostApplication:
            descriptor(
                read: .globalExclusive,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.application],
                responseTargetEvidence: .application)
        case .isApplicationRunning:
            descriptor(
                read: .globalExclusive,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.bool])
        case .launchApplication:
            descriptor(
                ownership: .service,
                typedResponse: .applicationIdentifier,
                completion: .dispatchedUnverified(nativeForeground),
                targetPolicy: .responseResolved,
                responseFamilies: [.application],
                responseTargetEvidence: .application)
        case .launchApplicationWithOptions:
            descriptor(
                ownership: .service,
                typedResponse: .applicationLaunch,
                completion: .requestDependent(mutatesDesktop: false),
                targetPolicy: .requestDependent,
                responseFamilies: [.application],
                responseTargetEvidence: .application)
        case .relaunchApplicationWithOptions:
            descriptor(
                ownership: .service,
                typedResponse: .applicationRelaunch,
                completion: .requestDependent(mutatesDesktop: true),
                targetPolicy: .responseResolved,
                responseFamilies: [.application],
                responseTargetEvidence: .application)
        case .activateApplication:
            descriptor(
                ownership: .service,
                completion: .dispatchedUnverified(nativeForeground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .quitApplication:
            descriptor(
                ownership: .service,
                completion: .dispatchedUnverified(nativeBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.bool])
        case .hideApplication:
            descriptor(
                ownership: .service,
                completion: .dispatchedUnverified(nativeBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .unhideApplication:
            descriptor(
                ownership: .service,
                completion: .dispatchedUnverified(nativeBackground),
                targetPolicy: .handlerRequired,
                responseFamilies: [.ok])
        case .hideOtherApplications, .showAllApplications:
            descriptor(
                ownership: .service,
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .global,
                responseFamilies: [.ok])
        case .listMenus:
            descriptor(
                read: .globalExclusive,
                typedResponse: .menuStructureApplication,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.menuStructure])
        case .listFrontmostMenus:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.menuStructure])
        case .clickMenuItem, .clickMenuItemByName:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.ok])
        case .listMenuExtras:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.menuExtras])
        case .clickMenuExtra:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axForeground),
                targetPolicy: .external,
                responseFamilies: [.ok])
        case .menuExtraOpenMenuFrame:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.rect])
        case .listMenuBarItems:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.menuBarItems])
        case .clickMenuBarItemNamed:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axForeground),
                targetPolicy: .external,
                responseFamilies: [.clickResult])
        case .clickMenuBarItemIndex:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility, .postEvent],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .external,
                responseFamilies: [.clickResult])
        case .listDockItems:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.dockItems])
        case .launchDockItem:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axForeground),
                targetPolicy: .external,
                responseFamilies: [.ok])
        case .rightClickDockItem:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .external,
                responseFamilies: [.ok])
        case .hideDock, .showDock:
            descriptor(
                ownership: .service,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(nativeBackground),
                targetPolicy: .global,
                responseFamilies: [.ok])
        case .isDockHidden:
            descriptor(
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.bool])
        case .findDockItem:
            descriptor(
                read: .globalExclusive,
                typedResponse: .dockItemSelector,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.dockItem])
        case .dialogFindActive:
            descriptor(
                ownership: .service,
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.dialogInfo])
        case .dialogClickButton, .dialogDismiss:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axForeground),
                targetPolicy: .responseResolved,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .backgroundDialogClickButton:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .responseResolved,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .dialogEnterText:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .responseResolved,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .dialogHandleFile:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(clipboardForeground),
                targetPolicy: .responseResolved,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .dialogListElements:
            descriptor(
                ownership: .service,
                read: .globalExclusive,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.dialogElements])
        case .targetedDialogListElements:
            descriptor(
                ownership: .service,
                read: .globalExclusive,
                typedResponse: .targetedDialogElements,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.dialogElements],
                responseTargetEvidence: .targetedDialog)
        case .prepareDialogAction:
            descriptor(
                ownership: .service,
                read: .globalExclusive,
                typedResponse: .preparedDialogAction,
                requiredPermissions: [.accessibility],
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.preparedDialogAction],
                responseTargetEvidence: .preparedDialog)
        case .exactDialogClickButton, .exactDialogDismiss:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(axBackground),
                targetPolicy: .requestPinned,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .exactDialogEnterText:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility],
                completion: .dispatchedUnverified(valueBackground),
                targetPolicy: .responseResolved,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .exactDialogForceDismiss:
            descriptor(
                ownership: .service,
                typedResponse: .dialogResult,
                requiredPermissions: [.accessibility, .postEvent],
                completion: .dispatchedUnverified(globalForeground),
                targetPolicy: .responseResolved,
                responseFamilies: [.dialogResult],
                responseTargetEvidence: .dialog)
        case .createSnapshot:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.snapshotID])
        case .storeDetectionResult:
            descriptor(
                typedResponse: .storedDetection,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.ok])
        case .getDetectionResult:
            descriptor(
                typedResponse: .detectionSnapshot,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.detection])
        case .ownsSnapshot:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.bool])
        case .storeScreenshot, .storeObservationSnapshot, .storeAnnotatedScreenshot,
             .finishSnapshotMutation, .cleanSnapshot:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.ok])
        case .listSnapshots:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.snapshots])
        case .getMostRecentSnapshot:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.snapshotID])
        case .invalidateImplicitLatestSnapshot:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.ok, .snapshotID])
        case .beginSnapshotMutation:
            descriptor(
                typedResponse: .snapshotMutationLease,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.snapshotMutationLease])
        case .cleanSnapshotsOlderThan, .cleanAllSnapshots:
            descriptor(
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [.int])
        case ._appleScriptProbe:
            descriptor(
                typedResponse: .noSuccessResponse,
                completion: .readOnly,
                targetPolicy: .notApplicable,
                responseFamilies: [])
        }
    }
}
