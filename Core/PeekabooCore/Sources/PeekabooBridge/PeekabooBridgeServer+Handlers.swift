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
        case .detectElements, .inspectAccessibilityTree, .click, .type, .typeActions, .targetedTypeActions,
             .setValue, .performAction, .scroll, .hotkey, .targetedHotkey, .targetedClick, .swipe, .drag, .moveMouse,
             .waitForElement:
            try await self.handleAutomationRequest(request)
        case .listWindows, .focusWindow, .moveWindow, .resizeWindow, .setWindowBounds, .closeWindow,
             .minimizeWindow, .maximizeWindow, .getFocusedWindow:
            try await self.handleWindowRequest(request)
        case .listApplications, .findApplication, .getFrontmostApplication, .isApplicationRunning,
             .launchApplication, .activateApplication, .quitApplication, .hideApplication, .unhideApplication,
             .hideOtherApplications, .showAllApplications:
            try await self.handleApplicationRequest(request)
        case .listMenus, .listFrontmostMenus, .clickMenuItem, .clickMenuItemByName, .listMenuExtras,
             .clickMenuExtra, .menuExtraOpenMenuFrame, .listMenuBarItems, .clickMenuBarItemNamed,
             .clickMenuBarItemIndex:
            try await self.handleMenuRequest(request)
        case .listDockItems, .launchDockItem, .rightClickDockItem, .hideDock, .showDock, .isDockHidden,
             .findDockItem:
            try await self.handleDockRequest(request)
        case .dialogFindActive, .dialogClickButton, .dialogEnterText, .dialogHandleFile, .dialogDismiss,
             .dialogListElements:
            try await self.handleDialogRequest(request)
        case .createSnapshot, .storeDetectionResult, .getDetectionResult, .storeScreenshot,
             .storeAnnotatedScreenshot, .listSnapshots, .getMostRecentSnapshot, .cleanSnapshot,
             .cleanSnapshotsOlderThan, .cleanAllSnapshots:
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
        case .targetedTypeActions, .targetedHotkey, .targetedClick:
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

            let result = try await targetedTypeService.typeActions(
                payload.actions,
                cadence: payload.cadence,
                snapshotId: payload.snapshotId,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .typeResult(result)
        case let .targetedHotkey(payload):
            guard
                let targetedHotkeyService = self.services.automation as? any TargetedHotkeyServiceProtocol,
                targetedHotkeyService.supportsTargetedHotkeys
            else {
                throw PeekabooBridgeErrorEnvelope(
                    code: .operationNotSupported,
                    message: "Background hotkeys are not supported by this bridge host")
            }

            try await targetedHotkeyService.hotkey(
                keys: payload.keys,
                holdDuration: payload.holdDuration,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
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

            try await targetedClickService.click(
                target: payload.target,
                clickType: payload.clickType,
                snapshotId: payload.snapshotId,
                targetProcessIdentifier: pid_t(payload.targetProcessIdentifier))
            return .ok
        default:
            throw Self.invalidRequest(for: request)
        }
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
            try await self.services.windows.moveWindow(target: payload.target, to: payload.position)
            return .ok
        case let .resizeWindow(payload):
            try await self.services.windows.resizeWindow(target: payload.target, to: payload.size)
            return .ok
        case let .setWindowBounds(payload):
            try await self.services.windows.setWindowBounds(target: payload.target, bounds: payload.bounds)
            return .ok
        case let .closeWindow(payload):
            try await self.services.windows.closeWindow(target: payload.target)
            return .ok
        case let .minimizeWindow(payload):
            try await self.services.windows.minimizeWindow(target: payload.target)
            return .ok
        case let .maximizeWindow(payload):
            try await self.services.windows.maximizeWindow(target: payload.target)
            return .ok
        case .getFocusedWindow:
            let window = try await self.services.windows.getFocusedWindow()
            return .window(window)
        default:
            throw Self.invalidRequest(for: request)
        }
    }
}
