//
//  PeekabooAgentService+Tools.swift
//  PeekabooCore
//

import Foundation
import MCP
import PeekabooAutomation
import Tachikoma
import TachikomaMCP

// MARK: - Tool Creation Extension

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func makeToolPreflightResult(
        for toolCall: AgentToolCall,
        context: ToolHandlingContext) -> AgentToolResult?
    {
        let tool = context.tool(named: toolCall.name)
        if let tool,
           let rejection = AgentToolArgumentValidator.rejection(
               tool: tool,
               arguments: AgentToolArguments(toolCall.arguments))
        {
            return Self.preflightResult(for: toolCall, response: rejection)
        }
        if let refusal = context.executionPolicy.rejection(
            toolName: toolCall.name,
            agentArguments: toolCall.arguments)
        {
            return Self.preflightResult(for: toolCall, response: refusal)
        }
        guard tool == nil else { return nil }
        return AgentToolResult(
            toolCallId: toolCall.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(string: "Tool '\(toolCall.name)' is not available in this context"),
            ]),
            isError: true)
    }

    private static func preflightResult(
        for toolCall: AgentToolCall,
        response: ToolResponse) -> AgentToolResult
    {
        let bridged = AgentToolMCPBridge.convert(response)
        if let failure = bridged.failure {
            var metadata = failure.metadata?.objectValue ?? [:]
            metadata["skipped"] = AnyAgentToolValue(bool: true)
            return AgentToolResult(
                toolCallId: toolCall.id,
                failure: AgentToolExecutionFailure(
                    message: failure.message,
                    content: failure.content,
                    structuredValue: failure.structuredValue,
                    metadata: AnyAgentToolValue(object: metadata)))
        }
        return AgentToolResult(
            toolCallId: toolCall.id,
            result: bridged.value,
            isError: true)
    }

    func makeToolContext() -> MCPToolContext {
        MCPToolContext(
            services: self.services,
            browser: Self.toolConstructionBrowserClient,
            snapshotMutationCoordinator: self.snapshotMutationCoordinator,
            snapshotExecutionGate: self.snapshotExecutionGate,
            snapshotOwner: Self.toolConstructionSnapshotOwner,
            executionPolicy: Self.toolConstructionExecutionPolicy,
            capturePreflightRefusal: self.capturePreflightRefusal)
    }

    func browserClient(
        forAgentSessionID sessionID: String,
        executionGeneration: UUID? = nil) async throws -> any BrowserMCPClientProviding
    {
        guard self.isCurrentAgentSessionExecution(
            sessionID: sessionID,
            executionGeneration: executionGeneration)
        else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        guard let root = self.services.browser as? BrowserMCPService,
              root.supportsAuthenticatedSessionBootstrap
        else {
            return try await self.remoteBrowserClient(forAgentSessionID: sessionID)
        }
        guard let scoped = root.authenticatedSession(named: "agent:\(sessionID)") else {
            throw BrowserMCPConnectionError.authenticatedSessionCapacityExceeded
        }
        return scoped
    }

    private func remoteBrowserClient(forAgentSessionID sessionID: String) async throws
        -> any BrowserMCPClientProviding
    {
        let root = self.services.browser
        guard let opening = root as? any BrowserMCPScopedSessionOpening else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        while true {
            try Task.checkCancellation()
            guard self.agentSessionDeletionTombstones[sessionID] == nil,
                  self.remoteBrowserEndingTasks[sessionID] == nil,
                  !self.remoteBrowserCleanupDebt.contains(sessionID)
            else {
                throw BrowserMCPConnectionError.sessionEnded
            }
            if let client = self.remoteBrowserClients[sessionID] {
                return client
            }
            if let pending = self.remoteBrowserOpeningTasks[sessionID] {
                switch pending {
                case let .inFlight(_, _, waiters):
                    return try await self.finishRemoteBrowserOpening(
                        forAgentSessionID: sessionID,
                        waiters: waiters)
                case .retryable:
                    return try await self.startRemoteBrowserOpening(
                        forAgentSessionID: sessionID,
                        openingID: UUID(),
                        opening: opening,
                        root: root)
                }
            }
            if let queuedID = self.remoteBrowserQueuedOpeningIDs[sessionID] {
                return try await self.finishRemoteBrowserQueuedOpening(
                    forAgentSessionID: sessionID,
                    queuedID: queuedID,
                    opening: opening,
                    root: root)
            }
            if self.remoteBrowserOpeningSessionID != nil {
                guard self.remoteBrowserSessionReservationCount < BrowserMCPAuthenticatedSessionPool.sessionCapacity
                else {
                    throw BrowserMCPConnectionError.authenticatedSessionCapacityExceeded
                }
                let queuedID = UUID()
                self.remoteBrowserQueuedOpeningIDs[sessionID] = queuedID
                return try await self.finishRemoteBrowserQueuedOpening(
                    forAgentSessionID: sessionID,
                    queuedID: queuedID,
                    opening: opening,
                    root: root)
            }
            guard self.remoteBrowserSessionReservationCount < BrowserMCPAuthenticatedSessionPool.sessionCapacity
            else {
                throw BrowserMCPConnectionError.authenticatedSessionCapacityExceeded
            }
            return try await self.startRemoteBrowserOpening(
                forAgentSessionID: sessionID,
                openingID: UUID(),
                opening: opening,
                root: root)
        }
    }

    private func finishRemoteBrowserQueuedOpenWait(
        forAgentSessionID sessionID: String,
        queuedID: UUID)
    {
        guard let waiterCount = self.remoteBrowserQueuedOpeningWaiterCounts[queuedID] else { return }
        if waiterCount > 1 {
            self.remoteBrowserQueuedOpeningWaiterCounts[queuedID] = waiterCount - 1
            return
        }
        self.remoteBrowserQueuedOpeningWaiterCounts.removeValue(forKey: queuedID)
        if self.remoteBrowserQueuedOpeningIDs[sessionID] == queuedID {
            self.remoteBrowserQueuedOpeningIDs.removeValue(forKey: sessionID)
        }
    }

    private var remoteBrowserSessionReservationCount: Int {
        self.remoteBrowserClients.count +
            self.remoteBrowserOpeningTasks.count +
            self.remoteBrowserQueuedOpeningIDs.count
    }

    private func finishRemoteBrowserQueuedOpening(
        forAgentSessionID sessionID: String,
        queuedID: UUID,
        opening: any BrowserMCPScopedSessionOpening,
        root: any BrowserMCPClientProviding) async throws -> any BrowserMCPClientProviding
    {
        self.remoteBrowserQueuedOpeningWaiterCounts[queuedID, default: 0] += 1
        defer {
            self.finishRemoteBrowserQueuedOpenWait(
                forAgentSessionID: sessionID,
                queuedID: queuedID)
        }
        while true {
            guard self.agentSessionDeletionTombstones[sessionID] == nil,
                  self.remoteBrowserEndingTasks[sessionID] == nil,
                  !self.remoteBrowserCleanupDebt.contains(sessionID)
            else {
                throw BrowserMCPConnectionError.sessionEnded
            }
            if let client = self.remoteBrowserClients[sessionID] {
                return client
            }
            if let pending = self.remoteBrowserOpeningTasks[sessionID] {
                switch pending {
                case let .inFlight(_, _, waiters):
                    return try await self.finishRemoteBrowserOpening(
                        forAgentSessionID: sessionID,
                        waiters: waiters)
                case .retryable:
                    return try await self.startRemoteBrowserOpening(
                        forAgentSessionID: sessionID,
                        openingID: UUID(),
                        opening: opening,
                        root: root)
                }
            }
            guard self.remoteBrowserQueuedOpeningIDs[sessionID] == queuedID else {
                throw BrowserMCPConnectionError.sessionEnded
            }
            if let ownerSessionID = self.remoteBrowserOpeningSessionID {
                do {
                    try await self.waitForRemoteBrowserOpening(ownerSessionID: ownerSessionID)
                } catch is CancellationError {
                    throw CancellationError()
                }
                continue
            }
            try Task.checkCancellation()
            self.remoteBrowserQueuedOpeningIDs.removeValue(forKey: sessionID)
            return try await self.startRemoteBrowserOpening(
                forAgentSessionID: sessionID,
                openingID: UUID(),
                opening: opening,
                root: root)
        }
    }

    private func startRemoteBrowserOpening(
        forAgentSessionID sessionID: String,
        openingID: UUID,
        opening: any BrowserMCPScopedSessionOpening,
        root: any BrowserMCPClientProviding) async throws -> any BrowserMCPClientProviding
    {
        try Task.checkCancellation()
        guard self.remoteBrowserOpeningSessionID == nil || self.remoteBrowserOpeningSessionID == sessionID else {
            throw BrowserMCPConnectionError.scopedSessionOpenRecoveryRequired
        }
        self.remoteBrowserOpeningSessionID = sessionID
        let waiters = AgentRemoteBrowserTaskWaiters<any BrowserMCPScopedSessionEnding>()
        let task = Task { @MainActor [weak self] () throws -> any BrowserMCPScopedSessionEnding in
            do {
                let scoped = try await opening.openBrowserMCPScopedSession(handoff: nil)
                guard scoped !== root else {
                    throw BrowserMCPConnectionError.receiptBindingUnsupported
                }
                self?.storeRemoteBrowserClient(
                    scoped,
                    forAgentSessionID: sessionID,
                    openingID: openingID)
                waiters.finish(.success(scoped))
                return scoped
            } catch {
                self?.recordRemoteBrowserOpeningFailure(
                    forAgentSessionID: sessionID,
                    openingID: openingID,
                    opening: opening)
                waiters.finish(.failure(error))
                throw error
            }
        }
        self.remoteBrowserOpeningTasks[sessionID] = .inFlight(
            id: openingID,
            task: task,
            waiters: waiters)
        return try await self.finishRemoteBrowserOpening(
            forAgentSessionID: sessionID,
            waiters: waiters)
    }

    private func waitForRemoteBrowserOpening(ownerSessionID: String) async throws {
        if let ending = self.remoteBrowserEndingTasks[ownerSessionID] {
            let cleanupConfirmed: Bool
            do {
                cleanupConfirmed = try await ending.waiters.value()
            } catch is CancellationError {
                throw CancellationError()
            }
            guard cleanupConfirmed else {
                throw BrowserMCPConnectionError.scopedSessionOpenRecoveryRequired
            }
            return
        }
        guard let pending = self.remoteBrowserOpeningTasks[ownerSessionID] else {
            if self.remoteBrowserOpeningSessionID == ownerSessionID {
                self.remoteBrowserOpeningSessionID = nil
            }
            return
        }
        switch pending {
        case .retryable:
            throw BrowserMCPConnectionError.scopedSessionOpenRecoveryRequired
        case let .inFlight(_, _, waiters):
            do {
                _ = try await self.finishRemoteBrowserOpening(
                    forAgentSessionID: ownerSessionID,
                    waiters: waiters)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The owner records its provider failure; the queued caller only needs the settled root state.
            }
            if self.remoteBrowserOpeningSessionID == ownerSessionID {
                throw BrowserMCPConnectionError.scopedSessionOpenRecoveryRequired
            }
        }
    }

    private func finishRemoteBrowserOpening(
        forAgentSessionID sessionID: String,
        waiters: AgentRemoteBrowserTaskWaiters<any BrowserMCPScopedSessionEnding>) async throws
        -> any BrowserMCPClientProviding
    {
        let scoped = try await waiters.value()
        guard self.agentSessionDeletionTombstones[sessionID] == nil,
              self.remoteBrowserEndingTasks[sessionID] == nil,
              !self.remoteBrowserCleanupDebt.contains(sessionID),
              let stored = self.remoteBrowserClients[sessionID],
              stored === scoped
        else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        return stored
    }

    private func recordRemoteBrowserOpeningFailure(
        forAgentSessionID sessionID: String,
        openingID: UUID,
        opening: any BrowserMCPScopedSessionOpening)
    {
        guard self.remoteBrowserOpeningTasks[sessionID]?.id == openingID else { return }
        if opening.browserMCPScopedSessionOpenAttemptRequiresRecovery {
            self.remoteBrowserOpeningTasks[sessionID] = .retryable(id: openingID)
        } else {
            self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
            if self.remoteBrowserOpeningSessionID == sessionID {
                self.remoteBrowserOpeningSessionID = nil
            }
        }
    }

    @discardableResult
    func endBrowserClient(forAgentSessionID sessionID: String) async -> Bool {
        if let root = self.services.browser as? BrowserMCPService {
            let directCleanupConfirmed = await root.endAuthenticatedSession(named: "agent:\(sessionID)")
            let pendingCleanupDrained = await root.retryPendingAuthenticatedSessionCleanup()
            self.browserCleanupDebtPending = !pendingCleanupDrained
            return (directCleanupConfirmed || pendingCleanupDrained) && pendingCleanupDrained
        }
        let cleanupConfirmed = await self.endRemoteBrowserClient(forAgentSessionID: sessionID)
        self.browserCleanupDebtPending = !self.remoteBrowserCleanupDebt.isEmpty
        return cleanupConfirmed
    }

    private func endRemoteBrowserClient(forAgentSessionID sessionID: String) async -> Bool {
        if let ending = self.remoteBrowserEndingTasks[sessionID] {
            let cleanupConfirmed: Bool
            do {
                cleanupConfirmed = try await ending.waiters.value()
            } catch {
                return false
            }
            guard !cleanupConfirmed else { return true }
            guard let replacement = self.remoteBrowserEndingTasks[sessionID],
                  replacement.id != ending.id
            else { return false }
            return await self.endRemoteBrowserClient(forAgentSessionID: sessionID)
        }
        let openingTask = self.remoteBrowserOpeningTasks[sessionID]
        let queuedOpeningID = self.remoteBrowserQueuedOpeningIDs[sessionID]
        guard openingTask != nil || queuedOpeningID != nil || self.remoteBrowserClients[sessionID] != nil else {
            self.remoteBrowserCapabilities.removeValue(forKey: sessionID)
            self.remoteBrowserCleanupDebt.remove(sessionID)
            return true
        }
        self.remoteBrowserCleanupDebt.insert(sessionID)
        self.browserCleanupDebtPending = true
        let endingID = UUID()
        let waiters = AgentRemoteBrowserTaskWaiters<Bool>()
        let task = Task { @MainActor in
            let cleanupConfirmed = await self.performRemoteBrowserEnd(
                forAgentSessionID: sessionID,
                endingID: endingID,
                openingTask: openingTask,
                queuedOpeningID: queuedOpeningID)
            waiters.finish(.success(cleanupConfirmed))
            return cleanupConfirmed
        }
        self.remoteBrowserEndingTasks[sessionID] = (endingID, task, waiters)
        do {
            return try await waiters.value()
        } catch {
            return false
        }
    }

    private func performRemoteBrowserEnd(
        forAgentSessionID sessionID: String,
        endingID: UUID,
        openingTask: AgentRemoteBrowserOpeningTask?,
        queuedOpeningID: UUID?) async -> Bool
    {
        if let queuedOpeningID,
           self.remoteBrowserQueuedOpeningIDs[sessionID] == queuedOpeningID
        {
            self.remoteBrowserQueuedOpeningIDs.removeValue(forKey: sessionID)
        }
        if let openingTask,
           await !(self.resolveRemoteBrowserOpeningForEnd(
               forAgentSessionID: sessionID,
               endingID: endingID,
               openingTask: openingTask))
        {
            guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
            self.remoteBrowserEndingTasks.removeValue(forKey: sessionID)
            self.browserCleanupDebtPending = true
            return false
        }
        guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
        guard let client = self.remoteBrowserClients[sessionID] else {
            self.remoteBrowserEndingTasks.removeValue(forKey: sessionID)
            self.remoteBrowserCapabilities.removeValue(forKey: sessionID)
            self.remoteBrowserCleanupDebt.remove(sessionID)
            self.browserCleanupDebtPending = !self.remoteBrowserCleanupDebt.isEmpty
            return true
        }
        let capabilities = self.remoteBrowserCapabilities[sessionID]
        await capabilities?.end()
        let cleanupConfirmed = await client.endBrowserMCPScopedSession()
        guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
        let generationCleanupConfirmed = cleanupConfirmed && self.remoteBrowserClients[sessionID] === client
        self.remoteBrowserEndingTasks.removeValue(forKey: sessionID)
        if generationCleanupConfirmed {
            self.remoteBrowserClients.removeValue(forKey: sessionID)
            self.remoteBrowserCapabilities.removeValue(forKey: sessionID)
            self.remoteBrowserCleanupDebt.remove(sessionID)
        }
        self.browserCleanupDebtPending = !self.remoteBrowserCleanupDebt.isEmpty
        return generationCleanupConfirmed
    }

    private func resolveRemoteBrowserOpeningForEnd(
        forAgentSessionID sessionID: String,
        endingID: UUID,
        openingTask: AgentRemoteBrowserOpeningTask) async -> Bool
    {
        guard let opening = self.services.browser as? any BrowserMCPScopedSessionOpening else { return true }
        let openingID = openingTask.id
        switch openingTask {
        case let .inFlight(_, task, _):
            do {
                let scoped = try await task.value
                guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
                self.storeRemoteBrowserClient(
                    scoped,
                    forAgentSessionID: sessionID,
                    openingID: openingID)
                return true
            } catch {
                guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
                self.recordRemoteBrowserOpeningFailure(
                    forAgentSessionID: sessionID,
                    openingID: openingID,
                    opening: opening)
                guard self.remoteBrowserOpeningTasks[sessionID]?.id == openingID else { return true }
            }
        case .retryable:
            break
        }

        do {
            let scoped = try await opening.openBrowserMCPScopedSession(handoff: nil)
            guard scoped !== self.services.browser else {
                self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
                if self.remoteBrowserOpeningSessionID == sessionID {
                    self.remoteBrowserOpeningSessionID = nil
                }
                return true
            }
            guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
            self.storeRemoteBrowserClient(
                scoped,
                forAgentSessionID: sessionID,
                openingID: openingID)
            return true
        } catch {
            guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
            self.recordRemoteBrowserOpeningFailure(
                forAgentSessionID: sessionID,
                openingID: openingID,
                opening: opening)
            return self.remoteBrowserOpeningTasks[sessionID]?.id != openingID
        }
    }

    private func storeRemoteBrowserClient(
        _ scoped: any BrowserMCPScopedSessionEnding,
        forAgentSessionID sessionID: String,
        openingID: UUID)
    {
        guard self.remoteBrowserOpeningTasks[sessionID]?.id == openingID else { return }
        self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
        if self.remoteBrowserOpeningSessionID == sessionID {
            self.remoteBrowserOpeningSessionID = nil
        }
        self.remoteBrowserClients[sessionID] = scoped
        self.remoteBrowserCapabilities[sessionID] = BrowserToolCapabilitySession()
    }

    @discardableResult
    func drainBrowserCleanupDebt() async -> Bool {
        let localCleanupDrained: Bool = if let root = self.services.browser as? BrowserMCPService {
            await root.retryPendingAuthenticatedSessionCleanup()
        } else {
            true
        }
        var remoteCleanupDrained = true
        for sessionID in self.remoteBrowserCleanupDebt.sorted() {
            let cleanupConfirmed = await self.endRemoteBrowserClient(forAgentSessionID: sessionID)
            remoteCleanupDrained = cleanupConfirmed && remoteCleanupDrained
        }
        remoteCleanupDrained = remoteCleanupDrained && self.remoteBrowserCleanupDebt.isEmpty
        let drained = localCleanupDrained && remoteCleanupDrained
        self.browserCleanupDebtPending = !drained
        if drained {
            self.recordDrainedAgentSessionBrowserCleanup()
        }
        return drained
    }

    @discardableResult
    func endEphemeralBrowserClientIfNeeded(_ context: SessionContext) async -> Bool {
        guard !context.isPersistent else { return await self.drainBrowserCleanupDebt() }
        let cleanupConfirmed = await self.endBrowserClient(forAgentSessionID: context.id)
        if !cleanupConfirmed {
            self.logger.error("Browser session cleanup remains pending for ephemeral session \(context.id)")
        }
        return cleanupConfirmed
    }

    func makeAgentTool(
        from tool: some MCPTool,
        name: String? = nil,
        description: String? = nil) -> AgentTool
    {
        let toolName = name ?? tool.name
        let context = self.makeToolContext()

        return AgentTool(
            name: toolName,
            description: description ?? tool.description,
            parameters: self.convertMCPSchemaToAgentSchema(tool.inputSchema),
            executeWithContext: { arguments, executionContext in
                let response = try await context.execute(
                    tool: tool,
                    arguments: makeToolArguments(from: arguments))
                return try await convertToolResponseToAgentToolExecutionValueAsync(
                    response,
                    executionContext: executionContext)
            })
    }

    // MARK: - Vision Tools

    public func createSeeTool() -> AgentTool {
        self.makeAgentTool(from: SeeTool(context: self.makeToolContext()))
    }

    public func createInspectUITool() -> AgentTool {
        self.makeAgentTool(from: InspectUITool(context: self.makeToolContext()))
    }

    public func createVerifyStateTool() -> AgentTool {
        self.makeAgentTool(from: VerifyStateTool(context: self.makeToolContext()))
    }

    public func createImageTool() -> AgentTool {
        self.makeAgentTool(from: ImageTool(context: self.makeToolContext()))
    }

    public func createCaptureTool() -> AgentTool {
        self.makeAgentTool(from: CaptureTool(context: self.makeToolContext()))
    }

    public func createBrowserTool() -> AgentTool {
        self.makeAgentTool(from: BrowserTool(context: self.makeToolContext()))
    }

    // MARK: - UI Automation Tools

    public func createClickTool() -> AgentTool {
        self.makeAgentTool(from: ClickTool(context: self.makeToolContext()))
    }

    public func createTypeTool() -> AgentTool {
        self.makeAgentTool(from: TypeTool(context: self.makeToolContext()))
    }

    public func createSetValueTool() -> AgentTool {
        self.makeAgentTool(from: SetValueTool(context: self.makeToolContext()))
    }

    public func createActionTool() -> AgentTool {
        self.makeAgentTool(from: ActionTool(context: self.makeToolContext()))
    }

    public func createScrollTool() -> AgentTool {
        self.makeAgentTool(from: ScrollTool(context: self.makeToolContext()))
    }

    public func createPressTool() -> AgentTool {
        self.makeAgentTool(from: PressTool(context: self.makeToolContext()))
    }

    public func createDragTool() -> AgentTool {
        self.makeAgentTool(from: DragTool(context: self.makeToolContext()))
    }

    public func createMoveTool() -> AgentTool {
        self.makeAgentTool(from: MoveTool(context: self.makeToolContext()))
    }

    // MARK: - Vision Tools

    public func createAnalyzeTool() -> AgentTool {
        self.makeAgentTool(from: AnalyzeTool())
    }

    // MARK: - Space Management

    public func createSpaceTool() -> AgentTool {
        self.makeAgentTool(from: SpaceTool(context: self.makeToolContext()))
    }

    // MARK: - Window Management

    public func createWindowTool() -> AgentTool {
        self.makeAgentTool(from: WindowTool(context: self.makeToolContext()))
    }

    // MARK: - Menu Interaction

    public func createMenuTool() -> AgentTool {
        self.makeAgentTool(from: MenuTool(context: self.makeToolContext()))
    }

    // MARK: - Dialog Handling

    public func createDialogTool() -> AgentTool {
        self.makeAgentTool(from: DialogTool(context: self.makeToolContext()))
    }

    // MARK: - Dock Management

    public func createDockTool() -> AgentTool {
        self.makeAgentTool(from: DockTool(context: self.makeToolContext()))
    }

    // MARK: - Timing Control

    public func createSleepTool() -> AgentTool {
        self.makeAgentTool(from: SleepTool())
    }

    // MARK: - Clipboard

    public func createClipboardTool() -> AgentTool {
        self.makeAgentTool(from: ClipboardTool(context: self.makeToolContext()))
    }

    // MARK: - Paste

    public func createPasteTool() -> AgentTool {
        self.makeAgentTool(from: PasteTool(context: self.makeToolContext()))
    }

    // MARK: - Permissions Check

    public func createPermissionsTool() -> AgentTool {
        self.makeAgentTool(from: PermissionsTool(context: self.makeToolContext()))
    }

    // MARK: - Full App Management

    public func createAppTool() -> AgentTool {
        self.makeAgentTool(from: AppTool(context: self.makeToolContext()))
    }

    // MARK: - Shell Tool

    public func createShellTool() -> AgentTool {
        self.makeAgentTool(from: ShellTool())
    }

    // MARK: - Completion Tools

    public func createDoneTool() -> AgentTool {
        AgentTool(
            name: "done",
            description: "Indicate completion after any two-phase structured verification debt is cleared",
            parameters: AgentToolParameters(
                properties: [
                    "message": AgentToolParameterProperty(
                        name: "message",
                        type: .string,
                        description: "Completion message"),
                ],
                required: []),
            execute: { arguments in
                let message: String = if let messageArg = arguments["message"],
                                         let msg = messageArg.stringValue
                {
                    msg
                } else {
                    "Task completed successfully"
                }
                return AnyAgentToolValue(string: "\(AgentDisplayTokens.Status.success) \(message)")
            })
    }

    public func createNeedInfoTool() -> AgentTool {
        AgentTool(
            name: "need_info",
            description: "Request additional information from the user",
            parameters: AgentToolParameters(
                properties: [
                    "question": AgentToolParameterProperty(
                        name: "question",
                        type: .string,
                        description: "Question to ask the user"),
                ],
                required: ["question"]),
            execute: { arguments in
                guard let questionArg = arguments["question"],
                      let question = questionArg.stringValue
                else {
                    return AnyAgentToolValue(string: "Please provide a question")
                }
                return AnyAgentToolValue(string: "\(AgentDisplayTokens.Status.info) Need more information: \(question)")
            })
    }
}
