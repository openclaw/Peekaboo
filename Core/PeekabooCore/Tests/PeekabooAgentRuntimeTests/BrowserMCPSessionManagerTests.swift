import Darwin
import Foundation
import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPSessionManagerTests {
    @Test
    func `channel connect refuses ambiguous same-channel processes before spawning MCP`() async {
        let manager = MockBrowserMCPManager()
        let browsers = [
            Self.browser(pid: 41, generation: 1041),
            Self.browser(pid: 42, generation: 1042),
        ]
        let session = Self.session(manager: manager, browsers: browsers)

        await #expect(throws: BrowserMCPConnectionError.ambiguousBrowsers(.stable, [41, 42])) {
            _ = try await session.connect(channel: .stable)
        }
        #expect(manager.addedConfigs.isEmpty)
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `connect probes list pages and publishes exact process receipt`() async throws {
        let manager = MockBrowserMCPManager()
        let browser = Self.browser(pid: 51, generation: 2051)
        let session = Self.session(manager: manager, browsers: [browser])

        let status = try await session.connect(channel: .stable)

        #expect(status.isConnected)
        #expect(status.toolCount == 29)
        #expect(status.connectionReceipt?.processIdentifier == 51)
        #expect(status.connectionReceipt?.processStartIdentity == 2051)
        #expect(manager.executedTools == ["list_pages"])
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.addedConfigs[0].autoReconnect == false)
    }

    @Test
    func `failed connection probe clears unknown MCP child`() async {
        let manager = MockBrowserMCPManager()
        manager.executeError = MockBrowserError.probe
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 61, generation: 3061)])

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.connect(channel: .stable)
        }
        #expect(manager.removeCount == 1)
        #expect(!manager.connected)
        let failedWorkspace = manager.addedConfigs.first?.env["TMPDIR"]
        #expect(failedWorkspace.map { !FileManager.default.fileExists(atPath: $0) } == true)
        let status = await session.status(channel: .stable)
        #expect(!status.isConnected)
        #expect(status.connectionReceipt == nil)
    }

    @Test
    func `lost MCP child refuses without implicit reconnect`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 71, generation: 4071)])
        _ = try await session.connect(channel: .stable)
        manager.connected = false
        manager.executedTools.removeAll()

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        #expect(manager.addedConfigs.count == 1)
        #expect(manager.executedTools.isEmpty)
        #expect(manager.removeCount == 1)
    }

    @Test
    func `process generation drift refuses before browser tool execution`() async throws {
        let manager = MockBrowserMCPManager()
        let currentGeneration = GenerationBox(5081)
        let browser = Self.browser(pid: 81, generation: 5081)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [browser] },
            processStartIdentity: { _ in currentGeneration.get() },
            endpointResolver: Self.endpointResolver())
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        currentGeneration.set(5082)

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `exact endpoint is converted to WebSocket target and locked until disconnect`() async throws {
        let manager = MockBrowserMCPManager()
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: Self.endpointResolver())

        let status = try await session.connect(
            channel: .stable,
            browserURL: "http://127.0.0.1:9222")
        #expect(status.connectionReceipt?.browserURL == "http://127.0.0.1:9222/")
        #expect(status.connectionReceipt?.devToolsBrowserID == "browser-a")
        #expect(manager.addedConfigs[0].args.contains(
            "--wsEndpoint=ws://127.0.0.1:9222/devtools/browser/browser-a"))

        await #expect(throws: BrowserMCPConnectionError.targetLocked) {
            _ = try await session.connect(
                channel: .stable,
                browserURL: "http://127.0.0.1:9333")
        }
    }

    @Test
    func `endpoint identity replacement refuses before execution`() async throws {
        let manager = MockBrowserMCPManager()
        let endpoints = EndpointMap()
        await endpoints.set("browser-a", port: 9222)
        let session = BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { _ in [] },
            processStartIdentity: { _ in nil },
            endpointResolver: BrowserMCPDevToolsEndpointResolver { url in
                try await endpoints.resolve(url)
            })
        _ = try await session.connect(channel: nil, browserURL: "http://127.0.0.1:9222")
        manager.executedTools.removeAll()
        await endpoints.set("browser-b", port: 9222)

        await #expect(throws: BrowserMCPConnectionError.self) {
            _ = try await session.execute(toolName: "take_snapshot", arguments: [:], channel: nil)
        }
        #expect(manager.executedTools.isEmpty)
    }

    @Test
    func `atomic browser sequence excludes a concurrent page action`() async throws {
        let manager = MockBrowserMCPManager()
        let session = Self.session(manager: manager, browsers: [Self.browser(pid: 91, generation: 6091)])
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let barrier = SequenceBarrier()
        manager.executeHandler = { toolName, _ in
            if toolName == "click" {
                await barrier.block()
            }
            return ToolResponse.text("ok")
        }

        let sequence = Task { @MainActor in
            try await session.executeSequence([
                BrowserMCPMappedCall(toolName: "click", arguments: ["uid": "91_1"]),
                BrowserMCPMappedCall(toolName: "type_text", arguments: ["text": "value"]),
            ], channel: nil)
        }
        await barrier.waitUntilBlocked()
        let contender = Task { @MainActor in
            try await session.execute(toolName: "hover", arguments: ["uid": "91_2"], channel: nil)
        }
        await Task.yield()
        await Task.yield()
        #expect(manager.executedTools == ["click"])

        await barrier.release()
        _ = try await sequence.value
        _ = try await contender.value
        #expect(manager.executedTools == ["click", "type_text", "hover"])
    }

    @Test
    func `connection advertises exact private TMPDIR and retains successful upload until disconnect`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "browser receipt.txt", contents: Data("receipt-value".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 101, generation: 7101)],
            uploadStager: fixture.stager())
        var stagedPath: String?
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            let path = try #require(arguments["filePath"] as? String)
            stagedPath = path
            #expect(URL(fileURLWithPath: path).lastPathComponent == "browser receipt.txt")
            #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("receipt-value".utf8))
            return ToolResponse.text("uploaded")
        }

        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])
        #expect(URL(fileURLWithPath: advertisedRoot).deletingLastPathComponent().path ==
            Self.canonicalPath(fixture.stagingParent.path))
        #expect(manager.addedConfigs.first?.args.contains("--allowUnrestrictedPaths") == false)
        manager.executedTools.removeAll()
        manager.executedArguments.removeAll()

        let response = try await session.execute(
            toolName: "upload_file",
            arguments: ["uid": "101_1", "filePath": source.path],
            channel: .stable)

        #expect(!response.isError)
        #expect(manager.executedTools == ["upload_file"])
        let actualStagedPath = try #require(stagedPath)
        #expect(actualStagedPath.hasPrefix(advertisedRoot + "/upload."))
        #expect(FileManager.default.fileExists(atPath: actualStagedPath))
        #expect(FileManager.default.fileExists(atPath: advertisedRoot))
        await session.disconnect()
        #expect(!FileManager.default.fileExists(atPath: advertisedRoot))
    }

    @Test
    func `invalid upload path is never dispatched and does not discard healthy browser session`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 111, generation: 8111)],
            uploadStager: fixture.stager())
        _ = try await session.connect(channel: .stable)
        manager.executedTools.removeAll()
        let removalsBefore = manager.removeCount

        await #expect(throws: BrowserMCPUploadStagingError.self) {
            _ = try await session.execute(
                toolName: "upload_file",
                arguments: ["uid": "111_1", "filePath": "relative.txt"],
                channel: .stable)
        }

        #expect(manager.executedTools.isEmpty)
        #expect(manager.connected)
        #expect(manager.removeCount == removalsBefore)
        #expect(await (session.status(channel: .stable)).isConnected)
    }

    @Test
    func `upload tool error retains dispatched transfer in exact browser workspace`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "failure.txt", contents: Data("failure".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 121, generation: 9121)],
            uploadStager: fixture.stager())
        var stagedPath: String?
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            stagedPath = arguments["filePath"] as? String
            return ToolResponse.error("fixture rejected upload")
        }
        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])

        let response = try await session.execute(
            toolName: "upload_file",
            arguments: ["uid": "121_1", "filePath": source.path],
            channel: .stable)

        #expect(response.isError)
        #expect(try FileManager.default.fileExists(atPath: #require(stagedPath)))
        #expect(FileManager.default.fileExists(atPath: advertisedRoot))
        #expect(manager.connected)
    }

    @Test
    func `caller cancellation removes staged bytes before noncooperative upload returns`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let source = try fixture.write(name: "cancel.txt", contents: Data("cancel".utf8))
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 131, generation: 10131)],
            uploadStager: fixture.stager())
        let barrier = SequenceBarrier()
        var stagedPath: String?
        var stagedFileExistedWhenChildRemoved = false
        manager.executeHandler = { toolName, arguments in
            guard toolName == "upload_file" else { return ToolResponse.text("ok") }
            stagedPath = arguments["filePath"] as? String
            await barrier.block()
            try Task.checkCancellation()
            return ToolResponse.text("unexpected")
        }
        manager.removeHandler = {
            stagedFileExistedWhenChildRemoved = stagedPath.map {
                FileManager.default.fileExists(atPath: $0)
            } ?? false
        }
        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])

        let upload = Task { @MainActor in
            try await session.execute(
                toolName: "upload_file",
                arguments: ["uid": "131_1", "filePath": source.path],
                channel: .stable)
        }
        await barrier.waitUntilBlocked()
        let actualStagedPath = try #require(stagedPath)
        #expect(FileManager.default.fileExists(atPath: actualStagedPath))
        upload.cancel()
        #expect(await Self.waitUntilMissing(advertisedRoot))
        #expect(stagedFileExistedWhenChildRemoved)
        #expect(!FileManager.default.fileExists(atPath: actualStagedPath))
        await barrier.release()
        await #expect(throws: CancellationError.self) {
            _ = try await upload.value
        }
    }

    @Test
    func `lost child cleanup removes the advertised browser workspace`() async throws {
        let fixture = try UploadStagingFixture()
        defer { fixture.cleanup() }
        let manager = MockBrowserMCPManager()
        let session = Self.session(
            manager: manager,
            browsers: [Self.browser(pid: 141, generation: 11141)],
            uploadStager: fixture.stager())
        _ = try await session.connect(channel: .stable)
        let advertisedRoot = try #require(manager.addedConfigs.first?.env["TMPDIR"])
        #expect(FileManager.default.fileExists(atPath: advertisedRoot))
        manager.connected = false

        let status = await session.status(channel: .stable)

        #expect(!status.isConnected)
        #expect(!FileManager.default.fileExists(atPath: advertisedRoot))
    }

    private static func session(
        manager: MockBrowserMCPManager,
        browsers: [DetectedBrowser],
        uploadStager: BrowserMCPUploadStager = .live) -> BrowserMCPSessionManager
    {
        let generations = Dictionary(uniqueKeysWithValues: browsers.compactMap { browser in
            browser.processStartIdentity.map { (browser.processIdentifier, $0) }
        })
        return BrowserMCPSessionManager(
            serverName: "test-browser",
            manager: manager,
            detectedBrowsers: { channel in
                browsers.filter { channel == nil || $0.channel == channel }
            },
            processStartIdentity: { generations[$0] },
            endpointResolver: self.endpointResolver(),
            uploadStager: uploadStager)
    }

    private static func browser(pid: Int32, generation: UInt64) -> DetectedBrowser {
        DetectedBrowser(
            name: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            processIdentifier: pid,
            processStartIdentity: generation,
            version: "151.0",
            channel: .stable)
    }

    private static func endpointResolver() -> BrowserMCPDevToolsEndpointResolver {
        BrowserMCPDevToolsEndpointResolver { url in
            guard let port = URL(string: url)?.port else {
                throw BrowserMCPConnectionError.invalidEndpoint("missing port")
            }
            return BrowserMCPDevToolsEndpoint(
                browserURL: "http://127.0.0.1:\(port)/",
                webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/browser-a",
                browserID: "browser-a",
                browserVersion: "Chrome/151.0",
                protocolVersion: "1.3")
        }
    }

    private static func canonicalPath(_ path: String) -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else { return path }
        let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8) ?? path
    }

    private static func waitUntilMissing(_ path: String) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while FileManager.default.fileExists(atPath: path), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !FileManager.default.fileExists(atPath: path)
    }
}

@MainActor
private final class MockBrowserMCPManager: BrowserMCPManaging {
    var connected = false
    var hasConfiguredServer = false
    var addedConfigs: [MCPServerConfig] = []
    var executedTools: [String] = []
    var executedArguments: [[String: Any]] = []
    var removeCount = 0
    var executeError: (any Error)?
    var executeHandler: (@MainActor (String, [String: Any]) async throws -> ToolResponse)?
    var removeHandler: (@MainActor () async -> Void)?

    func hasServer(name _: String) -> Bool {
        self.hasConfiguredServer
    }

    func isServerConnected(name _: String) async -> Bool {
        self.connected
    }

    func serverToolCount(name _: String) async -> Int {
        self.connected ? 29 : 0
    }

    func addServer(name _: String, config: MCPServerConfig) async throws {
        self.addedConfigs.append(config)
        self.hasConfiguredServer = true
        self.connected = true
    }

    func removeServer(name _: String) async {
        await self.removeHandler?()
        self.removeCount += 1
        self.hasConfiguredServer = false
        self.connected = false
    }

    func executeTool(
        serverName _: String,
        toolName: String,
        arguments: [String: Any]) async throws -> ToolResponse
    {
        if let executeError {
            throw executeError
        }
        self.executedTools.append(toolName)
        self.executedArguments.append(arguments)
        if let executeHandler {
            return try await executeHandler(toolName, arguments)
        }
        return ToolResponse.text("ok")
    }
}

private enum MockBrowserError: Error {
    case probe
}

private final class GenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64?

    init(_ value: UInt64?) {
        self.value = value
    }

    func get() -> UInt64? {
        self.lock.withLock { self.value }
    }

    func set(_ value: UInt64?) {
        self.lock.withLock { self.value = value }
    }
}

private actor EndpointMap {
    private var endpoints: [Int: String] = [:]

    func set(_ browserID: String, port: Int) {
        self.endpoints[port] = browserID
    }

    func resolve(_ url: String) throws -> BrowserMCPDevToolsEndpoint {
        guard let port = URL(string: url)?.port,
              let browserID = self.endpoints[port]
        else {
            throw BrowserMCPConnectionError.invalidEndpoint("unknown endpoint")
        }
        return BrowserMCPDevToolsEndpoint(
            browserURL: "http://127.0.0.1:\(port)/",
            webSocketDebuggerURL: "ws://127.0.0.1:\(port)/devtools/browser/\(browserID)",
            browserID: browserID,
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
    }
}

private actor SequenceBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { continuation in
            self.blockedWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}
