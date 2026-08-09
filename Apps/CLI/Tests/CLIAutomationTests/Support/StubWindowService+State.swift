import PeekabooCore

extension StubWindowService {
    func windowsForApplicationTarget(_ app: String) -> [ServiceWindowInfo] {
        guard app.uppercased().hasPrefix("PID:"),
              let processIdentifier = Int32(app.dropFirst("PID:".count))
        else {
            return self.windowsByApp[app] ?? []
        }
        return self.windowsByApp.values
            .flatMap(\.self)
            .filter { $0.mutationIdentity?.ownerProcessIdentifier == processIdentifier }
    }

    @MainActor
    func minimizeWindow(target: WindowTarget) async throws {
        try self.updateWindow(target: target) { $0.withMinimizedStateForTesting(true) }
    }

    func minimizeWindow(target: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        try await self.minimizeWindow(target: target)
    }

    @MainActor
    func restoreWindow(target: WindowTarget) async throws {
        try self.updateWindow(target: target) { $0.withMinimizedStateForTesting(false) }
    }

    func restoreWindow(target: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        try await self.restoreWindow(target: target)
    }
}

extension ServiceWindowInfo {
    fileprivate func withMinimizedStateForTesting(_ minimized: Bool) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: self.title,
            bounds: self.bounds,
            isMinimized: minimized,
            isMainWindow: self.isMainWindow,
            isKeyWindow: self.isKeyWindow,
            isFrontmost: self.isFrontmost,
            subrole: self.subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: minimized,
            layer: self.layer,
            isOnScreen: !minimized,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: self.mutationIdentity?.withMinimizedState(minimized)
        )
    }
}
