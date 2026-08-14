import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

@MainActor
extension PeekabooBridgeServer {
    func handleApplicationRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        switch request {
        case .listApplications:
            let apps = try await self.services.applications.listApplications()
            return .init(response: .applications(apps.data.applications))
        case let .findApplication(payload):
            let app = try await self.services.applications.findApplication(identifier: payload.identifier)
            return .init(response: .application(app))
        case .getFrontmostApplication:
            let app = try await self.services.applications.getFrontmostApplication()
            return .init(response: .application(app))
        case let .isApplicationRunning(payload):
            let running = try await self.services.applications.isApplicationRunning(identifier: payload.identifier)
            return .init(response: .bool(running))
        case let .launchApplication(payload):
            let request = ApplicationLaunchRequest(
                applicationIdentifier: payload.identifier,
                activates: true)
            let result: DesktopActionResult<ServiceApplicationInfo> = if let results = self.services
                .applications as? any ApplicationServiceActionResultProviding
            {
                try await results.launchApplicationActionResult(request: request)
            } else {
                try await DesktopActionResult(
                    payload: self.services.applications.launchApplication(identifier: payload.identifier),
                    outcome: nil)
            }
            self.automationActivityObserver?(pid_t(result.payload.processIdentifier))
            return .init(response: .application(result.payload), outcome: result.outcome)
        case let .launchApplicationWithOptions(payload):
            let result = try await self.services.applications.launchApplicationResult(request: payload)
            self.automationActivityObserver?(pid_t(result.payload.processIdentifier))
            return .init(response: .application(result.payload), outcome: result.outcome)
        case let .relaunchApplicationWithOptions(payload):
            let result = try await self.services.applications.relaunchApplicationResult(request: payload)
            self.automationActivityObserver?(pid_t(result.payload.processIdentifier))
            return .init(response: .application(result.payload), outcome: result.outcome)
        case let .activateApplication(payload):
            let request = ApplicationActivationRequest(
                identifier: payload.identifier,
                expectedIdentity: payload.expectedIdentity)
            let result = try await self.services.applications.activateApplicationResult(request: request)
            await self.reportAutomationActivity(appIdentifier: payload.identifier)
            return .init(response: .ok, outcome: result.outcome)
        case let .quitApplication(payload):
            guard let expectedIdentity = payload.expectedIdentity else {
                throw PeekabooError.invalidInput(
                    "Bridge application quit requires a process-generation identity " +
                        "(protocol 1.16 or newer); update the client")
            }
            guard expectedIdentity.processIdentifier != getpid() else {
                throw PeekabooError.serviceUnavailable("A runtime host cannot quit itself")
            }
            let request = ApplicationQuitRequest(
                identifier: payload.identifier,
                force: payload.force,
                expectedIdentity: expectedIdentity)
            do {
                let result = try await self.services.applications.quitApplicationResult(request: request)
                return .init(response: .bool(result.payload), outcome: result.outcome)
            } catch let failure as DesktopActionFailure {
                guard Self.isNativeQuitRequestRejection(failure) else { throw failure }
                return .init(response: .bool(false), outcome: failure.outcome)
            }
        case let .hideApplication(payload):
            let result = try await self.services.applications.hideApplicationResult(identifier: payload.identifier)
            await self.reportAutomationActivity(appIdentifier: payload.identifier)
            return .init(response: .ok, outcome: result.outcome)
        case .unhideApplication:
            throw ApplicationLifecycleRefusalError.legacyBridgeUnhide()
        case let .hideOtherApplications(payload):
            try await self.services.applications.hideOtherApplications(identifier: payload.identifier)
            return .init(response: .ok)
        case .showAllApplications:
            try await self.services.applications.showAllApplications()
            return .init(response: .ok)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    /// Reports app-identifier operations to the automation activity observer once the target resolves to a pid.
    private func reportAutomationActivity(appIdentifier: String) async {
        guard let observer = self.automationActivityObserver else { return }
        guard let app = try? await self.services.applications.findApplication(identifier: appIdentifier) else {
            return
        }
        observer(pid_t(app.processIdentifier))
    }

    private static func isNativeQuitRequestRejection(_ failure: DesktopActionFailure) -> Bool {
        let outcome = failure.outcome
        return outcome.route == .local &&
            outcome.state == .refused &&
            outcome.refusalReason == .targetUnavailable &&
            outcome.dispatchState == .none
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

    func handleDialogRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        switch request {
        case let .dialogFindActive(payload):
            let info = try await self.services.dialogs.findActiveDialog(
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .init(response: .dialogInfo(info))
        case let .dialogClickButton(payload):
            let result = try await self.services.dialogs.clickButton(
                buttonText: payload.buttonText,
                windowTitle: payload.windowTitle,
                appName: payload.appName,
                allowGlobalFallback: true)
            return .init(response: .dialogResult(result), outcome: result.outcome)
        case let .backgroundDialogClickButton(payload):
            let result = try await self.services.dialogs.clickButton(
                buttonText: payload.buttonText,
                windowTitle: payload.windowTitle,
                appName: payload.appName,
                allowGlobalFallback: false)
            return .init(response: .dialogResult(result), outcome: result.outcome)
        case let .dialogEnterText(payload):
            let result = if let focus = payload.focus {
                try await self.services.dialogs.enterText(DialogLegacyInputExecutionRequest(
                    text: payload.text,
                    fieldIdentifier: payload.fieldIdentifier,
                    clearExisting: payload.clearExisting,
                    windowTitle: payload.windowTitle,
                    appName: payload.appName,
                    focus: focus))
            } else {
                try await self.services.dialogs.enterText(
                    text: payload.text,
                    fieldIdentifier: payload.fieldIdentifier,
                    clearExisting: payload.clearExisting,
                    windowTitle: payload.windowTitle,
                    appName: payload.appName)
            }
            return .init(response: .dialogResult(result), outcome: result.outcome)
        case let .dialogHandleFile(payload):
            let result = try await self.services.dialogs.handleFileDialog(
                path: payload.path,
                filename: payload.filename,
                actionButton: payload.actionButton,
                ensureExpanded: payload.ensureExpanded ?? false,
                appName: payload.appName)
            return .init(response: .dialogResult(result), outcome: result.outcome)
        case let .dialogDismiss(payload):
            let result = try await self.services.dialogs.dismissDialog(
                force: payload.force,
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .init(response: .dialogResult(result), outcome: result.outcome)
        case let .dialogListElements(payload):
            let elements = try await self.services.dialogs.listDialogElements(
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .init(response: .dialogElements(elements))
        case let .targetedDialogListElements(selector):
            let elements = try await self.services.dialogs.listDialogElements(target: selector)
            return .init(response: .dialogElements(elements))
        case let .prepareDialogAction(payload):
            let receipt = try await self.services.dialogs.prepareDialogAction(payload)
            return .init(response: .preparedDialogAction(receipt))
        case let .exactDialogClickButton(receipt):
            guard receipt.kind == .clickButton else {
                throw PeekabooError.invalidInput("Exact dialog click requires a click-button receipt")
            }
            let result = try await self.services.dialogs.performPreparedDialogAction(receipt)
            let outcome = try result.requiredPreparedOutcome(kind: .clickButton)
            return .init(response: .dialogResult(result), outcome: outcome)
        case let .exactDialogDismiss(receipt):
            guard receipt.kind == .dismiss else {
                throw PeekabooError.invalidInput("Exact dialog dismiss requires a dismiss receipt")
            }
            let result = try await self.services.dialogs.performPreparedDialogAction(receipt)
            let outcome = try result.requiredPreparedOutcome(kind: .dismiss)
            return .init(response: .dialogResult(result), outcome: outcome)
        case let .exactDialogEnterText(payload):
            let result = try await self.services.dialogs.enterText(payload)
            guard result.success,
                  result.action == .enterText,
                  let outcome = result.outcome,
                  let targetReceipt = result.targetReceipt,
                  payload.target.processIdentifier.map({
                      $0 == targetReceipt.processIdentifier
                  }) ?? true,
                  payload.target.windowID.map({ $0 == targetReceipt.windowID }) ?? true
            else {
                throw DesktopActionFailure.indeterminate(
                    delivery: result.outcome?.delivery,
                    evidence: .completionUnknown,
                    unitCount: result.outcome?.dispatchState.unitCount,
                    message: "Exact dialog input did not return both its canonical outcome and target receipt.",
                    hint: "Observe the dialog before retrying and update the execution host.")
            }
            return .init(response: .dialogResult(result), outcome: outcome)
        case let .exactDialogForceDismiss(payload):
            let result = try await self.services.dialogs.forceDismissDialog(payload)
            guard result.success,
                  result.action == .dismiss,
                  let outcome = result.outcome,
                  outcome.state == .dispatchedUnverified,
                  outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground),
                  outcome.dispatchState.unitCount == .one,
                  let targetReceipt = result.targetReceipt,
                  // The unresolved selector has no process-generation claim to compare here;
                  // targetReceipt is the host's canonical resolved generation.
                  payload.target.processIdentifier.map({ $0 == targetReceipt.processIdentifier }) ?? true,
                  payload.target.windowID.map({ $0 == targetReceipt.windowID }) ?? true
            else {
                throw DesktopActionFailure.indeterminate(
                    delivery: result.outcome?.delivery,
                    evidence: .completionUnknown,
                    unitCount: result.outcome?.dispatchState.unitCount,
                    message: "Exact forced dialog dismissal returned invalid outcome or target evidence.",
                    hint: "Observe the dialog before retrying and update the execution host.")
            }
            return .init(response: .dialogResult(result), outcome: outcome)
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleSnapshotRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse {
        switch request {
        case let .createSnapshot(payload):
            let id = if payload.explicitOnly == true {
                try await self.services.snapshots.createExplicitSnapshot()
            } else if let pendingAt = payload.pendingAt {
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
        case let .storeObservationSnapshot(payload):
            let publication = Task { @MainActor in
                try await self.services.snapshots.storeObservationSnapshot(payload.publicationRequest)
            }
            try await publication.value
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
        case let .beginSnapshotMutation(payload):
            let lease = try await self.services.snapshots.beginSnapshotMutation(snapshotId: payload.snapshotId)
            return .snapshotMutationLease(lease)
        case let .finishSnapshotMutation(payload):
            try await self.services.snapshots.finishSnapshotMutation(
                payload.lease,
                requiresFreshObservation: payload.requiresFreshObservation)
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
}
