import AppKit
import AXorcist
import PeekabooFoundation

@MainActor
struct MenuExtraDiscoveryReaders {
    var resolveOwner: @MainActor (
        MenuBarApplicationScope, any ApplicationServiceProtocol, ApplicationProcessIdentity?) async throws
        -> ServiceApplicationInfo = { scope, applications, expected in
            let planner = DesktopTargetPlanning.ApplicationMutationPlanner(applications: applications)
            let plan = try await planner.plan(identifier: scope.identifier, expectedIdentity: expected)
            return plan.application
        }

    var snapshots: @MainActor (
        ApplicationProcessIdentity, ContinuousClock.Instant) async throws -> [MenuExtraAXSnapshot] = {
        try await MenuExtraAXReader.read(owner: $0, deadline: $1)
    }

    var windowExtras: (@MainActor () -> [MenuExtraInfo])?
    var windowIdentity: @MainActor (CGWindowID) -> WindowMutationIdentity? = {
        SystemIdentityResolver.windowMutationIdentity(windowID: $0)
    }

    var processGeneration: @MainActor (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity
    var displayBounds: (@MainActor () -> [CGRect])?
    var submit: @MainActor (MenuExtraAXSnapshot, Bool) throws -> Void = { snapshot, showMenu in
        try Element(snapshot.identity.element).performAction(showMenu ? .showMenu : .press)
    }
}
