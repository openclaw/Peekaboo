import Foundation
import MCP
import os.log
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

@MainActor
extension AppToolActions {
    func handleLaunch(request: AppToolRequest) async throws -> ToolResponse {
        try Self.validateExclusiveApplicationSelectors(request)
        if !request.foreground, request.newInstance {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background new-instance launch is refused before dispatch because a new app process can activate.")
        }
        if !request.foreground, !request.openTargets.isEmpty {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background URL or document delivery is refused before dispatch because the target app can activate.")
        }
        guard request.bundleId != nil || request.name != nil else {
            return ToolResponse.error("Must specify either 'name' or 'bundleId' for launch action")
        }

        let openURLs = try request.openTargets.map(Self.resolveOpenTarget)
        let launchRequest = ApplicationLaunchRequest(
            applicationIdentifier: request.bundleId == nil ? request.name : nil,
            applicationBundleIdentifier: request.bundleId,
            openURLs: openURLs,
            activates: request.foreground,
            waitUntilReady: request.waitUntilReady,
            waitForWindow: request.waitForWindow,
            createsNewInstance: request.newInstance)
        let actionResult = try await self.service.launchApplicationResult(request: launchRequest)
        let app = actionResult.payload
        let outcome = try self.validatedBackgroundLaunchNoOpOutcome(
            actionResult,
            request: launchRequest)

        let timing = self.executionTimeString(since: request.startTime)
        let message = if launchRequest.isSafeBackgroundNoOp ||
            outcome?.state == .confirmedNoChange
        {
            "\(AgentDisplayTokens.Status.success) \(app.name) was already running "
                + "(PID: \(app.processIdentifier)); no launch was needed (\(timing))"
        } else {
            "\(AgentDisplayTokens.Status.success) Launched \(app.name) "
                + "(PID: \(app.processIdentifier)) in \(timing)"
        }
        return try self.buildResponse(
            message: message,
            app: app,
            startTime: request.startTime,
            extraMeta: [
                "foreground": .bool(request.foreground),
                "open_targets": .array(request.openTargets.map(Value.string)),
                "wait_until_ready": .bool(request.waitUntilReady),
                "wait_for_window": .bool(request.waitForWindow),
                "new_instance": .bool(request.newInstance),
                "window_count": .double(Double(app.windowIDs?.count ?? app.windowCount)),
                "window_ready": .bool((app.windowIDs?.count ?? app.windowCount) > 0),
                "window_ids": app.windowIDs.map { .array($0.map { .double(Double($0)) }) } ?? .null,
                "window_identity": .string(app.windowIDs == nil ? "unknown" : "exact"),
            ],
            outcome: outcome)
    }

    private func validatedBackgroundLaunchNoOpOutcome(
        _ result: DesktopActionResult<ServiceApplicationInfo>,
        request: ApplicationLaunchRequest) throws -> DesktopActionOutcome?
    {
        guard request.isSafeBackgroundNoOp,
              let context,
              let authorization = AuthorizedDesktopTargetPlan.current
        else { return result.outcome }

        let authorizedIdentity = authorization.processIdentity
        guard let returnedIdentity = result.payload.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Background application readiness returned no process-generation identity.",
                hint: "Refresh the application inventory before retrying.")
                .attributed(to: Self.targetReceipt(authorizedIdentity))
        }
        _ = try context.coalesceAuthorizedDesktopTarget(
            DesktopTargetIdentity(processIdentity: returnedIdentity),
            operation: "Background application readiness")

        guard let outcome = result.outcome else {
            throw DesktopActionFailure.indeterminate(
                evidence: .completionUnknown,
                message: "Background application readiness returned without a canonical no-dispatch outcome.",
                hint: "Inspect the selected application before retrying and update the runtime host.")
                .attributed(to: Self.targetReceipt(authorizedIdentity))
        }
        guard outcome.state == .confirmedNoChange,
              outcome.dispatchState == .none,
              outcome.delivery == nil
        else {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Background application readiness did not prove an exact read-only no-op.",
                hint: "Inspect the selected application before retrying and update the runtime host.")
                .attributed(to: Self.targetReceipt(authorizedIdentity))
        }
        return outcome
    }

    private static func targetReceipt(_ identity: ApplicationProcessIdentity) -> DesktopActionTargetReceipt {
        DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity)
    }

    func handleOpen(request: AppToolRequest) async throws -> ToolResponse {
        try Self.validateExclusiveApplicationSelectors(request)
        guard request.foreground else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background URL or document delivery is refused before dispatch because the target app can activate.")
        }
        guard !request.openTargets.isEmpty else {
            return ToolResponse.error("Must specify at least one 'openTargets' URL or file path for open action")
        }
        guard request.openTargets.count == 1 || request.name != nil || request.bundleId != nil else {
            return ToolResponse.error("Opening multiple targets requires 'name' or 'bundleId'")
        }

        let openURLs = try request.openTargets.map(Self.resolveOpenTarget)
        let launchRequest = ApplicationLaunchRequest(
            applicationIdentifier: request.bundleId == nil ? request.name : nil,
            applicationBundleIdentifier: request.bundleId,
            openURLs: openURLs,
            activates: request.foreground,
            waitUntilReady: request.waitUntilReady,
            waitForWindow: request.waitForWindow,
            createsNewInstance: request.newInstance)
        let actionResult = try await self.service.launchApplicationResult(request: launchRequest)
        let app = actionResult.payload

        let count = request.openTargets.count
        let timing = self.executionTimeString(since: request.startTime)
        let message = if let outcome = actionResult.outcome,
                         !outcome.dispatchState.mutationDispatched
        {
            "\(AgentDisplayTokens.Status.success) No target delivery was dispatched to \(app.name) "
                + "(PID: \(app.processIdentifier)); 0 targets were opened (\(timing))"
        } else {
            "\(AgentDisplayTokens.Status.success) Opened \(count) target\(count == 1 ? "" : "s") "
                + "with \(app.name) (PID: \(app.processIdentifier)) in \(timing)"
        }
        return try self.buildResponse(
            message: message,
            app: app,
            startTime: request.startTime,
            extraMeta: [
                "foreground": .bool(request.foreground),
                "open_targets": .array(request.openTargets.map(Value.string)),
                "wait_until_ready": .bool(request.waitUntilReady),
                "wait_for_window": .bool(request.waitForWindow),
                "new_instance": .bool(request.newInstance),
                "window_count": .double(Double(app.windowIDs?.count ?? app.windowCount)),
                "window_ready": .bool((app.windowIDs?.count ?? app.windowCount) > 0),
                "window_ids": app.windowIDs.map { .array($0.map { .double(Double($0)) }) } ?? .null,
                "window_identity": .string(app.windowIDs == nil ? "unknown" : "exact"),
            ],
            outcome: actionResult.outcome)
    }

    func handleQuit(request: AppToolRequest) async throws -> ToolResponse {
        if request.all {
            return try await self.handleQuitAll(request: request)
        }

        guard let name = request.name else {
            return ToolResponse.error("Must specify 'name' for quit action (or set 'all': true)")
        }

        let appInfo = try await self.service.findApplication(identifier: name)
        let expectedIdentity = try self.authorizedProcessIdentity(
            for: appInfo,
            operation: "Application quit")
        let quitRequest = ApplicationQuitRequest(
            identifier: "PID:\(expectedIdentity.processIdentifier)",
            force: request.force,
            expectedIdentity: expectedIdentity)
        let actionResult = try await self.service.quitApplicationResult(request: quitRequest)
        let success = actionResult.payload

        do {
            try ApplicationActionResultSemantics.requireConsistentQuitResult(
                actionResult,
                expectedIdentity: expectedIdentity,
                operation: "Application quit")
        } catch let failure as DesktopActionFailure {
            let presentedFailure = if !success,
                                      let outcome = actionResult.outcome,
                                      let contextual = DesktopActionFailure(
                                          outcome: failure.outcome,
                                          message: failure.message,
                                          hint: Self.quitFailureHint(for: outcome, force: request.force),
                                          causeDescription: failure.causeDescription,
                                          targetReceipt: failure.targetReceipt)
            {
                contextual
            } else {
                failure
            }
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: presentedFailure,
                invalidatedSnapshotID: nil)
        }

        guard success else {
            return ToolResponse.error("Failed to quit \(appInfo.name). The application may have refused to quit.")
        }

        let timing = self.executionTimeString(since: request.startTime)
        let suffix = request.force ? " (force quit)" : ""
        let message = "\(AgentDisplayTokens.Status.success) Quit \(appInfo.name)\(suffix) in \(timing)"
        return try self.buildResponse(
            message: message,
            app: appInfo,
            startTime: request.startTime,
            extraMeta: ["force_quit": .bool(request.force)],
            outcome: actionResult.outcome)
    }

    func handleRelaunch(request: AppToolRequest) async throws -> ToolResponse {
        try Self.validateExclusiveApplicationSelectors(request)
        guard request.foreground else {
            throw ApplicationLifecycleRefusalError.backgroundLaunch(
                "Background app relaunch is refused before quit because terminating and launching " +
                    "an app can interrupt the user.")
        }
        guard let identifier = request.name ?? request.bundleId else {
            return ToolResponse.error("Must specify 'name' (or 'bundleId') for relaunch action")
        }

        let appInfo = try await self.service.findApplication(identifier: identifier)
        guard let originalProcessIdentity = appInfo.processIdentity else {
            throw PeekabooError.serviceUnavailable(
                "Application discovery did not return a process-generation identity for atomic relaunch")
        }
        let descriptor = "PID:\(appInfo.processIdentifier)"
        let launchIdentifier = appInfo.bundlePath ?? (appInfo.bundleIdentifier == nil ? appInfo.name : nil)
        let launchBundleIdentifier = appInfo.bundlePath == nil ? appInfo.bundleIdentifier : nil
        let relaunchRequest = ApplicationRelaunchRequest(
            targetIdentifier: descriptor,
            expectedTargetIdentity: originalProcessIdentity,
            launchRequest: ApplicationLaunchRequest(
                applicationIdentifier: launchIdentifier,
                applicationBundleIdentifier: launchBundleIdentifier,
                activates: request.foreground,
                waitUntilReady: request.waitUntilReady,
                waitForWindow: request.waitForWindow),
            force: request.force,
            waitSeconds: request.wait)
        let actionResult = try await self.service.relaunchApplicationResult(request: relaunchRequest)
        let refreshedInfo = actionResult.payload
        let timing = self.executionTimeString(since: request.startTime)
        let message = "\(AgentDisplayTokens.Status.success) Relaunched \(refreshedInfo.name) "
            + "(PID: \(refreshedInfo.processIdentifier)) in \(timing)"

        return try self.buildResponse(
            message: message,
            app: refreshedInfo,
            startTime: request.startTime,
            extraMeta: [
                "previous_pid": .double(Double(appInfo.processIdentifier)),
                "previous_process_start_identity": .double(Double(originalProcessIdentity.processStartIdentity)),
                "previous_process_start_identity_decimal": .string(String(
                    originalProcessIdentity.processStartIdentity)),
                "new_process_start_identity": refreshedInfo.processStartIdentity
                    .map { .double(Double($0)) } ?? .null,
                "new_process_start_identity_decimal": refreshedInfo.processStartIdentity
                    .map { .string(String($0)) } ?? .null,
                "wait": .double(request.wait),
                "wait_until_ready": .bool(request.waitUntilReady),
                "wait_for_window": .bool(request.waitForWindow),
                "force": .bool(request.force),
                "foreground": .bool(request.foreground),
            ],
            outcome: actionResult.outcome)
    }

    func handleHide(request: AppToolRequest) async throws -> ToolResponse {
        guard let name = request.name else {
            return ToolResponse.error("Must specify 'name' for hide action")
        }
        let app = try await self.service.findApplication(identifier: name)
        let expectedIdentity = try self.authorizedProcessIdentity(
            for: app,
            operation: "Application hide")
        let actionResult = try await self.service.hideApplicationTargetedResult(request: .init(
            identifier: "PID:\(expectedIdentity.processIdentifier)",
            expectedIdentity: expectedIdentity))
        let returnedExactTarget = actionResult.targetIdentity?.processIdentity == expectedIdentity
        let targetMetadata: [String: Value] = returnedExactTarget ? [
            "process_start_identity_decimal": .string(String(expectedIdentity.processStartIdentity)),
            "target_identity": .object([
                "kind": .string("process"),
                "pid": .int(Int(expectedIdentity.processIdentifier)),
                "process_start_identity_decimal": .string(String(expectedIdentity.processStartIdentity)),
            ]),
        ] : [:]
        try ApplicationActionResultSemantics.requireSuccessfulExactProcessResult(
            actionResult,
            expectedIdentity: expectedIdentity,
            operation: "Application hide")
        let outcome = actionResult.outcome
        let message = "\(AgentDisplayTokens.Status.success) Hid \(app.name) "
            + "(PID: \(app.processIdentifier)) in \(self.executionTimeString(since: request.startTime))"
        return try self.buildResponse(
            message: message,
            app: app,
            startTime: request.startTime,
            extraMeta: targetMetadata,
            outcome: outcome)
    }

    func handleUnhide(request: AppToolRequest) async throws -> ToolResponse {
        try Self.validateExclusiveApplicationSelectors(request)
        guard request.foreground else {
            throw ApplicationLifecycleRefusalError.unhideRequiresForegroundConsent()
        }
        guard let name = request.name else {
            return ToolResponse.error("Must specify 'name' for unhide action")
        }
        let app = try await self.service.findApplication(identifier: name)
        let activationRequest = try ApplicationActivationRequest(application: app)
        let actionResult = try await self.service.activateApplicationResult(request: activationRequest)
        let message = "\(AgentDisplayTokens.Status.success) Unhid and activated \(app.name) "
            + "(PID: \(app.processIdentifier)) in \(self.executionTimeString(since: request.startTime))"
        return try self.buildResponse(
            message: message,
            app: app,
            startTime: request.startTime,
            outcome: actionResult.outcome)
    }

    private func handleQuitAll(request: AppToolRequest) async throws -> ToolResponse {
        let excluded = request.except?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? []

        let appsOutput = try await self.service.listApplications()
        let allApps = appsOutput.data.applications
        let remaining = allApps.filter { app in
            excluded.contains { exclusion in exclusion.caseInsensitiveCompare(app.name) == .orderedSame }
        }
        let targets = allApps.filter { app in
            app.isEligibleForBulkQuit &&
                !remaining.contains(where: { $0.processIdentifier == app.processIdentifier })
        }

        var quitCount = 0
        var failed = [String]()
        var failedTargetReceipts = [DesktopActionTargetReceipt]()
        var outcomes = [DesktopActionOutcome?]()
        var wasCancelled = false
        var cancellationInterruptedAttempt = false
        for app in targets {
            if Task.isCancelled {
                guard !outcomes.isEmpty else { throw CancellationError() }
                wasCancelled = true
                break
            }
            do {
                let quitRequest = try Self.pinnedQuitRequest(for: app, force: request.force)
                let result = try await self.service.quitApplicationResult(request: quitRequest)
                guard let expectedIdentity = quitRequest.expectedIdentity else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .invalidRequest,
                        message: "Application quit requires a process-generation identity.")
                }
                try ApplicationActionResultSemantics.requireConsistentQuitResult(
                    result,
                    expectedIdentity: expectedIdentity,
                    operation: "Application quit",
                    requiresCanonicalOutcome: false)
                let success = result.payload
                outcomes.append(result.outcome)
                if success {
                    quitCount += 1
                } else {
                    failed.append(app.name)
                }
            } catch is CancellationError {
                wasCancelled = true
                cancellationInterruptedAttempt = true
                break
            } catch let failure as DesktopActionFailure {
                outcomes.append(failure.outcome)
                if let targetReceipt = failure.targetReceipt {
                    failedTargetReceipts.append(targetReceipt)
                }
                self.logger.error("Failed to quit \(app.name, privacy: .public): \(failure, privacy: .public)")
                failed.append(app.name)
            } catch {
                self.logger.error("Failed to quit \(app.name, privacy: .public): \(error, privacy: .public)")
                outcomes.append(nil)
                failed.append(app.name)
            }
        }

        let executionTime = self.executionTime(since: request.startTime)
        var message = "\(AgentDisplayTokens.Status.success) Quit \(quitCount) applications"
        if !excluded.isEmpty {
            message += " (except \(excluded.joined(separator: ", ")))"
        }
        message += " in \(self.executionTimeString(from: executionTime))"
        if !failed.isEmpty {
            let failureList = failed.joined(separator: ", ")
            let warningLine = "\n\(AgentDisplayTokens.Status.warning) Failed to quit: \(failureList)"
            message += warningLine
        }
        if wasCancelled {
            message += "\n\(AgentDisplayTokens.Status.warning) Quit batch cancelled after " +
                "\(outcomes.count) of \(targets.count) targets"
        }

        var baseMeta: [String: Value] = [
            "quit_count": .double(Double(quitCount)),
            "failed": .array(failed.map(Value.string)),
            "except": .array(excluded.map(Value.string)),
            "execution_time": .double(executionTime),
            "force": .bool(request.force),
            "cancelled": .bool(wasCancelled),
        ]
        if targets.count == 1,
           failed.count == 1,
           failedTargetReceipts.count == 1,
           let targetReceipt = failedTargetReceipts.first
        {
            baseMeta["target_receipt"] = try Value(targetReceipt)
        }
        let summary = self.makeSummary(for: nil, action: "Quit Applications", notes: "Quit \(quitCount) apps")
        let outcome = if wasCancelled {
            DesktopActionSequenceAccumulator.interruptedBatch(
                completedOutcomes: outcomes,
                succeededCount: quitCount,
                attemptedCount: outcomes.count,
                plannedCount: targets.count,
                inFlightAttemptMayHaveDispatched: cancellationInterruptedAttempt)?.outcome
        } else {
            DesktopActionSequenceAccumulator.completedBatch(
                outcomes: outcomes,
                succeededCount: quitCount,
                attemptedCount: outcomes.count)
        }
        return try ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: wasCancelled || !failed.isEmpty,
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)).objectValue ?? [:],
                outcome: outcome))
    }

    private static func pinnedQuitRequest(
        for application: ServiceApplicationInfo,
        force: Bool) throws -> ApplicationQuitRequest
    {
        guard let identity = application.processIdentity else {
            throw PeekabooError.serviceUnavailable(
                "Application discovery did not return a process-generation identity; update the runtime host")
        }
        return ApplicationQuitRequest(
            identifier: "PID:\(application.processIdentifier)",
            force: force,
            expectedIdentity: identity)
    }

    private func authorizedProcessIdentity(
        for application: ServiceApplicationInfo,
        operation: String) throws -> ApplicationProcessIdentity
    {
        guard let identity = application.processIdentity else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Application discovery did not return a process-generation identity for exact mutation.",
                hint: "Refresh the application inventory before retrying.")
        }
        guard let context = self.context else { return identity }
        let target = try context.coalesceAuthorizedDesktopTarget(
            DesktopTargetIdentity(processIdentity: identity),
            operation: operation)
        return target.processIdentity
    }

    private static func quitFailureHint(
        for outcome: DesktopActionOutcome,
        force: Bool) -> String?
    {
        if outcome.refusalReason == .targetUnavailable {
            return "Refresh the application target or inventory before retrying."
        }
        if outcome.retrySafety == .unsafe {
            return "Observe the application state before deciding whether to retry."
        }
        if !force,
           outcome.state == .suspectedNoop,
           outcome.retrySafety == .safe,
           outcome.escalation == .refreshTarget
        {
            return "Retry with force=true only if discarding unsaved changes is safe."
        }
        return switch outcome.escalation {
        case .correctRequest:
            "Correct the quit request before retrying."
        case .grantPermission:
            "Grant the required permission before retrying."
        case .refreshTarget:
            "Refresh the application target before retrying."
        case .reconnectSession:
            "Reconnect the transport session before retrying."
        case .updateRuntime:
            "Update the runtime before retrying."
        case .recoverSideEffect:
            "Recover any partial side effect before retrying."
        case .observeBeforeRetry:
            "Observe the application state before deciding whether to retry."
        case .none:
            nil
        }
    }

    func waitForRunningState(
        identifier: String,
        desiredState: Bool,
        timeout: TimeInterval) async throws -> Bool
    {
        let interval: TimeInterval = 0.1
        var elapsed: TimeInterval = 0

        while elapsed < timeout {
            let isRunning = try await self.service.isApplicationRunning(identifier: identifier)
            if isRunning == desiredState {
                return true
            }
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            // `try?` swallows CancellationError from sleep. Without this guard, later
            // sleeps return immediately and the loop hammers the application service
            // until its synthetic timeout budget is exhausted.
            guard !Task.isCancelled else {
                return false
            }
            elapsed += interval
        }

        let finalState = try await self.service.isApplicationRunning(identifier: identifier)
        return finalState == desiredState
    }

    private static func resolveOpenTarget(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PeekabooError.invalidInput("Open target must not be empty")
        }
        if let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty {
            return url
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let path = expanded.hasPrefix("/")
            ? expanded
            : NSString(string: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
        return URL(fileURLWithPath: path)
    }

    private static func validateExclusiveApplicationSelectors(_ request: AppToolRequest) throws {
        guard request.name == nil || request.bundleId == nil else {
            throw PeekabooError.invalidInput("Specify either 'name' or 'bundleId', not both")
        }
    }
}
