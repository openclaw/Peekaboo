import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation

extension PeekabooBridgeClient {
    public func listMenus(appIdentifier: String) async throws -> MenuStructure {
        let response = try await self.send(.listMenus(PeekabooBridgeMenuListRequest(appIdentifier: appIdentifier)))
        switch response {
        case let .menuStructure(structure): return structure
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu list response")
        }
    }

    public func listFrontmostMenus() async throws -> MenuStructure {
        let response = try await self.send(.listFrontmostMenus)
        switch response {
        case let .menuStructure(structure): return structure
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu list response")
        }
    }

    public func clickMenuItem(appIdentifier: String, itemPath: String) async throws {
        if self.usesExplicitReceiptlessTransport() {
            try await self.sendExpectOK(.clickMenuItem(.legacyReceiptless(
                appIdentifier: appIdentifier,
                itemPath: itemPath)))
            return
        }
        _ = try await self.clickMenuItemResult(appIdentifier: appIdentifier, itemPath: itemPath)
    }

    public func clickMenuItemResult(
        appIdentifier: String,
        itemPath: String) async throws -> UIAutomationActionResult<Void>
    {
        try self.requireAttestedMenuResultTransport(expectedResponse: "menu item click")
        let application = try await self.findApplication(identifier: appIdentifier)
        guard let expectedIdentity = application.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "The selected menu application has no stable process-generation identity.",
                hint: "Refresh the application inventory before retrying.")
        }
        return try await self.clickMenuItemResult(request: MenuItemActionRequest(
            appIdentifier: "PID:\(expectedIdentity.processIdentifier)",
            itemPath: itemPath,
            expectedIdentity: expectedIdentity))
    }

    public func clickMenuItemResult(
        request: MenuItemActionRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .clickMenuItem(PeekabooBridgeMenuClickRequest(request)),
            expectedResponse: "menu item click",
            requiresTargetIdentity: true)
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func clickMenuItemByName(appIdentifier: String, itemName: String) async throws {
        if self.usesExplicitReceiptlessTransport() {
            try await self.sendExpectOK(.clickMenuItemByName(.legacyReceiptless(
                appIdentifier: appIdentifier,
                itemName: itemName)))
            return
        }
        _ = try await self.clickMenuItemByNameResult(appIdentifier: appIdentifier, itemName: itemName)
    }

    public func clickMenuItemByNameResult(
        appIdentifier: String,
        itemName: String) async throws -> UIAutomationActionResult<Void>
    {
        try self.requireAttestedMenuResultTransport(expectedResponse: "named menu item click")
        let application = try await self.findApplication(identifier: appIdentifier)
        guard let expectedIdentity = application.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "The selected menu application has no stable process-generation identity.",
                hint: "Refresh the application inventory before retrying.")
        }
        return try await self.clickMenuItemByNameResult(request: MenuItemByNameActionRequest(
            appIdentifier: "PID:\(expectedIdentity.processIdentifier)",
            itemName: itemName,
            expectedIdentity: expectedIdentity))
    }

    public func clickMenuItemByNameResult(
        request: MenuItemByNameActionRequest) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .clickMenuItemByName(PeekabooBridgeMenuClickByNameRequest(request)),
            expectedResponse: "named menu item click",
            requiresTargetIdentity: true)
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    private func requireAttestedMenuResultTransport(expectedResponse: String) throws {
        guard self.usesExplicitReceiptlessTransport() else { return }
        throw DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .runtimeIncompatible,
            message: "\(expectedResponse) requires an attested exact-target result.",
            hint: "Update the Bridge host to protocol 1.29 before retrying this mutation.")
    }

    public func listMenuExtras() async throws -> [MenuExtraInfo] {
        let response = try await self.send(.listMenuExtras)
        switch response {
        case let .menuExtras(extras): return extras
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu extras response")
        }
    }

    public func clickMenuExtra(title: String) async throws {
        if self.usesExplicitReceiptlessTransport() {
            try await self.sendExpectOK(.clickMenuExtra(PeekabooBridgeMenuBarClickByNameRequest(name: title)))
            return
        }
        _ = try await self.clickMenuExtraResult(title: title)
    }

    public func clickMenuExtraResult(title: String) async throws -> UIAutomationActionResult<Void> {
        try await self.actionResult(
            for: .clickMenuExtra(PeekabooBridgeMenuBarClickByNameRequest(name: title)),
            expectedResponse: "menu extra click",
            requiresTargetIdentity: true)
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func menuExtraOpenMenuFrame(title: String, ownerPID: pid_t?) async throws -> CGRect? {
        let response = try await self.send(.menuExtraOpenMenuFrame(
            PeekabooBridgeMenuExtraOpenRequest(title: title, ownerPID: ownerPID)))
        switch response {
        case let .rect(rect): return rect
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu frame response")
        }
    }

    public func listMenuBarItems(includeRaw: Bool) async throws -> [MenuBarItemInfo] {
        let response = try await self.send(.listMenuBarItems(includeRaw))
        switch response {
        case let .menuBarItems(items): return items
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected menu bar response")
        }
    }

    public func clickMenuBarItem(named name: String) async throws -> ClickResult {
        if self.usesExplicitReceiptlessTransport() {
            return try await self.legacyMenuBarClick(
                request: .clickMenuBarItemNamed(PeekabooBridgeMenuBarClickByNameRequest(name: name)),
                expectedResponse: "named menu bar click")
        }
        return try await self.clickMenuBarItemResult(named: name).payload
    }

    public func clickMenuBarItemResult(named name: String) async throws -> UIAutomationActionResult<ClickResult> {
        try self.requireAttestedMenuResultTransport(expectedResponse: "named menu bar click")
        let items = try await self.listMenuBarItems(includeRaw: true)
        let selection = try Self.resolveMenuBarSelection(named: name, items: items)
        guard let baseEvidence = selection.candidate.value.selectionEvidence else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "The selected menu bar item has no exact leaf evidence.",
                hint: "Refresh the menu bar inventory and update the Bridge host before retrying.")
        }
        let evidence = try baseEvidence.selecting(
            normalizedSelector: selection.normalizedSelector,
            matchKind: selection.matchKind)
        return try await self.clickMenuBarItemResult(request: MenuBarItemActionRequest(
            named: name,
            expectedLeafEvidence: evidence))
    }

    public func clickMenuBarItemResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        let payload: PeekabooBridgeMenuBarClickByNameRequest
        guard let name = request.name else {
            guard let index = request.index else {
                throw PeekabooError.invalidInput("Menu bar action request has no selector")
            }
            return try await self.actionResult(
                for: .clickMenuBarItemIndex(PeekabooBridgeMenuBarClickByIndexRequest(
                    index: index,
                    expectedLeafEvidence: request.expectedLeafEvidence)),
                expectedResponse: "indexed menu bar click",
                requiresTargetIdentity: true)
            { response in
                guard case let .clickResult(result) = response else { return nil }
                return result
            }
        }
        payload = PeekabooBridgeMenuBarClickByNameRequest(
            name: name,
            expectedLeafEvidence: request.expectedLeafEvidence)
        return try await self.actionResult(
            for: .clickMenuBarItemNamed(payload),
            expectedResponse: "named menu bar click",
            requiresTargetIdentity: true)
        { response in
            guard case let .clickResult(result) = response else { return nil }
            return result
        }
    }

    public func clickMenuBarItem(at index: Int) async throws -> ClickResult {
        if self.usesExplicitReceiptlessTransport() {
            return try await self.legacyMenuBarClick(
                request: .clickMenuBarItemIndex(PeekabooBridgeMenuBarClickByIndexRequest(index: index)),
                expectedResponse: "indexed menu bar click")
        }
        return try await self.clickMenuBarItemResult(at: index).payload
    }

    public func clickMenuBarItemResult(at index: Int) async throws -> UIAutomationActionResult<ClickResult> {
        try self.requireAttestedMenuResultTransport(expectedResponse: "indexed menu bar click")
        let items = try await self.listMenuBarItems(includeRaw: true)
        let selection: DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
        do {
            selection = try MenuBarItemSelector.select(index: index, from: items)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Menu bar item index \(index) is no longer present.",
                hint: "Refresh the menu bar inventory before retrying.",
                causeDescription: error.localizedDescription)
        }
        guard let evidence = selection.candidate.value.selectionEvidence else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Menu bar item index \(index) has no exact leaf evidence.",
                hint: "Refresh the menu bar inventory and update the Bridge host before retrying.")
        }
        return try await self.clickMenuBarItemResult(request: MenuBarItemActionRequest(
            index: index,
            expectedLeafEvidence: evidence))
    }

    private nonisolated static func resolveMenuBarSelection(
        named name: String,
        items: [MenuBarItemInfo]) throws
        -> DeterministicDesktopLeafSelector.Selection<MenuBarItemInfo>
    {
        do {
            return try MenuBarItemSelector.select(named: name, from: items)
        } catch let error as DesktopLeafSelectionError {
            let reason: DesktopActionOutcome.RefusalReason = switch error {
            case .ambiguous: .invalidRequest
            case .notFound, .invalidIndex: .targetUnavailable
            }
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: reason,
                message: error.localizedDescription,
                hint: "Use an exact current status-item name or list index.")
        }
    }

    private func legacyMenuBarClick(
        request: PeekabooBridgeRequest,
        expectedResponse: String) async throws -> ClickResult
    {
        let response = try await self.send(request)
        switch response {
        case let .clickResult(result):
            return result
        case let .error(envelope):
            throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected \(expectedResponse) response")
        }
    }

    public func listDockItems(includeAll: Bool) async throws -> [DockItem] {
        let response = try await self.send(.listDockItems(PeekabooBridgeDockListRequest(includeAll: includeAll)))
        switch response {
        case let .dockItems(items): return items
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dock list response")
        }
    }

    public func launchDockItem(appName: String) async throws {
        if self.usesExplicitReceiptlessTransport() {
            try await self.sendExpectOK(.launchDockItem(PeekabooBridgeDockLaunchRequest(appName: appName)))
            return
        }
        _ = try await self.launchDockItemResult(appName: appName)
    }

    public func launchDockItemResult(appName: String) async throws -> UIAutomationActionResult<Void> {
        try await self.actionResult(
            for: .launchDockItem(PeekabooBridgeDockLaunchRequest(appName: appName)),
            expectedResponse: "Dock item launch",
            requiresTargetIdentity: true)
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func rightClickDockItem(appName: String, menuItem: String?) async throws {
        if self.usesExplicitReceiptlessTransport() {
            try await self.sendExpectOK(.rightClickDockItem(PeekabooBridgeDockRightClickRequest(
                appName: appName,
                menuItem: menuItem)))
            return
        }
        _ = try await self.rightClickDockItemResult(appName: appName, menuItem: menuItem)
    }

    public func rightClickDockItemResult(
        appName: String,
        menuItem: String?) async throws -> UIAutomationActionResult<Void>
    {
        try await self.actionResult(
            for: .rightClickDockItem(PeekabooBridgeDockRightClickRequest(
                appName: appName,
                menuItem: menuItem)),
            expectedResponse: "Dock item context click",
            requiresTargetIdentity: true)
        { response in
            guard case .ok = response else { return nil }
            return ()
        }
    }

    public func hideDock() async throws {
        _ = try await self.hideDockResult()
    }

    public func hideDockResult() async throws -> DesktopActionResult<Void> {
        try await self.actionResult(for: .hideDock, expectedResponse: "hide Dock") { response in
            guard case .ok = response else { return nil }
            return ()
        }.desktopActionResult
    }

    public func showDock() async throws {
        _ = try await self.showDockResult()
    }

    public func showDockResult() async throws -> DesktopActionResult<Void> {
        try await self.actionResult(for: .showDock, expectedResponse: "show Dock") { response in
            guard case .ok = response else { return nil }
            return ()
        }.desktopActionResult
    }

    public func isDockHidden() async throws -> Bool {
        let response = try await self.send(.isDockHidden)
        switch response {
        case let .bool(value): return value
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dock state response")
        }
    }

    public func findDockItem(name: String) async throws -> DockItem {
        let response = try await self.send(.findDockItem(PeekabooBridgeDockFindRequest(name: name)))
        switch response {
        case let .dockItem(item):
            if let item {
                return item
            }
            throw PeekabooBridgeErrorEnvelope(code: .notFound, message: "Dock item not found")
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dock find response")
        }
    }

    public func dialogFindActive(windowTitle: String?, appName: String?) async throws -> DialogInfo {
        let response = try await self.send(.dialogFindActive(PeekabooBridgeDialogFindRequest(
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogInfo(info): return info
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog response")
        }
    }

    public func dialogClickButton(
        buttonText: String,
        windowTitle: String?,
        appName: String?,
        allowGlobalFallback: Bool = false) async throws -> DialogActionResult
    {
        let request = PeekabooBridgeDialogClickButtonRequest(
            buttonText: buttonText,
            windowTitle: windowTitle,
            appName: appName)
        let response = try await self.send(
            allowGlobalFallback ? .dialogClickButton(request) : .backgroundDialogClickButton(request))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogEnterText(
        text: String,
        fieldIdentifier: String?,
        clearExisting: Bool,
        windowTitle: String?,
        appName: String?,
        focus: DialogForegroundFocusPolicy? = nil) async throws -> DialogActionResult
    {
        if focus != nil, !self.dialogInputFocusPolicyEnabled {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge host cannot preserve the dialog focus policy; no input was sent.",
                hint: "Select a protocol 1.28 host advertising dialog input focus policy support.")
        }
        let response = try await self.send(.dialogEnterText(PeekabooBridgeDialogEnterTextRequest(
            text: text,
            fieldIdentifier: fieldIdentifier,
            clearExisting: clearExisting,
            windowTitle: windowTitle,
            appName: appName,
            focus: focus)))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogEnterText(_ request: DialogLegacyInputExecutionRequest) async throws -> DialogActionResult {
        try await self.dialogEnterText(
            text: request.text,
            fieldIdentifier: request.fieldIdentifier,
            clearExisting: request.clearExisting,
            windowTitle: request.windowTitle,
            appName: request.appName,
            focus: request.focus)
    }

    /// Executes one exact dialog input request atomically in the selected Bridge host.
    ///
    /// This is intentionally separate from `dialogEnterText`: callers must capability-gate it and
    /// must never degrade the exact target or focus policy into the legacy operation.
    public func exactDialogEnterText(_ request: DialogInputExecutionRequest) async throws -> DialogActionResult {
        guard self.exactDialogInputExecutionEnabled else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge host does not advertise atomic exact dialog input; no input was sent.",
                hint: "Select a protocol 1.27 host advertising exact dialog input.")
        }
        let reply = try await self.sendCarryingActionOutcome(.exactDialogEnterText(request))
        switch reply.response {
        case let .dialogResult(result):
            guard result.success,
                  result.action == .enterText,
                  let outcome = result.outcome,
                  let targetReceipt = result.targetReceipt,
                  request.target.processIdentifier.map({
                      $0 == targetReceipt.processIdentifier
                  }) ?? true,
                  request.target.windowID.map({ $0 == targetReceipt.windowID }) ?? true
            else {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    evidence: .completionUnknown,
                    unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                    message: "Bridge exact dialog input did not return both its canonical outcome and target receipt.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            let routedOutcome = outcome.routed(to: .bridge)
            if let projected = reply.outcome?.outcome, projected != routedOutcome {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Bridge exact dialog input carried contradictory canonical outcomes.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            return DialogActionResult(
                success: result.success,
                action: result.action,
                details: result.details,
                outcome: routedOutcome,
                targetReceipt: targetReceipt,
                targetWindowIdentity: result.targetWindowIdentity,
                targetWindowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement,
                resolvedTarget: result.resolvedTarget)
        case let .error(envelope):
            if let failure = envelope.desktopActionFailure ?? reply.outcome.flatMap({ projection in
                DesktopActionFailure(
                    outcome: projection.outcome,
                    message: envelope.message,
                    hint: envelope.actionFailureHint,
                    causeDescription: envelope.actionFailureCauseDescription ?? envelope.details)
            }) {
                throw failure.routed(to: .bridge)
            }
            if let outcome = reply.outcome?.outcome {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Bridge exact dialog input error carried an invalid confirmed outcome.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            throw envelope
        default:
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                message: "Bridge returned an unexpected exact dialog input response.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
    }

    /// Executes one selector-preserving forced dialog dismissal atomically in the Bridge host.
    public func exactDialogForceDismiss(
        _ request: DialogForcedDismissExecutionRequest) async throws -> DialogActionResult
    {
        guard self.exactDialogForceDismissExecutionEnabled else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .runtimeIncompatible,
                message: "Bridge host does not advertise atomic exact forced dismissal; no Escape was sent.",
                hint: "Select a protocol 1.28 host advertising exact forced dialog dismissal.")
        }
        let reply = try await self.sendCarryingActionOutcome(.exactDialogForceDismiss(request))
        switch reply.response {
        case let .dialogResult(result):
            guard result.success,
                  result.action == .dismiss,
                  let outcome = result.outcome,
                  outcome.state == .dispatchedUnverified,
                  outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground),
                  outcome.dispatchState.unitCount == .one,
                  let targetReceipt = result.targetReceipt,
                  // The selector carries caller constraints, not a process-generation claim.
                  // The execution host publishes the resolved generation in this canonical receipt.
                  request.target.processIdentifier.map({ $0 == targetReceipt.processIdentifier }) ?? true,
                  request.target.windowID.map({ $0 == targetReceipt.windowID }) ?? true
            else {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    evidence: .completionUnknown,
                    unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                    message: "Bridge exact forced dismissal returned invalid outcome or target evidence.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            let routedOutcome = outcome.routed(to: .bridge)
            if let projected = reply.outcome?.outcome, projected != routedOutcome {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Bridge exact forced dismissal carried contradictory canonical outcomes.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            return DialogActionResult(
                success: result.success,
                action: result.action,
                details: result.details,
                outcome: routedOutcome,
                targetReceipt: targetReceipt,
                targetWindowIdentity: result.targetWindowIdentity,
                targetWindowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement,
                resolvedTarget: result.resolvedTarget)
        case let .error(envelope):
            if let failure = envelope.desktopActionFailure ?? reply.outcome.flatMap({ projection in
                DesktopActionFailure(
                    outcome: projection.outcome,
                    message: envelope.message,
                    hint: envelope.actionFailureHint,
                    causeDescription: envelope.actionFailureCauseDescription ?? envelope.details)
            }) {
                throw failure.routed(to: .bridge)
            }
            throw envelope
        default:
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                unitCount: reply.outcome?.outcome.dispatchState.unitCount,
                message: "Bridge returned an unexpected exact forced-dismiss response.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
    }

    public func dialogHandleFile(
        path: String?,
        filename: String?,
        actionButton: String?,
        ensureExpanded: Bool = false,
        appName: String?) async throws -> DialogActionResult
    {
        let response = try await self.send(.dialogHandleFile(PeekabooBridgeDialogHandleFileRequest(
            path: path,
            filename: filename,
            actionButton: actionButton,
            ensureExpanded: ensureExpanded,
            appName: appName)))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogDismiss(force: Bool, windowTitle: String?, appName: String?) async throws -> DialogActionResult {
        let response = try await self.send(.dialogDismiss(PeekabooBridgeDialogDismissRequest(
            force: force,
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogResult(result): return result
        case let .error(envelope): throw envelope
        default: throw PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: "Unexpected dialog result")
        }
    }

    public func dialogListElements(windowTitle: String?, appName: String?) async throws -> DialogElements {
        let response = try await self.send(.dialogListElements(PeekabooBridgeDialogFindRequest(
            windowTitle: windowTitle,
            appName: appName)))
        switch response {
        case let .dialogElements(elements): return elements
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected dialog elements response")
        }
    }

    public func targetedDialogListElements(target: DialogTargetSelector) async throws -> DialogElements {
        let response = try await self.send(.targetedDialogListElements(target))
        switch response {
        case let .dialogElements(elements): return elements
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected targeted dialog elements response")
        }
    }

    public func prepareDialogAction(_ request: DialogActionPreparationRequest) async throws
        -> PreparedDialogActionReceipt
    {
        let response = try await self.send(.prepareDialogAction(request))
        switch response {
        case let .preparedDialogAction(receipt): return receipt
        case let .error(envelope): throw envelope
        default:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Unexpected prepared dialog action response")
        }
    }

    public func performPreparedDialogAction(_ receipt: PreparedDialogActionReceipt) async throws
        -> DialogActionResult
    {
        let request: PeekabooBridgeRequest = switch receipt.kind {
        case .clickButton: .exactDialogClickButton(receipt)
        case .dismiss: .exactDialogDismiss(receipt)
        }
        let reply = try await self.sendCarryingActionOutcome(request)
        switch reply.response {
        case let .dialogResult(result):
            let outcome = try result.requiredPreparedOutcome(kind: receipt.kind)
            let routedOutcome = outcome.routed(to: .bridge)
            if let projected = reply.outcome?.outcome, projected != routedOutcome {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Bridge dialog action carried contradictory canonical outcomes.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            return DialogActionResult(
                success: result.success,
                action: result.action,
                details: result.details,
                outcome: routedOutcome,
                targetReceipt: result.targetReceipt,
                targetWindowIdentity: result.targetWindowIdentity,
                targetWindowBounds: result.targetWindowBounds,
                focusedElement: result.focusedElement,
                resolvedTarget: result.resolvedTarget)
        case let .error(envelope):
            if let failure = envelope.desktopActionFailure ?? reply.outcome.flatMap({ projection in
                DesktopActionFailure(
                    outcome: projection.outcome,
                    message: envelope.message,
                    hint: envelope.actionFailureHint,
                    causeDescription: envelope.actionFailureCauseDescription ?? envelope.details)
            }) {
                throw failure.routed(to: .bridge)
            }
            if let outcome = reply.outcome?.outcome {
                throw DesktopActionFailure.indeterminate(
                    route: .bridge,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "Bridge dialog error carried an invalid confirmed outcome.",
                    hint: "Observe the dialog before retrying and update the runtime host.")
            }
            throw envelope
        default:
            throw DesktopActionFailure.indeterminate(
                route: .bridge,
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Bridge returned an unexpected exact dialog action response.",
                hint: "Observe the dialog before retrying and update the runtime host.")
        }
    }
}
