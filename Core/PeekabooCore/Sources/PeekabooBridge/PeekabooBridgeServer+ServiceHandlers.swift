import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleApplicationRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case .listApplications:
            let apps = try await self.services.applications.listApplications()
            return .applications(apps.data.applications)
        case let .findApplication(payload):
            let app = try await self.services.applications.findApplication(identifier: payload.identifier)
            return .application(app)
        case .getFrontmostApplication:
            let app = try await self.services.applications.getFrontmostApplication()
            return .application(app)
        case let .isApplicationRunning(payload):
            let running = await self.services.applications.isApplicationRunning(identifier: payload.identifier)
            return .bool(running)
        case let .launchApplication(payload):
            let app = try await self.services.applications.launchApplication(identifier: payload.identifier)
            return .application(app)
        case let .launchApplicationWithOptions(payload):
            let app = try await self.services.applications.launchApplication(request: payload)
            return .application(app)
        case let .relaunchApplicationWithOptions(payload):
            let app = try await self.services.applications.relaunchApplication(request: payload)
            return .application(app)
        case let .activateApplication(payload):
            try await self.services.applications.activateApplication(identifier: payload.identifier)
            return .ok
        case let .quitApplication(payload):
            let success = try await self.services.applications.quitApplication(
                identifier: payload.identifier,
                force: payload.force)
            return .bool(success)
        case let .hideApplication(payload):
            try await self.services.applications.hideApplication(identifier: payload.identifier)
            return .ok
        case let .unhideApplication(payload):
            try await self.services.applications.unhideApplication(identifier: payload.identifier)
            return .ok
        case let .hideOtherApplications(payload):
            try await self.services.applications.hideOtherApplications(identifier: payload.identifier)
            return .ok
        case .showAllApplications:
            try await self.services.applications.showAllApplications()
            return .ok
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleMenuRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .listMenus(payload):
            let menus = try await self.services.menu.listMenus(for: payload.appIdentifier)
            return .menuStructure(menus)
        case .listFrontmostMenus:
            let menus = try await self.services.menu.listFrontmostMenus()
            return .menuStructure(menus)
        case let .clickMenuItem(payload):
            try await self.services.menu.clickMenuItem(app: payload.appIdentifier, itemPath: payload.itemPath)
            return .ok
        case let .clickMenuItemByName(payload):
            try await self.services.menu.clickMenuItemByName(app: payload.appIdentifier, itemName: payload.itemName)
            return .ok
        case .listMenuExtras:
            let extras = try await self.services.menu.listMenuExtras()
            return .menuExtras(extras)
        case let .clickMenuExtra(payload):
            try await self.services.menu.clickMenuExtra(title: payload.name)
            return .ok
        case let .menuExtraOpenMenuFrame(payload):
            let frame = try await self.services.menu.menuExtraOpenMenuFrame(
                title: payload.title,
                ownerPID: payload.ownerPID)
            return .rect(frame)
        case let .listMenuBarItems(includeRaw):
            let items = try await self.services.menu.listMenuBarItems(includeRaw: includeRaw)
            return .menuBarItems(items)
        case let .clickMenuBarItemNamed(payload):
            let result = try await self.services.menu.clickMenuBarItem(named: payload.name)
            return .clickResult(result)
        case let .clickMenuBarItemIndex(payload):
            let result = try await self.services.menu.clickMenuBarItem(at: payload.index)
            return .clickResult(result)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleDockRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .listDockItems(payload):
            let items = try await self.services.dock.listDockItems(includeAll: payload.includeAll)
            return .dockItems(items)
        case let .launchDockItem(payload):
            try await self.services.dock.launchFromDock(appName: payload.appName)
            return .ok
        case let .rightClickDockItem(payload):
            try await self.services.dock.rightClickDockItem(appName: payload.appName, menuItem: payload.menuItem)
            return .ok
        case .hideDock:
            try await self.services.dock.hideDock()
            return .ok
        case .showDock:
            try await self.services.dock.showDock()
            return .ok
        case .isDockHidden:
            let hidden = await self.services.dock.isDockAutoHidden()
            return .bool(hidden)
        case let .findDockItem(payload):
            let item = try await self.services.dock.findDockItem(name: payload.name)
            return .dockItem(item)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleDialogRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .dialogFindActive(payload):
            let info = try await self.services.dialogs.findActiveDialog(
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .dialogInfo(info)
        case let .dialogClickButton(payload):
            let result = try await self.services.dialogs.clickButton(
                buttonText: payload.buttonText,
                windowTitle: payload.windowTitle,
                appName: payload.appName,
                allowGlobalFallback: true)
            return .dialogResult(result)
        case let .backgroundDialogClickButton(payload):
            let result = try await self.services.dialogs.clickButton(
                buttonText: payload.buttonText,
                windowTitle: payload.windowTitle,
                appName: payload.appName,
                allowGlobalFallback: false)
            return .dialogResult(result)
        case let .dialogEnterText(payload):
            let result = try await self.services.dialogs.enterText(
                text: payload.text,
                fieldIdentifier: payload.fieldIdentifier,
                clearExisting: payload.clearExisting,
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .dialogResult(result)
        case let .dialogHandleFile(payload):
            let result = try await self.services.dialogs.handleFileDialog(
                path: payload.path,
                filename: payload.filename,
                actionButton: payload.actionButton,
                ensureExpanded: payload.ensureExpanded ?? false,
                appName: payload.appName)
            return .dialogResult(result)
        case let .dialogDismiss(payload):
            let result = try await self.services.dialogs.dismissDialog(
                force: payload.force,
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .dialogResult(result)
        case let .dialogListElements(payload):
            let elements = try await self.services.dialogs.listDialogElements(
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .dialogElements(elements)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleSnapshotRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .createSnapshot(payload):
            let id = if let pendingAt = payload.pendingAt {
                try await self.services.snapshots.createSnapshot(pendingAt: pendingAt)
            } else {
                try await self.services.snapshots.createSnapshot()
            }
            return .snapshotId(id)
        case let .storeDetectionResult(payload):
            try await self.services.snapshots.storeDetectionResult(
                snapshotId: payload.snapshotId,
                result: payload.result)
            return .ok
        case let .getDetectionResult(payload):
            if let result = try await self.services.snapshots.getDetectionResult(snapshotId: payload.snapshotId) {
                return .detection(result)
            }
            throw PeekabooBridgeErrorEnvelope(
                code: .notFound,
                message: "No detection result for snapshot \(payload.snapshotId)")
        case let .storeScreenshot(payload):
            try await self.services.snapshots.storeScreenshot(payload.snapshotRequest)
            return .ok
        case let .storeAnnotatedScreenshot(payload):
            try await self.services.snapshots.storeAnnotatedScreenshot(
                snapshotId: payload.snapshotId,
                annotatedScreenshotPath: payload.annotatedScreenshotPath)
            return .ok
        case .listSnapshots:
            let list = try await self.services.snapshots.listSnapshots()
            return .snapshots(list)
        case let .getMostRecentSnapshot(payload):
            return try await self.handleMostRecentSnapshot(payload)
        case let .invalidateImplicitLatestSnapshot(payload):
            if let id = try await self.services.snapshots.invalidateImplicitLatestSnapshot(
                through: payload.cutoff,
                preserving: payload.preservingSnapshotId,
                preservedAt: payload.preservedAt)
            {
                return .snapshotId(id)
            }
            return .ok
        case let .cleanSnapshot(payload):
            try await self.services.snapshots.cleanSnapshot(snapshotId: payload.snapshotId)
            return .ok
        case let .cleanSnapshotsOlderThan(payload):
            let count = try await self.services.snapshots.cleanSnapshotsOlderThan(days: payload.days)
            return .int(count)
        case .cleanAllSnapshots:
            let count = try await self.services.snapshots.cleanAllSnapshots()
            return .int(count)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleMostRecentSnapshot(
        _ payload: PeekabooBridgeGetMostRecentSnapshotRequest) async throws -> PeekabooBridgeResponse
    {
        let id: String? = if let bundleId = payload.applicationBundleId {
            await self.services.snapshots.getMostRecentSnapshot(applicationBundleId: bundleId)
        } else {
            await self.services.snapshots.getMostRecentSnapshot()
        }

        guard let id else {
            throw PeekabooBridgeErrorEnvelope(
                code: .notFound,
                message: "No recent snapshot found")
        }

        return .snapshotId(id)
    }

    func handleAppleScriptProbe() throws -> PeekabooBridgeResponse {
        guard self.services.permissions.checkAppleScriptPermission() else {
            throw PeekabooBridgeErrorEnvelope(
                code: .permissionDenied,
                message: "AppleScript permission not granted")
        }

        return .ok
    }
}
