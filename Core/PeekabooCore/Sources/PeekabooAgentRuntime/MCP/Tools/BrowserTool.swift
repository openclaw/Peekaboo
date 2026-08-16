import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP

public struct BrowserTool: MCPTool {
    private let client: any BrowserMCPClientProviding
    private let connectionPolicy: BrowserMCPExecutionConnectionPolicy
    private let executionPolicy: MCPToolExecutionPolicy

    public let name = "browser"
    public let description = """
    Controls and inspects Chrome web pages through Chrome DevTools MCP.

    Use this for browser page content: DOM/accessibility snapshots, web forms, navigation,
    console messages, network requests, screenshots, and performance traces. Use Peekaboo's
    native tools for macOS chrome, menus, dialogs, permissions, and non-browser applications.

    Chrome DevTools MCP requires Chrome 144+ with remote debugging enabled at
    chrome://inspect/#remote-debugging. The user must accept Chrome's remote debugging prompt.
    Peekaboo starts chrome-devtools-mcp with usage statistics and CrUX lookups disabled.
    Background-only Agent sessions reuse an existing exact connection and never auto-connect;
    ask the user to connect explicitly when status reports no live connection receipt.
    """

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(
                    description: """
                    Browser action to perform. Use `status` before connecting. Use `connect` after the user
                    enables remote debugging and accepts Chrome's prompt. Connect is a foreground-consent action
                    and is refused by background-only contexts.
                    """,
                    enum: BrowserAction.allCases.map(\.rawValue)),
                "channel": SchemaBuilder.string(
                    description: """
                    Chrome channel selected by explicit connect. Defaults to the running Chrome channel, then stable.
                    Other actions never auto-connect in a background-only context.
                    """,
                    enum: BrowserMCPChannel.allCases.map(\.rawValue)),
                "browser_url": SchemaBuilder.string(description: """
                Exact loopback DevTools HTTP endpoint for connect, for example http://127.0.0.1:9222.
                Peekaboo resolves and pins its browser WebSocket identity. Required when multiple Chrome
                processes share one channel.
                """),
                "page_id": SchemaBuilder.integer(description: """
                Chrome DevTools page ID. Required for every page-scoped action so concurrent clients cannot
                redirect one another by changing the shared selected page. Use list_pages to discover IDs.
                """, minimum: 0),
                "url": SchemaBuilder.string(description: "URL for navigate/new_page."),
                "navigation_type": SchemaBuilder.string(
                    description: "Navigation type for navigate.",
                    enum: ["url", "back", "forward", "reload"]),
                "uid": SchemaBuilder.string(description: """
                Element uid from the latest browser snapshot. Required for element actions, including type and
                press_key so keyboard input cannot inherit an unrelated focused element.
                """),
                "to_uid": SchemaBuilder.string(description: "Drop target uid for drag."),
                "text": SchemaBuilder.string(description: "Text for type or wait_for."),
                "value": SchemaBuilder.string(description: "Value for fill."),
                "key": SchemaBuilder.string(description: "Key or key combination for press_key."),
                "submit_key": SchemaBuilder.string(description: "Optional key pressed after type_text."),
                "dialog_action": SchemaBuilder.string(
                    description: "Browser dialog action.",
                    enum: ["accept", "dismiss"]),
                "include_snapshot": SchemaBuilder.boolean(
                    description: "Ask Chrome DevTools MCP to include a fresh snapshot when supported.",
                    default: false),
                "double": SchemaBuilder.boolean(description: "Double-click for click.", default: false),
                "bring_to_front": SchemaBuilder.boolean(description: "Bring selected page to front.", default: false),
                "background": SchemaBuilder.boolean(description: "Open new page in the background.", default: true),
                "timeout": SchemaBuilder.integer(description: "Timeout in milliseconds for navigation/waits."),
                "page_size": SchemaBuilder.integer(description: "Pagination size for console/network listings."),
                "page_index": SchemaBuilder.integer(description: "Zero-based page index for console/network listings."),
                "types": SchemaBuilder.array(
                    items: SchemaBuilder.string(),
                    description: "Console message types to include."),
                "resource_types": SchemaBuilder.array(
                    items: SchemaBuilder.string(),
                    description: "Network resource types to include."),
                "include_preserved": SchemaBuilder.boolean(
                    description: "Include preserved console/network data from recent navigations.",
                    default: false),
                "message_id": SchemaBuilder.integer(description: "Console message ID for get_console_message."),
                "request_id": SchemaBuilder.integer(description: "Network request ID for get_network_request."),
                "request_file_path": SchemaBuilder.string(description: "Path for saving a network request body."),
                "response_file_path": SchemaBuilder.string(description: "Path for saving a network response body."),
                "path": SchemaBuilder.string(description: "Absolute input file for upload_file; output path for " +
                    "snapshots, screenshots, or traces. Uploads accept current-user regular files up to 100 MiB."),
                "format": SchemaBuilder.string(
                    description: "Screenshot format.",
                    enum: ["png", "jpeg", "webp"]),
                "quality": SchemaBuilder.integer(description: "Screenshot quality for jpeg/webp."),
                "full_page": SchemaBuilder.boolean(description: "Capture a full-page screenshot.", default: false),
                "trace_action": SchemaBuilder.string(
                    description: "Performance trace operation.",
                    enum: ["start", "stop", "analyze"]),
                "reload": SchemaBuilder.boolean(description: "Reload page when starting a trace.", default: true),
                "auto_stop": SchemaBuilder.boolean(description: "Auto-stop trace after capture.", default: true),
                "insight_set_id": SchemaBuilder.string(description: "Insight set id from trace summary."),
                "insight_name": SchemaBuilder.string(description: "Insight name from trace summary."),
                "mcp_tool": SchemaBuilder.string(
                    description: "Advanced: audited Chrome DevTools MCP v1.6.0 tool name for call."),
                "mcp_args_json": SchemaBuilder.string(description: "Advanced: JSON object args for raw MCP call. " +
                    "Page-targeted tools require top-level page_id; nested pageId cannot select the page."),
            ],
            required: ["action"])
    }

    public init(context: MCPToolContext = .shared, client: (any BrowserMCPClientProviding)? = nil) {
        self.client = client ?? context.browser
        self.executionPolicy = context.executionPolicy
        self.connectionPolicy = context.executionPolicy == .backgroundOnly
            ? .requireExistingLiveReceipt
            : .allowAutoConnect
    }

    public init(
        client: any BrowserMCPClientProviding,
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly)
    {
        self.client = client
        self.executionPolicy = executionPolicy
        self.connectionPolicy = executionPolicy == .backgroundOnly
            ? .requireExistingLiveReceipt
            : .allowAutoConnect
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        if let rejection = self.executionPolicy.rejection(toolName: self.name, arguments: arguments) {
            return rejection
        }
        guard let actionName = arguments.getString("action"),
              let action = BrowserAction(rawValue: actionName)
        else {
            return ToolResponse.error("Missing or invalid required parameter: action")
        }

        let channel: BrowserMCPChannel?
        if let rawChannel = arguments.getString("channel") {
            guard let parsedChannel = BrowserMCPChannel(rawValue: rawChannel) else {
                return ToolResponse.error("Invalid browser channel: \(rawChannel)")
            }
            channel = parsedChannel
        } else {
            channel = nil
        }
        let browserURL = arguments.getString("browser_url")
        if browserURL != nil, action != .connect {
            return ToolResponse.error("browser_url is accepted only by the connect action")
        }

        do {
            switch action {
            case .status:
                return try await self.statusResponse(channel: channel)
            case .connect:
                guard let resultClient = self.client as? any BrowserMCPConnectionResultProviding else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .operationUnsupported,
                        message: "Browser connect requires a provider that reports canonical action outcomes.",
                        hint: "Update the runtime host before retrying browser connect.")
                }
                let result = try await resultClient.connectWithOutcome(
                    channel: channel,
                    browserURL: browserURL)
                let outcome = try Self.validatedConnectOutcome(result.outcome)
                return try self.formatStatus(
                    result.payload,
                    headline: "Connected Chrome DevTools MCP",
                    outcome: outcome)
            case .disconnect:
                await self.client.disconnect()
                return ToolResponse.text("Disconnected Chrome DevTools MCP.")
            case .call:
                return try await self.executeRawCall(arguments: arguments, channel: channel)
            default:
                let calls = try BrowserMCPCallMapper.mapSequence(action: action, arguments: arguments)
                return try await self.executeSequence(calls, channel: channel)
            }
        } catch let error as BrowserToolError {
            return ToolResponse.error(error.localizedDescription)
        } catch let error as MCPToolArgumentValueError {
            return ToolResponse.error(error.localizedDescription)
        } catch let error as BrowserMCPUploadStagingError {
            return ToolResponse.error(error.localizedDescription)
        } catch let failure as DesktopActionFailure {
            return try MCPToolResponseMetadataProjector.errorResponse(
                for: failure,
                invalidatedSnapshotID: nil)
        } catch {
            return ToolResponse.error(Self.permissionHelp(error: error))
        }
    }

    @MainActor
    private func statusResponse(channel: BrowserMCPChannel?) async throws -> ToolResponse {
        let status = await self.client.status(channel: channel)
        return try self.formatStatus(status, headline: "Chrome DevTools MCP Status")
    }

    private func executeRawCall(arguments: ToolArguments, channel: BrowserMCPChannel?) async throws -> ToolResponse {
        try await self.executeSequence(
            [BrowserMCPCallMapper.mapRawCall(arguments: arguments)],
            channel: channel)
    }

    @MainActor
    private func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let semantics = Self.sequenceSemantics(calls)
        guard let resultClient = self.client as? any BrowserMCPActionResultProviding else {
            if self.connectionPolicy == .requireExistingLiveReceipt {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: "The browser provider cannot enforce existing-connection-only execution.",
                    hint: "Update the runtime host before retrying this background-only browser action.")
            }
            guard semantics == .readOnly else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: "Browser mutations require a provider that reports canonical action outcomes.",
                    hint: "Update the runtime host before retrying this browser mutation.")
            }
            return try await self.client.executeSequence(calls, channel: channel)
        }
        let result = try await resultClient.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: self.connectionPolicy)
        let outcome = try Self.validatedOutcome(
            result.outcome,
            payloadIsError: result.payload.isError,
            semantics: semantics)
        let executionMetadata = BrowserMCPExecutionEvidence.split(result.payload.meta)
        var providerFields = MCPToolResponseMetadataProjector.providerFields(
            from: executionMetadata.providerMeta)
        if let evidence = executionMetadata.evidence {
            providerFields[BrowserMCPExecutionEvidence.metadataKey] = evidence
        }
        return try ToolResponse(
            content: result.payload.content,
            isError: result.payload.isError,
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: providerFields,
                outcome: outcome))
    }

    private static func sequenceSemantics(
        _ calls: [BrowserMCPMappedCall]) -> BrowserMCPPageRoutingContract.ActionSemantics
    {
        guard !calls.isEmpty else { return .mutating }
        return calls.allSatisfy { call in
            BrowserMCPPageRoutingContract.actionSemantics(
                for: call.toolName,
                arguments: call.arguments) == .readOnly
        } ? .readOnly : .mutating
    }

    private static func validatedOutcome(
        _ outcome: DesktopActionOutcome?,
        payloadIsError: Bool,
        semantics: BrowserMCPPageRoutingContract.ActionSemantics) throws -> DesktopActionOutcome?
    {
        guard let outcome else {
            guard semantics == .readOnly else {
                throw DesktopActionFailure.indeterminate(
                    delivery: .init(mechanism: .browserProtocol, mode: .background),
                    evidence: .completionUnknown,
                    message: "Browser mutation returned without a canonical action outcome.",
                    hint: "Observe the browser before retrying and update the runtime host.")
            }
            return nil
        }

        let isSuccessCompatible = outcome.isAccepted(by: .confirmedOrDispatched)
        if !payloadIsError, !isSuccessCompatible {
            guard let failure = DesktopActionFailure(
                outcome: outcome,
                message: "Browser mutation did not return a successful canonical outcome.",
                hint: "Follow the canonical outcome metadata before deciding whether to retry.")
            else {
                preconditionFailure("A browser non-success outcome must construct a failure")
            }
            throw failure
        }
        if payloadIsError, isSuccessCompatible {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "Browser provider returned an error payload with a successful canonical outcome.",
                hint: "Observe the browser before retrying and update the runtime host.")
        }
        return outcome
    }

    private static func validatedConnectOutcome(_ outcome: DesktopActionOutcome?) throws -> DesktopActionOutcome {
        guard let outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Browser connect returned without a canonical action outcome.",
                hint: "Check browser status before deciding whether to reconnect.")
        }
        switch outcome.state {
        case .confirmedNoChange:
            guard outcome.delivery == nil,
                  outcome.dispatchState == .none
            else { break }
            return outcome
        case .dispatchedUnverified:
            guard outcome.delivery == .init(mechanism: .browserProtocol, mode: .foreground),
                  outcome.dispatchState.unitCount == .one
            else { break }
            return outcome
        case .confirmedChange, .partial, .suspectedNoop, .refused, .indeterminate:
            break
        }
        throw DesktopActionFailure.indeterminate(
            route: outcome.route,
            delivery: outcome.delivery,
            evidence: .completionUnknown,
            unitCount: outcome.dispatchState.unitCount,
            message: "Browser connect returned contradictory canonical action semantics.",
            hint: "Check browser status before deciding whether to reconnect and update the runtime host.")
    }

    private func formatStatus(
        _ status: BrowserMCPStatus,
        headline: String,
        outcome: DesktopActionOutcome? = nil) throws -> ToolResponse
    {
        var lines = [headline, ""]
        lines.append("Connected: \(status.isConnected ? "yes" : "no")")
        lines.append("Tools: \(status.toolCount)")

        if status.detectedBrowsers.isEmpty {
            lines.append("Detected Chrome: none")
        } else {
            lines.append("Detected Chrome:")
            for browser in status.detectedBrowsers {
                let version = browser.version.map { " \($0)" } ?? ""
                lines.append(
                    "- \(browser.name)\(version) [\(browser.channel.rawValue)] pid=\(browser.processIdentifier)")
            }
        }

        if let error = status.error, !error.isEmpty {
            lines.append("Error: \(error)")
        }

        if let receipt = status.connectionReceipt {
            lines.append("Exact connection:")
            if let processIdentifier = receipt.processIdentifier,
               let processStartIdentity = receipt.processStartIdentity
            {
                lines.append("- pid=\(processIdentifier) generation=\(processStartIdentity)")
            }
            if let browserURL = receipt.browserURL,
               let browserID = receipt.devToolsBrowserID
            {
                lines.append("- endpoint=\(browserURL) browser_id=\(browserID)")
            }
        }

        if !status.isConnected {
            lines.append("")
            lines.append(contentsOf: Self.permissionInstructions())
        }

        return try ToolResponse.text(
            lines.joined(separator: "\n"),
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: self.statusMetaFields(status),
                outcome: outcome))
    }

    private func statusMetaFields(_ status: BrowserMCPStatus) -> [String: Value] {
        var meta: [String: Value] = [
            "connected": .bool(status.isConnected),
            "tool_count": .int(status.toolCount),
            "browser_count": .int(status.detectedBrowsers.count),
            "channels": .array(status.detectedBrowsers.map { .string($0.channel.rawValue) }),
        ]
        if let receipt = status.connectionReceipt {
            var receiptMeta: [String: Value] = [:]
            if let channel = receipt.channel {
                receiptMeta["channel"] = .string(channel.rawValue)
            }
            if let processIdentifier = receipt.processIdentifier {
                receiptMeta["pid"] = .int(Int(processIdentifier))
            }
            if let processStartIdentity = receipt.processStartIdentity {
                receiptMeta["process_start_identity_decimal"] = .string(String(processStartIdentity))
            }
            if let bundleIdentifier = receipt.bundleIdentifier {
                receiptMeta["bundle_id"] = .string(bundleIdentifier)
            }
            if let browserURL = receipt.browserURL {
                receiptMeta["browser_url"] = .string(browserURL)
            }
            if let browserID = receipt.devToolsBrowserID {
                receiptMeta["browser_id"] = .string(browserID)
            }
            if let browserVersion = receipt.browserVersion {
                receiptMeta["browser_version"] = .string(browserVersion)
            }
            if let protocolVersion = receipt.protocolVersion {
                receiptMeta["protocol_version"] = .string(protocolVersion)
            }
            meta["connection_receipt"] = .object(receiptMeta)
        }
        return meta
    }

    private static func permissionHelp(error: any Error) -> String {
        var lines = ["Chrome DevTools MCP failed: \(error.localizedDescription)", ""]
        lines.append(contentsOf: self.permissionInstructions())
        return lines.joined(separator: "\n")
    }

    private static func permissionInstructions() -> [String] {
        [
            "To enable browser control:",
            "1. Open Chrome 144+.",
            "2. Visit chrome://inspect/#remote-debugging.",
            "3. Enable remote debugging for this profile.",
            "4. Run browser { \"action\": \"connect\" }.",
            "5. Accept Chrome's remote debugging permission prompt.",
            "If multiple Chrome processes share a channel, pass browser_url for one exact loopback DevTools port.",
        ]
    }
}

extension BrowserTool: MCPToolArgumentSemanticValidating {
    func validateArgumentSemantics(_ arguments: ToolArguments) throws {
        guard let actionName = arguments.getString("action"),
              let action = BrowserAction(rawValue: actionName)
        else {
            throw BrowserToolError.missingParameter("action")
        }

        switch action {
        case .status, .connect, .disconnect:
            return
        case .call:
            _ = try BrowserMCPCallMapper.mapRawCall(arguments: arguments)
        default:
            _ = try BrowserMCPCallMapper.mapSequence(action: action, arguments: arguments)
        }
    }
}

private enum BrowserToolError: LocalizedError {
    case invalidJSONArguments
    case missingParameter(String)
    case invalidAction(String)
    case invalidPageID
    case unsupportedRawTool(String)
    case selectedPageRoutingUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSONArguments:
            "mcp_args_json must be a JSON object"
        case let .missingParameter(name):
            "Missing required parameter: \(name)"
        case let .invalidAction(action):
            "Invalid browser action: \(action)"
        case .invalidPageID:
            "page_id must be a non-negative integer from list_pages"
        case let .unsupportedRawTool(toolName):
            "Unsupported raw Chrome DevTools MCP tool '\(toolName)' for the audited " +
                "v\(BrowserMCPPageRoutingContract.dependencyVersion) contract"
        case let .selectedPageRoutingUnsupported(toolName):
            "Raw Chrome DevTools MCP tool '\(toolName)' depends on shared selected-page state and is unsupported " +
                "until upstream adds explicit pageId routing"
        }
    }
}

public enum BrowserAction: String, CaseIterable, Sendable {
    case status
    case connect
    case disconnect
    case listPages = "list_pages"
    case selectPage = "select_page"
    case closePage = "close_page"
    case newPage = "new_page"
    case navigate
    case waitFor = "wait_for"
    case snapshot
    case click
    case fill
    case fillForm = "fill_form"
    case drag
    case hover
    case type
    case pressKey = "press_key"
    case uploadFile = "upload_file"
    case handleDialog = "handle_dialog"
    case console
    case network
    case screenshot
    case performanceTrace = "performance_trace"
    case call
}

public struct BrowserMCPMappedCall {
    public let toolName: String
    public let arguments: [String: Any]

    public init(toolName: String, arguments: [String: Any]) {
        self.toolName = toolName
        self.arguments = arguments
    }
}

public enum BrowserMCPCallMapper {
    static func actionSemantics(
        action: BrowserAction,
        arguments: ToolArguments) -> BrowserMCPPageRoutingContract.ActionSemantics
    {
        let calls: [BrowserMCPMappedCall]?
        switch action {
        case .status, .disconnect:
            return .readOnly
        case .connect:
            return .mutating
        case .call:
            calls = try? [self.mapRawCall(arguments: arguments)]
        default:
            calls = try? self.mapSequence(action: action, arguments: arguments)
        }
        guard let calls else {
            return self.fallbackActionSemantics(action: action, arguments: arguments)
        }
        return calls.contains { call in
            BrowserMCPPageRoutingContract.actionSemantics(
                for: call.toolName,
                arguments: call.arguments) != .readOnly
        } ? .mutating : .readOnly
    }

    private static func fallbackActionSemantics(
        action: BrowserAction,
        arguments: ToolArguments) -> BrowserMCPPageRoutingContract.ActionSemantics
    {
        switch action {
        case .status, .disconnect, .listPages, .waitFor, .snapshot, .console, .network, .screenshot:
            .readOnly
        case .connect:
            .mutating
        case .selectPage:
            arguments.getBool("bring_to_front") == true ? .mutating : .readOnly
        case .performanceTrace:
            (arguments.getString("trace_action") ?? "start") == "start" && arguments.getBool("reload") != false
                ? .mutating
                : .readOnly
        case .call:
            // Invalid/unknown raw calls are rejected by the audited catalog before provider dispatch.
            .readOnly
        case .closePage, .newPage, .navigate, .click, .fill, .fillForm, .drag, .hover, .type, .pressKey,
             .uploadFile, .handleDialog:
            .mutating
        }
    }

    static func mapRawCall(arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        guard let toolName = arguments.getString("mcp_tool"), !toolName.isEmpty else {
            throw BrowserToolError.missingParameter("mcp_tool")
        }
        guard let routing = BrowserMCPPageRoutingContract.routing(for: toolName) else {
            throw BrowserToolError.unsupportedRawTool(toolName)
        }
        if routing == .blockedSelectedPage {
            throw BrowserToolError.selectedPageRoutingUnsupported(toolName)
        }
        var rawArguments = try self.parseJSONObject(arguments.getString("mcp_args_json") ?? "{}")
        if routing == .pageTargeted || arguments.getValue(for: "page_id") != nil {
            rawArguments["pageId"] = try self.requiredPageID(arguments)
        }
        return BrowserMCPMappedCall(toolName: toolName, arguments: rawArguments)
    }

    public static func map(action: BrowserAction, arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        guard action != .type, action != .pressKey else {
            throw BrowserToolError.invalidAction("\(action.rawValue) requires an exact atomic call sequence")
        }
        return try self.mapSingle(action: action, arguments: arguments)
    }

    public static func mapSequence(
        action: BrowserAction,
        arguments: ToolArguments) throws -> [BrowserMCPMappedCall]
    {
        let calls: [BrowserMCPMappedCall] = switch action {
        case .type, .pressKey:
            try [
                BrowserMCPMappedCall(toolName: "click", arguments: [
                    "uid": self.requiredString("uid", arguments),
                    "dblClick": false,
                    "includeSnapshot": false,
                ]),
                self.mapSingle(action: action, arguments: arguments),
            ]
        default:
            try [self.mapSingle(action: action, arguments: arguments)]
        }
        guard self.requiresPageID(action) else { return calls }
        let pageID = try self.requiredPageID(arguments)
        return calls.map { call in
            var mappedArguments = call.arguments
            mappedArguments["pageId"] = pageID
            return BrowserMCPMappedCall(toolName: call.toolName, arguments: mappedArguments)
        }
    }

    private static func mapSingle(action: BrowserAction, arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        let call: BrowserMCPMappedCall = switch action {
        case .status, .connect, .disconnect, .call:
            throw BrowserToolError.invalidAction(action.rawValue)
        case .listPages, .selectPage, .closePage, .newPage, .navigate, .waitFor:
            try self.pageCall(action: action, arguments: arguments)
        case .snapshot, .click, .fill, .fillForm, .drag, .hover, .type, .pressKey, .uploadFile, .handleDialog,
             .screenshot:
            try self.interactionCall(action: action, arguments: arguments)
        case .console, .network, .performanceTrace:
            try self.diagnosticsCall(action: action, arguments: arguments)
        }

        guard self.requiresPageID(action) else { return call }
        var mappedArguments = call.arguments
        mappedArguments["pageId"] = try self.requiredPageID(arguments)
        return BrowserMCPMappedCall(toolName: call.toolName, arguments: mappedArguments)
    }

    private static func requiresPageID(_ action: BrowserAction) -> Bool {
        switch action {
        case .navigate, .waitFor, .snapshot, .click, .fill, .fillForm, .drag, .hover, .type, .pressKey,
             .uploadFile, .handleDialog, .console, .network, .screenshot, .performanceTrace:
            true
        case .status, .connect, .disconnect, .listPages, .selectPage, .closePage, .newPage, .call:
            false
        }
    }

    private static func pageCall(action: BrowserAction, arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        switch action {
        case .listPages:
            return BrowserMCPMappedCall(toolName: "list_pages", arguments: [:])
        case .selectPage:
            return try BrowserMCPMappedCall(toolName: "select_page", arguments: [
                "pageId": self.requiredPageID(arguments),
                "bringToFront": arguments.getBool("bring_to_front") ?? false,
            ])
        case .closePage:
            return try BrowserMCPMappedCall(toolName: "close_page", arguments: [
                "pageId": self.requiredPageID(arguments),
            ])
        case .newPage:
            return try BrowserMCPMappedCall(toolName: "new_page", arguments: self.compact([
                "url": self.requiredURL(arguments),
                "background": arguments.getBool("background") ?? true,
                "timeout": arguments.validatedInt("timeout"),
            ]))
        case .navigate:
            return try BrowserMCPMappedCall(
                toolName: "navigate_page",
                arguments: self.navigateArguments(arguments))
        case .waitFor:
            let text: [String] = if let values = arguments.getStringArray("text") {
                values
            } else {
                try [self.requiredString("text", arguments)]
            }
            return try BrowserMCPMappedCall(toolName: "wait_for", arguments: self.compact([
                "text": text,
                "timeout": arguments.validatedInt("timeout"),
            ]))
        default:
            throw BrowserToolError.invalidAction(action.rawValue)
        }
    }

    private static func interactionCall(
        action: BrowserAction,
        arguments: ToolArguments) throws -> BrowserMCPMappedCall
    {
        switch action {
        case .snapshot:
            return BrowserMCPMappedCall(toolName: "take_snapshot", arguments: self.compact([
                "filePath": arguments.getString("path"),
            ]))
        case .click:
            return try BrowserMCPMappedCall(toolName: "click", arguments: self.compact([
                "uid": self.requiredString("uid", arguments),
                "dblClick": arguments.getBool("double") ?? false,
                "includeSnapshot": arguments.getBool("include_snapshot") ?? false,
            ]))
        case .fill:
            return try BrowserMCPMappedCall(toolName: "fill", arguments: self.compact([
                "uid": self.requiredString("uid", arguments),
                "value": self.requiredString("value", arguments),
                "includeSnapshot": arguments.getBool("include_snapshot") ?? false,
            ]))
        case .fillForm:
            return try BrowserMCPMappedCall(toolName: "fill_form", arguments: self.jsonObject(
                "mcp_args_json",
                arguments,
                fallbackError: "fill_form requires mcp_args_json with Chrome DevTools MCP form elements"))
        case .drag:
            return try BrowserMCPMappedCall(toolName: "drag", arguments: self.compact([
                "from_uid": self.requiredString("uid", arguments),
                "to_uid": self.requiredString("to_uid", arguments),
                "includeSnapshot": arguments.getBool("include_snapshot") ?? false,
            ]))
        case .hover:
            return try BrowserMCPMappedCall(toolName: "hover", arguments: self.compact([
                "uid": self.requiredString("uid", arguments),
                "includeSnapshot": arguments.getBool("include_snapshot") ?? false,
            ]))
        case .type:
            return try BrowserMCPMappedCall(toolName: "type_text", arguments: self.compact([
                "text": self.requiredString("text", arguments),
                "submitKey": arguments.getString("submit_key"),
            ]))
        case .pressKey:
            return try BrowserMCPMappedCall(toolName: "press_key", arguments: self.compact([
                "key": self.requiredString("key", arguments),
                "includeSnapshot": arguments.getBool("include_snapshot") ?? false,
            ]))
        case .uploadFile:
            return try BrowserMCPMappedCall(toolName: "upload_file", arguments: self.compact([
                "uid": self.requiredString("uid", arguments),
                "filePath": self.requiredString("path", arguments),
                "includeSnapshot": arguments.getBool("include_snapshot") ?? false,
            ]))
        case .handleDialog:
            return BrowserMCPMappedCall(toolName: "handle_dialog", arguments: self.compact([
                "action": arguments.getString("dialog_action") ?? "accept",
                "promptText": arguments.getString("text"),
            ]))
        case .screenshot:
            return try BrowserMCPMappedCall(toolName: "take_screenshot", arguments: self.compact([
                "format": arguments.getString("format") ?? "png",
                "quality": arguments.validatedInt("quality"),
                "uid": arguments.getString("uid"),
                "fullPage": arguments.getBool("full_page"),
                "filePath": arguments.getString("path"),
            ]))
        default:
            throw BrowserToolError.invalidAction(action.rawValue)
        }
    }

    private static func diagnosticsCall(
        action: BrowserAction,
        arguments: ToolArguments) throws -> BrowserMCPMappedCall
    {
        switch action {
        case .console:
            return try self.consoleCall(arguments)
        case .network:
            return try self.networkCall(arguments)
        case .performanceTrace:
            return try self.performanceCall(arguments)
        default:
            throw BrowserToolError.invalidAction(action.rawValue)
        }
    }

    private static func navigateArguments(_ arguments: ToolArguments) throws -> [String: Any] {
        let url = self.url(arguments)
        let type = arguments.getString("navigation_type") ?? (url == nil ? "reload" : "url")
        return try self.compact([
            "type": type,
            "url": url,
            "timeout": arguments.validatedInt("timeout"),
        ])
    }

    private static func consoleCall(_ arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        if let messageId = try arguments.validatedInt("message_id") {
            return BrowserMCPMappedCall(toolName: "get_console_message", arguments: ["msgid": messageId])
        }
        return try BrowserMCPMappedCall(toolName: "list_console_messages", arguments: self.compact([
            "pageSize": arguments.validatedInt("page_size"),
            "pageIdx": arguments.validatedInt("page_index"),
            "types": arguments.getStringArray("types"),
            "includePreservedMessages": arguments.getBool("include_preserved") ?? false,
        ]))
    }

    private static func networkCall(_ arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        if let requestId = try arguments.validatedInt("request_id") {
            return BrowserMCPMappedCall(toolName: "get_network_request", arguments: self.compact([
                "reqid": requestId,
                "requestFilePath": arguments.getString("request_file_path"),
                "responseFilePath": arguments.getString("response_file_path"),
            ]))
        }
        return try BrowserMCPMappedCall(toolName: "list_network_requests", arguments: self.compact([
            "pageSize": arguments.validatedInt("page_size"),
            "pageIdx": arguments.validatedInt("page_index"),
            "resourceTypes": arguments.getStringArray("resource_types"),
            "includePreservedRequests": arguments.getBool("include_preserved") ?? false,
        ]))
    }

    private static func performanceCall(_ arguments: ToolArguments) throws -> BrowserMCPMappedCall {
        let traceAction = arguments.getString("trace_action") ?? "start"
        switch traceAction {
        case "start":
            return BrowserMCPMappedCall(toolName: "performance_start_trace", arguments: self.compact([
                "reload": arguments.getBool("reload") ?? true,
                "autoStop": arguments.getBool("auto_stop") ?? true,
                "filePath": arguments.getString("path"),
            ]))
        case "stop":
            return BrowserMCPMappedCall(toolName: "performance_stop_trace", arguments: self.compact([
                "filePath": arguments.getString("path"),
            ]))
        case "analyze":
            return try BrowserMCPMappedCall(toolName: "performance_analyze_insight", arguments: [
                "insightSetId": self.requiredString("insight_set_id", arguments),
                "insightName": self.requiredString("insight_name", arguments),
            ])
        default:
            throw BrowserToolError.invalidAction("performance_trace.\(traceAction)")
        }
    }

    private static func requiredString(_ key: String, _ arguments: ToolArguments) throws -> String {
        guard let value = arguments.getString(key), !value.isEmpty else {
            throw BrowserToolError.missingParameter(key)
        }
        return value
    }

    private static func requiredURL(_ arguments: ToolArguments) throws -> String {
        guard let value = self.url(arguments), !value.isEmpty else {
            throw BrowserToolError.missingParameter("url")
        }
        return value
    }

    private static func url(_ arguments: ToolArguments) -> String? {
        guard let value = arguments.getValue(for: "url") else { return nil }
        switch value {
        case let .string(url):
            return url
        case .data:
            // MCP.Value decodes data: URL strings as binary values. Re-encode them before forwarding to Chrome.
            return value.description
        default:
            return nil
        }
    }

    private static func parseJSONObject(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            throw BrowserToolError.invalidJSONArguments
        }
        return dictionary
    }

    fileprivate static func requiredPageID(_ arguments: ToolArguments) throws -> Int {
        let pageID: Int? = switch arguments.getValue(for: "page_id") {
        case let .int(value):
            value
        case let .double(value) where value.isFinite && value.rounded() == value:
            Int(exactly: value)
        case let .string(value):
            Int(value)
        default:
            nil
        }
        guard let pageID, pageID >= 0 else {
            throw BrowserToolError.invalidPageID
        }
        return pageID
    }

    private static func jsonObject(
        _ key: String,
        _ arguments: ToolArguments,
        fallbackError: String) throws -> [String: Any]
    {
        guard let json = arguments.getString(key), let data = json.data(using: .utf8) else {
            throw BrowserToolError.missingParameter(fallbackError)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw BrowserToolError.invalidJSONArguments
        }
        return dictionary
    }

    private static func compact(_ dictionary: [String: Any?]) -> [String: Any] {
        dictionary.compactMapValues { $0 }
    }
}
