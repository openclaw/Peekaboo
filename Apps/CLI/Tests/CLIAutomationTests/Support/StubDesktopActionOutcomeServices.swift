import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
final class OutcomeStubApplicationService: StubApplicationService, ApplicationServiceActionResultProviding {
    enum QuitActionStep {
        case result(payload: Bool, outcome: DesktopActionOutcome?)
        case failure(any Error)
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
final class OutcomeStubWindowService: StubWindowService, WindowManagementActionResultProviding {
    var actionOutcome: DesktopActionOutcome? = .confirmedChange(
        delivery: .init(mechanism: .accessibilityValue, mode: .background),
        unitCount: .one
    )

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
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity
    ) async throws -> DesktopActionResult<Void> {
        try self.updateWindow(target: target) { Self.withMinimized($0, value: true) }
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity _: WindowMutationIdentity
    ) async throws -> DesktopActionResult<Void> {
        try self.updateWindow(target: target) { Self.withMinimized($0, value: false) }
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> DesktopActionResult<Void> {
        try await self.maximizeWindow(target: target, expectedIdentity: expectedIdentity)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func moveWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to position: CGPoint
    ) async throws -> DesktopActionResult<Void> {
        try await self.moveWindow(target: target, expectedIdentity: expectedIdentity, to: position)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func resizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        to size: CGSize
    ) async throws -> DesktopActionResult<Void> {
        try await self.resizeWindow(target: target, expectedIdentity: expectedIdentity, to: size)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    @MainActor
    func setWindowBoundsActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect
    ) async throws -> DesktopActionResult<Void> {
        try await self.setWindowBounds(target: target, expectedIdentity: expectedIdentity, bounds: bounds)
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
