import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
final class OutcomeStubApplicationService: StubApplicationService, ApplicationServiceActionResultProviding {
    enum QuitActionStep {
        case result(payload: Bool, outcome: DesktopActionOutcome?)
        case failure(any Error)
        case failureAndCancel(any Error)
    }

    var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one
    )
    var quitError: (any Error)?
    var quitActionSteps: [QuitActionStep] = []
    private(set) var quitActionResultCallCount = 0

    func launchApplicationActionResult(
        request: ApplicationLaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        try await DesktopActionResult(payload: self.launchApplication(request: request), outcome: self.actionOutcome)
    }

    func relaunchApplicationActionResult(
        request: ApplicationRelaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        try await DesktopActionResult(payload: self.relaunchApplication(request: request), outcome: self.actionOutcome)
    }

    func activateApplicationActionResult(
        request: ApplicationActivationRequest
    ) async throws -> DesktopActionResult<Void> {
        try await self.activateApplication(request: request)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func quitApplicationActionResult(
        request: ApplicationQuitRequest
    ) async throws -> DesktopActionResult<Bool> {
        self.quitActionResultCallCount += 1
        if !self.quitActionSteps.isEmpty {
            switch self.quitActionSteps.removeFirst() {
            case let .result(payload, outcome):
                _ = try await self.quitApplication(request: request)
                return DesktopActionResult(payload: payload, outcome: outcome)
            case let .failure(error):
                throw error
            case let .failureAndCancel(error):
                withUnsafeCurrentTask { $0?.cancel() }
                throw error
            }
        }
        if let quitError {
            throw quitError
        }
        return try await DesktopActionResult(
            payload: self.quitApplication(request: request),
            outcome: self.actionOutcome
        )
    }

    func hideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.hideApplication(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func unhideApplicationActionResult(identifier: String) async throws -> DesktopActionResult<Void> {
        try await self.unhideApplication(identifier: identifier)
        return DesktopActionResult(outcome: self.actionOutcome)
    }
}

@MainActor
final class OutcomeStubDockService: StubDockService, DockServiceActionResultProviding {
    var actionOutcome: DesktopActionOutcome?
    var actionTargetIdentity: DesktopTargetIdentity?
    var actionError: (any Error)?
    var removeItemsAfterLaunch = false
    var findItemError: (any Error)?
    private(set) var launchCalls: [String] = []
    private(set) var rightClickCalls: [(app: String, menuItem: String?)] = []
    private(set) var hideCallCount = 0
    private(set) var showCallCount = 0

    func launchFromDockActionResult(appName: String) async throws -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        self.launchCalls.append(appName)
        if self.removeItemsAfterLaunch {
            self.items = []
        }
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func rightClickDockItemActionResult(
        appName: String,
        menuItem: String?
    ) async throws -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        self.rightClickCalls.append((appName, menuItem))
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func hideDockActionResult() async throws -> DesktopActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        self.hideCallCount += 1
        self.autoHidden = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func showDockActionResult() async throws -> DesktopActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        self.showCallCount += 1
        self.autoHidden = false
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    override func findDockItem(name: String) async throws -> DockItem {
        if let findItemError {
            throw findItemError
        }
        return try await super.findDockItem(name: name)
    }

    private func throwActionErrorIfNeeded() throws {
        if let actionError {
            throw actionError
        }
    }
}

@MainActor
final class OutcomeStubMenuService: StubMenuService, MenuServiceGenerationPinnedActionResultProviding {
    var menuBarItems: [MenuBarItemInfo] = []
    var actionOutcome: DesktopActionOutcome?
    var actionTargetIdentity: DesktopTargetIdentity?
    var actionError: (any Error)?
    var actionCompleted: (() -> Void)?
    var listMenusError: (any Error)?
    var listMenusResult: MenuStructure?
    var menuBarClickResult = ClickResult(elementDescription: "Menu bar item", location: nil)
    private(set) var menuBarNameClickCalls: [String] = []
    private(set) var menuBarIndexClickCalls: [Int] = []
    private(set) var menuItemRequests: [MenuItemActionRequest] = []
    private(set) var namedMenuItemRequests: [MenuItemByNameActionRequest] = []

    override func listMenus(for appIdentifier: String) async throws -> MenuStructure {
        if let listMenusError {
            self.listMenusRequests.append(appIdentifier)
            throw listMenusError
        }
        if let listMenusResult {
            self.listMenusRequests.append(appIdentifier)
            return listMenusResult
        }
        return try await super.listMenus(for: appIdentifier)
    }

    override func listMenuBarItems(includeRaw: Bool) async throws -> [MenuBarItemInfo] {
        self.menuBarItems
    }

    func clickMenuItemActionResult(app: String, itemPath: String) async throws -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        try await self.clickMenuItem(app: app, itemPath: itemPath)
        self.actionCompleted?()
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func clickMenuItemByNameActionResult(app: String, itemName: String) async throws
    -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        try await self.clickMenuItemByName(app: app, itemName: itemName)
        self.actionCompleted?()
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func clickMenuItemActionResult(request: MenuItemActionRequest) async throws -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        self.menuItemRequests.append(request)
        let app = self.menuAppName(for: request.expectedIdentity) ?? request.appIdentifier
        self.clickPathCalls.append((app, request.itemPath))
        self.actionCompleted?()
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func clickMenuItemByNameActionResult(request: MenuItemByNameActionRequest) async throws
    -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        self.namedMenuItemRequests.append(request)
        let app = self.menuAppName(for: request.expectedIdentity) ?? request.appIdentifier
        self.clickItemCalls.append((app, request.itemName))
        self.actionCompleted?()
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func clickMenuExtraActionResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try self.throwActionErrorIfNeeded()
        try await self.clickMenuExtra(title: title)
        return UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func clickMenuBarItemActionResult(named name: String) async throws
    -> UIAutomationActionResult<ClickResult> {
        try self.throwActionErrorIfNeeded()
        self.menuBarNameClickCalls.append(name)
        self.actionCompleted?()
        return UIAutomationActionResult(
            payload: self.menuBarClickResult,
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    func clickMenuBarItemActionResult(at index: Int) async throws
    -> UIAutomationActionResult<ClickResult> {
        try self.throwActionErrorIfNeeded()
        self.menuBarIndexClickCalls.append(index)
        self.actionCompleted?()
        return UIAutomationActionResult(
            payload: self.menuBarClickResult,
            outcome: self.actionOutcome,
            targetIdentity: self.actionTargetIdentity
        )
    }

    private func throwActionErrorIfNeeded() throws {
        if let actionError {
            throw actionError
        }
    }

    private func menuAppName(for identity: ApplicationProcessIdentity) -> String? {
        self.menusByApp.values.first(where: { $0.application.processIdentity == identity })?.application.name
    }
}

@MainActor
final class OutcomeStubWindowService: StubWindowService, WindowManagementActionResultProviding,
WindowManagementPinnedFocusActionResultProviding {
    var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .accessibilityValue, mode: .background),
        unitCount: .one
    )
    var postActionReadbackError: (any Error)?
    var postActionReadbackWindow: ServiceWindowInfo?
    private var didCompleteAction = false

    override func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        if self.didCompleteAction, let postActionReadbackError {
            throw postActionReadbackError
        }
        if self.didCompleteAction, let postActionReadbackWindow {
            return [postActionReadbackWindow]
        }
        return try await super.listWindows(target: target)
    }

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindow(target: target)
        return UIAutomationActionResult(payload: (), outcome: self.actionOutcome)
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindow(target: target)
        guard let bounds = expectedIdentity.capturedBounds else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Test focus target is missing exact bounds."
            )
        }
        return try UIAutomationActionResult(
            payload: (),
            outcome: self.actionOutcome,
            targetIdentity: DesktopTargetIdentity(
                exactWindow: UIAutomationTarget.ExactWindow(
                    identity: expectedIdentity,
                    bounds: bounds
                )
            )
        )
    }

    @MainActor
    func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool
    ) async throws -> DesktopActionResult<Void> {
        try await self.closeWindow(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback
        )
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity
    ) async throws -> DesktopActionResult<Void> {
        try self.updateWindow(target: target) { Self.withMinimized($0, value: true) }
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity
    ) async throws -> DesktopActionResult<Void> {
        try self.updateWindow(target: target) { Self.withMinimized($0, value: false) }
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> DesktopActionResult<Void> {
        _ = target
        _ = expectedIdentity
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint
    ) async throws -> DesktopActionResult<Void> {
        try await self.moveWindow(target: target, expectedIdentity: expectedIdentity, to: position)
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize
    ) async throws -> DesktopActionResult<Void> {
        try await self.resizeWindow(target: target, expectedIdentity: expectedIdentity, to: size)
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect
    ) async throws -> DesktopActionResult<Void> {
        try await self.setWindowBounds(target: target, expectedIdentity: expectedIdentity, bounds: bounds)
        self.didCompleteAction = true
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    private nonisolated static func withMinimized(_ window: ServiceWindowInfo, value: Bool) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: window.windowID,
            title: window.title,
            bounds: window.bounds,
            isMinimized: value,
            isMainWindow: window.isMainWindow,
            isKeyWindow: window.isKeyWindow,
            isFrontmost: window.isFrontmost,
            subrole: window.subrole,
            windowLevel: window.windowLevel,
            alpha: window.alpha,
            index: window.index,
            spaceID: window.spaceID,
            spaceName: window.spaceName,
            screenIndex: window.screenIndex,
            screenName: window.screenName,
            isOffScreen: window.isOffScreen,
            layer: window.layer,
            isOnScreen: window.isOnScreen,
            sharingState: window.sharingState,
            isExcludedFromWindowsMenu: window.isExcludedFromWindowsMenu,
            mutationIdentity: window.mutationIdentity?.withMinimizedState(value)
        )
    }
}
