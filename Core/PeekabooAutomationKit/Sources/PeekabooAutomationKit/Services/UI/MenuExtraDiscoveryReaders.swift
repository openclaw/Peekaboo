import AppKit
import AXorcist
import PeekabooFoundation

@MainActor
struct MenuExtraDiscoveryReaders {
    var snapshots: @MainActor () async throws -> [MenuExtraAXSnapshot] = Self.readSnapshots
    var windowExtras: (@MainActor () -> [MenuExtraInfo])?
    var windowIdentity: @MainActor (CGWindowID) -> WindowMutationIdentity? = {
        SystemIdentityResolver.windowMutationIdentity(windowID: $0)
    }

    var processGeneration: @MainActor (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity
    var application: @MainActor (pid_t) -> (name: String?, bundle: String?) = {
        let app = NSRunningApplication(processIdentifier: $0)
        return (app?.localizedName, app?.bundleIdentifier)
    }

    var displayBounds: (@MainActor () -> [CGRect])?
    var submit: @MainActor (MenuExtraAXSnapshot, Bool) throws -> Void = { snapshot, showMenu in
        try Element(snapshot.identity.element).performAction(showMenu ? .showMenu : .press)
    }

    private static func readSnapshots() async throws -> [MenuExtraAXSnapshot] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let applications = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        guard let ownGeneration = SystemIdentityResolver.processStartIdentity(getpid()) else {
            throw MenuExtraAXReader.incomplete
        }
        var snapshots = try await MenuExtraAXReader.read(
            owner: .init(processIdentifier: getpid(), processStartIdentity: ownGeneration),
            systemWide: true,
            deadline: deadline)
        for app in applications {
            try MenuExtraAXReader.check(deadline)
            guard let generation = SystemIdentityResolver.processStartIdentity(app.processIdentifier) else {
                throw MenuExtraAXReader.incomplete
            }
            snapshots += try await MenuExtraAXReader.read(
                owner: .init(processIdentifier: app.processIdentifier, processStartIdentity: generation),
                deadline: deadline)
        }
        var seen: Set<MenuExtraAXIdentity> = []
        return snapshots.filter { seen.insert($0.identity).inserted }
    }
}
