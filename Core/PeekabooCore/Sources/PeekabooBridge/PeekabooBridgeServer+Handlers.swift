import CoreGraphics
import Foundation
@_spi(Bridge) import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    // swiftlint:disable:next cyclomatic_complexity
    func handleAuthorized(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeHandledResponse
    {
        switch request.operation {
        case .permissionsStatus, .daemonStatus, .daemonStop:
            return try await .init(
                response: self.handleCoreRequest(request, peer: peer, permissions: permissions))
        case .agentExecutionTrace:
            return try await self.handleAgentExecutionTraceRequest(request, peer: peer)
        case .observeProcessGeneration:
            guard case let .observeProcessGeneration(payload) = request else {
                throw Self.invalidRequest(for: request)
            }
            return try .init(response: .processGenerationObservation(
                self.handleProcessGenerationObservation(payload)))
        case .certificationProducerAttestation:
            guard case let .certificationProducerAttestation(payload) = request else {
                throw Self.invalidRequest(for: request)
            }
            return try await .init(response: .certificationProducerAttestation(
                self.handleCertificationProducerAttestation(payload)))
        case .requestPostEventPermission:
            return self.handlePostEventPermissionRequest()
        case .browserStatus:
            guard case let .browserStatus(payload) = request else {
                throw Self.invalidRequest(for: request)
            }
            if let sessionID = payload.sessionID {
                return try await .init(response: .browserStatus(
                    self.handleScopedBrowserStatus(sessionID: sessionID, channel: payload.channel)))
            }
            return try await .init(response: self.handleBrowserRequest(request))
        case .browserDisconnect:
            return try await .init(response: self.handleBrowserRequest(request))
        case .browserConnect:
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
                  case let .browserConnect(payload) = request
            else {
                return try await .init(response: self.handleBrowserRequest(request))
            }
            return try await self.handleBrowserConnect(payload)
        case .browserExecute:
            guard case let .browserExecute(payload) = request else {
                throw Self.invalidRequest(for: request)
            }
            _ = try Self.validatedBrowserExecutionReceipt(payload)
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                return try await .init(response: self.handleBrowserRequest(request))
            }
            return try await self.handleBrowserExecute(payload)
        case .browserSessionBootstrap:
            guard case let .browserSessionBootstrap(payload) = request,
                  let authority = PeekabooBridgeRequestContext.operationReceiptAuthority,
                  let operation = PeekabooBridgeRequestContext.browserHandoffOperation
            else {
                throw Self.invalidRequest(for: request)
            }
            try PeekabooBridgeRequestContext.checkRequestIsActive()
            return try await .init(response: .browserSessionBootstrap(
                self.browserHandoffGrantRegistry.bootstrap(
                    request: payload,
                    authority: authority,
                    caller: operation.peer.browserSessionCaller(
                        clientInstanceID: operation.clientInstanceID))))
        case .browserSessionControl:
            guard case let .browserSessionControl(payload) = request else {
                throw Self.invalidRequest(for: request)
            }
            return try await .init(response: self.handleBrowserSessionControl(payload))
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea:
            return try await .init(response: self.handleCaptureRequest(request))
        case .desktopObservation:
            return try await self.handleDesktopObservationRequest(request)
        case .detectElements, .inspectAccessibilityTree, .getFocusedElement, .click, .type,
             .typeActions,
             .targetedTypeActions, .exactWindowTargetedTypeActions, .exactWindowPixelFocusType,
             .foregroundModifierClick,
             .setValue, .performAction, .scroll, .targetedScroll, .hotkey, .targetedHotkey,
             .exactWindowTargetedHotkey, .targetedClick,
             .exactWindowTargetedClick, .swipe, .drag, .moveMouse, .waitForElement:
            return try await self.handleAutomationRequest(request)
        case .createExactWindowHeldPointerOwner, .beginExactWindowHeldPointer,
             .releaseExactWindowHeldPointer, .revokeExactWindowHeldPointer,
             .disconnectExactWindowHeldPointerOwner:
            return try await self.handleHeldPointerRequest(request, peer: peer)
        case .listWindows, .focusWindow, .moveWindow, .resizeWindow, .setWindowBounds, .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow, .restoreWindow, .maximizeWindow, .getFocusedWindow:
            return try await self.handleWindowRequest(request)
        case .listApplications, .findApplication, .getFrontmostApplication, .isApplicationRunning,
             .launchApplication, .launchApplicationWithOptions, .relaunchApplicationWithOptions,
             .activateApplication, .quitApplication,
             .hideApplication, .unhideApplication, .hideOtherApplications, .showAllApplications:
            return try await self.handleApplicationRequest(request)
        case .listMenus, .listFrontmostMenus, .clickMenuItem, .clickMenuItemByName, .listMenuExtras,
             .clickMenuExtra, .menuExtraOpenMenuFrame, .listMenuBarItems, .clickMenuBarItemNamed,
             .clickMenuBarItemIndex:
            return try await self.handleMenuRequest(request)
        case .listDockItems, .launchDockItem, .rightClickDockItem, .hideDock, .showDock, .isDockHidden,
             .findDockItem:
            return try await self.handleDockRequest(request)
        case .dialogFindActive, .dialogClickButton, .backgroundDialogClickButton, .dialogEnterText,
             .dialogHandleFile, .dialogDismiss,
             .dialogListElements, .targetedDialogListElements, .prepareDialogAction,
             .exactDialogClickButton, .exactDialogDismiss, .exactDialogEnterText,
             .exactDialogForceDismiss:
            return try await self.handleDialogRequest(request)
        case .createSnapshot, .storeDetectionResult, .getDetectionResult, .ownsSnapshot, .storeScreenshot,
             .storeObservationSnapshot, .storeAnnotatedScreenshot, .listSnapshots, .getMostRecentSnapshot,
             .cleanSnapshot,
             .invalidateImplicitLatestSnapshot, .beginSnapshotMutation, .finishSnapshotMutation,
             .cleanSnapshotsOlderThan, .cleanAllSnapshots:
            return try await .init(response: self.handleSnapshotRequest(request))
        case ._appleScriptProbe:
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message:
                "AppleScript probing is no longer supported; current operations use native macOS APIs")
        }
    }

    private func handlePostEventPermissionRequest() -> PeekabooBridgeHandledResponse {
        let granted = self.postEventAccessRequester()
        return .init(
            response: .bool(granted),
            mutation: .init(
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                target: .global))
    }

    private func handleCoreRequest(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeResponse
    {
        switch request {
        case .permissionsStatus:
            return .permissionsStatus(permissions)
        case .daemonStatus:
            guard let daemonControl = self.daemonControl else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Daemon status is not supported by this host")
            }
            let status = await daemonControl.daemonStatus()
            return .daemonStatus(status)
        case .daemonStop:
            guard let daemonControl = self.daemonControl else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Daemon stop is not supported by this host")
            }
            let stopped = await daemonControl.requestStop()
            return .bool(stopped)
        case let .daemonStopIf(payload):
            guard let daemonControl = self.daemonControl as? any PeekabooConditionalDaemonControlProviding
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Conditional daemon stop is not supported by this host")
            }
            let stopped = await daemonControl.requestStop(expectedPID: payload.expectedPID)
            return .bool(stopped)
        case let .handshake(payload):
            return try await self.handleHandshake(payload, peer: peer, permissions: permissions)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleAutomationRequest(
        _ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse
    {
        switch request {
        case let .detectElements(payload):
            let mutationTarget = try self.requireFocusMutationTarget(
                payload.windowContext,
                operation: .detectElements)
            let result = try await self.services.automation.detectElements(
                in: payload.imageData,
                snapshotId: payload.snapshotId,
                windowContext: payload.windowContext)
            return .init(
                response: .elementDetection(result),
                mutation: mutationTarget.map { target in
                    .init(
                        outcome: .dispatchedUnverified(
                            delivery: .init(mechanism: .accessibilityAction, mode: .background),
                            evidence: .deliveryAccepted,
                            unitCount: .one),
                        target: .handlerResolved(target))
                })
        case let .inspectAccessibilityTree(payload):
            let mutationTarget = try self.requireFocusMutationTarget(
                payload.windowContext,
                operation: .inspectAccessibilityTree)
            let result = try await self.services.automation.inspectAccessibilityTree(
                windowContext: payload.windowContext)
            return .init(
                response: .elementDetection(result),
                mutation: mutationTarget.map { _ in
                    .init(
                        outcome: .dispatchedUnverified(
                            delivery: .init(mechanism: .accessibilityAction, mode: .background),
                            evidence: .deliveryAccepted,
                            unitCount: .one),
                        target: .responseResolved)
                })
        case let .getFocusedElement(payload):
            return try await self.handleFocusedElementRequest(payload)
        case let .click(payload):
            let fallbackTarget: PeekabooBridgeHandledResponse.Mutation.TargetDisposition? =
                switch payload.target {
                case .coordinates: .global
                case .elementId, .query: nil
                }
            return try await self.handleAutomationAction(
                withOutcome: { service in
                    try await service.clickWithOutcome(
                        target: payload.target,
                        clickType: payload.clickType,
                        snapshotId: payload.snapshotId)
                },
                legacy: {
                    try await self.services.automation.click(
                        target: payload.target,
                        clickType: payload.clickType,
                        snapshotId: payload.snapshotId)
                    return ()
                },
                fallbackTarget: fallbackTarget,
                response: { _ in .ok })
        case let .type(payload):
            return try await self.handleAutomationAction(
                withOutcome: { service in
                    try await service.typeWithOutcome(
                        text: payload.text,
                        target: payload.target,
                        clearExisting: payload.clearExisting,
                        typingDelay: payload.typingDelay,
                        snapshotId: payload.snapshotId)
                },
                legacy: {
                    try await self.services.automation.type(
                        text: payload.text,
                        target: payload.target,
                        clearExisting: payload.clearExisting,
                        typingDelay: payload.typingDelay,
                        snapshotId: payload.snapshotId)
                    return ()
                },
                fallbackTarget: payload.target?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    == false
                    ? nil
                    : .global,
                response: { _ in .ok })
        case let .typeActions(payload):
            return try await self.handleAutomationAction(
                withOutcome: { service in
                    try await service.typeActionsWithOutcome(
                        payload.actions,
                        cadence: payload.cadence,
                        snapshotId: payload.snapshotId)
                },
                legacy: {
                    try await self.services.automation.typeActions(
                        payload.actions,
                        cadence: payload.cadence,
                        snapshotId: payload.snapshotId)
                },
                fallbackTarget: .global,
                response: PeekabooBridgeResponse.typeResult)
        case .targetedTypeActions, .exactWindowTargetedTypeActions, .exactWindowPixelFocusType,
             .foregroundModifierClick, .targetedHotkey,
             .exactWindowTargetedHotkey, .targetedClick:
            return try await self.handleTargetedAutomationRequest(request)
        case .setValue, .performAction:
            return try await self.handleElementActionRequest(request)
        case let .scroll(payload):
            return try await self.handleScroll(payload.request)
        case let .targetedScroll(payload):
            return try await self.handleScroll(payload.request)
        case let .hotkey(payload):
            return try await self.handleAutomationAction(
                withOutcome: { service in
                    try await service.hotkeyWithOutcome(
                        keys: payload.keys, holdDuration: payload.holdDuration)
                },
                legacy: {
                    try await self.services.automation.hotkey(
                        keys: payload.keys,
                        holdDuration: payload.holdDuration)
                    return ()
                },
                fallbackTarget: .global,
                response: { _ in .ok })
        case let .swipe(payload):
            try await self.services.automation.swipe(
                from: payload.from,
                to: payload.to,
                duration: payload.duration,
                steps: payload.steps,
                profile: payload.profile)
            return Self.globalPointerMutationResponse()
        case let .drag(payload):
            try await self.services.automation.drag(payload.automationRequest)
            return Self.globalPointerMutationResponse()
        case let .moveMouse(payload):
            try await self.services.automation.moveMouse(
                to: payload.to,
                duration: payload.duration,
                steps: payload.steps,
                profile: payload.profile)
            return Self.globalPointerMutationResponse()
        case let .waitForElement(payload):
            let result = try await self.services.automation.waitForElement(
                target: payload.target,
                timeout: payload.timeout,
                snapshotId: payload.snapshotId)
            return .init(response: .waitResult(result))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleFocusedElementRequest(
        _ payload: PeekabooBridgeFocusedElementRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard let automation = self.services.automation as? any TargetedFocusedElementServiceProtocol
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "PID-scoped focused-element queries are not supported by this bridge host")
        }
        guard let expectedIdentity = payload.expectedProcessIdentity else {
            let focusedElement = await automation.getFocusedElement(
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .init(response: .focusedElement(focusedElement))
        }
        guard expectedIdentity.processIdentifier == payload.targetProcessIdentifier,
              self.processStartIdentityProvider(payload.targetProcessIdentifier)
              == expectedIdentity.processStartIdentity
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Focused-element target process generation changed before inspection")
        }
        let focusedElement = await automation.getFocusedElement(
            targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
        guard
            self.processStartIdentityProvider(payload.targetProcessIdentifier)
            == expectedIdentity.processStartIdentity
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Focused-element target process generation changed during inspection")
        }
        if let focusedElement,
           focusedElement.processId != Int(payload.targetProcessIdentifier)
        {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Focused-element result belongs to a different process")
        }
        return try .init(
            response: .focusedElement(focusedElement),
            targetIdentity: DesktopTargetIdentity(processIdentity: expectedIdentity))
    }

    private func handleScroll(_ request: ScrollRequest) async throws -> PeekabooBridgeHandledResponse {
        try await self.handleAutomationAction(
            withOutcome: { service in
                try await service.scrollWithOutcome(request)
            },
            legacy: {
                try await self.services.automation.scroll(request)
                return ()
            },
            fallbackTarget: request.target == nil ? .global : nil,
            response: { _ in .ok })
    }

    private func handleAutomationAction<Payload: Sendable>(
        withOutcome: (any UIAutomationActionOutcomeProviding) async throws -> UIAutomationActionResult<
            Payload,
        >,
        legacy: () async throws -> Payload,
        fallbackTarget: PeekabooBridgeHandledResponse.Mutation.TargetDisposition?,
        response: (Payload) -> PeekabooBridgeResponse) async throws -> PeekabooBridgeHandledResponse
    {
        guard let service = try self.automationOutcomeService() else {
            let payload = try await legacy()
            return .init(response: response(payload))
        }
        let result = try await withOutcome(service)
        return try Self.handledActionResponse(
            response: response(result.payload),
            result: result,
            fallbackTarget: fallbackTarget)
    }

    private func automationOutcomeService() throws -> (any UIAutomationActionOutcomeProviding)? {
        if let service = self.services.automation as? any UIAutomationActionOutcomeProviding {
            return service
        }
        guard !PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The Bridge automation provider cannot attest mutation outcomes.",
                hint: "Update the runtime host before retrying this operation.")
        }
        return nil
    }

    private func handleElementActionRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        guard let automation = self.services.automation as? any ElementActionAutomationServiceProtocol
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Element actions are not supported by this bridge host")
        }

        switch request {
        case let .setValue(payload):
            return try await self.handleAutomationAction(
                withOutcome: { service in
                    try await service.setValueWithOutcome(
                        target: payload.target,
                        value: payload.value,
                        snapshotId: payload.snapshotId)
                },
                legacy: {
                    try await automation.setValue(
                        target: payload.target,
                        value: payload.value,
                        snapshotId: payload.snapshotId)
                },
                fallbackTarget: nil,
                response: PeekabooBridgeResponse.elementActionResult)
        case let .performAction(payload):
            return try await self.handleAutomationAction(
                withOutcome: { service in
                    try await service.performActionWithOutcome(
                        target: payload.target,
                        actionName: payload.actionName,
                        snapshotId: payload.snapshotId)
                },
                legacy: {
                    try await automation.performAction(
                        target: payload.target,
                        actionName: payload.actionName,
                        snapshotId: payload.snapshotId)
                },
                fallbackTarget: nil,
                response: PeekabooBridgeResponse.elementActionResult)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleTargetedAutomationRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        switch request {
        case let .targetedTypeActions(payload):
            guard
                let targetedTypeService = self.services.automation as? any TargetedTypeServiceProtocol,
                targetedTypeService.supportsTargetedTypeActions
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Background typing is not supported by this bridge host")
            }

            return try await self.handleTargetedTypeActions(payload, service: targetedTypeService)
        case let .exactWindowTargetedTypeActions(payload):
            return try await self.handleExactWindowTargetedTypeActions(payload)
        case let .exactWindowPixelFocusType(payload):
            return try await self.handleExactWindowPixelFocusType(payload)
        case let .foregroundModifierClick(payload):
            return try await self.handleForegroundModifierClick(payload)
        case let .targetedHotkey(payload):
            return try await self.handleTargetedHotkey(payload)
        case let .exactWindowTargetedHotkey(payload):
            return try await self.handleExactWindowTargetedHotkey(payload)
        case let .targetedClick(payload):
            return try await self.handleTargetedClick(payload)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleExactWindowTargetedTypeActions(
        _ payload: PeekabooBridgeExactWindowTypeActionsRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
              service.supportsExactWindowTargetedKeyboard
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Atomic exact-window background typing is not supported by this bridge host")
        }
        if payload.actions.contains(where: \.mayUseAccessibilityValueDelivery) {
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
                  self.hostCapabilities.contains(PeekabooBridgeHostCapability.compositeTypeDelivery),
                  service.supportsExactWindowCompositeTypeDelivery
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Truthful composite background typing receipts are not supported by this bridge host")
            }
        }
        self.automationActivityObserver?(pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier))
        if let outcomeService = try self.automationOutcomeService() {
            let result =
                if let expectedFocusedElement = payload.expectedFocusedElement {
                    try await outcomeService.typeActionsWithOutcome(
                        payload.actions,
                        cadence: payload.cadence,
                        snapshotId: payload.snapshotId,
                        target: ExactWindowKeyboardTarget(
                            windowIdentity: payload.expectedWindowIdentity,
                            windowBounds: payload.expectedWindowBounds,
                            focusedElement: expectedFocusedElement))
                } else {
                    try await outcomeService.typeActionsWithOutcome(
                        payload.actions,
                        cadence: payload.cadence,
                        snapshotId: payload.snapshotId,
                        expectedWindowIdentity: payload.expectedWindowIdentity,
                        expectedWindowBounds: payload.expectedWindowBounds)
                }
            return try Self.handledActionResponse(
                response: .typeResult(result.payload),
                result: result,
                fallbackTarget: .requestPinned)
        }
        let result =
            if let expectedFocusedElement = payload.expectedFocusedElement {
                try await service.typeActions(
                    payload.actions,
                    cadence: payload.cadence,
                    snapshotId: payload.snapshotId,
                    target: ExactWindowKeyboardTarget(
                        windowIdentity: payload.expectedWindowIdentity,
                        windowBounds: payload.expectedWindowBounds,
                        focusedElement: expectedFocusedElement))
            } else {
                try await service.typeActions(
                    payload.actions,
                    cadence: payload.cadence,
                    snapshotId: payload.snapshotId,
                    expectedWindowIdentity: payload.expectedWindowIdentity,
                    expectedWindowBounds: payload.expectedWindowBounds)
            }
        return .init(response: .typeResult(result))
    }

    private func handleExactWindowPixelFocusType(
        _ payload: PeekabooBridgeExactWindowPixelFocusTypeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.automation as? any ExactWindowPixelFocusTypingServiceProtocol,
              service.supportsExactWindowPixelFocusTyping
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Atomic exact-window pixel-focus typing is not supported by this bridge host")
        }
        if payload.request.actions.contains(where: \.mayUseAccessibilityValueDelivery) {
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
                  self.hostCapabilities.contains(PeekabooBridgeHostCapability.compositeTypeDelivery),
                  (self.services.automation as? any CompositeTypeDeliveryServiceProtocol)?
                      .supportsExactWindowCompositeTypeDelivery == true
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Truthful composite background typing receipts are not supported by this bridge host")
            }
        }
        self.automationActivityObserver?(pid_t(payload.request.windowIdentity.ownerProcessIdentifier))
        let result = try await service.typeActionsByFocusingPixelWithOutcome(payload.request)
        return try Self.handledActionResponse(
            response: .typeResult(result.payload),
            result: result,
            fallbackTarget: .requestPinned)
    }

    private func handleForegroundModifierClick(
        _ payload: PeekabooBridgeForegroundModifierClickRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.automation as? any ForegroundModifierClickServiceProtocol,
              service.supportsForegroundModifierClick,
              service.supportsForegroundModifierClickSnapshotLease,
              self.services.snapshots.supportsSnapshotMutationLeases
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Host-leased foreground modifier-click is not supported by this bridge host")
        }
        self.automationActivityObserver?(pid_t(payload.request.windowIdentity.ownerProcessIdentifier))
        let result = try await service.foregroundModifierClickWithOutcome(payload.request)
        return try Self.handledActionResponse(
            response: .foregroundModifierClickResult(result.payload),
            result: result,
            fallbackTarget: .requestPinned)
    }

    private func handleExactWindowTargetedHotkey(
        _ payload: PeekabooBridgeExactWindowHotkeyRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
              service.supportsExactWindowTargetedKeyboard
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Atomic exact-window background hotkeys are not supported by this bridge host")
        }
        self.automationActivityObserver?(pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier))
        if let outcomeService = try self.automationOutcomeService() {
            let result =
                if let expectedFocusedElement = payload.expectedFocusedElement {
                    try await outcomeService.hotkeyWithOutcome(
                        keys: payload.keys,
                        holdDuration: payload.holdDuration,
                        target: ExactWindowKeyboardTarget(
                            windowIdentity: payload.expectedWindowIdentity,
                            windowBounds: payload.expectedWindowBounds,
                            focusedElement: expectedFocusedElement))
                } else {
                    try await outcomeService.hotkeyWithOutcome(
                        keys: payload.keys,
                        holdDuration: payload.holdDuration,
                        expectedWindowIdentity: payload.expectedWindowIdentity,
                        expectedWindowBounds: payload.expectedWindowBounds)
                }
            return try Self.handledActionResponse(
                response: .ok,
                result: result,
                fallbackTarget: .requestPinned)
        }
        if let expectedFocusedElement = payload.expectedFocusedElement {
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                target: ExactWindowKeyboardTarget(
                    windowIdentity: payload.expectedWindowIdentity,
                    windowBounds: payload.expectedWindowBounds,
                    focusedElement: expectedFocusedElement))
        } else {
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                expectedWindowIdentity: payload.expectedWindowIdentity,
                expectedWindowBounds: payload.expectedWindowBounds)
        }
        return .init(response: .ok)
    }

    private func handleTargetedClick(_ payload: PeekabooBridgeTargetedClickRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        let usesProcessPinnedRoute = payload.targetWindowID == nil && payload.expectedProcessIdentity != nil
        let usesExactWindowPinnedRoute = payload.targetWindowID != nil &&
            payload.expectedWindowIdentity != nil &&
            payload.expectedWindowBounds != nil
        guard payload.allowsAccessibilityValueDelivery == nil ||
            usesProcessPinnedRoute ||
            usesExactWindowPinnedRoute
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "An explicit accessibility-value click policy requires a process- or exact-window identity")
        }
        guard
            let targetedClickService = self.services.automation as? any TargetedClickServiceProtocol,
            targetedClickService.supportsTargetedClicks
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Background clicks are not supported by this bridge host")
        }
        if payload.clickType.requiresStatelessVariantSupport {
            guard targetedClickService.supportsStatelessClickVariants else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "This Bridge host does not support middle- or triple-click requests")
            }
            guard payload.targetWindowID != nil else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Background middle- and triple-clicks require an exact-window receipt")
            }
        }
        if case .coordinates = payload.target, payload.targetWindowID == nil {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message:
                "Background coordinate clicks require an exact capture-time window identity and bounds; "
                    + "PID-only coordinates are refused")
        }
        guard let targetWindowID = payload.targetWindowID else {
            return try await self.handleProcessTargetedClick(payload, service: targetedClickService)
        }
        return try await self.handleExactWindowTargetedClick(
            payload,
            targetWindowID: targetWindowID,
            service: targetedClickService)
    }

    private func handleExactWindowTargetedClick(
        _ payload: PeekabooBridgeTargetedClickRequest,
        targetWindowID: Int,
        service: any TargetedClickServiceProtocol) async throws -> PeekabooBridgeHandledResponse
    {
        guard payload.expectedProcessIdentity == nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Exact-window clicks cannot also supply a process-only identity")
        }
        guard let exactWindowService = service as? any ExactWindowTargetedClickServiceProtocol else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Exact-window background clicks are not supported by this bridge host")
        }
        guard let expectedIdentity = payload.expectedWindowIdentity,
              let expectedBounds = payload.expectedWindowBounds,
              expectedIdentity.windowID == targetWindowID,
              expectedIdentity.ownerProcessIdentifier == payload.targetProcessIdentifier
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Exact-window click requires a matching process-generation identity and bounds")
        }
        self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
        guard let outcomeService = try self.automationOutcomeService() else {
            try await exactWindowService.click(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId,
                windowEvidence: ExactWindowClickEvidence(identity: expectedIdentity, bounds: expectedBounds),
                allowsAccessibilityValueDelivery: payload.allowsAccessibilityValueDelivery != false)
            return .init(response: .ok)
        }
        let result = try await outcomeService.clickWithOutcome(
            target: payload.target,
            clickType: payload.clickType,
            snapshotId: payload.snapshotId,
            windowEvidence: ExactWindowClickEvidence(identity: expectedIdentity, bounds: expectedBounds),
            allowsAccessibilityValueDelivery: payload.allowsAccessibilityValueDelivery != false)
        return try Self.handledActionResponse(
            response: .ok,
            result: result,
            fallbackTarget: .requestPinned)
    }

    private func handleTargetedTypeActions(
        _ payload: PeekabooBridgeTargetedTypeActionsRequest,
        service: any TargetedTypeServiceProtocol) async throws -> PeekabooBridgeHandledResponse
    {
        if payload.actions.contains(where: \.mayUseAccessibilityValueDelivery) {
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
                  self.hostCapabilities.contains(PeekabooBridgeHostCapability.compositeTypeDelivery),
                  (self.services.automation as? any CompositeTypeDeliveryServiceProtocol)?
                      .supportsExactWindowCompositeTypeDelivery == true
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Truthful composite background typing receipts are not supported by this bridge host")
            }
        }
        self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
        guard let expectedIdentity = payload.expectedProcessIdentity else {
            if let outcomeService = try self.automationOutcomeService() {
                let result = try await outcomeService.typeActionsWithOutcome(
                    payload.actions,
                    cadence: payload.cadence,
                    snapshotId: payload.snapshotId,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
                return try Self.handledActionResponse(
                    response: .typeResult(result.payload),
                    result: result,
                    fallbackTarget: nil)
            }
            let result = try await service.typeActions(
                payload.actions,
                cadence: payload.cadence,
                snapshotId: payload.snapshotId,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .init(response: .typeResult(result))
        }
        guard expectedIdentity.processIdentifier == payload.targetProcessIdentifier else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Targeted typing PID does not match its process-generation receipt")
        }
        guard service.supportsProcessGenerationPinnedTypeActions else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Process-generation-pinned background typing is not supported by this bridge host")
        }
        if let outcomeService = try self.automationOutcomeService() {
            let result = try await outcomeService.typeActionsWithOutcome(
                payload.actions,
                cadence: payload.cadence,
                snapshotId: payload.snapshotId,
                expectedProcessIdentity: expectedIdentity)
            return try Self.handledActionResponse(
                response: .typeResult(result.payload),
                result: result,
                fallbackTarget: .requestPinned)
        }
        let result = try await service.typeActions(
            payload.actions,
            cadence: payload.cadence,
            snapshotId: payload.snapshotId,
            expectedProcessIdentity: expectedIdentity)
        return .init(response: .typeResult(result))
    }

    private func handleProcessTargetedClick(
        _ payload: PeekabooBridgeTargetedClickRequest,
        service: any TargetedClickServiceProtocol) async throws -> PeekabooBridgeHandledResponse
    {
        self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
        guard let expectedIdentity = payload.expectedProcessIdentity else {
            if let outcomeService = try self.automationOutcomeService() {
                let result = try await outcomeService.clickWithOutcome(
                    target: payload.target,
                    clickType: payload.clickType,
                    snapshotId: payload.snapshotId,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
                return try Self.handledActionResponse(
                    response: .ok,
                    result: result,
                    fallbackTarget: nil)
            }
            try await service.click(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .init(response: .ok)
        }
        guard expectedIdentity.processIdentifier == payload.targetProcessIdentifier else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Targeted click PID does not match its process-generation receipt")
        }
        guard service.supportsProcessGenerationPinnedClicks else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Process-generation-pinned background clicks are not supported by this bridge host")
        }
        if let outcomeService = try self.automationOutcomeService() {
            let result = try await outcomeService.clickWithOutcome(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId,
                expectedProcessIdentity: expectedIdentity,
                allowsAccessibilityValueDelivery: payload.allowsAccessibilityValueDelivery != false)
            return try Self.handledActionResponse(
                response: .ok,
                result: result,
                fallbackTarget: .requestPinned)
        }
        try await service.click(
            target: payload.target,
            clickType: payload.clickType,
            snapshotId: payload.snapshotId,
            expectedProcessIdentity: expectedIdentity,
            allowsAccessibilityValueDelivery: payload.allowsAccessibilityValueDelivery != false)
        return .init(response: .ok)
    }

    private func handleTargetedHotkey(
        _ payload: PeekabooBridgeTargetedHotkeyRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard
            let service = self.services.automation as? any TargetedHotkeyServiceProtocol,
            service.supportsTargetedHotkeys
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Background hotkeys are not supported by this bridge host")
        }

        self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
        if let expectedIdentity = payload.expectedProcessIdentity {
            guard expectedIdentity.processIdentifier == payload.targetProcessIdentifier else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Targeted hotkey PID does not match its process-generation receipt")
            }
            guard service.supportsProcessGenerationPinnedHotkeys else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message:
                    "Process-generation-pinned background hotkeys are not supported by this bridge host")
            }
            if let outcomeService = try self.automationOutcomeService() {
                let result = try await outcomeService.hotkeyWithOutcome(
                    keys: payload.keys,
                    holdDuration: payload.holdDuration,
                    expectedProcessIdentity: expectedIdentity)
                return try Self.handledActionResponse(
                    response: .ok,
                    result: result,
                    fallbackTarget: .requestPinned)
            }
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                expectedProcessIdentity: expectedIdentity)
        } else {
            if let outcomeService = try self.automationOutcomeService() {
                let result = try await outcomeService.hotkeyWithOutcome(
                    keys: payload.keys,
                    holdDuration: payload.holdDuration,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
                return try Self.handledActionResponse(
                    response: .ok,
                    result: result,
                    fallbackTarget: nil)
            }
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
        }
        return .init(response: .ok)
    }

    private func handleWindowRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        switch request {
        case let .listWindows(payload):
            let result = try await self.services.windows.listWindows(target: payload.target)
            return .init(response: .windows(result))
        case let .listWindowMutationInventory(payload):
            let inventory = try await self.services.windows.mutationInventory(target: payload.target)
            return .init(response: .windowMutationInventory(inventory))
        case let .focusWindow(payload):
            return try await self.handleWindowFocus(payload)
        case let .moveWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity, operation: .moveWindow)
            let result = try await self.services.windows.moveWindowResult(
                target: payload.target,
                expectedIdentity: identity,
                to: payload.position)
            let response = try await self.windowMutationResponse(
                request: request, outcome: result.outcome)
            return try Self.handledActionResponse(
                response: response,
                outcome: result.outcome,
                fallbackTarget: .requestPinned)
        case let .resizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity, operation: .resizeWindow)
            let result = try await self.services.windows.resizeWindowResult(
                target: payload.target,
                expectedIdentity: identity,
                to: payload.size)
            let response = try await self.windowMutationResponse(
                request: request, outcome: result.outcome)
            return try Self.handledActionResponse(
                response: response,
                outcome: result.outcome,
                fallbackTarget: .requestPinned)
        case let .setWindowBounds(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity,
                operation: .setWindowBounds)
            let result = try await self.services.windows.setWindowBoundsResult(
                target: payload.target,
                expectedIdentity: identity,
                bounds: payload.bounds)
            let response = try await self.windowMutationResponse(
                request: request, outcome: result.outcome)
            return try Self.handledActionResponse(
                response: response,
                outcome: result.outcome,
                fallbackTarget: .requestPinned)
        case let .closeWindow(payload):
            return try await self.handleWindowClose(payload, allowForegroundFallback: true)
        case let .backgroundCloseWindow(payload):
            return try await self.handleWindowClose(payload, allowForegroundFallback: false)
        case let .minimizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity, operation: .minimizeWindow)
            let result = try await self.services.windows.minimizeWindowResult(
                target: payload.target,
                expectedIdentity: identity)
            let response = try await self.windowMutationResponse(
                request: request, outcome: result.outcome)
            return try Self.handledActionResponse(
                response: response,
                outcome: result.outcome,
                fallbackTarget: .requestPinned)
        case let .restoreWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity, operation: .restoreWindow)
            let result = try await self.services.windows.restoreWindowResult(
                target: payload.target,
                expectedIdentity: identity)
            let response = try await self.windowMutationResponse(
                request: request, outcome: result.outcome)
            return try Self.handledActionResponse(
                response: response,
                outcome: result.outcome,
                fallbackTarget: .requestPinned)
        case let .maximizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity, operation: .maximizeWindow)
            let result = try await self.services.windows.maximizeWindowResult(
                target: payload.target,
                expectedIdentity: identity)
            let response = try await self.windowMutationResponse(
                request: request, outcome: result.outcome)
            return try Self.handledActionResponse(
                response: response,
                outcome: result.outcome,
                fallbackTarget: .requestPinned)
        case .getFocusedWindow:
            let window = try await self.services.windows.getFocusedWindow()
            return .init(response: .window(window))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleWindowFocus(
        _ payload: PeekabooBridgeWindowTargetRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard let expectedIdentity = payload.expectedIdentity else {
            guard !PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .invalidRequest,
                    message: "Current window focus requires an exact process-generation target receipt.",
                    hint: "List windows again and retry with one exact window ID.")
            }
            try await self.services.windows.focusWindow(target: payload.target)
            return .init(response: .ok)
        }
        let identity = try Self.requireWindowMutationReceipt(
            expectedIdentity,
            operation: .focusWindow)
        guard case let .windowId(targetWindowID) = payload.target,
              targetWindowID == identity.windowID
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .local,
                reason: .invalidRequest,
                message: "Window focus selector contradicts its exact target receipt.",
                hint: "List windows again and retry with one exact window ID.")
        }
        guard self.validatesCurrentWindowMutationIdentity(identity) else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .local,
                reason: .targetUnavailable,
                message: "Window focus target changed before dispatch.",
                hint: "List windows again and retry with the fresh exact target receipt.")
        }
        let result: UIAutomationActionResult<Void>
        let focusReadback: ServiceWindowInfo?
        if let provider = self.services.windows as? any WindowManagementFocusProofProviding {
            let proof = try await provider.focusWindowProofActionResult(
                target: payload.target,
                expectedIdentity: identity)
            focusReadback = proof.payload
            result = UIAutomationActionResult(
                payload: (),
                outcome: proof.outcome,
                targetIdentity: proof.targetIdentity,
                selectedLeafEvidence: proof.selectedLeafEvidence)
        } else {
            // Preserve the public 4.x provider contract and its existing fail-closed readback.
            focusReadback = nil
            result = try await self.services.windows.focusWindowResult(
                target: payload.target,
                expectedIdentity: identity)
        }
        let outcome = try Self.requireCurrentWindowOutcome(result.outcome, operation: "focus window")
        if outcome.state == .refused, outcome.dispatchState == .none {
            return try Self.handledActionResponse(
                response: .ok,
                result: result,
                fallbackTarget: nil)
        }
        guard let exactWindow = result.targetIdentity?.exactWindow,
              exactWindow.identity.hasSameStableReceipt(as: identity),
              exactWindow.bounds == identity.capturedBounds
        else {
            throw DesktopActionFailure.indeterminate(
                route: .local,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Window focus provider returned a different or missing exact target.",
                hint: "Observe the intended window before retrying and update the runtime host.")
        }
        let response = try await self.windowMutationResponse(
            request: .focusWindow(payload),
            outcome: result.outcome,
            focusReadback: focusReadback)
        return try Self.handledActionResponse(
            response: response,
            result: result,
            fallbackTarget: nil)
    }

    private func handleWindowClose(
        _ payload: PeekabooBridgeWindowTargetRequest,
        allowForegroundFallback: Bool) async throws -> PeekabooBridgeHandledResponse
    {
        let operation: PeekabooBridgeOperation =
            allowForegroundFallback ? .closeWindow : .backgroundCloseWindow
        let operationName = allowForegroundFallback ? "close window" : "background close window"
        let identity = try Self.requireWindowMutationReceipt(
            payload.expectedIdentity,
            operation: operation)
        let result: DesktopActionResult<Void>
        if PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics {
            let results = try Self.requireCurrentWindowActionResults(self.services.windows)
            result = try await results.closeWindowActionResult(
                target: payload.target,
                expectedIdentity: identity,
                allowForegroundFallback: allowForegroundFallback)
            _ = try Self.requireCurrentWindowOutcome(result.outcome, operation: operationName)
        } else {
            result = try await self.services.windows.closeWindowResult(
                target: payload.target,
                expectedIdentity: identity,
                allowForegroundFallback: allowForegroundFallback)
        }
        let request: PeekabooBridgeRequest =
            allowForegroundFallback
                ? .closeWindow(payload)
                : .backgroundCloseWindow(payload)
        let response = try await self.windowMutationResponse(request: request, outcome: result.outcome)
        return try Self.handledActionResponse(
            response: response,
            outcome: result.outcome,
            fallbackTarget: .requestPinned)
    }

    static func handledActionResponse(
        response: PeekabooBridgeResponse,
        result: UIAutomationActionResult<some Sendable>,
        fallbackTarget: PeekabooBridgeHandledResponse.Mutation.TargetDisposition?) throws
        -> PeekabooBridgeHandledResponse
    {
        try self.handledActionResponse(
            response: response,
            outcome: result.outcome,
            targetIdentity: result.targetIdentity,
            fallbackTarget: fallbackTarget)
    }

    private static func requireCurrentWindowOutcome(
        _ outcome: DesktopActionOutcome?,
        operation: String) throws -> DesktopActionOutcome
    {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                route: .local,
                evidence: .completionUnknown,
                message: "The \(operation) provider returned without a canonical action outcome.",
                hint: "Observe the exact window before retrying and update the runtime host.")
        }
        return outcome
    }

    private static func requireCurrentWindowActionResults(
        _ service: any WindowManagementServiceProtocol) throws -> any WindowManagementActionResultProviding
    {
        guard let results = service as? any WindowManagementActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The window service cannot return canonical close execution results.",
                hint: "Update the runtime host before retrying this exact close request.")
        }
        return results
    }

    static func handledActionResponse(
        response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome?,
        targetIdentity: DesktopTargetIdentity? = nil,
        fallbackTarget: PeekabooBridgeHandledResponse.Mutation.TargetDisposition?) throws
        -> PeekabooBridgeHandledResponse
    {
        guard let outcome else {
            return .init(response: response, targetIdentity: targetIdentity)
        }
        if PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
           outcome.state == .refused,
           outcome.dispatchState == .none,
           let failure = DesktopActionFailure(
               outcome: outcome,
               message: "The desktop action was refused before dispatch.",
               hint: "Follow the canonical refusal metadata before retrying.")
        {
            throw failure
        }
        if let targetIdentity {
            return .init(
                response: response,
                mutation: .init(outcome: outcome, target: .handlerResolved(targetIdentity)))
        }
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
            return .init(
                response: response,
                mutation: .init(outcome: outcome, target: fallbackTarget ?? .external))
        }
        guard let fallbackTarget else {
            throw DesktopActionFailure.indeterminate(
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "The desktop action completed without its required exact target receipt.",
                hint: "Observe the intended target before retrying and update the runtime host.")
        }
        return .init(
            response: response,
            mutation: .init(outcome: outcome, target: fallbackTarget))
    }

    private static func globalPointerMutationResponse() -> PeekabooBridgeHandledResponse {
        .init(
            response: .ok,
            mutation: .init(
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .globalEvents, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                target: .global))
    }

    private static func dispatchUnitCount(_ count: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let count = DesktopActionOutcome.DispatchUnitCount(count) else {
            preconditionFailure("A dispatched Bridge operation must contain at least one unit")
        }
        return count
    }

    private func requireFocusMutationTarget(
        _ context: WindowContext?,
        operation: PeekabooBridgeOperation) throws -> DesktopTargetIdentity?
    {
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else { return nil }
        guard context?.shouldFocusWebContent == true else { return nil }
        guard let context,
              let processIdentifier = context.applicationProcessId,
              let windowID = context.windowID,
              let bounds = context.windowBounds,
              let identity = context.windowMutationIdentity,
              identity.ownerProcessIdentifier == processIdentifier,
              identity.windowID == windowID,
              identity.capturedBounds == bounds
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message:
                "Operation \(operation.rawValue) requires an exact process-generation window receipt "
                    + "before web-content focus is allowed.",
                hint: "Capture the target window again and retry with its exact window context.")
        }
        guard self.validatesCurrentWindowMutationIdentity(identity) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact web-content focus target changed before dispatch.",
                hint: "Capture the target window again and retry with its fresh window context.")
        }
        do {
            return try DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: identity,
                    bounds: bounds))
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "The exact web-content focus target receipt is inconsistent.",
                hint: "Capture the target window again and retry with its exact window context.",
                causeDescription: error.localizedDescription)
        }
    }

    private static func requireWindowMutationReceipt(
        _ identity: WindowMutationIdentity?,
        operation: PeekabooBridgeOperation) throws -> WindowMutationIdentity
    {
        guard let identity, identity.capturedBounds != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Operation \(operation.rawValue) requires a process-generation window mutation "
                    + "receipt with capture-time bounds")
        }
        return identity
    }

    private func validatesCurrentWindowMutationIdentity(_ identity: WindowMutationIdentity) -> Bool {
        guard let windowID = CGWindowID(exactly: identity.windowID),
              let capturedBounds = identity.capturedBounds
        else { return false }
        return self.windowOwnerProcessIdentifierProvider(windowID) == identity.ownerProcessIdentifier
            && self.processStartIdentityProvider(identity.ownerProcessIdentifier)
            == identity.ownerProcessStartIdentity
            && self.windowBoundsProvider(windowID) == capturedBounds
    }
}
