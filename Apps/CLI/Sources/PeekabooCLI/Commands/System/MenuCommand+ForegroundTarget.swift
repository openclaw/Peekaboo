import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
enum MenuForegroundTargetSupport {
    struct PreparedTarget {
        let application: ServiceApplicationInfo
        let identity: ApplicationProcessIdentity

        var identifier: String {
            "PID:\(self.identity.processIdentifier)"
        }
    }

    static func resolveApplicationIdentifier(
        target: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> String {
        if let appIdentifier = try target.resolveApplicationIdentifierOptional() {
            return appIdentifier
        }

        guard let frontmost = try? await services.applications.getFrontmostApplication() else {
            throw ValidationError("No frontmost app found; provide --app or --pid")
        }
        return frontmost.bundleIdentifier ?? frontmost.name
    }

    static func prepare(application: ServiceApplicationInfo) throws -> PreparedTarget {
        guard let identity = application.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Menu access requires a stable application process receipt.",
                hint: "Refresh the application inventory before retrying."
            )
        }
        return PreparedTarget(application: application, identity: identity)
    }

    static func focus(
        target: PreparedTarget,
        selector: InteractionTargetOptions,
        options: FocusCommandOptions,
        services: any PeekabooServiceProviding,
        beginMutation: () -> Void
    ) async throws -> UIAutomationActionResult<Void> {
        if let preparedWindow = try await self.resolvePreparedWindow(
            target: target,
            selector: selector,
            services: services
        ) {
            beginMutation()
            return try await ensureFocused(
                preparedWindow: preparedWindow,
                applicationName: target.identifier,
                options: options,
                services: services
            )
        }

        beginMutation()
        return try await ApplicationServiceBridge.activateApplicationTargeted(
            applications: services.applications,
            application: target.application
        )
    }

    private static func resolvePreparedWindow(
        target: PreparedTarget,
        selector: InteractionTargetOptions,
        services: any PeekabooServiceProviding
    ) async throws -> ServiceWindowInfo? {
        let hasExplicitWindowSelector = selector.windowId != nil ||
            selector.windowTitle != nil ||
            selector.windowIndex != nil
        let planner = DesktopTargetPlanning.MutationAuthorityPlanner(
            applications: services.applications,
            windows: services.windows
        )
        do {
            let authority = try await planner.plan(
                selector: InteractionTargetSelector(
                    applicationIdentifier: target.identifier,
                    windowID: selector.windowId,
                    windowTitle: selector.windowTitle,
                    windowIndex: selector.windowIndex
                ),
                requirement: .exactWindow(
                    automaticSelection: .preferredMutationWindow(.general)
                ),
                expectedProcessIdentity: target.identity
            )
            guard let window = authority.window?.selectionWindow else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Foreground menu focus lost its exact window authority.",
                    hint: "Retry through the current Peekaboo runtime."
                )
            }
            return window
        } catch let error as DesktopTargetPlanningError {
            if !hasExplicitWindowSelector, case .windowNotFound = error {
                return nil
            }
            throw error.desktopActionFailure
        }
    }
}
