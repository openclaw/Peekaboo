import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP

private struct BrowserCommandInputError: LocalizedError, ResultEnvelopeError {
    let errorDescription: String?
    let envelopeHint: String?

    nonisolated var envelopeCode: ErrorCode? {
        .VALIDATION_ERROR
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeRetrySafe: Bool? {
        true
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        false
    }

    static func invalidBrowserURL() -> Self {
        Self(
            errorDescription: "Invalid --browser-url. Expected http://127.0.0.1:<port>, " +
                "http://[::1]:<port>, or http://localhost:<port>.",
            envelopeHint: "Run `peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground`."
        )
    }
}

@MainActor
struct BrowserCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable,
InjectedRuntimeBackedCommand {
    var action = "status"
    var channel: String?
    var browserUrl: String?
    var pageId: Int?
    var url: String?
    var navigationType: String?
    var uid: String?
    var toUid: String?
    var text: String?
    var value: String?
    var key: String?
    var submitKey: String?
    var dialogAction: String?
    var includeSnapshot = false
    var double = false
    var bringToFront = false
    var noBringToFront = false
    var background = false
    var foreground = false
    var timeout: CLIDuration?
    var pageSize: Int?
    var pageIndex: Int?
    var types: [String] = []
    var resourceTypes: [String] = []
    var includePreserved = false
    var messageId: Int?
    var requestId: Int?
    var requestFilePath: String?
    var responseFilePath: String?
    var path: String?
    var format: String?
    var quality: Int?
    var fullPage = false
    var traceAction: String?
    var noReload = false
    var noAutoStop = false
    var insightSetId: String?
    var insightName: String?
    var mcpTool: String?
    var mcpArgsJson: String?
    var handoffFile: String?
    private let handoffReceiptStoreCache = BrowserHandoffReceiptStoreCache()

    var runtimeOptions: CommandRuntimeOptions = {
        var options = CommandRuntimeOptions()
        options.requiresBrowserMCP = true
        return options
    }()

    @RuntimeStorage var runtime: CommandRuntime?

    static let commandDescription = CommandDescription(
        commandName: "browser",
        abstract: "Control Chrome page content through the browser MCP tool",
        discussion: """
        Dedicated CLI wrapper around Peekaboo's browser MCP tool. Use it for DOM/page
        operations such as status, connect, navigate, snapshot, click, dom-click, fill, type,
        screenshots, console/network inspection, and performance traces.

        Examples:
          peekaboo browser status --json
          peekaboo browser connect --channel stable --foreground
          peekaboo browser new-page --url https://example.com --foreground
          peekaboo browser snapshot --page-id 2 --path /tmp/page.txt --foreground

        The pinned provider grants browser user activation to every Puppeteer page evaluation, including
        headless and background pages. Default mode therefore exposes only source-audited routes that do not
        enter that evaluation path and reports those calls as background browser-protocol delivery. Page discovery,
        snapshots, navigation, element interaction, and arbitrary script evaluation require explicit --foreground
        and report foreground browser-protocol delivery.
        Default calls still require an existing exact connection and never ambiently auto-connect. With explicit
        --foreground, only standalone CLI page actions may auto-connect when no receipt exists.
        dom-click invokes synthetic element.click() without trusted pointer input. Its provider evaluation still
        grants browser user activation and requires --foreground. Success does not prove the intended page effect;
        observe the page before retrying. This is not a guarantee that Chrome stays behind other apps.
        """
    )

    mutating func setRuntimeOptions(_ options: CommandRuntimeOptions) {
        var options = options
        options.requiresBrowserMCP = true
        options.requiresImplicitSnapshotInvalidation = false
        options.usesPerToolSnapshotInvalidation = self.boundInvocationMayMutate(using: options)
        options.dynamicToolScreenCaptureReachable = false
        self.runtimeOptions = options
    }

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            let arguments = try self.arguments()
            let context = MCPToolContext(
                services: self.services,
                snapshotMutationCoordinator: runtime.toolSnapshotMutationCoordinator,
                executionPolicy: self.toolExecutionPolicy,
                capturePreflightRefusal: runtime.toolCapturePreflightRefusal
            )
            let tool = BrowserTool(context: context, instructionAudience: .commandLine)
            let response = try await context.execute(
                tool: tool,
                arguments: ToolArguments(raw: arguments)
            )
            if let store = try self.handoffReceiptStore() {
                if response.isError {
                    _ = (self.services.browser as? any BrowserMCPConnectionHandoffProviding)?
                        .takeConnectionHandoffReceiptBundleData()
                    try MCPToolCommandOutput.output(
                        tool: tool.name,
                        response: response,
                        jsonOutput: self.jsonOutput,
                        logger: self.outputLogger
                    )
                    return
                }
                guard let provider = self.services.browser as? any BrowserMCPConnectionHandoffProviding else {
                    throw BrowserHandoffCommandError.providerUnavailable
                }
                guard let receiptData = provider.takeConnectionHandoffReceiptBundleData() else {
                    throw await self.handoffPublicationFailure(
                        cause: "the provider returned no authenticated receipt",
                        provider: provider
                    )
                }
                do {
                    try store.save(receiptData)
                } catch {
                    throw await self.handoffPublicationFailure(
                        cause: "the receipt could not be published: \(error.localizedDescription)",
                        provider: provider
                    )
                }
            }
            try MCPToolCommandOutput.output(
                tool: tool.name,
                response: response,
                jsonOutput: self.jsonOutput,
                logger: self.outputLogger
            )
        } catch let exit as ExitCode {
            throw exit
        } catch {
            self.handleError(error)
            throw ExitCode(1)
        }
    }

    private func handoffPublicationFailure(
        cause: String,
        provider: any BrowserMCPConnectionHandoffProviding
    ) async -> BrowserHandoffCommandError {
        do {
            let status = try await provider.disconnectWithResult()
            guard status.observation == .confirmed, !status.isConnected else {
                return .publicationFailed(
                    cause: cause,
                    rollbackFailure: "the provider did not confirm that the browser connection ended"
                )
            }
            return .publicationFailed(cause: cause, rollbackFailure: nil)
        } catch {
            return .publicationFailed(cause: cause, rollbackFailure: error.localizedDescription)
        }
    }

    private func boundInvocationMayMutate(using runtimeOptions: CommandRuntimeOptions) -> Bool {
        var command = self
        command.runtimeOptions = runtimeOptions
        guard let rawArguments = try? command.arguments(),
              let actionName = rawArguments["action"] as? String,
              let action = BrowserAction(rawValue: actionName)
        else { return true }
        return BrowserMCPCallMapper.effectiveActionSemantics(
            action: action,
            arguments: ToolArguments(raw: rawArguments)
        ) == .mutating
    }

    var toolExecutionPolicy: MCPToolExecutionPolicy {
        self.foreground ? .foregroundAllowed : .backgroundOnly
    }

    func validateBeforeRuntime() throws {
        try self.validateHandoffEnvironment()
        _ = try self.arguments()
        try self.handoffReceiptStore()?.validateCanSave()
    }

    func validateHandoffEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        guard self.handoffFile != nil else { return }
        guard environment["PEEKABOO_NO_REMOTE"] == nil else {
            throw ValidationError("browser connect --handoff-file does not support PEEKABOO_NO_REMOTE")
        }
        if let environmentSocket = environment["PEEKABOO_BRIDGE_SOCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !environmentSocket.isEmpty,
            environmentSocket != self.runtimeOptions.bridgeSocketPath {
            throw ValidationError("--bridge-socket conflicts with PEEKABOO_BRIDGE_SOCKET")
        }
    }

    private func arguments() throws -> [String: Any] {
        let normalizedAction = self.action
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
        guard BrowserAction(rawValue: normalizedAction) != nil else {
            throw ValidationError("Unsupported browser action '\(self.action)'")
        }
        if let channel, BrowserMCPChannel(rawValue: channel) == nil {
            let choices = BrowserMCPChannel.allCases.map(\.rawValue).joined(separator: "|")
            throw ValidationError("Unsupported browser channel '\(channel)' (expected \(choices))")
        }
        if normalizedAction == BrowserAction.connect.rawValue,
           let browserUrl,
           BrowserLoopbackEndpoint(browserURL: browserUrl) == nil {
            throw BrowserCommandInputError.invalidBrowserURL()
        }
        if self.handoffFile != nil {
            guard normalizedAction == BrowserAction.connect.rawValue else {
                throw ValidationError("--handoff-file is accepted only by browser connect")
            }
            guard self.foreground else {
                throw ValidationError("browser connect --handoff-file requires --foreground")
            }
            guard !self.runtimeOptions.remoteIsolationRequested, self.runtimeOptions.preferRemote else {
                throw ValidationError("browser connect --handoff-file does not support --no-remote")
            }
            _ = try self.validatedExplicitBridgeSocket()
        }

        var arguments: [String: Any] = ["action": normalizedAction]
        self.add(self.channel, as: "channel", to: &arguments)
        self.add(self.browserUrl, as: "browser_url", to: &arguments)
        self.add(self.pageId, as: "page_id", to: &arguments)
        self.add(self.url, as: "url", to: &arguments)
        self.add(self.navigationType, as: "navigation_type", to: &arguments)
        self.add(self.uid, as: "uid", to: &arguments)
        self.add(self.toUid, as: "to_uid", to: &arguments)
        self.add(self.text, as: "text", to: &arguments)
        self.add(self.value, as: "value", to: &arguments)
        self.add(self.key, as: "key", to: &arguments)
        self.add(self.submitKey, as: "submit_key", to: &arguments)
        self.add(self.dialogAction, as: "dialog_action", to: &arguments)
        self.addFlag(self.includeSnapshot, as: "include_snapshot", to: &arguments)
        self.addFlag(self.double, as: "double", to: &arguments)
        if self.bringToFront {
            arguments["bring_to_front"] = true
        } else if self.noBringToFront {
            arguments["bring_to_front"] = false
        }
        if self.foreground {
            arguments["background"] = false
        } else if self.background {
            arguments["background"] = true
        }
        self.add(self.timeout?.roundedMilliseconds, as: "timeout", to: &arguments)
        self.add(self.pageSize, as: "page_size", to: &arguments)
        self.add(self.pageIndex, as: "page_index", to: &arguments)
        if !self.types.isEmpty {
            arguments["types"] = self.types
        }
        if !self.resourceTypes.isEmpty {
            arguments["resource_types"] = self.resourceTypes
        }
        self.addFlag(self.includePreserved, as: "include_preserved", to: &arguments)
        self.add(self.messageId, as: "message_id", to: &arguments)
        self.add(self.requestId, as: "request_id", to: &arguments)
        self.add(self.requestFilePath, as: "request_file_path", to: &arguments)
        self.add(self.responseFilePath, as: "response_file_path", to: &arguments)
        self.add(self.path, as: "path", to: &arguments)
        self.add(self.format, as: "format", to: &arguments)
        self.add(self.quality, as: "quality", to: &arguments)
        self.addFlag(self.fullPage, as: "full_page", to: &arguments)
        self.add(self.traceAction, as: "trace_action", to: &arguments)
        if self.noReload {
            arguments["reload"] = false
        }
        if self.noAutoStop {
            arguments["auto_stop"] = false
        }
        self.add(self.insightSetId, as: "insight_set_id", to: &arguments)
        self.add(self.insightName, as: "insight_name", to: &arguments)
        self.add(self.mcpTool, as: "mcp_tool", to: &arguments)
        self.addFlag(self.handoffFile != nil, as: "request_handoff", to: &arguments)
        if let mcpArgsJson {
            do {
                _ = try MCPArgumentParsing.parseJSONObject(mcpArgsJson)
            } catch {
                throw ValidationError("--mcp-args-json must be a JSON object")
            }
            arguments["mcp_args_json"] = mcpArgsJson
        }
        return arguments
    }

    private func handoffReceiptStore() throws -> BrowserHandoffReceiptStore? {
        guard let handoffFile = self.handoffFile else { return nil }
        return try self.handoffReceiptStoreCache.store(resolvingAbsolutePath: handoffFile)
    }

    private func validatedExplicitBridgeSocket() throws -> String {
        guard let bridgeSocket = self.runtimeOptions.bridgeSocketPath,
              bridgeSocket.hasPrefix("/"),
              URL(fileURLWithPath: bridgeSocket).standardizedFileURL.path == bridgeSocket
        else {
            throw ValidationError(
                "browser connect --handoff-file requires one standardized absolute --bridge-socket"
            )
        }
        return bridgeSocket
    }

    private func add(_ value: String?, as key: String, to arguments: inout [String: Any]) {
        guard let value, !value.isEmpty else { return }
        arguments[key] = value
    }

    private func add(_ value: Int?, as key: String, to arguments: inout [String: Any]) {
        guard let value else { return }
        arguments[key] = value
    }

    private func addFlag(_ value: Bool, as key: String, to arguments: inout [String: Any]) {
        if value {
            arguments[key] = true
        }
    }
}

extension BrowserCommand: ParsableCommand {}
extension BrowserCommand: AsyncRuntimeCommand {}
extension BrowserCommand: PreRuntimeValidatingCommand {}

extension BrowserCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(
                    label: "action",
                    help: "Browser action (default: status)",
                    isOptional: true
                ),
            ],
            options: [
                .commandOption("channel", help: "Chrome channel", long: "channel"),
                .commandOption(
                    "browserUrl",
                    help: "Exact loopback DevTools HTTP endpoint for connect",
                    long: "browser-url"
                ),
                .commandOption("pageId", help: "Chrome DevTools page ID", long: "page-id"),
                .commandOption("url", help: "URL for navigate/new-page", long: "url"),
                .commandOption(
                    "navigationType",
                    help: "Navigation type: url|back|forward|reload",
                    long: "navigation-type"
                ),
                .commandOption("uid", help: "Element uid from browser snapshot", long: "uid"),
                .commandOption("toUid", help: "Drop target uid for drag", long: "to-uid"),
                .commandOption("text", help: "Text for type/wait/dialog", long: "text"),
                .commandOption("value", help: "Value for fill", long: "value"),
                .commandOption("key", help: "Key or key combination for press-key", long: "key"),
                .commandOption("submitKey", help: "Optional key after type", long: "submit-key"),
                .commandOption("dialogAction", help: "Dialog action: accept|dismiss", long: "dialog-action"),
                .commandOption(
                    "timeout",
                    help: "Timeout; bare values are milliseconds, or use ms/s suffixes",
                    long: "timeout"
                ),
                .commandOption("pageSize", help: "Console/network page size", long: "page-size"),
                .commandOption("pageIndex", help: "Console/network page index", long: "page-index"),
                OptionDefinition.make(
                    label: "types",
                    names: [.long("type"), .aliasLong("types")],
                    help: "Console message type; repeat or comma-separate",
                    parsing: .singleValue
                ),
                OptionDefinition.make(
                    label: "resourceTypes",
                    names: [.long("resource-type"), .aliasLong("resource-types")],
                    help: "Network resource type; repeat or comma-separate",
                    parsing: .singleValue
                ),
                .commandOption("messageId", help: "Console message ID", long: "message-id"),
                .commandOption("requestId", help: "Network request ID", long: "request-id"),
                .commandOption("requestFilePath", help: "Path for saving a request body", long: "request-file-path"),
                .commandOption("responseFilePath", help: "Path for saving a response body", long: "response-file-path"),
                .commandOption(
                    "path",
                    help: "Absolute input file for upload-file; output path for snapshot/screenshot/trace",
                    long: "path"
                ),
                .commandOption("format", help: "Screenshot format: png|jpeg|webp", long: "format"),
                .commandOption("quality", help: "Screenshot quality for jpeg/webp", long: "quality"),
                .commandOption("traceAction", help: "Trace action: start|stop|analyze", long: "trace-action"),
                .commandOption("insightSetId", help: "Trace insight set ID", long: "insight-set-id"),
                .commandOption("insightName", help: "Trace insight name", long: "insight-name"),
                .commandOption("mcpTool", help: "Advanced browser MCP tool for call action", long: "mcp-tool"),
                .commandOption(
                    "mcpArgsJson",
                    help: "Advanced JSON object args for call/fill-form",
                    long: "mcp-args-json"
                ),
                .commandOption(
                    "handoffFile",
                    help: "Atomically create one signed browser handoff receipt at an unused path " +
                        "in an owner-only directory",
                    long: "handoff-file"
                ),
            ],
            flags: [
                .commandFlag(
                    "includeSnapshot",
                    help: "Include fresh snapshot when supported",
                    long: "include-snapshot"
                ),
                .commandFlag("double", help: "Double-click for click", long: "double"),
                .commandFlag("bringToFront", help: "Bring selected page to front", long: "bring-to-front"),
                .commandFlag(
                    "noBringToFront",
                    help: "Keep selected page in background (default; legacy explicit form)",
                    long: "no-bring-to-front"
                ),
                .commandFlag("background", help: "Open new page in background (default)", long: "background"),
                .commandFlag(
                    "foreground",
                    help: "Allow browser user activation, foreground effects, and standalone CLI auto-connect",
                    long: "foreground"
                ),
                .commandFlag(
                    "includePreserved",
                    help: "Include preserved console/network data",
                    long: "include-preserved"
                ),
                .commandFlag("fullPage", help: "Capture full-page screenshot", long: "full-page"),
                .commandFlag("noReload", help: "Do not reload when starting a trace", long: "no-reload"),
                .commandFlag("noAutoStop", help: "Do not auto-stop performance trace", long: "no-auto-stop"),
            ]
        )
    }
}

extension BrowserCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.action = values.positionalValue(at: 0) ?? "status"
        self.channel = values.singleOption("channel")
        self.browserUrl = values.singleOption("browserUrl")
        self.pageId = try values.decodeOption("pageId", as: Int.self)
        self.url = values.singleOption("url")
        self.navigationType = values.singleOption("navigationType")
        self.uid = values.singleOption("uid")
        self.toUid = values.singleOption("toUid")
        self.text = values.singleOption("text")
        self.value = values.singleOption("value")
        self.key = values.singleOption("key")
        self.submitKey = values.singleOption("submitKey")
        self.dialogAction = values.singleOption("dialogAction")
        self.includeSnapshot = values.flag("includeSnapshot")
        self.double = values.flag("double")
        self.bringToFront = values.flag("bringToFront")
        self.noBringToFront = values.flag("noBringToFront")
        self.background = values.flag("background")
        self.foreground = values.flag("foreground")
        if self.bringToFront, self.noBringToFront {
            throw ValidationError("--bring-to-front and --no-bring-to-front cannot be used together")
        }
        if self.background, self.foreground {
            throw ValidationError("--background and --foreground cannot be used together")
        }
        self.timeout = try values.decodeOption("timeout", as: CLIDuration.self)
        self.pageSize = try values.decodeOption("pageSize", as: Int.self)
        self.pageIndex = try values.decodeOption("pageIndex", as: Int.self)
        self.types = Self.splitCSV(values.optionValues("types"))
        self.resourceTypes = Self.splitCSV(values.optionValues("resourceTypes"))
        self.includePreserved = values.flag("includePreserved")
        self.messageId = try values.decodeOption("messageId", as: Int.self)
        self.requestId = try values.decodeOption("requestId", as: Int.self)
        self.requestFilePath = values.singleOption("requestFilePath")
        self.responseFilePath = values.singleOption("responseFilePath")
        self.path = values.singleOption("path")
        self.format = values.singleOption("format")
        self.quality = try values.decodeOption("quality", as: Int.self)
        self.fullPage = values.flag("fullPage")
        self.traceAction = values.singleOption("traceAction")
        self.noReload = values.flag("noReload")
        self.noAutoStop = values.flag("noAutoStop")
        self.insightSetId = values.singleOption("insightSetId")
        self.insightName = values.singleOption("insightName")
        self.mcpTool = values.singleOption("mcpTool")
        self.mcpArgsJson = values.singleOption("mcpArgsJson")
        let handoffFiles = values.optionValues("handoffFile")
        guard handoffFiles.count <= 1 else {
            throw ValidationError("--handoff-file may be specified only once")
        }
        if !handoffFiles.isEmpty, values.optionValues("bridge-socket").count != 1 {
            throw ValidationError("browser connect --handoff-file requires exactly one --bridge-socket")
        }
        self.handoffFile = handoffFiles.last
    }

    private static func splitCSV(_ values: [String]) -> [String] {
        values.flatMap { value in
            value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }
}

private enum BrowserHandoffCommandError: LocalizedError, ResultEnvelopeError {
    case providerUnavailable
    case publicationFailed(cause: String, rollbackFailure: String?)

    nonisolated var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            "The selected browser provider cannot produce authenticated handoff receipts."
        case let .publicationFailed(cause, nil):
            "Browser handoff failed: \(cause) The new browser connection was disconnected cleanly."
        case let .publicationFailed(cause, rollbackFailure?):
            "Browser handoff failed: \(cause) Connection rollback could not be confirmed: " +
                rollbackFailure
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        .INTERACTION_FAILED
    }

    nonisolated var envelopeEffect: ActionEffect? {
        .partial
    }

    nonisolated var envelopeRetrySafe: Bool? {
        if case .publicationFailed(_, nil) = self {
            return true
        }
        return false
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        true
    }

    nonisolated var envelopeHint: String? {
        if case .publicationFailed(_, nil) = self {
            return "Use a fresh owner-private destination and retry the foreground handoff connect."
        }
        return "Do not reconnect automatically. Check browser status and use a fresh owner-private destination."
    }
}
