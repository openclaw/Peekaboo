import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

// MARK: - Service Bridges

enum AutomationServiceBridge {
    static func waitForElement(
        automation: any UIAutomationServiceProtocol,
        target: ClickTarget,
        timeout: TimeInterval,
        snapshotId: String?
    ) async throws -> WaitForElementResult {
        let result = try await Task { @MainActor in
            try await automation.waitForElement(target: target, timeout: timeout, snapshotId: snapshotId)
        }.value

        if !result.warnings.isEmpty {
            Logger.shared.debug(
                "waitForElement warnings: \(result.warnings.joined(separator: ","))",
                category: "Automation"
            )
        }

        return result
    }

    static func click(
        automation: any UIAutomationServiceProtocol,
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?
    ) async throws {
        try await Task { @MainActor in
            try await automation.click(target: target, clickType: clickType, snapshotId: snapshotId)
        }.value
    }

    static func click(
        automation: any UIAutomationServiceProtocol,
        target: ClickTarget,
        clickType: ClickType,
        snapshotId: String?,
        targetProcessIdentifier: pid_t,
        targetWindowID: Int? = nil,
        expectedWindowIdentity: WindowMutationIdentity? = nil,
        expectedWindowBounds: CGRect? = nil
    ) async throws {
        try await Task { @MainActor in
            guard let targetedClickService = automation as? any TargetedClickServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "Background clicks require an automation service that supports targeted click delivery"
                )
            }

            guard targetedClickService.supportsTargetedClicks else {
                throw self.targetedClickUnavailableError(service: targetedClickService)
            }

            if let targetWindowID {
                guard let exactWindowService = targetedClickService as? any ExactWindowTargetedClickServiceProtocol
                else {
                    throw PeekabooError.serviceUnavailable(
                        "Background clicks with an exact window require a compatible automation service"
                    )
                }
                guard let expectedWindowIdentity,
                      let expectedWindowBounds,
                      expectedWindowIdentity.windowID == targetWindowID,
                      expectedWindowIdentity.ownerProcessIdentifier == targetProcessIdentifier
                else {
                    throw PeekabooError.invalidInput(
                        field: "target",
                        reason: "Exact-window clicks require a matching process-generation identity and bounds"
                    )
                }
                try await exactWindowService.click(
                    target: target,
                    clickType: clickType,
                    snapshotId: snapshotId,
                    expectedWindowIdentity: expectedWindowIdentity,
                    expectedWindowBounds: expectedWindowBounds
                )
            } else {
                try await targetedClickService.click(
                    target: target,
                    clickType: clickType,
                    snapshotId: snapshotId,
                    targetProcessIdentifier: targetProcessIdentifier
                )
            }
        }.value
    }

    static func typeActions(
        automation: any UIAutomationServiceProtocol,
        request: TypeActionsRequest
    ) async throws -> TypeResult {
        try await Task { @MainActor in
            try await automation.typeActions(
                request.actions,
                cadence: request.cadence,
                snapshotId: request.snapshotId
            )
        }.value
    }

    static func typeActions(
        automation: any UIAutomationServiceProtocol,
        request: TypeActionsRequest,
        targetProcessIdentifier: pid_t
    ) async throws -> TypeResult {
        try await Task { @MainActor in
            guard let targetedTypeService = automation as? any TargetedTypeServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "Background typing requires an automation service that supports targeted type delivery"
                )
            }

            guard targetedTypeService.supportsTargetedTypeActions else {
                throw self.targetedTypeUnavailableError(service: targetedTypeService)
            }

            return try await targetedTypeService.typeActions(
                request.actions,
                cadence: request.cadence,
                snapshotId: request.snapshotId,
                targetProcessIdentifier: targetProcessIdentifier
            )
        }.value
    }

    static func scroll(
        automation: any UIAutomationServiceProtocol,
        request: ScrollRequest
    ) async throws {
        try await Task { @MainActor in
            try await automation.scroll(request)
        }.value
    }

    static func setValue(
        automation: any UIAutomationServiceProtocol,
        target: String,
        value: UIElementValue,
        snapshotId: String?
    ) async throws -> ElementActionResult {
        try await Task { @MainActor in
            guard let automation = automation as? any ElementActionAutomationServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "This automation host does not support direct accessibility value setting"
                )
            }
            return try await automation.setValue(target: target, value: value, snapshotId: snapshotId)
        }.value
    }

    static func performAction(
        automation: any UIAutomationServiceProtocol,
        target: String,
        actionName: String,
        snapshotId: String?
    ) async throws -> ElementActionResult {
        try await Task { @MainActor in
            guard let automation = automation as? any ElementActionAutomationServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "This automation host does not support direct accessibility action invocation"
                )
            }
            return try await automation.performAction(target: target, actionName: actionName, snapshotId: snapshotId)
        }.value
    }

    static func hotkey(automation: any UIAutomationServiceProtocol, keys: String, holdDuration: Int) async throws {
        try await Task { @MainActor in
            try await automation.hotkey(keys: keys, holdDuration: holdDuration)
        }.value
    }

    static func hotkey(
        automation: any UIAutomationServiceProtocol,
        keys: String,
        holdDuration: Int,
        targetProcessIdentifier: pid_t
    ) async throws {
        try await Task { @MainActor in
            try BackgroundHotkeyPolicy.validate(keys: keys)

            guard let targetedHotkeyService = automation as? any TargetedHotkeyServiceProtocol else {
                throw PeekabooError.serviceUnavailable(
                    "Background hotkeys require an automation service that supports targeted hotkey delivery"
                )
            }

            guard targetedHotkeyService.supportsTargetedHotkeys else {
                throw self.targetedHotkeyUnavailableError(service: targetedHotkeyService)
            }

            try await targetedHotkeyService.hotkey(
                keys: keys,
                holdDuration: holdDuration,
                targetProcessIdentifier: targetProcessIdentifier
            )
        }.value
    }

    private static func targetedHotkeyUnavailableError(service: any TargetedHotkeyServiceProtocol) -> PeekabooError {
        if service.targetedHotkeyRequiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            service.targetedHotkeyUnavailableReason ??
                "Remote bridge host does not support background hotkeys; use --no-remote or update the host"
        )
    }

    private static func targetedTypeUnavailableError(service: any TargetedTypeServiceProtocol) -> PeekabooError {
        if service.targetedTypeRequiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            service.targetedTypeUnavailableReason ??
                "Remote bridge host does not support background typing; use --no-remote or update the host"
        )
    }

    private static func targetedClickUnavailableError(service: any TargetedClickServiceProtocol) -> PeekabooError {
        if service.targetedClickRequiresEventSynthesizingPermission {
            return .permissionDeniedEventSynthesizing
        }

        return .serviceUnavailable(
            service.targetedClickUnavailableReason ??
                "Remote bridge host does not support background clicks; use --no-remote or update the host"
        )
    }

    static func swipe(
        automation: any UIAutomationServiceProtocol,
        request: SwipeRequest
    ) async throws {
        try await Task { @MainActor in
            try await automation.swipe(
                from: request.from,
                to: request.to,
                duration: request.duration,
                steps: request.steps,
                profile: request.profile
            )
        }.value
    }

    static func drag(
        automation: any UIAutomationServiceProtocol,
        request: DragRequest
    ) async throws {
        try await Task { @MainActor in
            try await automation.drag(
                DragOperationRequest(
                    from: request.from,
                    to: request.to,
                    duration: request.duration,
                    steps: request.steps,
                    modifiers: request.modifiers,
                    profile: request.profile
                )
            )
        }.value
    }

    static func moveMouse(
        automation: any UIAutomationServiceProtocol,
        to point: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile
    ) async throws {
        try await Task { @MainActor in
            try await automation.moveMouse(to: point, duration: duration, steps: steps, profile: profile)
        }.value
    }

    static func detectElements(
        automation: any UIAutomationServiceProtocol,
        imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?
    ) async throws -> ElementDetectionResult {
        try await Task { @MainActor in
            try await automation.detectElements(
                in: imageData,
                snapshotId: snapshotId,
                windowContext: windowContext
            )
        }.value
    }

    static func hasAccessibilityPermission(automation: any UIAutomationServiceProtocol) async -> Bool {
        await Task { @MainActor in
            await automation.hasAccessibilityPermission()
        }.value
    }
}

struct TypeActionsRequest {
    let actions: [TypeAction]
    let cadence: TypingCadence
    let snapshotId: String?
}

struct SwipeRequest {
    let from: CGPoint
    let to: CGPoint
    let duration: Int
    let steps: Int
    let profile: MouseMovementProfile
}

struct DragRequest {
    let from: CGPoint
    let to: CGPoint
    let duration: Int
    let steps: Int
    let modifiers: String?
    let profile: MouseMovementProfile
}

enum WindowServiceBridge {
    static func closeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        allowForegroundFallback: Bool = false
    ) async throws {
        let operation = Task { @MainActor in
            if let expectedIdentity {
                try await windows.closeWindow(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    allowForegroundFallback: allowForegroundFallback
                )
            } else {
                try await windows.closeWindow(
                    target: target,
                    allowForegroundFallback: allowForegroundFallback
                )
            }
        }

        return try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
    }

    static func minimizeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws {
        try await Task { @MainActor in
            if let expectedIdentity {
                try await windows.minimizeWindow(target: target, expectedIdentity: expectedIdentity)
            } else {
                try await windows.minimizeWindow(target: target)
            }
        }.value
    }

    static func restoreWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws {
        try await Task { @MainActor in
            if let expectedIdentity {
                try await windows.restoreWindow(target: target, expectedIdentity: expectedIdentity)
            } else {
                try await windows.restoreWindow(target: target)
            }
        }.value
    }

    static func maximizeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil
    ) async throws {
        try await Task { @MainActor in
            if let expectedIdentity {
                try await windows.maximizeWindow(target: target, expectedIdentity: expectedIdentity)
            } else {
                try await windows.maximizeWindow(target: target)
            }
        }.value
    }

    static func moveWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        to origin: CGPoint
    ) async throws {
        try await Task { @MainActor in
            if let expectedIdentity {
                try await windows.moveWindow(target: target, expectedIdentity: expectedIdentity, to: origin)
            } else {
                try await windows.moveWindow(target: target, to: origin)
            }
        }.value
    }

    static func resizeWindow(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        to size: CGSize
    ) async throws {
        try await Task { @MainActor in
            if let expectedIdentity {
                try await windows.resizeWindow(target: target, expectedIdentity: expectedIdentity, to: size)
            } else {
                try await windows.resizeWindow(target: target, to: size)
            }
        }.value
    }

    static func setWindowBounds(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity? = nil,
        bounds: CGRect
    ) async throws {
        try await Task { @MainActor in
            if let expectedIdentity {
                try await windows.setWindowBounds(
                    target: target,
                    expectedIdentity: expectedIdentity,
                    bounds: bounds
                )
            } else {
                try await windows.setWindowBounds(target: target, bounds: bounds)
            }
        }.value
    }

    static func focusWindow(windows: any WindowManagementServiceProtocol, target: WindowTarget) async throws {
        try await Task { @MainActor in
            try await windows.focusWindow(target: target)
        }.value
    }

    static func listWindows(
        windows: any WindowManagementServiceProtocol,
        target: WindowTarget
    ) async throws -> [ServiceWindowInfo] {
        try await Task { @MainActor in
            try await windows.listWindows(target: target)
        }.value
    }

    static func getFocusedWindow(windows: any WindowManagementServiceProtocol) async throws -> ServiceWindowInfo? {
        try await Task { @MainActor in
            try await windows.getFocusedWindow()
        }.value
    }
}

enum MenuServiceBridge {
    static func listMenus(menu: any MenuServiceProtocol, appIdentifier: String) async throws -> MenuStructure {
        try await Task { @MainActor in
            try await menu.listMenus(for: appIdentifier)
        }.value
    }

    static func listFrontmostMenus(menu: any MenuServiceProtocol) async throws -> MenuStructure {
        try await Task { @MainActor in
            try await menu.listFrontmostMenus()
        }.value
    }

    static func listMenuExtras(menu: any MenuServiceProtocol) async throws -> [MenuExtraInfo] {
        try await Task { @MainActor in
            try await menu.listMenuExtras()
        }.value
    }

    static func clickMenuItem(menu: any MenuServiceProtocol, appIdentifier: String, itemPath: String) async throws {
        try await Task { @MainActor in
            try await menu.clickMenuItem(app: appIdentifier, itemPath: itemPath)
        }.value
    }

    static func clickMenuItemByName(
        menu: any MenuServiceProtocol,
        appIdentifier: String,
        itemName: String
    ) async throws {
        try await Task { @MainActor in
            try await menu.clickMenuItemByName(app: appIdentifier, itemName: itemName)
        }.value
    }

    static func clickMenuExtra(menu: any MenuServiceProtocol, title: String) async throws {
        try await Task { @MainActor in
            try await menu.clickMenuExtra(title: title)
        }.value
    }

    static func isMenuExtraMenuOpen(
        menu: any MenuServiceProtocol,
        title: String,
        ownerPID: pid_t?
    ) async throws -> Bool {
        try await Task { @MainActor in
            try await menu.isMenuExtraMenuOpen(title: title, ownerPID: ownerPID)
        }.value
    }

    static func listMenuBarItems(menu: any MenuServiceProtocol, includeRaw: Bool = false) async throws
    -> [MenuBarItemInfo] {
        try await Task { @MainActor in
            try await menu.listMenuBarItems(includeRaw: includeRaw)
        }.value
    }

    static func clickMenuBarItem(named name: String, menu: any MenuServiceProtocol) async throws -> PeekabooCore
    .ClickResult {
        try await Task<PeekabooCore.ClickResult, any Error> { @MainActor in
            try await menu.clickMenuBarItem(named: name)
        }.value
    }

    static func clickMenuBarItem(at index: Int, menu: any MenuServiceProtocol) async throws -> PeekabooCore
    .ClickResult {
        try await Task<PeekabooCore.ClickResult, any Error> { @MainActor in
            try await menu.clickMenuBarItem(at: index)
        }.value
    }
}

enum DockServiceBridge {
    static func launchFromDock(dock: any DockServiceProtocol, appName: String) async throws {
        try await Task { @MainActor in
            try await dock.launchFromDock(appName: appName)
        }.value
    }

    static func findDockItem(dock: any DockServiceProtocol, name: String) async throws -> DockItem {
        try await Task { @MainActor in
            try await dock.findDockItem(name: name)
        }.value
    }

    static func rightClickDockItem(dock: any DockServiceProtocol, appName: String, menuItem: String?) async throws {
        try await Task { @MainActor in
            try await dock.rightClickDockItem(appName: appName, menuItem: menuItem)
        }.value
    }

    static func hideDock(dock: any DockServiceProtocol) async throws {
        try await Task { @MainActor in
            try await dock.hideDock()
        }.value
    }

    static func showDock(dock: any DockServiceProtocol) async throws {
        try await Task { @MainActor in
            try await dock.showDock()
        }.value
    }

    static func listDockItems(dock: any DockServiceProtocol, includeAll: Bool) async throws -> [DockItem] {
        try await Task { @MainActor in
            try await dock.listDockItems(includeAll: includeAll)
        }.value
    }
}
