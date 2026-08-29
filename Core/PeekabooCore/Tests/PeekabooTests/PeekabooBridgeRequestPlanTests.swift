import PeekabooAutomationKitTestSupport
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeRequestPlanTests {
    typealias Semantics = PeekabooBridgeOperationResultSemantics

    @Test
    func `Every wire operation has one complete static descriptor`() {
        let operations = PeekabooBridgeOperation.allCases
        #expect(operations.count == 116)

        let descriptors = operations.map(Semantics.operationDescriptor(for:))
        #expect(descriptors.map(\.operation) == operations)
        #expect(Set(descriptors.map(\.operation)) == Set(operations))
        #expect(descriptors.allSatisfy {
            !$0.responseFamilies.isEmpty || $0.operation == ._appleScriptProbe
        })
        #expect(descriptors.allSatisfy {
            $0.windowResponseProof == ($0.typedResponse == .postMutationWindow ? .postMutationState : .none)
        })

        let evidenceSources: [Semantics.ResponseTargetEvidenceSource] = [
            .none,
            .agentProcess,
            .application,
            .browserConnection,
            .capture,
            .desktopObservation,
            .dialog,
            .heldPointerTermination,
            .inspectWindowContext,
            .preparedDialog,
            .targetedDialog,
            .window,
        ]
        let partition = evidenceSources.map { source in
            Set(descriptors.filter { $0.responseTargetEvidence == source }.map(\.operation))
        }
        #expect(partition.reduce(0) { $0 + $1.count } == operations.count)
        #expect(partition.reduce(into: Set<PeekabooBridgeOperation>()) { $0.formUnion($1) } == Set(operations))
    }

    @Test
    func `Static descriptors own the exact base permission partition`() {
        let allOperations = PeekabooBridgeOperation.allCases
        let descriptors = allOperations.map(Semantics.operationDescriptor(for:))

        func operationSet(requiring permissions: Set<PeekabooBridgePermissionKind>) -> Set<PeekabooBridgeOperation> {
            Set(descriptors.filter { $0.requiredPermissions == permissions }.map(\.operation))
        }

        let screenRecording: Set<PeekabooBridgeOperation> = [
            .captureScreen,
            .captureWindow,
            .captureFrontmost,
            .captureArea,
            .detectElements,
            .desktopObservation,
        ]
        let postEvent: Set<PeekabooBridgeOperation> = [
            .targetedHotkey,
            .targetedTypeActions,
            .click,
            .scroll,
            .swipe,
            .drag,
            .moveMouse,
            .beginExactWindowHeldPointer,
        ]
        let accessibilityAndPostEvent: Set<PeekabooBridgeOperation> = [
            .exactWindowTargetedHotkey,
            .exactWindowTargetedTypeActions,
            .exactWindowPixelFocusType,
            .foregroundModifierClick,
            .exactDialogForceDismiss,
            .clickMenuBarItemIndex,
        ]
        let accessibility: Set<PeekabooBridgeOperation> = [
            .inspectAccessibilityTree,
            .getFocusedElement,
            .type,
            .typeActions,
            .setValue,
            .performAction,
            .hotkey,
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
            .listMenus,
            .listFrontmostMenus,
            .clickMenuItem,
            .clickMenuItemByName,
            .listMenuExtras,
            .clickMenuExtra,
            .menuExtraOpenMenuFrame,
            .listMenuBarItems,
            .clickMenuBarItemNamed,
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
            .targetedClick,
            .exactWindowTargetedClick,
            .targetedScroll,
        ]

        #expect(operationSet(requiring: [.screenRecording]) == screenRecording)
        #expect(operationSet(requiring: [.postEvent]) == postEvent)
        #expect(operationSet(requiring: [.accessibility, .postEvent]) == accessibilityAndPostEvent)
        #expect(operationSet(requiring: [.accessibility]) == accessibility)

        let nonempty = screenRecording
            .union(postEvent)
            .union(accessibilityAndPostEvent)
            .union(accessibility)
        #expect(operationSet(requiring: []) == Set(allOperations).subtracting(nonempty))
        #expect(allOperations.allSatisfy {
            $0.requiredPermissions == Semantics.operationDescriptor(for: $0).requiredPermissions
        })
    }

    @Test
    func `Linked exact window plan captures legacy and current vocabulary immutably`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget()
        let request = PeekabooBridgeRequest.focusWindow(.init(
            target: .windowId(fixture.windowIdentity.windowID),
            expectedIdentity: fixture.windowIdentity))
        let legacy = Semantics.requestPlan(for: request, vocabulary: .legacy)
        let current = Semantics.requestPlan(for: request, vocabulary: .current)

        #expect(legacy.vocabulary == .legacy)
        #expect(current.vocabulary == .current)
        #expect(!legacy.target.requiresPinnedWindowMutation)
        #expect(current.target.requiresPinnedWindowMutation)
        #expect(legacy.target.policy == .requestPinned)
        #expect(current.target.policy == .requestPinned)
        #expect(legacy.target.desktopOperationScope == .global)
        #expect(current.target.desktopOperationScope == .global)
        #expect(Semantics.operationPolicy(for: request.operation) == current.descriptor)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(legacy) == fixture.windowTargetIdentity)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(current) == fixture.windowTargetIdentity)
    }

    @Test(arguments: [Semantics.PeekabooBridgeRequestPlan.Vocabulary.legacy, .current])
    func `Invalid nested carriage remains a fail closed plan`(
        vocabulary: Semantics.PeekabooBridgeRequestPlan.Vocabulary)
    {
        let inner = PeekabooBridgeRequest.setValue(.init(
            target: "B1",
            value: .string("fixture"),
            snapshotId: "snapshot"))
        let malformed = PeekabooBridgeRequest.projectedAction(.init(
            request: .projectedAction(.init(request: inner))))
        let plan = Semantics.requestPlan(for: malformed, vocabulary: vocabulary)

        #expect(plan.operation == .setValue)
        #expect(plan.vocabulary == vocabulary)
        #expect(plan.result.completion == .readOnly)
        #expect(plan.result.responseFamilies.isEmpty)
        #expect(plan.result.deliveryRules.isEmpty)
        #expect(plan.result.allowedSuccessStates.isEmpty)
        #expect(plan.result.successResponsePolicy == .errorOnly)
        #expect(plan.result.typedResponseRule == .none)
        #expect(plan.target.policy == .notApplicable)
        #expect(plan.target.requestEvidence.isEmpty)
        #expect(plan.target.responseEvidenceSource == .none)
        #expect(plan.target.desktopOperationScope == .global)
        #expect(plan.target.desktopReadOperationLane?.scope == .global)
        #expect(plan.target.desktopReadOperationLane?.access == .write)
        #expect(!plan.target.requiresPinnedWindowMutation)
        #expect(plan.descriptor.lane.nativeOwnership == .bridge)
        #expect(plan.descriptor.lane.readPolicy == .globalExclusive)
        #expect(plan.descriptor.typedResponse == .noSuccessResponse)
        #expect(plan.descriptor.requiredPermissions.isEmpty)
    }
}
