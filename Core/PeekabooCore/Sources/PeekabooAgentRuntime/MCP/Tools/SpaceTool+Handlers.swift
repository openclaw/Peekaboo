import Algorithms
import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

extension SpaceTool {
    @MainActor
    func perform(
        action: SpaceAction,
        service: any SpaceManaging,
        startTime: Date) async throws -> ToolResponse
    {
        switch action {
        case let .list(detailed):
            try await self.handleList(service: service, detailed: detailed, startTime: startTime)
        case let .switchSpace(spaceNumber, _):
            try await self.handleSwitch(service: service, spaceNumber: spaceNumber, startTime: startTime)
        case let .moveWindow(request):
            try await self.handleMoveWindow(service: service, request: request, startTime: startTime)
        }
    }

    @MainActor
    private func handleList(
        service: any SpaceManaging,
        detailed: Bool,
        startTime: Date) async throws -> ToolResponse
    {
        let spaces = service.getAllSpaces()
        let executionTime = Date().timeIntervalSince(startTime)

        if spaces.isEmpty {
            return ToolResponse(
                content: [.text(text: "No Spaces found", annotations: nil, _meta: nil)],
                meta: .object([
                    "count": .double(0),
                    "execution_time": .double(executionTime),
                ]))
        }

        var output = "Found \(spaces.count) Space(s):\n\n"

        for (index, space) in spaces.indexed() {
            let spaceNumber = index + 1
            let activeIndicator = space.isActive ? " (Active)" : ""

            output += "Space \(spaceNumber)\(activeIndicator):\n"

            if detailed {
                output += "  • ID: \(space.id)\n"
                output += "  • Type: \(space.type.rawValue)\n"
                if let displayID = space.displayID {
                    output += "  • Display: \(displayID)\n"
                }
                if let name = space.name, !name.isEmpty {
                    output += "  • Name: \(name)\n"
                }
                if !space.ownerPIDs.isEmpty {
                    let owners = space.ownerPIDs.map(String.init).joined(separator: ", ")
                    output += "  • Owner PIDs: \(owners)\n"
                }
            } else {
                output += "  • Type: \(space.type.rawValue)\n"
            }

            output += "\n"
        }

        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseMeta: [String: Value] = [
            "count": .double(Double(spaces.count)),
            "execution_time": .double(executionTime),
            "detailed": .bool(detailed),
        ]
        let summary = ToolEventSummary(
            actionDescription: "List Spaces",
            notes: "\(spaces.count) spaces")
        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)))
    }

    @MainActor
    private func handleSwitch(
        service: any SpaceManaging,
        spaceNumber: Int,
        startTime: Date) async throws -> ToolResponse
    {
        let spaces = service.getAllSpaces()

        guard spaceNumber > 0, spaceNumber <= spaces.count else {
            return ToolResponse.error("Invalid space number. Available spaces: 1-\(spaces.count)")
        }

        let targetSpace = spaces[spaceNumber - 1]

        if targetSpace.isActive {
            let executionTime = Date().timeIntervalSince(startTime)
            return try ToolResponse(
                content: [.text(text: "Already on Space \(spaceNumber)", annotations: nil, _meta: nil)],
                meta: MCPToolResponseMetadataProjector.metadata(
                    merging: [
                        "space_number": .double(Double(spaceNumber)),
                        "space_id": .double(Double(targetSpace.id)),
                        "was_already_active": .bool(true),
                        "execution_time": .double(executionTime),
                    ],
                    outcome: .confirmedNoChange()))
        }

        let result = try await service.switchToSpaceResult(targetSpace.id)
        let outcome = try Self.requireSuccessfulSwitchResult(result)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage("Switched to Space \(spaceNumber)", duration: executionTime)

        let baseMeta: [String: Value] = [
            "space_number": .double(Double(spaceNumber)),
            "space_id": .double(Double(targetSpace.id)),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(
            actionDescription: "Switch Space",
            notes: "Space \(spaceNumber)")
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: ToolEventSummary.merge(
                    summary: summary,
                    into: .object(baseMeta)).objectValue ?? [:],
                outcome: outcome))
    }

    @MainActor
    private func handleMoveWindow(
        service: any SpaceManaging,
        request: MoveWindowRequest,
        startTime: Date) async throws -> ToolResponse
    {
        let operation = "Space move-window"
        let authorizedPlan = try self.context.authorizedDesktopTargetPlan(operation: operation)
        let windowInfo: ServiceWindowInfo
        let exactWindow: UIAutomationTarget.ExactWindow
        if let authorizedPlan {
            windowInfo = try authorizedPlan.requireSelectedWindow(operation: operation)
            exactWindow = try authorizedPlan.requireExactWindow(operation: operation)
            guard request.windowID == windowInfo.windowID else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Space move-window leaf did not retain its authorized window_id.",
                    hint: "Refresh the window inventory before retrying.")
            }
        } else {
            let windowTarget = try self.createWindowTarget(
                app: request.appName,
                windowID: request.windowID,
                title: request.windowTitle,
                index: request.windowIndex)
            let windows = try await self.context.windows.listWindows(target: windowTarget)
            do {
                windowInfo = try ExactWindowSelectorResolver.select(
                    from: windows,
                    selection: ExactWindowSelectorResolver.selection(for: windowTarget),
                    operation: operation)
            } catch {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: error.localizedDescription,
                    hint: "Refresh the window inventory and select one exact window_id.")
            }
            let selectedWindow = try self.exactAuthorizedWindow(windowInfo, operation: operation)
            exactWindow = try await self.exactWindow(
                selectedWindow,
                matchingApplication: request.appName,
                operation: operation)
        }

        guard let windowID = UInt32(exactly: exactWindow.identity.windowID),
              windowInfo.windowID == exactWindow.identity.windowID
        else {
            return ToolResponse.error("Window '\(windowInfo.title)' is missing an identifier")
        }

        if request.toCurrent {
            return try self.moveWindowToCurrentSpace(
                service: service,
                windowInfo: windowInfo,
                windowID: windowID,
                expectedIdentity: exactWindow.identity,
                startTime: startTime)
        }

        return try await self.moveWindowToSpecificSpace(
            service: service,
            request: request,
            windowInfo: windowInfo,
            expectedIdentity: exactWindow.identity,
            startTime: startTime)
    }

    @MainActor
    private func moveWindowToCurrentSpace(
        service: any SpaceManaging,
        windowInfo: ServiceWindowInfo,
        windowID: UInt32,
        expectedIdentity: WindowMutationIdentity,
        startTime: Date) throws -> ToolResponse
    {
        let actionResult = try Self.requireSuccessfulMoveResult(
            service.moveWindowToCurrentSpaceResult(
                windowID: windowID,
                expectedIdentity: expectedIdentity),
            expectedIdentity: expectedIdentity)

        let executionTime = Date().timeIntervalSince(startTime)
        let message = self.successMessage(
            "Moved window '\(windowInfo.title)' to current Space",
            duration: executionTime)

        let baseMeta: [String: Value] = [
            "window_title": .string(windowInfo.title),
            "window_id": .double(Double(windowID)),
            "moved_to_current": .bool(true),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(
            windowTitle: windowInfo.title,
            actionDescription: "Space Move",
            notes: "current")
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ObservationActionResultSupport.metadata(
                merging: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)).objectValue ?? [:],
                result: actionResult))
    }

    @MainActor
    private func moveWindowToSpecificSpace(
        service: any SpaceManaging,
        request: MoveWindowRequest,
        windowInfo: ServiceWindowInfo,
        expectedIdentity: WindowMutationIdentity,
        startTime: Date) async throws -> ToolResponse
    {
        guard let targetSpaceNumber = request.targetSpaceNumber else {
            return ToolResponse.error("Internal error: targetSpaceNumber is nil")
        }

        let spaces = service.getAllSpaces()
        guard targetSpaceNumber > 0, targetSpaceNumber <= spaces.count else {
            return ToolResponse.error("Invalid space number. Available spaces: 1-\(spaces.count)")
        }

        let targetSpace = spaces[targetSpaceNumber - 1]
        guard let windowID = UInt32(exactly: expectedIdentity.windowID) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move-window exact target has an invalid window identifier.",
                hint: "Refresh the window inventory before retrying.")
        }
        let moveResult = try Self.requireSuccessfulMoveResult(
            service.moveWindowToSpaceResult(
                windowID: windowID,
                expectedIdentity: expectedIdentity,
                spaceID: targetSpace.id),
            expectedIdentity: expectedIdentity)
        let actionResult: UIAutomationActionResult<Void>

        if request.follow {
            guard let moveOutcome = moveResult.outcome else {
                preconditionFailure("Validated Space move result lost its canonical outcome")
            }
            var sequence = DesktopActionSequenceAccumulator()
            sequence.record(.reportedOutcome(moveOutcome, defaultDispatchedUnitCount: .one))
            do {
                let switchResult = try await service.switchToSpaceResult(targetSpace.id)
                let switchOutcome = try Self.requireSuccessfulSwitchResult(switchResult)
                sequence.record(.reportedOutcome(switchOutcome, defaultDispatchedUnitCount: .one))
            } catch {
                let switchFailure = if let failure = error as? DesktopActionFailure {
                    failure
                } else {
                    DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: error.localizedDescription,
                        hint: "Observe the active Space before retrying.",
                        causeDescription: String(describing: error))
                }
                let combinedFailure = sequence.failure(
                    combining: switchFailure,
                    message: "The window moved, but following it to the target Space failed.",
                    hint: "Observe both the exact window and active Space before retrying.",
                    causeDescription: switchFailure.causeDescription ?? error.localizedDescription)
                throw combinedFailure.attributed(to: Self.targetReceipt(expectedIdentity))
            }
            let resolution = sequence.successResolution()
            guard let outcome = resolution.outcome else {
                throw DesktopActionFailure.indeterminate(
                    route: moveOutcome.route,
                    evidence: .completionUnknown,
                    unitCount: resolution.mutationDisposition.unitCount,
                    message: "Space move-window follow returned incompatible canonical outcomes.",
                    hint: "Observe both the exact window and active Space before retrying.")
                    .attributed(to: Self.targetReceipt(expectedIdentity))
            }
            actionResult = UIAutomationActionResult(
                payload: (),
                outcome: outcome,
                targetIdentity: moveResult.targetIdentity)
        } else {
            actionResult = moveResult
        }

        let executionTime = Date().timeIntervalSince(startTime)
        let followText = request.follow ? " and switched to Space \(targetSpaceNumber)" : ""
        let body = "Moved window '\(windowInfo.title)' to Space \(targetSpaceNumber)\(followText)"
        let message = self.successMessage(body, duration: executionTime)

        let baseMeta: [String: Value] = [
            "window_title": .string(windowInfo.title),
            "window_id": .double(Double(windowID)),
            "target_space_number": .double(Double(targetSpaceNumber)),
            "target_space_id": .double(Double(targetSpace.id)),
            "followed": .bool(request.follow),
            "execution_time": .double(executionTime),
        ]
        let summary = ToolEventSummary(
            windowTitle: windowInfo.title,
            actionDescription: "Space Move",
            notes: "space \(targetSpaceNumber)")
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ObservationActionResultSupport.metadata(
                merging: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)).objectValue ?? [:],
                result: actionResult))
    }

    private func exactAuthorizedWindow(
        _ window: ServiceWindowInfo,
        operation: String) throws -> UIAutomationTarget.ExactWindow
    {
        let candidate: DesktopTargetIdentity
        do {
            candidate = try DesktopTargetIdentity(
                exactWindow: DesktopTargetPlanning.DesktopTargetIdentityCoalescer.exactWindow(from: window))
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) could not establish one exact generation-pinned window.",
                hint: "Refresh the window inventory before retrying.",
                causeDescription: error.localizedDescription)
        }

        let authorized = try self.context.coalesceAuthorizedDesktopTarget(candidate, operation: operation)
        guard let exactWindow = authorized.exactWindow else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) did not retain an exact-window target.",
                hint: "Refresh the window inventory before retrying.")
        }
        return exactWindow
    }

    private func exactWindow(
        _ window: UIAutomationTarget.ExactWindow,
        matchingApplication app: String?,
        operation: String) async throws -> UIAutomationTarget.ExactWindow
    {
        guard let app else { return window }
        do {
            let application = try await self.context.applications.findApplication(identifier: app)
            guard let processIdentity = application.processIdentity else {
                throw DesktopTargetIdentityError.missingProcessGeneration
            }
            let processTarget = try DesktopTargetIdentity(processIdentity: processIdentity)
            let resolved = try processTarget.coalescing(DesktopTargetIdentity(exactWindow: window))
            guard let exactWindow = resolved.exactWindow else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "\(operation) window is not owned by the requested application process.",
                hint: "Refresh both the application and window inventories before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private static func requireSuccessfulMoveResult(
        _ result: UIAutomationActionResult<Void>,
        expectedIdentity: WindowMutationIdentity) throws -> UIAutomationActionResult<Void>
    {
        let expectedTarget = try Self.expectedTargetIdentity(expectedIdentity)
        _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
            result,
            policy: .confirmedOrDispatched(requiring: .background),
            targetRequirement: .exact(expectedTarget),
            operation: "Space move-window",
            missingOutcomeMessage: "Space move-window returned without a canonical action outcome.",
            missingTargetMessage: "Space move-window returned a missing or mismatched exact target.",
            rejectedOutcomeMessage: "Space move-window did not return a successful outcome.",
            missingOutcomeHint: "Observe the exact window before retrying and update the runtime host.",
            missingTargetHint: "Observe the exact window before retrying and update the runtime host.")
        return result
    }

    private static func requireSuccessfulSwitchResult(
        _ result: DesktopActionResult<Void>) throws -> DesktopActionOutcome
    {
        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Space switch returned without a canonical action outcome.",
                hint: "Observe the active Space before retrying and update the runtime host.")
        }
        guard !outcome.isAccepted(by: .confirmedOrDispatched) else { return outcome }
        guard let failure = DesktopActionFailure(
            outcome: outcome,
            message: "Space switch did not return a successful outcome.",
            hint: "Follow the canonical escalation metadata before deciding whether to retry.")
        else { preconditionFailure("A non-success Space switch outcome must construct a failure") }
        throw failure
    }

    private static func expectedTargetIdentity(
        _ identity: WindowMutationIdentity) throws -> DesktopTargetIdentity
    {
        let receipt = self.targetReceipt(identity)
        guard let bounds = identity.capturedBounds else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move-window expected target has no immutable bounds.",
                hint: "Refresh the exact window before retrying.")
                .attributed(to: receipt)
        }
        do {
            return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: bounds))
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Space move-window expected target receipt is invalid.",
                hint: "Refresh the exact window before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: receipt)
        }
    }

    private static func targetReceipt(
        _ identity: WindowMutationIdentity) -> DesktopActionTargetReceipt
    {
        DesktopActionTargetReceipt(
            processIdentifier: identity.ownerProcessIdentifier,
            processStartIdentity: identity.ownerProcessStartIdentity,
            windowID: identity.windowID)
    }

    private func createWindowTarget(
        app: String?,
        windowID: Int?,
        title: String?,
        index: Int?) throws -> WindowTarget
    {
        if let windowID {
            return .windowId(windowID)
        }

        guard let app else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Space move-window requires an application or exact window selector.")
        }
        if let title {
            return .applicationAndTitle(app: app, title: title)
        }

        if let index {
            return .index(app: app, index: index)
        }

        return .application(app)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.2f", duration)
    }

    private func successMessage(_ body: String, duration: TimeInterval) -> String {
        "\(AgentDisplayTokens.Status.success) \(body) in \(self.formatDuration(duration))s"
    }
}
