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
        case .permissionsStatus, .requestPostEventPermission, .daemonStatus, .daemonStop:
            return try await .init(response: self.handleCoreRequest(request, peer: peer, permissions: permissions))
        case .browserStatus, .browserConnect, .browserDisconnect, .browserExecute:
            return try await .init(response: self.handleBrowserRequest(request))
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea:
            return try await .init(response: self.handleCaptureRequest(request))
        case .desktopObservation:
            return try await .init(response: self.handleDesktopObservationRequest(request))
        case .detectElements, .inspectAccessibilityTree, .getFocusedElement, .click, .type, .typeActions,
             .targetedTypeActions, .exactWindowTargetedTypeActions,
             .setValue, .performAction, .scroll, .targetedScroll, .hotkey, .targetedHotkey,
             .exactWindowTargetedHotkey, .targetedClick,
             .exactWindowTargetedClick, .swipe, .drag, .moveMouse, .waitForElement:
            return try await self.handleAutomationRequest(request)
        case .listWindows, .focusWindow, .moveWindow, .resizeWindow, .setWindowBounds, .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow, .restoreWindow, .maximizeWindow, .getFocusedWindow:
            return try await self.handleWindowRequest(request)
        case .listApplications, .findApplication, .getFrontmostApplication, .isApplicationRunning,
             .launchApplication, .launchApplicationWithOptions, .relaunchApplicationWithOptions,
             .activateApplication, .quitApplication,
             .hideApplication, .unhideApplication, .hideOtherApplications, .showAllApplications:
            return try await .init(response: self.handleApplicationRequest(request))
        case .listMenus, .listFrontmostMenus, .clickMenuItem, .clickMenuItemByName, .listMenuExtras,
             .clickMenuExtra, .menuExtraOpenMenuFrame, .listMenuBarItems, .clickMenuBarItemNamed,
             .clickMenuBarItemIndex:
            return try await .init(response: self.handleMenuRequest(request))
        case .listDockItems, .launchDockItem, .rightClickDockItem, .hideDock, .showDock, .isDockHidden,
             .findDockItem:
            return try await .init(response: self.handleDockRequest(request))
        case .dialogFindActive, .dialogClickButton, .backgroundDialogClickButton, .dialogEnterText,
             .dialogHandleFile, .dialogDismiss,
             .dialogListElements:
            return try await .init(response: self.handleDialogRequest(request))
        case .createSnapshot, .storeDetectionResult, .getDetectionResult, .storeScreenshot,
             .storeObservationSnapshot, .storeAnnotatedScreenshot, .listSnapshots, .getMostRecentSnapshot,
             .cleanSnapshot,
             .invalidateImplicitLatestSnapshot, .beginSnapshotMutation, .finishSnapshotMutation,
             .cleanSnapshotsOlderThan, .cleanAllSnapshots:
            return try await .init(response: self.handleSnapshotRequest(request))
        case ._appleScriptProbe:
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "AppleScript probing is no longer supported; current operations use native macOS APIs")
        }
    }

    private func handleBrowserRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .browserStatus(payload):
            return try await .browserStatus(self.services.browserStatus(channel: payload.channel))
        case let .browserConnect(payload):
            return try await .browserStatus(self.services.browserConnect(channel: payload.channel))
        case .browserDisconnect:
            try await self.services.browserDisconnect()
            return .ok
        case let .browserExecute(payload):
            return try await .browserToolResponse(self.services.browserExecute(payload))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleCoreRequest(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?,
        permissions: PermissionsStatus) async throws -> PeekabooBridgeResponse
    {
        switch request {
        case .permissionsStatus:
            return .permissionsStatus(permissions)
        case .requestPostEventPermission:
            return .bool(self.postEventAccessRequester())
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
            guard let daemonControl = self.daemonControl as? any PeekabooConditionalDaemonControlProviding else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Conditional daemon stop is not supported by this host")
            }
            let stopped = await daemonControl.requestStop(expectedPID: payload.expectedPID)
            return .bool(stopped)
        case let .handshake(payload):
            return try self.handleHandshake(payload, peer: peer, permissions: permissions)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleCaptureRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
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
        if let windowId = payload.windowId {
            let capture = try await self.services.screenCapture.captureWindow(
                windowID: CGWindowID(windowId),
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
    -> PeekabooBridgeResponse {
        switch request {
        case let .desktopObservation(payload):
            let observation = try await self.services.desktopObservation.observe(payload)
            return .desktopObservation(observation.withoutImageData())
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleAutomationRequest(
        _ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse
    {
        switch request {
        case let .detectElements(payload):
            let result = try await self.services.automation.detectElements(
                in: payload.imageData,
                snapshotId: payload.snapshotId,
                windowContext: payload.windowContext)
            return .init(response: .elementDetection(result))
        case let .inspectAccessibilityTree(payload):
            let result = try await self.services.automation.inspectAccessibilityTree(
                windowContext: payload.windowContext)
            return .init(response: .elementDetection(result))
        case let .getFocusedElement(payload):
            guard let automation = self.services.automation as? any TargetedFocusedElementServiceProtocol else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "PID-scoped focused-element queries are not supported by this bridge host")
            }
            let focusedElement = await automation.getFocusedElement(
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .init(response: .focusedElement(focusedElement))
        case let .click(payload):
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
                    try await service.hotkeyWithOutcome(keys: payload.keys, holdDuration: payload.holdDuration)
                },
                legacy: {
                    try await self.services.automation.hotkey(
                        keys: payload.keys,
                        holdDuration: payload.holdDuration)
                    return ()
                },
                response: { _ in .ok })
        case let .swipe(payload):
            try await self.services.automation.swipe(
                from: payload.from,
                to: payload.to,
                duration: payload.duration,
                steps: payload.steps,
                profile: payload.profile)
            return .init(response: .ok)
        case let .drag(payload):
            try await self.services.automation.drag(payload.automationRequest)
            return .init(response: .ok)
        case let .moveMouse(payload):
            try await self.services.automation.moveMouse(
                to: payload.to,
                duration: payload.duration,
                steps: payload.steps,
                profile: payload.profile)
            return .init(response: .ok)
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

    private func handleScroll(_ request: ScrollRequest) async throws -> PeekabooBridgeHandledResponse {
        try await self.handleAutomationAction(
            withOutcome: { service in
                try await service.scrollWithOutcome(request)
            },
            legacy: {
                try await self.services.automation.scroll(request)
                return ()
            },
            response: { _ in .ok })
    }

    private func handleAutomationAction<Payload: Sendable>(
        withOutcome: (any UIAutomationActionOutcomeProviding) async throws -> UIAutomationActionResult<Payload>,
        legacy: () async throws -> Payload,
        response: (Payload) -> PeekabooBridgeResponse) async throws -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.automation as? any UIAutomationActionOutcomeProviding else {
            let payload = try await legacy()
            return .init(response: response(payload))
        }
        let result = try await withOutcome(service)
        return .init(response: response(result.payload), outcome: result.outcome)
    }

    private func handleElementActionRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeHandledResponse
    {
        guard let automation = self.services.automation as? any ElementActionAutomationServiceProtocol else {
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
        if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
            let result = if let expectedFocusedElement = payload.expectedFocusedElement {
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
            return .init(response: .typeResult(result.payload), outcome: result.outcome)
        }
        let result = if let expectedFocusedElement = payload.expectedFocusedElement {
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
        if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
            let result = if let expectedFocusedElement = payload.expectedFocusedElement {
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
            return .init(response: .ok, outcome: result.outcome)
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
        if case .coordinates = payload.target, payload.targetWindowID == nil {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Background coordinate clicks require an exact capture-time window identity and bounds; " +
                    "PID-only coordinates are refused")
        }
        guard let targetWindowID = payload.targetWindowID else {
            let outcome = try await self.handleProcessTargetedClick(payload, service: targetedClickService)
            return .init(response: .ok, outcome: outcome)
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
        guard let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding else {
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
        return .init(response: .ok, outcome: result.outcome)
    }

    private func handleTargetedTypeActions(
        _ payload: PeekabooBridgeTargetedTypeActionsRequest,
        service: any TargetedTypeServiceProtocol) async throws -> PeekabooBridgeHandledResponse
    {
        self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
        guard let expectedIdentity = payload.expectedProcessIdentity else {
            if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeService.typeActionsWithOutcome(
                    payload.actions,
                    cadence: payload.cadence,
                    snapshotId: payload.snapshotId,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
                return .init(response: .typeResult(result.payload), outcome: result.outcome)
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
        if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
            let result = try await outcomeService.typeActionsWithOutcome(
                payload.actions,
                cadence: payload.cadence,
                snapshotId: payload.snapshotId,
                expectedProcessIdentity: expectedIdentity)
            return .init(response: .typeResult(result.payload), outcome: result.outcome)
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
        service: any TargetedClickServiceProtocol) async throws -> DesktopActionOutcome?
    {
        self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
        guard let expectedIdentity = payload.expectedProcessIdentity else {
            if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeService.clickWithOutcome(
                    target: payload.target,
                    clickType: payload.clickType,
                    snapshotId: payload.snapshotId,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
                return result.outcome
            }
            try await service.click(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return nil
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
        if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
            let result = try await outcomeService.clickWithOutcome(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId,
                expectedProcessIdentity: expectedIdentity)
            return result.outcome
        }
        try await service.click(
            target: payload.target,
            clickType: payload.clickType,
            snapshotId: payload.snapshotId,
            expectedProcessIdentity: expectedIdentity)
        return nil
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
                    message: "Process-generation-pinned background hotkeys are not supported by this bridge host")
            }
            if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeService.hotkeyWithOutcome(
                    keys: payload.keys,
                    holdDuration: payload.holdDuration,
                    expectedProcessIdentity: expectedIdentity)
                return .init(response: .ok, outcome: result.outcome)
            }
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                expectedProcessIdentity: expectedIdentity)
        } else {
            if let outcomeService = self.services.automation as? any UIAutomationActionOutcomeProviding {
                let result = try await outcomeService.hotkeyWithOutcome(
                    keys: payload.keys,
                    holdDuration: payload.holdDuration,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
                return .init(response: .ok, outcome: result.outcome)
            }
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
        }
        return .init(response: .ok)
    }

    private func handleWindowRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        switch request {
        case let .listWindows(payload):
            let result = try await self.services.windows.listWindows(target: payload.target)
            return .init(response: .windows(result))
        case let .focusWindow(payload):
            try await self.services.windows.focusWindow(target: payload.target)
            return .init(response: .ok)
        case let .moveWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .moveWindow)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.moveWindowWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity,
                        to: payload.position)
                },
                legacy: {
                    try await self.services.windows.moveWindow(
                        target: payload.target,
                        expectedIdentity: identity,
                        to: payload.position)
                })
        case let .resizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .resizeWindow)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.resizeWindowWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity,
                        to: payload.size)
                },
                legacy: {
                    try await self.services.windows.resizeWindow(
                        target: payload.target,
                        expectedIdentity: identity,
                        to: payload.size)
                })
        case let .setWindowBounds(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity,
                operation: .setWindowBounds)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.setWindowBoundsWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity,
                        bounds: payload.bounds)
                },
                legacy: {
                    try await self.services.windows.setWindowBounds(
                        target: payload.target,
                        expectedIdentity: identity,
                        bounds: payload.bounds)
                })
        case let .closeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .closeWindow)
            try await self.services.windows.closeWindow(
                target: payload.target,
                expectedIdentity: identity,
                allowForegroundFallback: true)
            return .init(response: .ok)
        case let .backgroundCloseWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity,
                operation: .backgroundCloseWindow)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.closeWindowWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity)
                },
                legacy: {
                    try await self.services.windows.closeWindow(
                        target: payload.target,
                        expectedIdentity: identity,
                        allowForegroundFallback: false)
                })
        case let .minimizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .minimizeWindow)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.minimizeWindowWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity)
                },
                legacy: {
                    try await self.services.windows.minimizeWindow(
                        target: payload.target,
                        expectedIdentity: identity)
                })
        case let .restoreWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .restoreWindow)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.restoreWindowWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity)
                },
                legacy: {
                    try await self.services.windows.restoreWindow(
                        target: payload.target,
                        expectedIdentity: identity)
                })
        case let .maximizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .maximizeWindow)
            return try await self.handleWindowAction(
                withOutcome: { service in
                    try await service.maximizeWindowWithOutcome(
                        target: payload.target,
                        expectedIdentity: identity)
                },
                legacy: {
                    try await self.services.windows.maximizeWindow(
                        target: payload.target,
                        expectedIdentity: identity)
                })
        case .getFocusedWindow:
            let window = try await self.services.windows.getFocusedWindow()
            return .init(response: .window(window))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleWindowAction(
        withOutcome: (any WindowManagementActionOutcomeProviding) async throws -> DesktopActionOutcome?,
        legacy: () async throws -> Void) async throws -> PeekabooBridgeHandledResponse
    {
        guard let service = self.services.windows as? any WindowManagementActionOutcomeProviding else {
            try await legacy()
            return .init(response: .ok)
        }
        let outcome = try await withOutcome(service)
        return .init(response: .ok, outcome: outcome)
    }

    private static func requireWindowMutationReceipt(
        _ identity: WindowMutationIdentity?,
        operation: PeekabooBridgeOperation) throws -> WindowMutationIdentity
    {
        guard let identity, identity.capturedBounds != nil else {
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Operation \(operation.rawValue) requires a process-generation window mutation " +
                    "receipt with capture-time bounds")
        }
        return identity
    }
}
