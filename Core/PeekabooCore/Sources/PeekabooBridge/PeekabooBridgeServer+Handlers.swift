import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleAuthorized(
        _ request: PeekabooBridgeRequest,
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeResponse
    {
        switch request.operation {
        case .permissionsStatus, .requestPostEventPermission, .daemonStatus, .daemonStop:
            try await self.handleCoreRequest(request, peer: peer)
        case .browserStatus, .browserConnect, .browserDisconnect, .browserExecute:
            try await self.handleBrowserRequest(request)
        case .captureScreen, .captureWindow, .captureFrontmost, .captureArea:
            try await self.handleCaptureRequest(request)
        case .desktopObservation:
            try await self.handleDesktopObservationRequest(request)
        case .detectElements, .inspectAccessibilityTree, .getFocusedElement, .click, .type, .typeActions,
             .targetedTypeActions, .exactWindowTargetedTypeActions,
             .setValue, .performAction, .scroll, .targetedScroll, .hotkey, .targetedHotkey,
             .exactWindowTargetedHotkey, .targetedClick,
             .exactWindowTargetedClick, .swipe, .drag, .moveMouse, .waitForElement:
            try await self.handleAutomationRequest(request)
        case .listWindows, .focusWindow, .moveWindow, .resizeWindow, .setWindowBounds, .closeWindow,
             .backgroundCloseWindow,
             .minimizeWindow, .restoreWindow, .maximizeWindow, .getFocusedWindow:
            try await self.handleWindowRequest(request)
        case .listApplications, .findApplication, .getFrontmostApplication, .isApplicationRunning,
             .launchApplication, .launchApplicationWithOptions, .relaunchApplicationWithOptions,
             .activateApplication, .quitApplication,
             .hideApplication, .unhideApplication, .hideOtherApplications, .showAllApplications:
            try await self.handleApplicationRequest(request)
        case .listMenus, .listFrontmostMenus, .clickMenuItem, .clickMenuItemByName, .listMenuExtras,
             .clickMenuExtra, .menuExtraOpenMenuFrame, .listMenuBarItems, .clickMenuBarItemNamed,
             .clickMenuBarItemIndex:
            try await self.handleMenuRequest(request)
        case .listDockItems, .launchDockItem, .rightClickDockItem, .hideDock, .showDock, .isDockHidden,
             .findDockItem:
            try await self.handleDockRequest(request)
        case .dialogFindActive, .dialogClickButton, .backgroundDialogClickButton, .dialogEnterText,
             .dialogHandleFile, .dialogDismiss,
             .dialogListElements:
            try await self.handleDialogRequest(request)
        case .createSnapshot, .storeDetectionResult, .getDetectionResult, .storeScreenshot,
             .storeAnnotatedScreenshot, .listSnapshots, .getMostRecentSnapshot, .cleanSnapshot,
             .invalidateImplicitLatestSnapshot, .cleanSnapshotsOlderThan, .cleanAllSnapshots:
            try await self.handleSnapshotRequest(request)
        case ._appleScriptProbe:
            try self.handleAppleScriptProbe()
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
        peer: PeekabooBridgePeer?) async throws -> PeekabooBridgeResponse
    {
        switch request {
        case .permissionsStatus:
            return .permissionsStatus(self.currentPermissions(allowAppleScriptLaunch: false))
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
            return try self.handleHandshake(payload, peer: peer)
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

    private func handleAutomationRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .detectElements(payload):
            let result = try await self.services.automation.detectElements(
                in: payload.imageData,
                snapshotId: payload.snapshotId,
                windowContext: payload.windowContext)
            return .elementDetection(result)
        case let .inspectAccessibilityTree(payload):
            let result = try await self.services.automation.inspectAccessibilityTree(
                windowContext: payload.windowContext)
            return .elementDetection(result)
        case let .getFocusedElement(payload):
            guard let automation = self.services.automation as? any TargetedFocusedElementServiceProtocol else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "PID-scoped focused-element queries are not supported by this bridge host")
            }
            let focusedElement = await automation.getFocusedElement(
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .focusedElement(focusedElement)
        case let .click(payload):
            try await self.services.automation.click(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId)
            return .ok
        case let .type(payload):
            try await self.services.automation.type(
                text: payload.text,
                target: payload.target,
                clearExisting: payload.clearExisting,
                typingDelay: payload.typingDelay,
                snapshotId: payload.snapshotId)
            return .ok
        case let .typeActions(payload):
            let result = try await self.services.automation.typeActions(
                payload.actions,
                cadence: payload.cadence,
                snapshotId: payload.snapshotId)
            return .typeResult(result)
        case .targetedTypeActions, .exactWindowTargetedTypeActions, .targetedHotkey,
             .exactWindowTargetedHotkey, .targetedClick:
            return try await self.handleTargetedAutomationRequest(request)
        case let .setValue(payload):
            guard let automation = self.services.automation as? any ElementActionAutomationServiceProtocol else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "setValue is not supported by this bridge host")
            }
            let result = try await automation.setValue(
                target: payload.target,
                value: payload.value,
                snapshotId: payload.snapshotId)
            return .elementActionResult(result)
        case let .performAction(payload):
            guard let automation = self.services.automation as? any ElementActionAutomationServiceProtocol else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "performAction is not supported by this bridge host")
            }
            let result = try await automation.performAction(
                target: payload.target,
                actionName: payload.actionName,
                snapshotId: payload.snapshotId)
            return .elementActionResult(result)
        case let .scroll(payload):
            try await self.services.automation.scroll(payload.request)
            return .ok
        case let .targetedScroll(payload):
            try await self.services.automation.scroll(payload.request)
            return .ok
        case let .hotkey(payload):
            try await self.services.automation.hotkey(keys: payload.keys, holdDuration: payload.holdDuration)
            return .ok
        case let .swipe(payload):
            try await self.services.automation.swipe(
                from: payload.from,
                to: payload.to,
                duration: payload.duration,
                steps: payload.steps,
                profile: payload.profile)
            return .ok
        case let .drag(payload):
            try await self.services.automation.drag(payload.automationRequest)
            return .ok
        case let .moveMouse(payload):
            try await self.services.automation.moveMouse(
                to: payload.to,
                duration: payload.duration,
                steps: payload.steps,
                profile: payload.profile)
            return .ok
        case let .waitForElement(payload):
            let result = try await self.services.automation.waitForElement(
                target: payload.target,
                timeout: payload.timeout,
                snapshotId: payload.snapshotId)
            return .waitResult(result)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleTargetedAutomationRequest(_ request: PeekabooBridgeRequest) async throws
        -> PeekabooBridgeResponse
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

            self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
            let result = try await targetedTypeService.typeActions(
                payload.actions,
                cadence: payload.cadence,
                snapshotId: payload.snapshotId,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .typeResult(result)
        case let .exactWindowTargetedTypeActions(payload):
            guard let service = self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
                  service.supportsExactWindowTargetedKeyboard
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Atomic exact-window background typing is not supported by this bridge host")
            }
            self.automationActivityObserver?(pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier))
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
            return .typeResult(result)
        case let .targetedHotkey(payload):
            return try await self.handleTargetedHotkey(payload)
        case let .exactWindowTargetedHotkey(payload):
            guard let service = self.services.automation as? any ExactWindowTargetedKeyboardServiceProtocol,
                  service.supportsExactWindowTargetedKeyboard
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Atomic exact-window background hotkeys are not supported by this bridge host")
            }
            self.automationActivityObserver?(pid_t(payload.expectedWindowIdentity.ownerProcessIdentifier))
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
            return .ok
        case let .targetedClick(payload):
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

            if let targetWindowID = payload.targetWindowID {
                guard let exactWindowService = targetedClickService as? any ExactWindowTargetedClickServiceProtocol
                else {
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
                try await exactWindowService.click(
                    target: payload.target,
                    clickType: payload.clickType,
                    snapshotId: payload.snapshotId,
                    expectedWindowIdentity: expectedIdentity,
                    expectedWindowBounds: expectedBounds)
            } else {
                self.automationActivityObserver?(pid_t(payload.targetProcessIdentifier))
                try await targetedClickService.click(
                    target: payload.target,
                    clickType: payload.clickType,
                    snapshotId: payload.snapshotId,
                    targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            }
            return .ok
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleTargetedHotkey(
        _ payload: PeekabooBridgeTargetedHotkeyRequest) async throws -> PeekabooBridgeResponse
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
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                expectedProcessIdentity: expectedIdentity)
        } else {
            try await service.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
        }
        return .ok
    }

    private func handleWindowRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .listWindows(payload):
            let result = try await self.services.windows.listWindows(target: payload.target)
            return .windows(result)
        case let .focusWindow(payload):
            try await self.services.windows.focusWindow(target: payload.target)
            return .ok
        case let .moveWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .moveWindow)
            try await self.services.windows.moveWindow(
                target: payload.target,
                expectedIdentity: identity,
                to: payload.position)
            return .ok
        case let .resizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .resizeWindow)
            try await self.services.windows.resizeWindow(
                target: payload.target,
                expectedIdentity: identity,
                to: payload.size)
            return .ok
        case let .setWindowBounds(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity,
                operation: .setWindowBounds)
            try await self.services.windows.setWindowBounds(
                target: payload.target,
                expectedIdentity: identity,
                bounds: payload.bounds)
            return .ok
        case let .closeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .closeWindow)
            try await self.services.windows.closeWindow(
                target: payload.target,
                expectedIdentity: identity,
                allowForegroundFallback: true)
            return .ok
        case let .backgroundCloseWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(
                payload.expectedIdentity,
                operation: .backgroundCloseWindow)
            try await self.services.windows.closeWindow(
                target: payload.target,
                expectedIdentity: identity,
                allowForegroundFallback: false)
            return .ok
        case let .minimizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .minimizeWindow)
            try await self.services.windows.minimizeWindow(
                target: payload.target,
                expectedIdentity: identity)
            return .ok
        case let .restoreWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .restoreWindow)
            try await self.services.windows.restoreWindow(
                target: payload.target,
                expectedIdentity: identity)
            return .ok
        case let .maximizeWindow(payload):
            let identity = try Self.requireWindowMutationReceipt(payload.expectedIdentity, operation: .maximizeWindow)
            try await self.services.windows.maximizeWindow(
                target: payload.target,
                expectedIdentity: identity)
            return .ok
        case .getFocusedWindow:
            let window = try await self.services.windows.getFocusedWindow()
            return .window(window)
        default:
            throw Self.invalidRequest(for: request)
        }
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
