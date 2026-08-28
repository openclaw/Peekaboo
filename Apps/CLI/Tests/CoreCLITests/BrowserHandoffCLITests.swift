import Commander
import Darwin
import Foundation
import MCP
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI

struct BrowserHandoffCLITests {
    private struct InvalidBrowserInput {
        let action: String
        let handoffs: [String]
        let sockets: [String]
        let flags: Set<String>
        let expectedMessage: String
    }

    @Test
    @MainActor
    func `browser and MCP help expose only the explicit handoff file workflow`() throws {
        let browserHelp = BrowserCommand.helpMessage()
        let mcpHelp = MCPCommand.Serve.helpMessage()

        #expect(browserHelp.contains("--handoff-file"))
        #expect(browserHelp.contains("authenticated browser handoff receipt"))
        #expect(mcpHelp.contains("--browser-handoff"))
        #expect(mcpHelp.contains("authenticated browser target"))

        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let invocation = try Program(descriptors: descriptors.map(\.metadata)).resolve(argv: [
            "peekaboo", "mcp", "serve",
            "--browser-handoff", "/private/tmp/handoff.json",
            "--bridge-socket", "/private/tmp/bridge.sock",
        ])
        #expect(invocation.parsedValues.options["browserHandoff"] == ["/private/tmp/handoff.json"])
        #expect(invocation.parsedValues.options["bridge-socket"] == ["/private/tmp/bridge.sock"])
    }

    @Test
    @MainActor
    func `browser handoff requires connect foreground one exact socket and one absolute destination`() throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let handoff = directory.appendingPathComponent("handoff.json").path
        let socket = "/private/tmp/peekaboo-handoff.sock"

        let valid = try Self.browserCommand(
            action: "connect",
            handoffValues: [handoff],
            socketValues: [socket],
            flags: ["foreground"]
        )
        #expect(throws: Never.self) { try valid.validateBeforeRuntime() }
        #expect(valid.runtimeOptions.requiresBrowserHandoffBridge)
        #expect(throws: ValidationError.self) {
            try valid.validateHandoffEnvironment(["PEEKABOO_NO_REMOTE": "1"])
        }
        #expect(throws: ValidationError.self) {
            try valid.validateHandoffEnvironment(["PEEKABOO_BRIDGE_SOCKET": "/private/tmp/other.sock"])
        }

        let cases = [
            InvalidBrowserInput(
                action: "connect",
                handoffs: [handoff],
                sockets: [socket],
                flags: [],
                expectedMessage: "requires --foreground"
            ),
            InvalidBrowserInput(
                action: "status",
                handoffs: [handoff],
                sockets: [socket],
                flags: ["foreground"],
                expectedMessage: "accepted only by browser connect"
            ),
            InvalidBrowserInput(
                action: "connect",
                handoffs: [handoff],
                sockets: [],
                flags: ["foreground"],
                expectedMessage: "requires exactly one --bridge-socket"
            ),
            InvalidBrowserInput(
                action: "connect",
                handoffs: ["relative.json"],
                sockets: [socket],
                flags: ["foreground"],
                expectedMessage: "path must be absolute"
            ),
            InvalidBrowserInput(
                action: "connect",
                handoffs: [handoff],
                sockets: [socket],
                flags: ["foreground", "no-remote"],
                expectedMessage: "does not support --no-remote"
            ),
        ]
        for testCase in cases {
            do {
                let command = try Self.browserCommand(
                    action: testCase.action,
                    handoffValues: testCase.handoffs,
                    socketValues: testCase.sockets,
                    flags: testCase.flags
                )
                try command.validateBeforeRuntime()
                Issue.record("Expected refusal containing \(testCase.expectedMessage)")
            } catch {
                #expect(error.localizedDescription.contains(testCase.expectedMessage))
            }
        }

        #expect(throws: ValidationError.self) {
            _ = try Self.browserCommand(
                action: "connect",
                handoffValues: [handoff, directory.appendingPathComponent("other.json").path],
                socketValues: [socket],
                flags: ["foreground"]
            )
        }
        #expect(throws: ValidationError.self) {
            _ = try Self.browserCommand(
                action: "connect",
                handoffValues: [handoff],
                socketValues: [socket, "/private/tmp/other.sock"],
                flags: ["foreground"]
            )
        }
    }

    @Test
    @MainActor
    func `hidden handoff request is command line only and never enters tool output`() async throws {
        let provider = HandoffToolFixtureBrowser()
        let arguments = ToolArguments(raw: [
            "action": "connect",
            "browser_url": "http://127.0.0.1:9222",
            "request_handoff": true,
        ])

        let mcpResponse = try await BrowserTool(
            client: provider,
            executionPolicy: .foregroundAllowed,
            instructionAudience: .mcp
        ).execute(arguments: arguments)
        #expect(mcpResponse.isError)
        #expect(provider.handoffConnectCount == 0)

        let cliResponse = try await BrowserTool(
            client: provider,
            executionPolicy: .foregroundAllowed,
            instructionAudience: .commandLine
        ).execute(arguments: arguments)
        #expect(!cliResponse.isError)
        #expect(provider.handoffConnectCount == 1)
        #expect(!String(describing: cliResponse).contains("private-handoff-bytes"))
        #expect(provider.takeConnectionHandoffReceiptBundleData() == Data("private-handoff-bytes".utf8))
        #expect(provider.takeConnectionHandoffReceiptBundleData() == nil)
    }

    @Test
    @MainActor
    func `store atomically publishes and stably reloads canonical mode 0600 bytes`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))

        try store.validateCanSave()
        try store.save(fixture)
        #expect(try store.load() == fixture)
        var info = stat()
        #expect(lstat(store.fileURL.path, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFREG)
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(info.st_uid == geteuid())
        #expect(info.st_nlink == 1)
        #expect(throws: BrowserHandoffReceiptStoreError.alreadyExists) { try store.validateCanSave() }
        #expect(throws: BrowserHandoffReceiptStoreError.alreadyExists) { try store.save(fixture) }
        #expect(try store.load() == fixture)
    }

    @Test
    @MainActor
    func `store rejects symlinks hardlinks widened modes ACLs and nonprivate parents`() async throws {
        let fixture = try await Self.canonicalHandoffData()

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let target = directory.appendingPathComponent("target.json")
            let link = directory.appendingPathComponent("handoff.json")
            try fixture.write(to: target)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let store = BrowserHandoffReceiptStore(fileURL: link)
            #expect(throws: BrowserHandoffReceiptStoreError.self) { try store.load() }
            #expect(throws: BrowserHandoffReceiptStoreError.self) { try store.validateCanSave() }
        }

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("handoff.json")
            let alias = directory.appendingPathComponent("alias.json")
            try fixture.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            #expect(link(file.path, alias.path) == 0)
            #expect(throws: BrowserHandoffReceiptStoreError.self) {
                try BrowserHandoffReceiptStore(fileURL: file).load()
            }
        }

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("handoff.json")
            try fixture.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
            #expect(throws: BrowserHandoffReceiptStoreError.self) {
                try BrowserHandoffReceiptStore(fileURL: file).load()
            }
        }

        do {
            let directory = try Self.privateDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("handoff.json")
            try fixture.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try Self.addReadableACL(to: file)
            #expect(throws: BrowserHandoffReceiptStoreError.self) {
                try BrowserHandoffReceiptStore(fileURL: file).load()
            }
        }

        do {
            let directory = try Self.privateDirectory(mode: 0o755)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))
            #expect(throws: BrowserHandoffReceiptStoreError.self) { try store.validateCanSave() }
        }
    }

    @Test
    @MainActor
    func `store rejects path substitution noncanonical bytes and oversized input`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("handoff.json")
        let displaced = directory.appendingPathComponent("displaced.json")
        let store = BrowserHandoffReceiptStore(fileURL: file)
        try store.save(fixture)

        #expect(throws: BrowserHandoffReceiptStoreError.self) {
            try store.load {
                try FileManager.default.moveItem(at: file, to: displaced)
                try fixture.write(to: file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }

        var noncanonical = fixture
        noncanonical.append(UInt8(ascii: "\n"))
        #expect(throws: BrowserHandoffReceiptStoreError.self) {
            try BrowserHandoffReceiptStore.validateCanonicalReceipt(noncanonical)
        }
        let oversized = Data(
            repeating: UInt8(ascii: "x"),
            count: Int(BrowserHandoffReceiptStore.maximumReceiptBytes) + 1
        )
        #expect(throws: BrowserHandoffReceiptStoreError.self) {
            try BrowserHandoffReceiptStore.validateCanonicalReceipt(oversized)
        }
        #expect(throws: BrowserHandoffReceiptStoreError.self) {
            _ = try BrowserHandoffReceiptStore(resolvingAbsolutePath: "relative.json")
        }

        let longNameDirectory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: longNameDirectory) }
        let longNameStore = BrowserHandoffReceiptStore(
            fileURL: longNameDirectory.appendingPathComponent(String(repeating: "a", count: 255))
        )
        try longNameStore.validateCanSave()
        try longNameStore.save(fixture)
        #expect(try longNameStore.load() == fixture)
    }

    @Test
    @MainActor
    func `MCP input loads canonical bytes and rejects duplicate conflicting or local routing`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))
        try store.save(fixture)
        let socket = "/private/tmp/peekaboo-handoff.sock"
        let valid = ParsedValues(
            positional: [],
            options: [
                "browserHandoff": [store.fileURL.path],
                "bridge-socket": [socket],
            ],
            flags: []
        )

        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: valid,
            commandType: MCPCommand.Serve.self,
            environment: [:]
        )
        #expect(options.browserHandoffReceiptBundleData == fixture)
        #expect(options.bridgeSocketPath == socket)
        #expect(options.preferRemote)
        #expect(!options.remoteIsolationRequested)
        #expect(!options.autoStartDaemon)
        #expect(options.requiresBrowserHandoffBridge)
        let captureEnvironmentOptions = options.applyingEnvironmentOverrides(
            environment: ["PEEKABOO_CAPTURE_ENGINE": "classic"]
        )
        #expect(captureEnvironmentOptions.preferRemote)
        #expect(!captureEnvironmentOptions.remoteIsolationRequested)
        let runtime = CommandRuntime(options: options, services: PeekabooServices())
        #expect(runtime.browserHandoffReceiptBundleData == fixture)

        let invalidCases: [(ParsedValues, [String: String], BrowserHandoffCLIInputError)] = [
            (
                ParsedValues(
                    positional: [],
                    options: [
                        "browserHandoff": [store.fileURL.path, store.fileURL.path],
                        "bridge-socket": [socket],
                    ],
                    flags: []
                ),
                [:],
                .duplicateOption("--browser-handoff")
            ),
            (
                ParsedValues(
                    positional: [],
                    options: ["browserHandoff": [store.fileURL.path]],
                    flags: []
                ),
                [:],
                .exactBridgeSocketRequired
            ),
            (
                ParsedValues(
                    positional: [],
                    options: ["browserHandoff": [store.fileURL.path], "bridge-socket": [socket]],
                    flags: ["no-remote"]
                ),
                [:],
                .localExecutionRefused
            ),
            (valid, ["PEEKABOO_NO_REMOTE": "1"], .localExecutionRefused),
            (
                valid,
                ["PEEKABOO_BRIDGE_SOCKET": "/private/tmp/other.sock"],
                .conflictingBridgeSocket
            ),
        ]
        for (values, environment, expected) in invalidCases {
            #expect(throws: expected) {
                _ = try CommanderCLIBinder.makeRuntimeOptions(
                    from: values,
                    commandType: MCPCommand.Serve.self,
                    environment: environment
                )
            }
        }
    }

    @Test
    @MainActor
    func `unsafe MCP receipt refuses before runtime factory construction`() async throws {
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipt = directory.appendingPathComponent("handoff.json")
        try Data("{}".utf8).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        var runtimeConstructed = false

        await #expect(throws: BrowserHandoffCLIInputError.self) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: [
                    "peekaboo", "mcp", "serve",
                    "--browser-handoff", receipt.path,
                    "--bridge-socket", "/private/tmp/peekaboo-handoff.sock",
                ],
                runtimeFactory: .init { _ in
                    runtimeConstructed = true
                    return CommandRuntime(options: CommandRuntimeOptions(), services: PeekabooServices())
                }
            )
        }
        #expect(!runtimeConstructed)
    }

    @Test
    @MainActor
    func `valid MCP receipt reaches runtime factory before any server construction`() async throws {
        let fixture = try await Self.canonicalHandoffData()
        let directory = try Self.privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BrowserHandoffReceiptStore(fileURL: directory.appendingPathComponent("handoff.json"))
        try store.save(fixture)
        var receivedData: Data?

        await #expect(throws: StopBeforeRuntimeConstruction.self) {
            try await CommanderRuntimeExecutor.resolveAndRun(
                arguments: [
                    "peekaboo", "mcp", "serve",
                    "--browser-handoff", store.fileURL.path,
                    "--bridge-socket", "/private/tmp/peekaboo-handoff.sock",
                ],
                runtimeFactory: .init { options in
                    receivedData = options.browserHandoffReceiptBundleData
                    throw StopBeforeRuntimeConstruction()
                }
            )
        }
        #expect(receivedData == fixture)
    }

    @Test
    @MainActor
    func `handoff adoption is scoped fail closed and cleaned up exactly once`() async throws {
        let receiptData = Data("fixture-signed-handoff".utf8)
        let provider = HandoffToolFixtureBrowser()
        let services = Self.services(browser: provider)
        let runtime = CommandRuntime(
            configuration: .init(
                verbose: false,
                jsonOutput: false,
                logLevel: nil,
                captureEnginePreference: nil,
                inputStrategy: nil
            ),
            services: services,
            selectedRemoteSocketPath: "/private/tmp/peekaboo-handoff.sock",
            browserHandoffReceiptBundleData: receiptData
        )

        let adoption = try #require(try await MCPCommand.Serve.adoptBrowserHandoffIfRequested(using: runtime))
        #expect(provider.adoptedReceiptData == receiptData)
        let scopedBrowser = try #require(provider.adoptedBrowser)
        let context = MCPCommand.Serve.makeToolContext(
            services: services,
            snapshotMutationCoordinator: nil,
            browser: adoption.browser
        )
        #expect(ObjectIdentifier(context.browser as AnyObject) == ObjectIdentifier(scopedBrowser))
        #expect(ObjectIdentifier(context.browser as AnyObject) != ObjectIdentifier(provider))
        await adoption.close()
        await adoption.close()
        #expect(provider.adoptionCleanupCount == 1)

        let unavailableRuntime = CommandRuntime(
            configuration: runtime.configuration,
            services: PeekabooServices(),
            selectedRemoteSocketPath: "/private/tmp/peekaboo-handoff.sock",
            browserHandoffReceiptBundleData: receiptData
        )
        await #expect(throws: BrowserHandoffCLIInputError.adoptionUnavailable) {
            _ = try await MCPCommand.Serve.adoptBrowserHandoffIfRequested(using: unavailableRuntime)
        }
    }

    @MainActor
    private static func browserCommand(
        action: String,
        handoffValues: [String],
        socketValues: [String],
        flags: Set<String>
    ) throws -> BrowserCommand {
        var options: [String: [String]] = [:]
        if !handoffValues.isEmpty {
            options["handoffFile"] = handoffValues
        }
        if !socketValues.isEmpty {
            options["bridge-socket"] = socketValues
        }
        return try CommanderCLIBinder.instantiateCommand(
            ofType: BrowserCommand.self,
            parsedValues: ParsedValues(positional: [action], options: options, flags: flags)
        )
    }

    private static func privateDirectory(mode: Int = 0o700) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-browser-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: mode]
        )
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: directory.path)
        return directory
    }

    private static func addReadableACL(to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = ["+a", "everyone allow read", url.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    @MainActor
    private static func canonicalHandoffData() async throws -> Data {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent(
            "pbh-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = HandoffToolFixtureBrowser()
        let services = Self.services(browser: browser)
        let socket = root.appendingPathComponent("bridge.sock").path
        let host = PeekabooBridgeHost(
            socketPath: socket,
            server: PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: []
            ),
            allowedTeamIDs: [],
            requestTimeoutSec: 2
        )
        try await host.startChecked()
        do {
            let client = BridgeTestFixtures.authenticatedClient(socketPath: socket, requestTimeoutSec: 2)
            _ = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.browser-handoff-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()
            ))
            let handoff = try await client.browserConnectHandoffResult(
                channel: "stable",
                browserURL: "http://127.0.0.1:9222"
            )
            let encoder = JSONEncoder.peekabooBridgeEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(handoff.receiptBundle)
            await host.stop()
            return data
        } catch {
            await host.stop()
            throw error
        }
    }

    @MainActor
    private static func services(browser: any BrowserMCPClientProviding) -> PeekabooServices {
        let defaults = PeekabooServices()
        return PeekabooServices(
            logging: defaults.logging,
            screenCapture: defaults.screenCapture,
            applications: defaults.applications,
            automation: defaults.automation,
            windows: defaults.windows,
            menu: defaults.menu,
            dock: defaults.dock,
            dialogs: defaults.dialogs,
            snapshots: defaults.snapshots,
            files: defaults.files,
            clipboard: defaults.clipboard,
            permissions: defaults.permissions,
            audioInput: defaults.audioInput,
            browser: browser,
            configuration: defaults.configuration,
            screens: defaults.screens
        )
    }
}

@MainActor
private final class HandoffToolFixtureBrowser: BrowserMCPConnectionHandoffProviding,
BrowserHandoffRuntimeAdopting, @unchecked Sendable {
    private(set) var handoffConnectCount = 0
    private var handoffData: Data?
    private(set) var adoptedReceiptData: Data?
    private(set) var adoptedBrowser: HandoffToolFixtureBrowser?
    private(set) var adoptionCleanupCount = 0

    nonisolated var supportsNativeBrowserConnectionBinding: Bool {
        true
    }

    private static let receipt = BrowserMCPConnectionReceipt(
        channel: .stable,
        browserURL: "http://127.0.0.1:9222/",
        webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-handoff",
        devToolsBrowserID: "browser-handoff",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3"
    )

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        Self.connectedStatus
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        Self.connectedStatus
    }

    func connect(channel _: BrowserMCPChannel?, browserURL _: String?) async throws -> BrowserMCPStatus {
        Self.connectedStatus
    }

    func connectWithOutcome(
        channel _: BrowserMCPChannel?,
        browserURL _: String?
    ) async throws -> DesktopActionResult<BrowserMCPStatus> {
        DesktopActionResult(payload: Self.connectedStatus, outcome: .confirmedNoChange())
    }

    func connectWithHandoffOutcome(
        channel _: BrowserMCPChannel?,
        browserURL _: String?
    ) async throws -> DesktopActionResult<BrowserMCPStatus> {
        self.handoffConnectCount += 1
        self.handoffData = Data("private-handoff-bytes".utf8)
        return DesktopActionResult(payload: Self.connectedStatus, outcome: .confirmedNoChange())
    }

    func takeConnectionHandoffReceiptBundleData() -> Data? {
        defer { self.handoffData = nil }
        return self.handoffData
    }

    func adoptBrowserHandoff(receiptBundleData: Data) async throws -> BrowserMCPAdoptedHandoff {
        let child = HandoffToolFixtureBrowser()
        self.adoptedReceiptData = receiptBundleData
        self.adoptedBrowser = child
        return BrowserMCPAdoptedHandoff(browser: child) { [weak self] in
            await self?.recordAdoptionCleanup()
        }
    }

    private func recordAdoptionCleanup() {
        self.adoptionCleanupCount += 1
    }

    func disconnect() async {}

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?
    ) async throws -> ToolResponse {
        .error("unexpected")
    }

    private static var connectedStatus: BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: true,
            toolCount: 3,
            detectedBrowsers: [],
            connectionReceipt: self.receipt
        )
    }
}

private struct StopBeforeRuntimeConstruction: Error {}
