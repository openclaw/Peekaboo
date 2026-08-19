import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
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
        case .requestPostEventPermission:
            return self.handlePostEventPermissionRequest()
        case .browserStatus, .browserDisconnect:
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
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
                  !payload.isReadOnly
            else {
                return try await .init(response: self.handleBrowserRequest(request))
            }
            return try await self.handleBrowserExecute(payload)
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea:
            return try await .init(response: self.handleCaptureRequest(request))
        case .desktopObservation:
            return try await self.handleDesktopObservationRequest(request)
        case .detectElements, .inspectAccessibilityTree, .getFocusedElement, .click, .type,
             .typeActions,
             .targetedTypeActions, .exactWindowTargetedTypeActions,
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
        case .createSnapshot, .storeDetectionResult, .getDetectionResult, .storeScreenshot,
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

    private func handleBrowserRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeResponse
    {
        switch request {
        case let .browserStatus(payload):
            return try await .browserStatus(self.services.browserStatus(channel: payload.channel))
        case let .browserConnect(payload):
            return try await .browserStatus(
                self.services.browserConnect(
                    channel: payload.channel,
                    browserURL: payload.browserURL))
        case .browserDisconnect:
            try await self.services.browserDisconnect()
            return .ok
        case let .browserExecute(payload):
            return try await .browserToolResponse(self.services.browserExecute(payload))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleBrowserExecute(
        _ payload: PeekabooBridgeBrowserExecuteRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard !payload.resolvedCalls.isEmpty else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Browser execution requires at least one tool call.",
                hint: "Provide one browser tool call before retrying.")
        }
        let target = try await self.browserExecutionTarget(payload)
        let result: PeekabooBridgeBrowserExecutionResult
        do {
            result = try await self.services.browserExecute(
                payload,
                expectedConnectionReceipt: target.receipt)
        } catch is CancellationError {
            return Self.browserOpaqueCancellationHandledResponse(
                target: target,
                causeDescription:
                "The browser provider was cancelled after accepting the execution request.")
        }
        guard result.connectionReceipt == target.receipt,
              result.completedCallCount >= 0,
              result.dispatchedCallCount >= result.completedCallCount,
              result.dispatchedCallCount <= payload.mutationCallCount
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                message: "Browser execution returned a different connection receipt.",
                hint: "Observe the intended browser before retrying and update the runtime host.")
        }
        if result.dispatchedCallCount == 0 {
            return try Self.browserNoDispatchHandledResponse(result: result, target: target)
        }
        guard
            let dispatchedCallCount = DesktopActionOutcome.DispatchUnitCount(result.dispatchedCallCount)
        else {
            preconditionFailure("A positive browser dispatch count must have a canonical unit count")
        }
        let routedFailure: DesktopActionFailure? =
            if let failure = result.actionFailure,
            failure.outcome.dispatchState.mutationDispatched,
            failure.outcome.dispatchState.unitCount == dispatchedCallCount {
                failure.routed(to: .bridge)
            } else if result.actionFailure != nil || result.response.isError
                || result.completedCallCount != payload.mutationCallCount
            {
                Self.browserProviderIndeterminateFailure(
                    completedCallCount: result.completedCallCount,
                    dispatchedCallCount: dispatchedCallCount,
                    causeDescription:
                    "The browser provider returned incomplete or contradictory result semantics.")
            } else {
                nil
            }
        let response = PeekabooBridgeBrowserToolResponse(
            content: result.response.content,
            isError: routedFailure != nil,
            meta: result.response.meta,
            connectionReceipt: target.receipt,
            completedCallCount: result.completedCallCount,
            dispatchedCallCount: result.dispatchedCallCount,
            actionFailure: routedFailure)
        let outcome =
            routedFailure?.outcome
                ?? .dispatchedUnverified(
                    delivery: .init(mechanism: .browserProtocol, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: dispatchedCallCount)
        return .init(
            response: .browserToolResponse(response),
            mutation: .init(
                outcome: outcome,
                target: target.disposition))
    }

    private static func browserNoDispatchHandledResponse(
        result: PeekabooBridgeBrowserExecutionResult,
        target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition)) throws
        -> PeekabooBridgeHandledResponse
    {
        guard result.completedCallCount == 0,
              let failure = result.actionFailure,
              failure.outcome.state == .refused,
              failure.outcome.dispatchState == .none,
              failure.outcome.retrySafety == .safe,
              failure.outcome.refusalReason != nil
        else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                message: "Browser provider returned contradictory zero-progress semantics.",
                hint: "Observe the exact browser before retrying and update the runtime host.")
        }
        let routedFailure = failure.routed(to: .bridge)
        return .init(
            response: .browserToolResponse(
                .init(
                    content: result.response.content,
                    isError: true,
                    meta: result.response.meta,
                    connectionReceipt: target.receipt,
                    completedCallCount: 0,
                    dispatchedCallCount: 0,
                    actionFailure: routedFailure)),
            mutation: .init(outcome: routedFailure.outcome, target: target.disposition))
    }

    private static func browserOpaqueCancellationHandledResponse(
        target: (
            receipt: PeekabooBridgeBrowserConnectionReceipt,
            disposition: PeekabooBridgeHandledResponse.Mutation.TargetDisposition),
        causeDescription: String) -> PeekabooBridgeHandledResponse
    {
        let failure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            message: "Browser execution completion is indeterminate; exact progress is unavailable.",
            hint: "Observe the exact browser before deciding which work remains unfinished.",
            causeDescription: causeDescription)
        return .init(
            response: .browserToolResponse(
                .init(
                    content: [
                        .object([
                            "type": .string("text"),
                            "text": .string(failure.message),
                        ]),
                    ],
                    isError: true,
                    meta: nil,
                    connectionReceipt: target.receipt,
                    actionFailure: failure)),
            mutation: .init(outcome: failure.outcome, target: target.disposition))
    }

    private static func browserProviderIndeterminateFailure(
        completedCallCount: Int,
        dispatchedCallCount: DesktopActionOutcome.DispatchUnitCount,
        causeDescription: String) -> DesktopActionFailure
    {
        .indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: dispatchedCallCount,
            message: "Browser execution completion is indeterminate "
                + "(\(completedCallCount) completed, \(dispatchedCallCount.rawValue) dispatched or accepted).",
            hint: "Observe the exact browser before resuming unfinished work.",
            causeDescription: causeDescription)
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

    private func handleCaptureRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeResponse
    {
        switch request {
        case let .captureScreen(payload):
            let capture = try await self.services.screenCapture.captureScreen(
                displayIndex: payload.displayIndex,
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        case let .captureWindow(payload):
            return try await self.handleCaptureWindow(payload)
        case let .captureFrontmost(payload):
            let capture = try await self.services.screenCapture.captureFrontmost(
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        case let .captureArea(payload):
            let capture = try await self.services.screenCapture.captureArea(
                payload.rect,
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleCaptureWindow(
        _ payload: PeekabooBridgeCaptureWindowRequest) async throws -> PeekabooBridgeResponse
    {
        if let windowID = try payload.validatedWindowID() {
            let capture = try await self.services.screenCapture.captureWindow(
                windowID: windowID,
                visualizerMode: payload.visualizerMode,
                scale: payload.scale)
            return .capture(capture)
        }

        guard !payload.appIdentifier.isEmpty else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "captureWindow requires appIdentifier or windowId")
        }

        let capture = try await self.services.screenCapture.captureWindow(
            appIdentifier: payload.appIdentifier,
            windowIndex: payload.windowIndex,
            visualizerMode: payload.visualizerMode,
            scale: payload.scale)
        return .capture(capture)
    }

    private func handleDesktopObservationRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        switch request {
        case let .desktopObservation(payload):
            try Self.validateAttestedWebFocusTarget(payload)
            if self.services.desktopObservation is any DesktopObservationActionResultProviding {
                let result = try await self.services.desktopObservation.observeResult(payload)
                try Self.validateAttestedObservationBinding(
                    payload,
                    result: result.payload,
                    requireContentDigest: false)
                let attested = try result.payload.attestingCaptureContent()
                try Self.validateAttestedObservationBinding(payload, result: attested)
                let response = PeekabooBridgeResponse.desktopObservation(attested.withoutImageData())
                guard request.mayMutateDesktop else {
                    if let failure = Self.readOnlyObservationFailure(result) {
                        let target = try PeekabooBridgeOperationTargetAttribution.resolve(
                            request: request,
                            response: response,
                            handledTarget: result.targetIdentity)
                        return .init(
                            response: .error(
                                .init(
                                    code: .internalError,
                                    actionFailure: failure.routed(to: .bridge))),
                            targetIdentity: target)
                    }
                    return .init(response: response, targetIdentity: result.targetIdentity)
                }
                let outcome = try Self.requireSuccessfulObservationOutcome(result)
                let target =
                    result.targetIdentity.map {
                        PeekabooBridgeHandledResponse.Mutation.TargetDisposition.handlerResolved($0)
                    } ?? Self.observationFallbackTarget(for: payload)
                if let failure = Self.observationFailure(result, outcome: outcome) {
                    return .init(
                        response: .error(
                            .init(
                                code: .internalError,
                                actionFailure: failure.routed(to: .bridge))),
                        mutation: .init(outcome: outcome, target: target))
                }
                return .init(
                    response: response,
                    mutation: .init(outcome: outcome, target: target))
            }
            if case let .menubarPopover(_, openIfNeeded) = payload.target,
               openIfNeeded != nil
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Menu-bar popover opening requires an action-result-aware observation service.",
                    hint: "Update the runtime host before retrying this conditional background mutation.")
            }
            let observation = try await self.services.desktopObservation.observe(payload)
            try Self.validateAttestedObservationBinding(
                payload,
                result: observation,
                requireContentDigest: false)
            let attested = try observation.attestingCaptureContent()
            try Self.validateAttestedObservationBinding(payload, result: attested)
            let response = PeekabooBridgeResponse.desktopObservation(attested.withoutImageData())
            guard request.mayMutateDesktop else {
                return .init(response: response)
            }
            let mode: DesktopActionOutcome.Delivery.Mode =
                payload.capture.focus == .background
                    ? .background
                    : .foreground
            return .init(
                response: response,
                mutation: .init(
                    outcome: .dispatchedUnverified(
                        delivery: .init(mechanism: .capturePipeline, mode: mode),
                        evidence: .deliveryAccepted,
                        unitCount: .one),
                    target: Self.observationFallbackTarget(for: payload)))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private static func readOnlyObservationFailure(
        _ result: UIAutomationActionResult<DesktopObservationResult>) -> DesktopActionFailure?
    {
        guard let outcome = result.outcome else { return nil }
        let targetReceipt = self.observationTargetReceipt(result.targetIdentity)
        if outcome.state == .confirmedNoChange,
           outcome.delivery == nil,
           outcome.dispatchState == .none
        {
            return nil
        }
        if let failure = DesktopActionFailure(
            outcome: outcome,
            message: "Read-only desktop observation returned a non-success or dispatching outcome.",
            hint: "Observe the target before retrying and update the runtime host.",
            targetReceipt: targetReceipt)
        {
            return failure
        }
        return DesktopActionFailure.indeterminate(
            route: outcome.route,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "Read-only desktop observation contradicted its no-dispatch contract.",
            hint: "Observe the target before retrying and update the runtime host.")
            .attributed(to: targetReceipt)
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
        case .targetedTypeActions, .exactWindowTargetedTypeActions, .targetedHotkey,
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
                expectedWindowIdentity: expectedIdentity,
                expectedWindowBounds: expectedBounds)
            return .init(response: .ok)
        }
        let result = try await outcomeService.clickWithOutcome(
            target: payload.target,
            clickType: payload.clickType,
            snapshotId: payload.snapshotId,
            expectedWindowIdentity: expectedIdentity,
            expectedWindowBounds: expectedBounds)
        return try Self.handledActionResponse(
            response: .ok,
            result: result,
            fallbackTarget: .requestPinned)
    }

    private func handleTargetedTypeActions(
        _ payload: PeekabooBridgeTargetedTypeActionsRequest,
        service: any TargetedTypeServiceProtocol) async throws -> PeekabooBridgeHandledResponse
    {
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
                expectedProcessIdentity: expectedIdentity)
            return try Self.handledActionResponse(
                response: .ok,
                result: result,
                fallbackTarget: .requestPinned)
        }
        try await service.click(
            target: payload.target,
            clickType: payload.clickType,
            snapshotId: payload.snapshotId,
            expectedProcessIdentity: expectedIdentity)
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
        let result = try await self.services.windows.focusWindowResult(
            target: payload.target,
            expectedIdentity: identity)
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
            outcome: result.outcome)
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
