extension MCPToolContext {
    @MainActor
    func scopingBrowserSession(named name: String) -> Self {
        guard let root = self.browser as? BrowserMCPService,
              let scoped = root.authenticatedSession(named: name)
        else { return self }
        return self.replacingBrowser(with: scoped)
    }

    private func replacingBrowser(with browser: any BrowserMCPClientProviding) -> Self {
        Self(
            automation: self.automation,
            menu: self.menu,
            windows: self.windows,
            applications: self.applications,
            dialogs: self.dialogs,
            dock: self.dock,
            screenCapture: self.screenCapture,
            desktopObservation: self.desktopObservation,
            snapshots: self.snapshots,
            screens: self.screens,
            agent: self.agent,
            permissions: self.permissions,
            clipboard: self.clipboard,
            browser: browser,
            permissionsStatusProvider: self.permissionsStatusProvider,
            snapshotMutationCoordinator: self.snapshotMutationCoordinator,
            snapshotExecutionGate: self.snapshotExecutionGate,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: self.executionPolicy,
            executionHost: self.executionHost,
            capturePreflightRefusal: self.capturePreflightRefusal)
    }
}
