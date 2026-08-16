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
        case .listApplicationMutationInventory:
            let inventory = try await self.services.applications.mutationApplicationInventory()
            return .init(response: .applicationMutationInventory(inventory))
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
            let resultAware = self.services.applications is any ApplicationServiceActionResultProviding
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
            let outcome = try Self.applicationMutationOutcome(
                result.outcome,
                resultAware: resultAware,
                mode: .foreground,
                operation: "Launch application",
                targetReceipt: Self.applicationTargetReceipt(result.payload.processIdentity))
            return .init(
                response: .application(result.payload),
                mutation: .init(
                    outcome: outcome,
                    target: .responseResolved))
        case let .launchApplicationWithOptions(payload):
            return try await self.handleApplicationLaunchWithOptions(payload)
        case let .relaunchApplicationWithOptions(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                let result = try await self.services.applications.relaunchApplicationResult(request: payload)
                self.automationActivityObserver?(pid_t(result.payload.processIdentifier))
                return try Self.legacyApplicationMutationResponse(
                    .application(result.payload),
                    outcome: result.outcome,
                    operation: "Application relaunch")
            }
            let expectedTargetIdentity = try Self.requireRelaunchTargetIdentity(payload)
            let result = try await self.services.applications.relaunchApplicationResult(request: payload)
            self.automationActivityObserver?(pid_t(result.payload.processIdentifier))
            let outcome = try Self.applicationMutationOutcome(
                result.outcome,
                resultAware: self.services.applications is any ApplicationServiceActionResultProviding,
                mode: payload.launchRequest.activates ? .foreground : .background,
                operation: "Relaunch application",
                targetReceipt: Self.applicationTargetReceipt(result.payload.processIdentity))
            try Self.validateRelaunchResponse(
                result.payload,
                differsFrom: expectedTargetIdentity,
                activates: payload.launchRequest.activates,
                outcome: outcome)
            return .init(
                response: .application(result.payload),
                mutation: .init(
                    outcome: outcome,
                    target: .responseResolved))
        case let .activateApplication(payload):
            let activationRequest = ApplicationActivationRequest(
                identifier: payload.identifier,
                expectedIdentity: payload.expectedIdentity)
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                let result = try await self.services.applications.activateApplicationResult(
                    request: activationRequest)
                await self.reportAutomationActivity(appIdentifier: payload.identifier)
                // Receiptless hosts cannot bind a broad activation selector to one process generation.
                // Preserve canonical dispatch evidence without inventing target attribution.
                return try Self.legacyApplicationMutationResponse(
                    .ok,
                    outcome: result.outcome,
                    operation: "Application activation")
            }
            let result = try await self.services.applications.activateApplicationTargetedResult(
                request: activationRequest)
            await self.reportAutomationActivity(appIdentifier: payload.identifier)
            let outcome = try Self.applicationMutationOutcome(
                result.outcome,
                resultAware: self.services.applications is any ApplicationServiceActionResultProviding ||
                    self.services.applications is any ApplicationServiceTargetedActionResultProviding,
                mode: .foreground,
                operation: "Activate application",
                targetReceipt: Self.applicationTargetReceipt(result.targetIdentity?.processIdentity))
            let target = try Self.requireActionTarget(
                result.targetIdentity,
                outcome: outcome,
                operation: "activate application")
            return .init(
                response: .ok,
                mutation: .init(
                    outcome: outcome,
                    target: .handlerResolved(target)))
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
                try ApplicationActionResultSemantics.requireConsistentQuitResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Quit application",
                    missingOutcomeRoute: .bridge)
                let outcome = try Self.applicationMutationOutcome(
                    result.outcome,
                    resultAware: self.services.applications is any ApplicationServiceActionResultProviding,
                    mode: .background,
                    operation: "Quit application",
                    targetReceipt: Self.applicationTargetReceipt(expectedIdentity))
                return .init(
                    response: .bool(result.payload),
                    mutation: .init(
                        outcome: outcome,
                        target: .requestPinned))
            } catch let failure as DesktopActionFailure {
                guard !PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
                      Self.isNativeQuitRequestRejection(failure)
                else { throw failure }
                return .init(
                    response: .bool(false),
                    mutation: .init(outcome: failure.outcome, target: .requestPinned))
            }
        case let .hideApplication(payload):
            return try await self.handleApplicationHide(payload)
        case .unhideApplication:
            throw ApplicationLifecycleRefusalError.legacyBridgeUnhide()
        case let .hideOtherApplications(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.applications.hideOtherApplications(identifier: payload.identifier)
                return .init(response: .ok)
            }
            let result = try await self.services.applications.hideOtherApplicationsResult(
                identifier: payload.identifier)
            let outcome = try Self.applicationMutationOutcome(
                result.outcome,
                resultAware: self.services.applications is any ApplicationServiceTargetedActionResultProviding,
                mode: .background,
                operation: "Hide other applications")
            return .init(
                response: .ok,
                mutation: .init(
                    outcome: outcome,
                    target: .global))
        case .showAllApplications:
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.applications.showAllApplications()
                return .init(response: .ok)
            }
            let result = try await self.services.applications.showAllApplicationsResult()
            let outcome = try Self.applicationMutationOutcome(
                result.outcome,
                resultAware: self.services.applications is any ApplicationServiceTargetedActionResultProviding,
                mode: .background,
                operation: "Show all applications")
            return .init(
                response: .ok,
                mutation: .init(
                    outcome: outcome,
                    target: .global))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private func handleApplicationHide(
        _ payload: PeekabooBridgeAppIdentifierRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
            let result = try await self.services.applications.hideApplicationResult(identifier: payload.identifier)
            await self.reportAutomationActivity(appIdentifier: payload.identifier)
            // Receiptless hosts cannot bind a broad hide selector to one process generation.
            // Preserve canonical dispatch evidence without inventing target attribution.
            return try Self.legacyApplicationMutationResponse(
                .ok,
                outcome: result.outcome,
                operation: "Application hide")
        }
        guard let expectedIdentity = payload.expectedIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Attested application hide requires a process-generation identity.",
                hint: "Resolve the application again before retrying.")
        }
        let result = try await self.services.applications.hideApplicationTargetedResult(
            request: .init(
                identifier: payload.identifier,
                expectedIdentity: expectedIdentity))
        await self.reportAutomationActivity(appIdentifier: payload.identifier)
        let outcome = try Self.applicationMutationOutcome(
            result.outcome,
            resultAware: self.services.applications is any ApplicationServiceTargetedActionResultProviding,
            mode: .background,
            operation: "Hide application",
            targetReceipt: Self.applicationTargetReceipt(result.targetIdentity?.processIdentity))
        let target = try Self.requireActionTarget(
            result.targetIdentity,
            outcome: outcome,
            operation: "hide application")
        guard target.processIdentity == expectedIdentity else {
            throw DesktopActionFailure.indeterminate(
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Application hide returned a different process-generation target.",
                hint: "Observe the selected application before retrying and update the runtime host.")
        }
        return .init(
            response: .ok,
            mutation: .init(
                outcome: outcome,
                target: .requestPinned))
    }

    private func handleApplicationLaunchWithOptions(
        _ request: ApplicationLaunchRequest) async throws -> PeekabooBridgeHandledResponse
    {
        guard !request.isSafeBackgroundNoOp ||
            self.services.applications.supportsSafeBackgroundApplicationLaunchNoOp
        else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "Application service cannot guarantee a no-dispatch background launch check")
        }
        let resultAware = self.services.applications is any ApplicationServiceActionResultProviding
        let result = try await self.services.applications.launchApplicationResult(request: request)
        self.automationActivityObserver?(pid_t(result.payload.processIdentifier))
        if request.isSafeBackgroundNoOp {
            try Self.requireAttestedSafeBackgroundLaunchOutcome(
                result.outcome,
                resultAware: resultAware,
                targetReceipt: Self.applicationTargetReceipt(result.payload.processIdentity))
            return .init(response: .application(result.payload))
        }
        let outcome = try Self.applicationMutationOutcome(
            result.outcome,
            resultAware: resultAware,
            mode: request.activates ? .foreground : .background,
            operation: "Launch application",
            targetReceipt: Self.applicationTargetReceipt(result.payload.processIdentity))
        return .init(
            response: .application(result.payload),
            mutation: .init(
                outcome: outcome,
                target: .responseResolved))
    }

    private static func requireAttestedSafeBackgroundLaunchOutcome(
        _ outcome: DesktopActionOutcome?,
        resultAware: Bool,
        targetReceipt: DesktopActionTargetReceipt?) throws
    {
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics,
              resultAware
        else { return }

        let outcome = try self.applicationMutationOutcome(
            outcome,
            resultAware: true,
            mode: .background,
            operation: "Safe background application check",
            targetReceipt: targetReceipt)
        guard outcome.state == .confirmedNoChange,
              outcome.delivery == nil,
              outcome.dispatchState == .none
        else {
            if let failure = DesktopActionFailure(
                outcome: outcome,
                message: "Safe background application check returned a non-success or dispatching outcome.",
                hint: "Update the runtime host before retrying this background application check.")
            {
                throw failure.attributed(to: targetReceipt)
            }
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Safe background application check contradicted its no-dispatch contract.",
                hint: "Observe the application before retrying and update the runtime host.")
                .attributed(to: targetReceipt)
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

    private static func unverifiedApplicationOutcome(
        mode: DesktopActionOutcome.Delivery.Mode) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            delivery: .init(mechanism: .nativeFramework, mode: mode),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    private static func applicationMutationOutcome(
        _ outcome: DesktopActionOutcome?,
        resultAware: Bool,
        mode: DesktopActionOutcome.Delivery.Mode,
        operation: String,
        targetReceipt: DesktopActionTargetReceipt? = nil) throws -> DesktopActionOutcome
    {
        if let outcome {
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                return outcome
            }
            do {
                try ApplicationActionResultSemantics.requireSuccessfulOutcome(
                    outcome,
                    operation: operation)
            } catch let failure as DesktopActionFailure {
                throw failure.attributed(to: targetReceipt)
            }
            return outcome
        }
        guard resultAware else { return self.unverifiedApplicationOutcome(mode: mode) }
        throw DesktopActionFailure.indeterminate(
            route: .bridge,
            evidence: .completionUnknown,
            message: "\(operation) result provider returned without a canonical outcome.",
            hint: "Observe the application before retrying and update the runtime host.")
            .attributed(to: targetReceipt)
    }

    private static func applicationTargetReceipt(
        _ identity: ApplicationProcessIdentity?) -> DesktopActionTargetReceipt?
    {
        guard let identity else { return nil }
        return DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity)
    }

    private static func requireRelaunchTargetIdentity(
        _ request: ApplicationRelaunchRequest) throws -> ApplicationProcessIdentity
    {
        guard let identity = request.expectedTargetIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .invalidRequest,
                message: "Application relaunch requires the selected process-generation receipt.",
                hint: "Refresh the application inventory and retry with its exact process generation.")
        }
        return identity
    }

    private static func validateRelaunchResponse(
        _ application: ServiceApplicationInfo,
        differsFrom expectedIdentity: ApplicationProcessIdentity,
        activates: Bool,
        outcome: DesktopActionOutcome) throws
    {
        guard let responseIdentity = application.processIdentity,
              responseIdentity != expectedIdentity
        else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: .init(
                    mechanism: .nativeFramework,
                    mode: activates ? .foreground : .background),
                evidence: .completionUnknown,
                message: "Application relaunch did not return a distinct exact process generation.",
                hint: "Refresh the application inventory before retrying.")
        }
        guard outcome.state != .confirmedNoChange else {
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Application relaunch returned a new process generation with a no-change outcome.",
                hint: "Observe the relaunched application before retrying and update the runtime host.")
        }
    }

    private static func requireActionTarget(
        _ target: DesktopTargetIdentity?,
        outcome: DesktopActionOutcome?,
        operation: String) throws -> DesktopTargetIdentity
    {
        if let outcome,
           outcome.state == .refused,
           outcome.dispatchState == .none,
           let failure = DesktopActionFailure(
               outcome: outcome,
               message: "The \(operation) service refused the request before dispatch.",
               hint: "Follow the refusal escalation before retrying.")
        {
            throw failure
        }
        if let target {
            return target
        }
        throw DesktopActionFailure.indeterminate(
            evidence: .completionUnknown,
            message: "The \(operation) service completed without an exact target identity.",
            hint: "Observe the intended target before retrying and update the runtime host.")
    }

    func handleMenuRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        switch request {
        case let .listMenus(payload):
            let menus = try await self.services.menu.listMenus(for: payload.appIdentifier)
            return .init(response: .menuStructure(menus))
        case .listFrontmostMenus:
            let menus = try await self.services.menu.listFrontmostMenus()
            return .init(response: .menuStructure(menus))
        case let .clickMenuItem(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.menu.clickMenuItem(
                    app: payload.appIdentifier,
                    itemPath: payload.itemPath)
                return .init(response: .ok)
            }
            let request = try Self.pinnedMenuItemRequest(payload)
            let results = try Self.requireGenerationPinnedMenuActionResults(self.services.menu)
            let result = try await results.clickMenuItemActionResult(request: request)
            return try Self.pinnedMenuMutationResponse(
                .ok,
                result: result,
                expectedIdentity: request.expectedIdentity,
                expectedDeliveryMode: request.deliveryMode,
                operation: "click menu item")
        case let .clickMenuItemByName(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.menu.clickMenuItemByName(
                    app: payload.appIdentifier,
                    itemName: payload.itemName)
                return .init(response: .ok)
            }
            let request = try Self.pinnedMenuItemByNameRequest(payload)
            let results = try Self.requireGenerationPinnedMenuActionResults(self.services.menu)
            let result = try await results.clickMenuItemByNameActionResult(request: request)
            return try Self.pinnedMenuMutationResponse(
                .ok,
                result: result,
                expectedIdentity: request.expectedIdentity,
                expectedDeliveryMode: request.deliveryMode,
                operation: "click menu item by name")
        case .listMenuExtras:
            let extras = try await self.services.menu.listMenuExtras()
            return .init(response: .menuExtras(extras))
        case let .clickMenuExtra(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.menu.clickMenuExtra(title: payload.name)
                return .init(response: .ok)
            }
            let results = try Self.requireMenuActionResults(self.services.menu)
            let result = try await results.clickMenuExtraActionResult(title: payload.name)
            return try Self.menuMutationResponse(.ok, result: result, operation: "click menu extra")
        case let .menuExtraOpenMenuFrame(payload):
            let frame = try await self.services.menu.menuExtraOpenMenuFrame(
                title: payload.title,
                ownerPID: payload.ownerPID)
            return .init(response: .rect(frame))
        case let .listMenuBarItems(includeRaw):
            let items = try await self.services.menu.listMenuBarItems(includeRaw: includeRaw)
            return .init(response: .menuBarItems(items))
        case let .clickMenuBarItemNamed(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                let result = try await self.services.menu.clickMenuBarItem(named: payload.name)
                return .init(response: .clickResult(result))
            }
            let results = try Self.requireExactLeafMenuActionResults(self.services.menu)
            guard let expectedLeafEvidence = payload.expectedLeafEvidence else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Protocol 1.29 named menu bar mutation omitted selected-leaf evidence.",
                    hint: "Update the Bridge client before retrying.")
            }
            let result = try await results.clickMenuBarItemActionResult(request: MenuBarItemActionRequest(
                named: payload.name,
                expectedLeafEvidence: expectedLeafEvidence))
            return try Self.menuMutationResponse(
                .clickResult(result.payload),
                result: result,
                operation: "click named menu bar item")
        case let .clickMenuBarItemIndex(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                let result = try await self.services.menu.clickMenuBarItem(at: payload.index)
                return .init(response: .clickResult(result))
            }
            let results = try Self.requireExactLeafMenuActionResults(self.services.menu)
            guard let expectedLeafEvidence = payload.expectedLeafEvidence else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "Protocol 1.29 indexed menu bar mutation omitted selected-leaf evidence.",
                    hint: "Update the Bridge client before retrying.")
            }
            let result = try await results.clickMenuBarItemActionResult(request: MenuBarItemActionRequest(
                index: payload.index,
                expectedLeafEvidence: expectedLeafEvidence))
            return try Self.menuMutationResponse(
                .clickResult(result.payload),
                result: result,
                operation: "click indexed menu bar item")
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    func handleDockRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        switch request {
        case let .listDockItems(payload):
            let items = try await self.services.dock.listDockItems(includeAll: payload.includeAll)
            return .init(response: .dockItems(items))
        case let .launchDockItem(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.dock.launchFromDock(appName: payload.appName)
                return .init(response: .ok)
            }
            let results = try Self.requireDockActionResults(self.services.dock)
            let result = try await results.launchFromDockActionResult(appName: payload.appName)
            return try Self.dockMutationResponse(.ok, result: result, operation: "launch Dock item")
        case let .rightClickDockItem(payload):
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.dock.rightClickDockItem(
                    appName: payload.appName,
                    menuItem: payload.menuItem)
                return .init(response: .ok)
            }
            let results = try Self.requireDockActionResults(self.services.dock)
            let result = try await results.rightClickDockItemActionResult(
                appName: payload.appName,
                menuItem: payload.menuItem)
            return try Self.dockMutationResponse(.ok, result: result, operation: "right-click Dock item")
        case .hideDock:
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.dock.hideDock()
                return .init(response: .ok)
            }
            let results = try Self.requireDockActionResults(self.services.dock)
            let result = try await results.hideDockActionResult()
            let outcome = try Self.requireCanonicalMutationOutcome(
                result.outcome,
                operation: "hide Dock")
            return .init(
                response: .ok,
                mutation: .init(
                    outcome: outcome,
                    target: .global))
        case .showDock:
            guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
                try await self.services.dock.showDock()
                return .init(response: .ok)
            }
            let results = try Self.requireDockActionResults(self.services.dock)
            let result = try await results.showDockActionResult()
            let outcome = try Self.requireCanonicalMutationOutcome(
                result.outcome,
                operation: "show Dock")
            return .init(
                response: .ok,
                mutation: .init(
                    outcome: outcome,
                    target: .global))
        case .isDockHidden:
            let hidden = await self.services.dock.isDockAutoHidden()
            return .init(response: .bool(hidden))
        case let .findDockItem(payload):
            let item = try await self.services.dock.findDockItem(name: payload.name)
            return .init(response: .dockItem(item))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private static func requireMenuActionResults(
        _ service: any MenuServiceProtocol) throws -> any MenuServiceActionResultProviding
    {
        guard let results = service as? any MenuServiceActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The menu service cannot return an exact action target.",
                hint: "Update the runtime host before retrying this menu mutation.")
        }
        return results
    }

    private static func requireGenerationPinnedMenuActionResults(
        _ service: any MenuServiceProtocol) throws -> any MenuServiceGenerationPinnedActionResultProviding
    {
        guard let results = service as? any MenuServiceGenerationPinnedActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The menu service cannot honor a process-generation-pinned action target.",
                hint: "Update the runtime host before retrying this menu mutation.")
        }
        return results
    }

    private static func requireExactLeafMenuActionResults(
        _ service: any MenuServiceProtocol) throws -> any MenuServiceExactLeafActionResultProviding
    {
        guard let results = service as? any MenuServiceExactLeafActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The menu service cannot preserve selected status-item evidence.",
                hint: "Update the runtime host before retrying this menu mutation.")
        }
        return results
    }

    private static func pinnedMenuItemRequest(
        _ payload: PeekabooBridgeMenuClickRequest) throws -> MenuItemActionRequest
    {
        guard let expectedIdentity = payload.expectedIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Protocol 1.29 menu mutation omitted its process-generation target.",
                hint: "Update the Bridge client before retrying.")
        }
        guard let deliveryMode = payload.deliveryMode else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Protocol 1.29 menu mutation omitted its explicit delivery mode.",
                hint: "Update the Bridge client before retrying.")
        }
        do {
            return try MenuItemActionRequest(
                appIdentifier: payload.appIdentifier,
                itemPath: payload.itemPath,
                expectedIdentity: expectedIdentity,
                deliveryMode: deliveryMode)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "The menu mutation target contradicts its process-generation identity.",
                hint: "Refresh the application inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private static func pinnedMenuItemByNameRequest(
        _ payload: PeekabooBridgeMenuClickByNameRequest) throws -> MenuItemByNameActionRequest
    {
        guard let expectedIdentity = payload.expectedIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Protocol 1.29 named menu mutation omitted its process-generation target.",
                hint: "Update the Bridge client before retrying.")
        }
        guard let deliveryMode = payload.deliveryMode else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Protocol 1.29 named menu mutation omitted its explicit delivery mode.",
                hint: "Update the Bridge client before retrying.")
        }
        do {
            return try MenuItemByNameActionRequest(
                appIdentifier: payload.appIdentifier,
                itemName: payload.itemName,
                expectedIdentity: expectedIdentity,
                deliveryMode: deliveryMode)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "The named menu mutation target contradicts its process-generation identity.",
                hint: "Refresh the application inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private static func requireDockActionResults(
        _ service: any DockServiceProtocol) throws -> any DockServiceActionResultProviding
    {
        guard let results = service as? any DockServiceActionResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "The Dock service cannot return an exact Dock process target.",
                hint: "Update the runtime host before retrying this Dock mutation.")
        }
        return results
    }

    private static func menuMutationResponse(
        _ response: PeekabooBridgeResponse,
        result: UIAutomationActionResult<some Sendable>,
        operation: String) throws -> PeekabooBridgeHandledResponse
    {
        let outcome = try self.requireCanonicalMutationOutcome(result.outcome, operation: operation)
        let target = try self.requireActionTarget(
            result.targetIdentity,
            outcome: outcome,
            operation: operation)
        return .init(
            response: response,
            mutation: .init(outcome: outcome, target: .handlerResolved(target)),
            selectedLeafEvidence: result.selectedLeafEvidence)
    }

    private static func pinnedMenuMutationResponse(
        _ response: PeekabooBridgeResponse,
        result: UIAutomationActionResult<some Sendable>,
        expectedIdentity: ApplicationProcessIdentity,
        expectedDeliveryMode: DesktopActionOutcome.Delivery.Mode,
        operation: String) throws -> PeekabooBridgeHandledResponse
    {
        let outcome = try self.requireCanonicalMutationOutcome(result.outcome, operation: operation)
        guard result.targetIdentity?.processIdentity == expectedIdentity else {
            throw DesktopActionFailure.indeterminate(
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "The \(operation) provider returned a target different from its pinned request.",
                hint: "Observe the intended application before retrying and update the runtime host.")
        }
        if outcome.state != .confirmedNoChange,
           outcome.delivery?.mode != expectedDeliveryMode
        {
            throw DesktopActionFailure.indeterminate(
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "The \(operation) provider contradicted its requested delivery mode.",
                hint: "Observe the intended application before retrying and update the runtime host.")
        }
        return .init(
            response: response,
            mutation: .init(outcome: outcome, target: .requestPinned))
    }

    private static func dockMutationResponse(
        _ response: PeekabooBridgeResponse,
        result: UIAutomationActionResult<some Sendable>,
        operation: String) throws -> PeekabooBridgeHandledResponse
    {
        let outcome = try self.requireCanonicalMutationOutcome(result.outcome, operation: operation)
        let target = try self.requireActionTarget(
            result.targetIdentity,
            outcome: outcome,
            operation: operation)
        return .init(
            response: response,
            mutation: .init(outcome: outcome, target: .handlerResolved(target)),
            selectedLeafEvidence: result.selectedLeafEvidence)
    }

    private static func requireCanonicalMutationOutcome(
        _ outcome: DesktopActionOutcome?,
        operation: String) throws -> DesktopActionOutcome
    {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "The \(operation) provider returned without a canonical action outcome.",
                hint: "Observe the target before retrying and update the runtime host.")
        }
        if outcome.state == .refused,
           outcome.dispatchState == .none,
           let failure = DesktopActionFailure(
               outcome: outcome,
               message: "The \(operation) provider refused the request before dispatch.",
               hint: "Follow the canonical refusal metadata before retrying.")
        {
            throw failure
        }
        return outcome
    }

    private static func legacyMutationResponse(
        _ response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome?) -> PeekabooBridgeHandledResponse
    {
        guard let outcome else { return .init(response: response) }
        return .init(
            response: response,
            mutation: .init(outcome: outcome, target: .external))
    }

    private static func legacyApplicationMutationResponse(
        _ response: PeekabooBridgeResponse,
        outcome: DesktopActionOutcome?,
        operation: String) throws -> PeekabooBridgeHandledResponse
    {
        try ApplicationActionResultSemantics.requireSuccessfulOutcome(outcome, operation: operation)
        return self.legacyMutationResponse(response, outcome: outcome)
    }

    func handleDialogRequest(_ request: PeekabooBridgeRequest) async throws -> PeekabooBridgeHandledResponse {
        switch request {
        case let .dialogFindActive(payload):
            let info = try await self.services.dialogs.findActiveDialog(
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return .init(response: .dialogInfo(info))
        case let .dialogClickButton(payload):
            try Self.requireLegacyDialogMutationCompatibility(
                operation: .dialogClickButton,
                replacement: "prepareDialogAction followed by exactDialogClickButton")
            let result = try await self.services.dialogs.clickButton(
                buttonText: payload.buttonText,
                windowTitle: payload.windowTitle,
                appName: payload.appName,
                allowGlobalFallback: true)
            return try Self.dialogMutationResponse(result)
        case let .backgroundDialogClickButton(payload):
            try Self.requireLegacyDialogMutationCompatibility(
                operation: .backgroundDialogClickButton,
                replacement: "prepareDialogAction followed by exactDialogClickButton")
            let result = try await self.services.dialogs.clickButton(
                buttonText: payload.buttonText,
                windowTitle: payload.windowTitle,
                appName: payload.appName,
                allowGlobalFallback: false)
            return try Self.dialogMutationResponse(result)
        case let .dialogEnterText(payload):
            try Self.requireLegacyDialogMutationCompatibility(
                operation: .dialogEnterText,
                replacement: "exactDialogEnterText with an explicit app, PID, or window target")
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
            return try Self.dialogMutationResponse(result)
        case let .dialogHandleFile(payload):
            try Self.requireLegacyDialogMutationCompatibility(
                operation: .dialogHandleFile,
                replacement: "an explicit exact-target file-dialog workflow")
            let result = try await self.services.dialogs.handleFileDialog(
                path: payload.path,
                filename: payload.filename,
                actionButton: payload.actionButton,
                ensureExpanded: payload.ensureExpanded ?? false,
                appName: payload.appName)
            return try Self.dialogMutationResponse(result)
        case let .dialogDismiss(payload):
            try Self.requireLegacyDialogMutationCompatibility(
                operation: .dialogDismiss,
                replacement: payload.force
                    ? "exactDialogForceDismiss with an explicit target"
                    : "prepareDialogAction followed by exactDialogDismiss")
            let result = try await self.services.dialogs.dismissDialog(
                force: payload.force,
                windowTitle: payload.windowTitle,
                appName: payload.appName)
            return try Self.dialogMutationResponse(result)
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
            return .init(
                response: .dialogResult(result),
                mutation: .init(outcome: outcome, target: .requestPinned))
        case let .exactDialogDismiss(receipt):
            guard receipt.kind == .dismiss else {
                throw PeekabooError.invalidInput("Exact dialog dismiss requires a dismiss receipt")
            }
            let result = try await self.services.dialogs.performPreparedDialogAction(receipt)
            let outcome = try result.requiredPreparedOutcome(kind: .dismiss)
            return .init(
                response: .dialogResult(result),
                mutation: .init(outcome: outcome, target: .requestPinned))
        case let .exactDialogEnterText(payload):
            let usesBackgroundExecution = PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics
            if usesBackgroundExecution, !self.services.dialogs.supportsBackgroundExactDialogInput {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .runtimeIncompatible,
                    message: "The selected dialog provider cannot guarantee background AXValue input.",
                    hint: "Update the runtime host or use protocol 1.28 foreground compatibility explicitly.")
            }
            let result = if usesBackgroundExecution {
                try await self.services.dialogs.enterText(payload)
            } else {
                try await self.services.dialogs.enterTextForegroundCompatible(payload)
            }
            try Self.throwExactDialogRefusalIfReported(result, operation: "Exact dialog input")
            guard result.success,
                  result.action == .enterText,
                  let outcome = result.outcome,
                  !usesBackgroundExecution || Self.isCanonicalBackgroundExactDialogInputOutcome(outcome),
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
            return .init(
                response: .dialogResult(result),
                mutation: .init(outcome: outcome, target: .responseResolved))
        case let .exactDialogForceDismiss(payload):
            let result = try await self.services.dialogs.forceDismissDialog(payload)
            try Self.throwExactDialogRefusalIfReported(result, operation: "Exact forced dialog dismissal")
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
            return .init(
                response: .dialogResult(result),
                mutation: .init(outcome: outcome, target: .responseResolved))
        default:
            throw Self.invalidRequest(for: request)
        }
    }

    private static func isCanonicalBackgroundExactDialogInputOutcome(_ outcome: DesktopActionOutcome) -> Bool {
        switch outcome.state {
        case .confirmedNoChange:
            outcome.delivery == nil && outcome.dispatchState == .none
        case .dispatchedUnverified:
            outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background) &&
                outcome.dispatchState.unitCount != nil
        case .confirmedChange, .partial, .suspectedNoop, .refused, .indeterminate:
            false
        }
    }

    private static func throwExactDialogRefusalIfReported(
        _ result: DialogActionResult,
        operation: String) throws
    {
        guard !result.success,
              let outcome = result.outcome,
              outcome.state == .refused,
              outcome.dispatchState == .none,
              let failure = DesktopActionFailure(
                  outcome: outcome,
                  message: "\(operation) was refused before dispatch.",
                  hint: "Follow the refusal metadata before retrying.")
        else { return }
        throw failure
    }

    private static func requireDialogOutcome(_ outcome: DesktopActionOutcome?) throws -> DesktopActionOutcome {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "The dialog service completed without a canonical action outcome.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
        return outcome
    }

    private static func requireLegacyDialogMutationCompatibility(
        operation: PeekabooBridgeOperation,
        replacement: String) throws
    {
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else { return }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "Operation \(operation.rawValue) cannot attest an exact dialog target before dispatch.",
            hint: "Use \(replacement). Protocol 1.28 compatibility remains available without receipt carriage.")
    }

    private static func dialogMutationResponse(
        _ result: DialogActionResult) throws -> PeekabooBridgeHandledResponse
    {
        let response = PeekabooBridgeResponse.dialogResult(result)
        guard PeekabooBridgeRequestContext.usesAttestedOperationResultSemantics else {
            return self.legacyMutationResponse(response, outcome: result.outcome)
        }
        return try .init(
            response: response,
            mutation: .init(
                outcome: self.requireDialogOutcome(result.outcome),
                target: .responseResolved))
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
