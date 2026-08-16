import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

extension WindowTool {
    // MARK: - Action Handlers

    func handleClose(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        allowForegroundFallback: Bool,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window close")
        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window close")

        try service.requireWindowMutationResultProvider(operation: "Window close")
        let actionResult = try await service.closeWindowResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity,
            allowForegroundFallback: allowForegroundFallback)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window close")

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(action: "Closed window '\(windowInfo.title)'", duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Close",
            baseMeta: ["execution_time": .double(executionTime)],
            actionResult: validatedResult)
    }

    func handleMinimize(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window minimize")
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window minimize")

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        try service.requireWindowMutationResultProvider(operation: "Window minimize")
        let actionResult = try await service.minimizeWindowResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window minimize")

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(action: "Minimized window '\(windowInfo.title)'", duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Minimize",
            baseMeta: ["execution_time": .double(executionTime)],
            actionResult: validatedResult)
    }

    func handleRestore(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window restore")
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window restore")

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        try service.requireWindowMutationResultProvider(operation: "Window restore")
        let actionResult = try await service.restoreWindowResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window restore")
        let readback = try await self.readBackWindowAfterMutation(
            service: service,
            target: exactTarget,
            action: "Restore",
            actionResult: validatedResult)
        let responseResult = UIAutomationActionResult(
            payload: (),
            outcome: validatedResult.outcome,
            targetIdentity: readback.targetIdentity)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(
            action: "Restored window '\(readback.windowInfo.title)'",
            duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: readback.windowInfo,
            actionDescription: "Window Restore",
            baseMeta: ["execution_time": .double(executionTime)],
            actionResult: responseResult)
    }

    func handleMaximize(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window maximize")

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window maximize")
        try service.requireWindowMutationResultProvider(operation: "Window maximize")
        let actionResult = try await service.maximizeWindowResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window maximize")
        let readback = try await self.readBackWindowAfterMutation(
            service: service,
            target: exactTarget,
            action: "Maximize",
            actionResult: validatedResult)
        let responseResult = UIAutomationActionResult(
            payload: (),
            outcome: validatedResult.outcome,
            targetIdentity: readback.targetIdentity)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(
            action: "Maximized window '\(readback.windowInfo.title)'",
            duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: readback.windowInfo,
            actionDescription: "Window Maximize",
            baseMeta: ["execution_time": .double(executionTime)],
            actionResult: responseResult)
    }

    func handleMove(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        position: CGPoint,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window move")
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window move")

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        try service.requireWindowMutationResultProvider(operation: "Window move")
        let actionResult = try await service.moveWindowResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity,
            to: position)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window move")

        let executionTime = Date().timeIntervalSince(startTime)
        let detail = "Moved window '\(windowInfo.title)' to (\(Int(position.x)), \(Int(position.y)))"
        let message = self.successMessage(action: detail, duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Move",
            coordinates: ToolEventSummary.Coordinates(x: Double(position.x), y: Double(position.y)),
            baseMeta: [
                "new_x": .double(Double(position.x)),
                "new_y": .double(Double(position.y)),
                "execution_time": .double(executionTime),
            ],
            actionResult: validatedResult)
    }

    func handleResize(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        size: CGSize,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window resize")
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window resize")

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        try service.requireWindowMutationResultProvider(operation: "Window resize")
        let actionResult = try await service.resizeWindowResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity,
            to: size)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window resize")

        let executionTime = Date().timeIntervalSince(startTime)
        let detail = "Resized window '\(windowInfo.title)' to \(Int(size.width)) × \(Int(size.height))"
        let message = self.successMessage(action: detail, duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Resize",
            notes: "\(Int(size.width))×\(Int(size.height))",
            baseMeta: [
                "new_width": .double(Double(size.width)),
                "new_height": .double(Double(size.height)),
                "execution_time": .double(executionTime),
            ],
            actionResult: validatedResult)
    }

    func handleSetBounds(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        bounds: CGRect,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window set bounds")
        let mutationIdentity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window set bounds")

        let exactTarget = WindowTarget.windowId(windowInfo.windowID)
        try service.requireWindowMutationResultProvider(operation: "Window set bounds")
        let actionResult = try await service.setWindowBoundsResult(
            target: exactTarget,
            expectedIdentity: mutationIdentity,
            bounds: bounds)
        let validatedResult = try service.validatedWindowMutationResult(
            actionResult,
            expectedIdentity: mutationIdentity,
            operation: "Window set bounds")

        let executionTime = Date().timeIntervalSince(startTime)
        let detail = "Set bounds for window '\(windowInfo.title)' to (\(Int(bounds.origin.x)), "
            + "\(Int(bounds.origin.y)), \(Int(bounds.width)) × \(Int(bounds.height)))"
        let message = self.successMessage(action: detail, duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Set Bounds",
            coordinates: ToolEventSummary.Coordinates(
                x: Double(bounds.origin.x),
                y: Double(bounds.origin.y)),
            notes: "\(Int(bounds.width))×\(Int(bounds.height))",
            baseMeta: [
                "new_x": .double(Double(bounds.origin.x)),
                "new_y": .double(Double(bounds.origin.y)),
                "new_width": .double(Double(bounds.width)),
                "new_height": .double(Double(bounds.height)),
                "execution_time": .double(executionTime),
            ],
            actionResult: validatedResult)
    }

    func handleFocus(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        appName: String?,
        startTime: Date) async throws -> ToolResponse
    {
        let windowInfo = try await self.mutationWindow(
            service: service,
            target: target,
            operation: "Window focus")

        let identity = try self.authorizedWindowIdentity(
            for: windowInfo,
            target: target,
            operation: "Window focus")
        guard let bounds = identity.capturedBounds,
              bounds == windowInfo.bounds
        else {
            throw PeekabooError.commandFailed(
                "Window \(windowInfo.windowID) did not include a consistent process-generation identity")
        }
        let actionResult = try await service.focusWindowResult(
            target: .windowId(windowInfo.windowID),
            expectedIdentity: identity)
        let outcome = try Self.requireSuccessfulFocusResult(
            actionResult,
            expectedIdentity: identity,
            expectedBounds: bounds)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(action: "Focused window '\(windowInfo.title)'", duration: executionTime)
        return try self.windowResponse(
            message: message,
            appName: appName,
            windowInfo: windowInfo,
            actionDescription: "Window Focus",
            baseMeta: ["execution_time": .double(executionTime)],
            outcome: outcome,
            targetIdentity: actionResult.targetIdentity)
    }

    func successMessage(action: String, duration: TimeInterval) -> String {
        "\(AgentDisplayTokens.Status.success) \(action) in \(String(format: "%.2f", duration))s"
    }

    private func validateWindowOwner(
        _ identity: WindowMutationIdentity,
        expected: ApplicationProcessIdentity?) throws
    {
        guard let expected else { return }
        guard identity.ownerProcessIdentifier == expected.processIdentifier,
              identity.ownerProcessStartIdentity == expected.processStartIdentity
        else {
            throw PeekabooError.windowNotFound(
                criteria: "Window \(identity.windowID) is not owned by the selected application process receipt")
        }
    }

    private func mutationWindow(
        service: any WindowManagementServiceProtocol,
        target: WindowActionTarget,
        operation: String) async throws -> ServiceWindowInfo
    {
        if let authorizedWindow = target.authorizedWindow {
            guard case let .windowId(windowID) = target.target,
                  windowID == authorizedWindow.windowID
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "\(operation) leaf did not retain its authorized window_id.",
                    hint: "Refresh the window inventory before retrying.")
            }
            return authorizedWindow
        }

        let windows = try await service.listWindows(target: target.target)
        do {
            return try ExactWindowSelectorResolver.select(
                from: windows,
                selection: ExactWindowSelectorResolver.selection(for: target.target),
                operation: operation)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: error.localizedDescription,
                hint: "Refresh the window inventory and select one exact window_id.")
        }
    }

    private func authorizedWindowIdentity(
        for window: ServiceWindowInfo,
        target: WindowActionTarget,
        operation: String) throws -> WindowMutationIdentity
    {
        guard window.mutationIdentity != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Window \(window.windowID) did not include a process-generation identity.",
                hint: "Refresh the window inventory before retrying.")
        }
        let candidate = try DesktopTargetIdentity(
            exactWindow: UIAutomationTarget.ExactWindow(window: window))
        let authorized = try self.context.coalesceAuthorizedDesktopTarget(
            candidate,
            operation: operation)
        guard let exactWindow = authorized.exactWindow else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) lost its exact-window authority before dispatch.",
                hint: "Refresh the window inventory before retrying.")
        }
        try self.validateWindowOwner(exactWindow.identity, expected: target.expectedOwnerIdentity)
        return exactWindow.identity
    }

    private static func requireSuccessfulFocusResult(
        _ result: UIAutomationActionResult<Void>,
        expectedIdentity: WindowMutationIdentity,
        expectedBounds: CGRect) throws -> DesktopActionOutcome
    {
        let expectedTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: expectedIdentity,
            bounds: expectedBounds))
        return try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result,
            policy: .confirmedOrDispatched(requiring: .foreground),
            targetRequirement: .exact(expectedTarget),
            operation: "Window focus",
            missingTargetMessage: "Window focus returned a missing or mismatched exact target.",
            rejectedOutcomeMessage: "Window focus did not return a successful outcome.",
            missingTargetHint: "Observe the selected window before retrying and update the runtime host.")
    }

    private func readBackWindowAfterMutation(
        service: any WindowManagementServiceProtocol,
        target: WindowTarget,
        action: String,
        actionResult: UIAutomationActionResult<Void>) async throws -> WindowPostMutationReadback
    {
        do {
            let windows = try await service.listWindows(target: target)
            let windowInfo = try ExactWindowSelectorResolver.select(
                from: windows,
                selection: ExactWindowSelectorResolver.selection(for: target),
                operation: "\(action) post-action readback")
            let targetIdentity = try Self.coalescedPostMutationWindowTargetIdentity(
                windowInfo: windowInfo,
                actionResultTarget: actionResult.targetIdentity)
            return WindowPostMutationReadback(
                windowInfo: windowInfo,
                targetIdentity: targetIdentity)
        } catch {
            guard let outcome = actionResult.outcome else { preconditionFailure("Validated result lost outcome") }
            let readbackFailure = if let failure = error as? DesktopActionFailure {
                failure
            } else {
                DesktopActionFailure.preDispatchRefusal(
                    route: outcome.route,
                    reason: .targetUnavailable,
                    message: "\(action) post-action readback failed.",
                    hint: "Observe the exact window before deciding whether to retry.",
                    causeDescription: error.localizedDescription)
            }
            var sequence = DesktopActionSequenceAccumulator()
            sequence.record(.outcome(outcome))
            let failure = sequence.failure(
                combining: readbackFailure,
                message: "\(action) was dispatched, but the exact window could not be read back.",
                hint: "Observe the exact window before deciding whether to retry.",
                causeDescription: error.localizedDescription)
            let receipt = actionResult.targetIdentity?.exactWindow.map {
                DesktopActionTargetReceipt(
                    processIdentifier: $0.identity.ownerProcessIdentifier,
                    processStartIdentity: $0.identity.ownerProcessStartIdentity,
                    windowID: $0.identity.windowID)
            }
            throw failure.attributed(to: receipt)
        }
    }

    private static func coalescedPostMutationWindowTargetIdentity(
        windowInfo: ServiceWindowInfo,
        actionResultTarget: DesktopTargetIdentity?) throws -> DesktopTargetIdentity
    {
        guard let readbackIdentity = windowInfo.mutationIdentity,
              readbackIdentity.capturedBounds == windowInfo.bounds,
              let actionWindow = actionResultTarget?.exactWindow,
              actionWindow.identity.hasSameStableReceipt(as: readbackIdentity)
        else {
            throw DesktopTargetIdentityError.contradictoryWindowIdentity
        }
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: readbackIdentity,
            bounds: windowInfo.bounds))
    }

    func windowResponse(
        message: String,
        appName: String?,
        windowInfo: ServiceWindowInfo,
        actionDescription: String,
        coordinates: ToolEventSummary.Coordinates? = nil,
        notes: String? = nil,
        baseMeta: [String: Value],
        outcome: DesktopActionOutcome? = nil,
        targetIdentity: DesktopTargetIdentity? = nil,
        actionResult: UIAutomationActionResult<Void>? = nil) throws -> ToolResponse
    {
        var meta = baseMeta
        meta["window_title"] = .string(windowInfo.title)
        meta["window_id"] = .double(Double(windowInfo.windowID))

        let summary = ToolEventSummary(
            targetApp: appName,
            windowTitle: windowInfo.title,
            actionDescription: actionDescription,
            coordinates: coordinates,
            notes: notes)
        let effectiveResult = actionResult ?? UIAutomationActionResult(
            payload: (),
            outcome: outcome,
            targetIdentity: targetIdentity)
        let resultMetadata: Value? = if effectiveResult.targetIdentity != nil {
            try ObservationActionResultSupport.metadata(
                merging: ToolEventSummary.merge(summary: summary, into: .object(meta)).objectValue ?? [:],
                result: effectiveResult)
        } else {
            try MCPToolResponseMetadataProjector.metadata(
                merging: ToolEventSummary.merge(summary: summary, into: .object(meta)).objectValue ?? [:],
                outcome: effectiveResult.outcome)
        }
        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: resultMetadata)
    }
}

private struct WindowPostMutationReadback {
    let windowInfo: ServiceWindowInfo
    let targetIdentity: DesktopTargetIdentity
}
