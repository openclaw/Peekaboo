import Commander
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooCLI

@MainActor
struct BrowserCLINamespaceCommandTests {
    private static let pageReference = "bp1_0123456789abcdef0123456789abcdef"

    @Test
    func `remote adapter replaces local outcome metadata with verified bridge truth`() throws {
        let local = DesktopActionOutcome.dispatchedUnverified(
            route: .local,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        let verified = local.routed(to: .bridge)
        let localData = try JSONEncoder().encode(local.projection)
        var localFields = try #require(JSONSerialization.jsonObject(with: localData) as? [String: Any])
        localFields["provider_note"] = "preserved"
        let wireMetaData = try JSONSerialization.data(withJSONObject: localFields)
        let wireMeta = try JSONDecoder().decode(PeekabooBridgeJSONValue.self, from: wireMetaData)

        let response = try RemoteBrowserCLINamespaceBridgeAdapter.toolResponse(.init(
            content: [],
            isError: false,
            meta: wireMeta
        ), verifiedOutcome: verified)
        let fields = try #require(response.meta?.objectValue)

        #expect(fields["route"]?.stringValue == "bridge")
        #expect(fields["provider_note"]?.stringValue == "preserved")
        #expect(fields["state"]?.stringValue == verified.state.rawValue)
    }

    @Test
    func `namespace runtime selects only on demand Bridge candidates without local fallback`() {
        var options = CommandRuntimeOptions()
        options.requiresBrowserCapabilityNamespace = true
        options.preferRemote = false
        let decision = RuntimeHostResolver.initialRoutingDecision(
            options: options,
            environment: [:],
            configurationInput: nil,
            knownSnapshotInvalidationRemoteSocketPaths: []
        )
        #expect(decision == .remote)

        let candidates = RuntimeHostResolver.implicitRemoteCandidates(
            options: options,
            daemonSocketPath: "/tmp/peekaboo-daemon.sock",
            buildScopedDaemonSocketPath: "/tmp/peekaboo-build.sock",
            historicalBuildScopedDaemonSocketPaths: ["/tmp/peekaboo-old.sock"]
        )
        #expect(!candidates.isEmpty)
        #expect(candidates.allSatisfy { $0.requiredHostKind == .onDemand })
        #expect(!candidates.contains { $0.socketPath == PeekabooBridgeConstants.peekabooSocketPath })
    }

    @Test
    func `remote services expose namespace adapter only after negotiated construction`() {
        let client = PeekabooBridgeClient(socketPath: "/tmp/peekaboo-unused-browser-namespace.sock")
        let legacy = RemotePeekabooServices(client: client)
        let current = RemotePeekabooServices(
            client: client,
            supportsBrowserCapabilityNamespaces: true
        )

        #expect((legacy as any BrowserCLINamespaceBridgeAdapterProviding)
            .browserCLINamespaceBridgeAdapter == nil)
        #expect((current as any BrowserCLINamespaceBridgeAdapterProviding)
            .browserCLINamespaceBridgeAdapter != nil)
    }

    @Test
    func `bind window parses exactly three selectors and disables legacy browser routing`() throws {
        let command = try Self.command(options: [
            "pageId": [Self.pageReference],
            "pid": ["123"],
            "windowId": ["456"],
        ])

        #expect(try command.namespaceBindWindowRequest() == BrowserCLINamespaceBindWindowRequest(
            pageID: Self.pageReference,
            processIdentifier: 123,
            windowID: 456
        ))
        #expect(!command.runtimeOptions.requiresBrowserMCP)
        #expect(command.runtimeOptions.requiresBrowserCapabilityNamespace)
        #expect(command.runtimeOptions.ignoresCaptureEnginePreference)
        #expect(!BrowserCommand.actionMayMutate("bind-window"))
        #expect(!BrowserCommand.actionMayMutate("bind_window"))
    }

    @Test
    func `bind window requires every selector before runtime discovery`() throws {
        for omitted in ["pageId", "pid", "windowId"] {
            var options = [
                "pageId": [Self.pageReference],
                "pid": ["123"],
                "windowId": ["456"],
            ]
            options.removeValue(forKey: omitted)
            let command = try Self.command(options: options)
            #expect(throws: BrowserCLINamespaceCommandError.missingSelectors) {
                try command.validateBeforeRuntime()
            }
        }
    }

    @Test(arguments: [
        "bp1_0123456789abcdef0123456789abcde",
        "bp1_0123456789abcdef0123456789abcdef0",
        "bp1_0123456789abcdef0123456789abcdeg",
        "bp1_0123456789ABCDEF0123456789ABCDEF",
        "1",
        "",
    ])
    func `bind window refuses noncanonical page capabilities`(_ pageReference: String) throws {
        let command = try Self.command(options: [
            "pageId": [pageReference],
            "pid": ["123"],
            "windowId": ["456"],
        ])
        #expect(throws: BrowserCLINamespaceCommandError.invalidPageReference) {
            try command.validateBeforeRuntime()
        }
    }

    @Test(arguments: ["0", "-1", "2147483648"])
    func `bind window refuses invalid process selectors`(_ processIdentifier: String) throws {
        let command = try Self.command(options: [
            "pageId": [Self.pageReference],
            "pid": [processIdentifier],
            "windowId": ["456"],
        ])
        #expect(throws: BrowserCLINamespaceCommandError.invalidProcessIdentifier) {
            try command.validateBeforeRuntime()
        }
    }

    @Test(arguments: ["0", "-1", "4294967296"])
    func `bind window refuses invalid native window selectors`(_ windowID: String) throws {
        let command = try Self.command(options: [
            "pageId": [Self.pageReference],
            "pid": ["123"],
            "windowId": [windowID],
        ])
        #expect(throws: BrowserCLINamespaceCommandError.invalidWindowID) {
            try command.validateBeforeRuntime()
        }
    }

    @Test(arguments: IrrelevantArgument.fixtures)
    private func `bind window rejects every irrelevant browser argument`(_ argument: IrrelevantArgument) throws {
        var parsed = ParsedValues(
            positional: ["bind-window"],
            options: [
                "pageId": [Self.pageReference],
                "pid": ["123"],
                "windowId": ["456"],
                "namespaceFile": ["/private/tmp/fixture-browser-namespace.json"],
            ],
            flags: []
        )
        argument.apply(to: &parsed)
        let command = try CommanderCLIBinder.instantiateCommand(ofType: BrowserCommand.self, parsedValues: parsed)
        #expect(throws: BrowserCLINamespaceCommandError.self) {
            try command.validateBeforeRuntime()
        }
    }

    @Test
    func `bind window refuses local routing while allowing output and exact socket controls`() throws {
        let local = try Self.command(
            options: [
                "pageId": [Self.pageReference],
                "pid": ["123"],
                "windowId": ["456"],
            ],
            flags: ["no-remote"]
        )
        #expect(throws: BrowserCLINamespaceCommandError.localExecutionRefused) {
            try local.validateBeforeRuntime()
        }

        let ambient = try Self.command(options: [
            "pageId": [Self.pageReference],
            "pid": ["123"],
            "windowId": ["456"],
        ])
        #expect(throws: BrowserCLINamespaceCommandError.localExecutionRefused) {
            try ambient.namespaceBindWindowRequest(environment: ["PEEKABOO_NO_REMOTE": "1"])
        }

        let remote = try Self.command(
            options: [
                "pageId": [Self.pageReference],
                "pid": ["123"],
                "windowId": ["456"],
                "bridge-socket": ["/private/tmp/fixture.sock"],
                "namespaceFile": ["/private/tmp/fixture-browser-namespace.json"],
            ],
            flags: ["jsonOutput", "verbose"]
        )
        #expect(try remote.namespaceBindWindowRequest().windowID == 456)
        #expect(remote.runtimeOptions.bridgeSocketPath == "/private/tmp/fixture.sock")
    }

    @Test
    func `ordinary browser actions retain numeric page IDs and legacy browser routing`() throws {
        let command = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["snapshot"],
                options: ["pageId": ["7"]],
                flags: []
            )
        )
        #expect(command.pageId == "7")
        #expect(command.runtimeOptions.requiresBrowserMCP)
        try command.validateBeforeRuntime()

        let opaque = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["snapshot"],
                options: ["pageId": [Self.pageReference]],
                flags: []
            )
        )
        #expect(throws: ValidationError.self) {
            try opaque.validateBeforeRuntime()
        }
    }

    @Test
    func `bind window requires an explicit existing namespace file before runtime discovery`() throws {
        let missingOption = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["bind-window"],
                options: [
                    "pageId": [Self.pageReference],
                    "pid": ["123"],
                    "windowId": ["456"],
                ],
                flags: []
            )
        )
        #expect(throws: BrowserCLINamespaceCommandError.missingNamespaceFile) {
            try missingOption.validateBeforeRuntime()
        }

        let privateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-missing-namespace-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: privateDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: privateDirectory.path
        )
        defer { try? FileManager.default.removeItem(at: privateDirectory) }
        let missingPath = privateDirectory.appendingPathComponent("receipt.json").path
        let missingFile = try Self.command(options: [
            "pageId": [Self.pageReference],
            "pid": ["123"],
            "windowId": ["456"],
            "namespaceFile": [missingPath],
        ])
        #expect(throws: BrowserCLINamespaceReceiptStoreError.missing) {
            try missingFile.validateBeforeRuntime()
        }
    }

    @Test
    func `adapter seam keeps create bind and close in one explicit authority owner`() async throws {
        let receipt = Data("canonical-receipt-fixture".utf8)
        let adapter = RecordingNamespaceAdapter(receipt: receipt)
        let creation = await adapter.createNamespace()
        #expect(creation.namespaceReceiptData == receipt)
        _ = try await adapter.bindWindow(
            request: BrowserCLINamespaceBindWindowRequest(
                pageID: Self.pageReference,
                processIdentifier: 123,
                windowID: 456
            ),
            namespaceReceiptData: creation.namespaceReceiptData
        )
        _ = try await adapter.executeAction(
            request: BrowserCLINamespaceHighLevelActionRequest(
                action: .listPages,
                arguments: [:],
                executionMode: .backgroundOnly
            ),
            namespaceReceiptData: creation.namespaceReceiptData
        )
        _ = try await adapter.closeNamespace(namespaceReceiptData: creation.namespaceReceiptData)
        #expect(adapter.operations == ["create", "bind", "execute", "close"])
    }

    @Test
    func `namespace lifecycle and closed high level actions select only namespace routing`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-cli-namespace-command-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let namespacePath = root.appendingPathComponent("namespace.json").path

        var create = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["namespace-create"],
                options: ["namespaceFile": [namespacePath]],
                flags: []
            )
        )
        create.setRuntimeOptions(CommandRuntimeOptions())
        #expect(create.runtimeOptions.requiresBrowserCapabilityNamespace)
        #expect(!create.runtimeOptions.requiresBrowserMCP)
        try create.validateBeforeRuntime()

        let store = try create.namespaceReceiptStore()
        try store.save(BrowserCLINamespaceReceiptStoreTests.fixture())

        let listPages = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["list-pages"],
                options: ["namespaceFile": [namespacePath]],
                flags: []
            )
        )
        try listPages.validateBeforeRuntime()
        let request = try listPages.namespaceHighLevelActionRequest()
        #expect(request.action.rawValue == BrowserAction.listPages.rawValue)
        #expect(request.arguments.isEmpty)
        if case .backgroundOnly = request.executionMode {} else {
            Issue.record("Namespace list-pages must remain background-only")
        }

        let snapshot = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["snapshot"],
                options: [
                    "namespaceFile": [namespacePath],
                    "pageId": [Self.pageReference],
                ],
                flags: []
            )
        )
        let snapshotRequest = try snapshot.namespaceHighLevelActionRequest()
        #expect(snapshotRequest.arguments["page_id"] as? String == Self.pageReference)

        let rawPage = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["snapshot"],
                options: [
                    "namespaceFile": [namespacePath],
                    "pageId": ["7"],
                ],
                flags: []
            )
        )
        #expect(throws: BrowserCLINamespaceCommandError.invalidPageReference) {
            try rawPage.namespaceHighLevelActionRequest()
        }

        let foregroundConnect = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["connect"],
                options: ["namespaceFile": [namespacePath]],
                flags: ["foreground"]
            )
        )
        let connectRequest = try foregroundConnect.namespaceHighLevelActionRequest()
        #expect(connectRequest.action == .connect)
        if case .foregroundAllowed = connectRequest.executionMode {} else {
            Issue.record("Explicit foreground consent must reach the namespace adapter")
        }

        let close = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["namespace-close"],
                options: ["namespaceFile": [namespacePath]],
                flags: []
            )
        )
        try close.validateBeforeRuntime()
    }

    @Test
    func `namespace routing refuses raw call unknown actions and lifecycle argument leakage`() throws {
        let namespacePath = "/private/tmp/fixture-browser-namespace.json"
        for action in ["call", "frobnicate"] {
            let command = try CommanderCLIBinder.instantiateCommand(
                ofType: BrowserCommand.self,
                parsedValues: ParsedValues(
                    positional: [action],
                    options: [
                        "namespaceFile": [namespacePath],
                        "mcpTool": ["get_tab_id"],
                    ],
                    flags: []
                )
            )
            #expect(throws: (any Error).self) {
                try command.namespaceHighLevelActionRequest()
            }
        }

        let createWithSelector = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["namespace-create"],
                options: [
                    "namespaceFile": [namespacePath],
                    "pageId": [Self.pageReference],
                ],
                flags: []
            )
        )
        #expect(throws: BrowserCLINamespaceCommandError.self) {
            try createWithSelector.validateBrowserCapabilityNamespaceActionBeforeRuntime()
        }
    }

    @Test
    func `namespace lifecycle persists creation and removes only confirmed close`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-cli-namespace-lifecycle-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BrowserCLINamespaceReceiptStore(fileURL: root.appendingPathComponent("namespace.json"))
        let receipt = try BrowserCLINamespaceReceiptStoreTests.fixture()

        let createAdapter = RecordingNamespaceAdapter(receipt: receipt)
        let creation = try await BrowserCLINamespaceLifecycle.create(adapter: createAdapter, store: store)
        #expect(!creation.isError)
        #expect(try store.load() == receipt)

        let refusingClose = RecordingNamespaceAdapter(receipt: receipt, closeIsError: true)
        let refusal = try await BrowserCLINamespaceLifecycle.close(adapter: refusingClose, store: store)
        #expect(refusal.isError)
        #expect(try store.load() == receipt)

        let closingAdapter = RecordingNamespaceAdapter(receipt: receipt)
        let close = try await BrowserCLINamespaceLifecycle.close(adapter: closingAdapter, store: store)
        #expect(!close.isError)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test
    func `post dispatch namespace failures never claim no mutation`() {
        let rolledBack = BrowserCLINamespacePostDispatchError.creationRolledBack("fixture")
        let rollbackFailed = BrowserCLINamespacePostDispatchError.creationRollbackFailed("fixture")
        let cleanupFailed = BrowserCLINamespacePostDispatchError.closedReceiptCleanupFailed("fixture")

        #expect(rolledBack.envelopeMutationDispatched == true)
        #expect(rolledBack.envelopeRetrySafe == true)
        #expect(rollbackFailed.envelopeMutationDispatched == true)
        #expect(rollbackFailed.envelopeRetrySafe == false)
        #expect(cleanupFailed.envelopeMutationDispatched == true)
        #expect(cleanupFailed.envelopeRetrySafe == false)
        #expect(cleanupFailed.envelopeEffect == .partial)
    }

    private static func command(
        options: [String: [String]],
        flags: Set<String> = []
    ) throws -> BrowserCommand {
        var options = options
        if options["namespaceFile"] == nil {
            options["namespaceFile"] = ["/private/tmp/fixture-browser-namespace.json"]
        }
        var command = try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(
                positional: ["bind-window"],
                options: options,
                flags: flags
            )
        )
        var runtimeOptions = CommandRuntimeOptions()
        runtimeOptions.remoteIsolationRequested = flags.contains("no-remote")
        runtimeOptions.bridgeSocketPath = options["bridge-socket"]?.last
        runtimeOptions.jsonOutput = flags.contains("jsonOutput")
        runtimeOptions.verbose = flags.contains("verbose")
        command.setRuntimeOptions(runtimeOptions)
        return command
    }
}

@MainActor
private final class RecordingNamespaceAdapter: BrowserCLINamespaceBridgeAdapter {
    let receipt: Data
    let closeIsError: Bool
    var operations: [String] = []

    init(receipt: Data, closeIsError: Bool = false) {
        self.receipt = receipt
        self.closeIsError = closeIsError
    }

    func createNamespace() async -> BrowserCLINamespaceCreateResult {
        self.operations.append("create")
        return BrowserCLINamespaceCreateResult(
            namespaceReceiptData: self.receipt,
            response: .text("created")
        )
    }

    func bindWindow(
        request: BrowserCLINamespaceBindWindowRequest,
        namespaceReceiptData: Data
    ) async throws -> ToolResponse {
        guard request.pageID == "bp1_0123456789abcdef0123456789abcdef",
              namespaceReceiptData == self.receipt
        else {
            throw BrowserCLINamespaceCommandError.invalidPageReference
        }
        self.operations.append("bind")
        return .text("bound")
    }

    func closeNamespace(namespaceReceiptData: Data) async throws -> ToolResponse {
        guard namespaceReceiptData == self.receipt else {
            throw BrowserCLINamespaceReceiptStoreError.invalidState("wrong receipt")
        }
        self.operations.append("close")
        if self.closeIsError {
            return ToolResponse(content: [], isError: true)
        }
        return .text("closed")
    }

    func executeAction(
        request: BrowserCLINamespaceHighLevelActionRequest,
        namespaceReceiptData: Data
    ) async throws -> ToolResponse {
        guard request.action.rawValue == BrowserAction.listPages.rawValue,
              namespaceReceiptData == self.receipt
        else {
            throw BrowserCLINamespaceCommandError.unsupportedNamespaceAction(request.action.rawValue)
        }
        self.operations.append("execute")
        return .text("executed")
    }
}

private nonisolated struct IrrelevantArgument: Sendable, CustomTestStringConvertible {
    let optionLabel: String?
    let optionValue: String?
    let flagLabel: String?

    var testDescription: String {
        self.optionLabel ?? self.flagLabel ?? "invalid-fixture"
    }

    static let fixtures: [Self] = [
        .option("channel", "stable"),
        .option("browserUrl", "http://127.0.0.1:9222"),
        .option("url", "https://example.com"),
        .option("navigationType", "url"),
        .option("uid", "be1_0123456789abcdef0123456789abcdef"),
        .option("toUid", "be1_0123456789abcdef0123456789abcdef"),
        .option("text", "fixture"),
        .option("value", "fixture"),
        .option("key", "Return"),
        .option("submitKey", "Return"),
        .option("dialogAction", "accept"),
        .flag("includeSnapshot"),
        .flag("double"),
        .flag("bringToFront"),
        .flag("noBringToFront"),
        .flag("background"),
        .flag("foreground"),
        .option("timeout", "1s"),
        .option("pageSize", "10"),
        .option("pageIndex", "1"),
        .option("types", "error"),
        .option("resourceTypes", "script"),
        .flag("includePreserved"),
        .option("messageId", "1"),
        .option("requestId", "1"),
        .option("requestFilePath", "/private/tmp/request"),
        .option("responseFilePath", "/private/tmp/response"),
        .option("path", "/private/tmp/path"),
        .option("format", "png"),
        .option("quality", "80"),
        .flag("fullPage"),
        .option("traceAction", "start"),
        .flag("noReload"),
        .flag("noAutoStop"),
        .option("insightSetId", "fixture"),
        .option("insightName", "fixture"),
        .option("mcpTool", "fixture"),
        .option("mcpArgsJson", "{}"),
        .option("inputStrategy", "actionOnly"),
        .option("captureEngine", "classic"),
    ]

    static func option(_ label: String, _ value: String) -> Self {
        Self(optionLabel: label, optionValue: value, flagLabel: nil)
    }

    static func flag(_ label: String) -> Self {
        Self(optionLabel: nil, optionValue: nil, flagLabel: label)
    }

    @MainActor
    func apply(to values: inout ParsedValues) {
        if let optionLabel, let optionValue {
            values.options[optionLabel] = [optionValue]
        }
        if let flagLabel {
            values.flags.insert(flagLabel)
        }
    }
}
