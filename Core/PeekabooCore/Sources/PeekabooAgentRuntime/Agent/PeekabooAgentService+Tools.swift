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

    func browserClient(forAgentSessionID sessionID: String) async throws -> any BrowserMCPClientProviding {
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
            guard self.services.executionHost == .local else {
                throw BrowserMCPConnectionError.receiptBindingUnsupported
            }
            return root
        }
        guard self.remoteBrowserEndingTasks[sessionID] == nil,
              !self.remoteBrowserCleanupDebt.contains(sessionID)
        else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        if let client = self.remoteBrowserClients[sessionID] {
            return client
        }
        if let pending = self.remoteBrowserOpeningTasks[sessionID] {
            return try await self.finishRemoteBrowserOpening(
                forAgentSessionID: sessionID,
                openingID: pending.id,
                task: pending.task)
        }
        guard self.remoteBrowserClients.count + self.remoteBrowserOpeningTasks.count <
            BrowserMCPAuthenticatedSessionPool.sessionCapacity
        else {
            throw BrowserMCPConnectionError.authenticatedSessionCapacityExceeded
        }
        let openingID = UUID()
        let task = Task { @MainActor () throws -> any BrowserMCPScopedSessionEnding in
            let scoped = try await opening.openBrowserMCPScopedSession(handoff: nil)
            guard scoped !== root else {
                throw BrowserMCPConnectionError.receiptBindingUnsupported
            }
            return scoped
        }
        self.remoteBrowserOpeningTasks[sessionID] = (openingID, task)
        return try await self.finishRemoteBrowserOpening(
            forAgentSessionID: sessionID,
            openingID: openingID,
            task: task)
    }

    private func finishRemoteBrowserOpening(
        forAgentSessionID sessionID: String,
        openingID: UUID,
        task: Task<any BrowserMCPScopedSessionEnding, any Error>) async throws
        -> any BrowserMCPClientProviding
    {
        let scoped: any BrowserMCPScopedSessionEnding
        do {
            scoped = try await task.value
        } catch {
            if self.remoteBrowserOpeningTasks[sessionID]?.id == openingID {
                self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
            }
            throw error
        }
        if self.remoteBrowserOpeningTasks[sessionID]?.id == openingID {
            self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
            self.remoteBrowserClients[sessionID] = scoped
            self.remoteBrowserCapabilities[sessionID] = BrowserToolCapabilitySession()
        }
        guard self.remoteBrowserEndingTasks[sessionID] == nil,
              !self.remoteBrowserCleanupDebt.contains(sessionID),
              let stored = self.remoteBrowserClients[sessionID],
              stored === scoped
        else {
            throw BrowserMCPConnectionError.sessionEnded
        }
        return stored
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
            let cleanupConfirmed = await ending.task.value
            guard !cleanupConfirmed else { return true }
            guard self.remoteBrowserEndingTasks[sessionID]?.id != ending.id else { return false }
            return await self.endRemoteBrowserClient(forAgentSessionID: sessionID)
        }
        let opening = self.remoteBrowserOpeningTasks[sessionID]
        guard opening != nil || self.remoteBrowserClients[sessionID] != nil else {
            self.remoteBrowserCapabilities.removeValue(forKey: sessionID)
            self.remoteBrowserCleanupDebt.remove(sessionID)
            return true
        }
        self.remoteBrowserCleanupDebt.insert(sessionID)
        let endingID = UUID()
        let task = Task { @MainActor in
            if let opening {
                do {
                    let scoped = try await opening.task.value
                    guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID else { return false }
                    if self.remoteBrowserOpeningTasks[sessionID]?.id == opening.id {
                        self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
                        self.remoteBrowserClients[sessionID] = scoped
                        self.remoteBrowserCapabilities[sessionID] = BrowserToolCapabilitySession()
                    }
                } catch {
                    if self.remoteBrowserEndingTasks[sessionID]?.id == endingID {
                        if self.remoteBrowserOpeningTasks[sessionID]?.id == opening.id {
                            self.remoteBrowserOpeningTasks.removeValue(forKey: sessionID)
                        }
                        self.remoteBrowserEndingTasks.removeValue(forKey: sessionID)
                        self.remoteBrowserCapabilities.removeValue(forKey: sessionID)
                        self.remoteBrowserCleanupDebt.remove(sessionID)
                        self.browserCleanupDebtPending = !self.remoteBrowserCleanupDebt.isEmpty
                    }
                    return true
                }
            }
            guard self.remoteBrowserEndingTasks[sessionID]?.id == endingID,
                  let client = self.remoteBrowserClients[sessionID]
            else { return false }
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
        self.remoteBrowserEndingTasks[sessionID] = (endingID, task)
        return await task.value
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
