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
            snapshotMutationCoordinator: self.snapshotMutationCoordinator,
            snapshotExecutionGate: self.snapshotExecutionGate,
            snapshotOwner: Self.toolConstructionSnapshotOwner,
            executionPolicy: Self.toolConstructionExecutionPolicy,
            capturePreflightRefusal: self.capturePreflightRefusal)
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
