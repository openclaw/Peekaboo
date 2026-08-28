extension MCPToolContext {
    @MainActor
    func scopingBrowserSession(named name: String) throws -> Self {
        guard let root = self.browser as? BrowserMCPService,
              root.supportsAuthenticatedSessionBootstrap
        else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        guard let scoped = root.authenticatedSession(named: name) else {
            throw BrowserMCPConnectionError.authenticatedSessionCapacityExceeded
        }
        return self.replacingBrowser(with: scoped)
    }

    /// Creates a browser session owned only by this MCP server.
    ///
    /// Local providers use their process-local pool. Remote providers must authenticate a new Bridge scope;
    /// returning the root client here would let an MCP server observe or operate another caller's connection.
    @MainActor
    func openingBrowserSession(
        named name: String,
        handoff: BrowserMCPHandoffGrant? = nil) async throws -> Self
    {
        if let root = self.browser as? BrowserMCPService,
           root.supportsAuthenticatedSessionBootstrap
        {
            guard handoff == nil else {
                throw BrowserMCPConnectionError.receiptBindingUnsupported
            }
            guard let scoped = root.authenticatedSession(named: name) else {
                throw BrowserMCPConnectionError.authenticatedSessionCapacityExceeded
            }
            return self.replacingBrowser(with: scoped)
        }
        guard let opening = self.browser as? any BrowserMCPScopedSessionOpening else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        let scoped = try await opening.openBrowserMCPScopedSession(handoff: handoff)
        guard scoped !== self.browser else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
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
            browserCleanupOwner: self.browserCleanupOwner,
            snapshotOwner: self.uiSnapshots.owner,
            executionPolicy: self.executionPolicy,
            executionHost: self.executionHost,
            capturePreflightRefusal: self.capturePreflightRefusal)
    }
}
