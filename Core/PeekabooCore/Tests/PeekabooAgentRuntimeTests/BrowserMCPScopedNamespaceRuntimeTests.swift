import Foundation
import MCP
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserMCPScopedNamespaceRuntimeTests {
    @Test
    func `cross namespace page references refuse before fake provider dispatch`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let firstID = Self.namespaceID(1)
        let secondID = Self.namespaceID(2)
        try fixture.runtime.open(firstID)
        try fixture.runtime.open(secondID)

        let firstPage = try await Self.pageReference(from: fixture.runtime.execute(
            in: firstID,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        let secondPage = try await Self.pageReference(from: fixture.runtime.execute(
            in: secondID,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        #expect(firstPage != secondPage)
        let second = try #require(fixture.sessions[secondID])
        let dispatchCount = second.providerDispatchCount

        let rejected = try await fixture.runtime.execute(
            in: secondID,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": firstPage,
            ]))

        #expect(rejected.response.isError)
        #expect(Self.text(from: rejected.response).contains("another or expired provider session"))
        #expect(second.providerDispatchCount == dispatchCount)
        #expect(secondPage.hasPrefix("bp1_"))
    }

    @Test
    func `close publishes closing then joins one drain and releases the identity`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let namespaceID = Self.namespaceID(3)
        try fixture.runtime.open(namespaceID)
        let session = try #require(fixture.sessions[namespaceID])
        let executionBarrier = NamespaceRuntimeBarrier()
        session.executionBarrier = executionBarrier

        let execution = Task { @MainActor in
            try await fixture.runtime.execute(
                in: namespaceID,
                arguments: ToolArguments(raw: ["action": "status"]))
        }
        await executionBarrier.waitUntilBlocked()
        let firstCloseFinished = NamespaceRuntimeFlag()
        let secondCloseFinished = NamespaceRuntimeFlag()
        let firstClose = Task { @MainActor in
            try await fixture.runtime.close(namespaceID)
            await firstCloseFinished.mark()
        }
        await session.closeStarted.waitUntilSignalled()
        let secondClose = Task { @MainActor in
            try await fixture.runtime.close(namespaceID)
            await secondCloseFinished.mark()
        }
        await Task.yield()

        do {
            _ = try await fixture.runtime.execute(
                in: namespaceID,
                arguments: ToolArguments(raw: ["action": "status"]))
            Issue.record("Expected closing namespace to reject new work")
        } catch let error as BrowserMCPScopedNamespaceRuntimeError {
            #expect(error == .namespaceClosing)
        }
        #expect(await !firstCloseFinished.value)
        #expect(await !secondCloseFinished.value)
        #expect(session.closeCount == 1)

        await executionBarrier.release()
        _ = try await execution.value
        try await firstClose.value
        try await secondClose.value
        #expect(session.closeCount == 1)
        #expect(await firstCloseFinished.value)
        #expect(await secondCloseFinished.value)

        do {
            _ = try await fixture.runtime.execute(
                in: namespaceID,
                arguments: ToolArguments(raw: ["action": "status"]))
            Issue.record("Expected closed namespace to reject new work")
        } catch let error as BrowserMCPScopedNamespaceRuntimeError {
            #expect(error == .namespaceUnknown)
        }
        try await fixture.runtime.close(namespaceID)
        #expect(session.closeCount == 1)
    }

    @Test
    func `sequential namespace closes retain no runtime identities`() async throws {
        let fixture = NamespaceRuntimeFixture()
        for index in 1...96 {
            let namespaceID = BrowserMCPScopedNamespaceID(rawValue: UUID())
            try fixture.runtime.open(namespaceID)
            _ = try await fixture.runtime.execute(
                in: namespaceID,
                arguments: ToolArguments(raw: ["action": "status"]))
            try await fixture.runtime.close(namespaceID)
            #expect(fixture.runtime.namespaceCount == 0, "retained namespace at cycle \(index)")
        }
    }

    @Test
    func `independent namespaces overlap while each retains its own session`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let firstID = Self.namespaceID(4)
        let secondID = Self.namespaceID(5)
        try fixture.runtime.open(firstID)
        try fixture.runtime.open(secondID)
        let first = try #require(fixture.sessions[firstID])
        let second = try #require(fixture.sessions[secondID])
        let firstBarrier = NamespaceRuntimeBarrier()
        let secondBarrier = NamespaceRuntimeBarrier()
        first.executionBarrier = firstBarrier
        second.executionBarrier = secondBarrier

        let firstExecution = Task { @MainActor in
            try await fixture.runtime.execute(
                in: firstID,
                arguments: ToolArguments(raw: ["action": "status"]))
        }
        await firstBarrier.waitUntilBlocked()
        let secondExecution = Task { @MainActor in
            try await fixture.runtime.execute(
                in: secondID,
                arguments: ToolArguments(raw: ["action": "status"]))
        }
        await secondBarrier.waitUntilBlocked()

        #expect(first.activeExecutionCount == 1)
        #expect(second.activeExecutionCount == 1)
        await firstBarrier.release()
        await secondBarrier.release()
        _ = try await firstExecution.value
        _ = try await secondExecution.value
    }

    @Test
    func `new runtime generation and namespace reject references from an ended session`() async throws {
        let firstFixture = NamespaceRuntimeFixture()
        let endedID = Self.namespaceID(6)
        try firstFixture.runtime.open(endedID)
        let endedPage = try await Self.pageReference(from: firstFixture.runtime.execute(
            in: endedID,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        try await firstFixture.runtime.close(endedID)

        let restartedFixture = NamespaceRuntimeFixture()
        let restartedID = Self.namespaceID(7)
        try restartedFixture.runtime.open(restartedID)
        let restarted = try #require(restartedFixture.sessions[restartedID])
        let dispatchCount = restarted.providerDispatchCount
        let rejected = try await restartedFixture.runtime.execute(
            in: restartedID,
            arguments: ToolArguments(raw: [
                "action": "snapshot",
                "page_id": endedPage,
            ]))

        #expect(rejected.response.isError)
        #expect(restarted.providerDispatchCount == dispatchCount)
        let restartedPage = try await Self.pageReference(from: restartedFixture.runtime.execute(
            in: restartedID,
            arguments: ToolArguments(raw: ["action": "list_pages"])))
        #expect(restartedPage != endedPage)
    }

    @Test
    func `host generation retirement closes independent children concurrently`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let firstID = Self.namespaceID(10)
        let secondID = Self.namespaceID(11)
        try fixture.runtime.open(firstID)
        try fixture.runtime.open(secondID)
        let first = try #require(fixture.sessions[firstID])
        let second = try #require(fixture.sessions[secondID])
        let firstBarrier = NamespaceRuntimeBarrier()
        let secondBarrier = NamespaceRuntimeBarrier()
        first.executionBarrier = firstBarrier
        second.executionBarrier = secondBarrier
        let firstExecution = Task { @MainActor in
            try await fixture.runtime.execute(
                in: firstID,
                arguments: ToolArguments(raw: ["action": "status"]))
        }
        let secondExecution = Task { @MainActor in
            try await fixture.runtime.execute(
                in: secondID,
                arguments: ToolArguments(raw: ["action": "status"]))
        }
        await firstBarrier.waitUntilBlocked()
        await secondBarrier.waitUntilBlocked()

        let retirement = Task { @MainActor in await fixture.runtime.closeAll() }
        await first.closeStarted.waitUntilSignalled()
        await second.closeStarted.waitUntilSignalled()
        #expect(first.closeCount == 1)
        #expect(second.closeCount == 1)
        #expect(throws: BrowserMCPScopedNamespaceRuntimeError.namespaceClosing) {
            try fixture.runtime.open(Self.namespaceID(12))
        }

        await firstBarrier.release()
        await secondBarrier.release()
        _ = try await firstExecution.value
        _ = try await secondExecution.value
        await retirement.value
        #expect(throws: BrowserMCPScopedNamespaceRuntimeError.namespaceEnded) {
            try fixture.runtime.open(Self.namespaceID(13))
        }
        for namespaceID in [firstID, secondID] {
            do {
                _ = try await fixture.runtime.execute(
                    in: namespaceID,
                    arguments: ToolArguments(raw: ["action": "status"]))
                Issue.record("Expected retired namespace to remain ended")
            } catch let error as BrowserMCPScopedNamespaceRuntimeError {
                #expect(error == .namespaceEnded)
            }
        }
    }

    @Test
    func `bind and foreground connect use one high level non sticky execution path`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let namespaceID = Self.namespaceID(8)
        try fixture.runtime.open(namespaceID)
        let session = try #require(fixture.sessions[namespaceID])
        _ = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: ["action": "connect"]),
            policy: .explicitlyForegroundAllowed)
        let page = try await Self.pageReference(from: fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: ["action": "list_pages"])))

        let bound = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: [
                "action": BrowserProcessLocalAction.bindWindow,
                "page_id": page,
                "pid": 42,
                "window_id": 313,
            ]))
        let navigated = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: [
                "action": "navigate",
                "page_id": page,
                "url": "https://example.test/next",
            ]))
        _ = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: ["action": "status"]))

        let bind = try #require(session.executions.first { $0.arguments.getString("action") == "bind_window" })
        #expect(bind.arguments.getString("page_id") == page)
        #expect(bind.arguments.getInt("pid") == 42)
        #expect(bind.arguments.getInt("window_id") == 313)
        #expect(bind.arguments.getValue(for: "mcp_tool") == nil)
        #expect(bind.policy == .backgroundOnly)
        #expect(session.executions.first?.policy == .explicitlyForegroundAllowed)
        #expect(session.executions.dropFirst().allSatisfy { $0.policy == .backgroundOnly })
        for receipt in [bound.nativeWindowReceipt, navigated.nativeWindowReceipt] {
            #expect(receipt?.pageReference == page)
            #expect(receipt?.processIdentifier == 42)
            #expect(receipt?.processStartIdentity == 1001)
            #expect(receipt?.windowID == 313)
            #expect(receipt?.quality == .exact)
        }
    }

    @Test
    func `foreground connect projects its top level process receipt as exact target`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let namespaceID = Self.namespaceID(14)
        try fixture.runtime.open(namespaceID)
        let session = try #require(fixture.sessions[namespaceID])
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one)
        session.response = try ToolResponse.text(
            "connected",
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: [
                    "connection_receipt": .object([
                        "pid": .int(42),
                        "process_start_identity_decimal": .string("1001"),
                        "browser_url": .string("http://127.0.0.1:9222"),
                    ]),
                ],
                outcome: outcome))

        let connected = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: ["action": "connect"]),
            policy: .explicitlyForegroundAllowed)

        #expect(connected.targetIdentity?.processIdentity.processIdentifier == 42)
        #expect(connected.targetIdentity?.processIdentity.processStartIdentity == 1001)
        #expect(connected.outcome == outcome)
        #expect(!Self.dump(connected.response).contains("127.0.0.1:9222"))
    }

    @Test
    func `recursive scrubber removes host IDs and fails closed on raw provider capabilities`() async throws {
        let fixture = NamespaceRuntimeFixture()
        let namespaceID = Self.namespaceID(9)
        try fixture.runtime.open(namespaceID)
        let session = try #require(fixture.sessions[namespaceID])
        session.response = ToolResponse(
            content: [.text(
                text: "Chrome status\n- endpoint=http://127.0.0.1:9222 browser_id=private-browser",
                annotations: nil,
                _meta: Metadata(additionalFields: [
                    "nested": .object(["browser_url": .string("http://127.0.0.1:9222")]),
                ]))],
            meta: .object([
                BrowserMCPExecutionEvidence.metadataKey: .object([
                    "provider_session_epoch": .string("private-epoch"),
                    "connection_receipt": .object([
                        "pid": .int(42),
                        "process_start_identity_decimal": .string("1001"),
                        "browser_url": .string("http://127.0.0.1:9222"),
                        "websocket_debugger_url": .string("ws://127.0.0.1:9222/devtools/browser/private"),
                        "browser_id": .string("private-browser"),
                    ]),
                ]),
                "wrapper": .array([.object([
                    "devToolsBrowserID": .string("private-browser"),
                ])]),
            ]),
            structuredContent: .object([
                "deep": .array([.object([
                    "browserURL": .string("http://127.0.0.1:9222"),
                ])]),
            ]))

        let scrubbed = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: ["action": "status"]))

        #expect(!scrubbed.response.isError)
        #expect(scrubbed.targetIdentity?.processIdentity.processIdentifier == 42)
        #expect(scrubbed.targetIdentity?.processIdentity.processStartIdentity == 1001)
        let scrubbedDump = Self.dump(scrubbed.response)
        #expect(!scrubbedDump.contains("private-browser"))
        #expect(!scrubbedDump.contains("private-epoch"))
        #expect(!scrubbedDump.contains("127.0.0.1:9222"))
        #expect(!scrubbedDump.contains("provider_session_epoch"))

        session.response = ToolResponse(
            content: [.text(
                text: "browser_id=private-plain\n- uid=1_0 button \"Continue\"\n" +
                    #"{"targetId":"private-json-target"}"#,
                annotations: nil,
                _meta: nil)],
            meta: .object([
                "pages": .array([.object([
                    "id": .int(7),
                    "deeper": .object(["uid": .string("1_0")]),
                ])]),
            ]),
            structuredContent: .object([
                "targetId": .string("private-target"),
            ]))

        let withheld = try await fixture.runtime.execute(
            in: namespaceID,
            arguments: ToolArguments(raw: ["action": "list_pages"]))
        #expect(withheld.response.isError)
        let withheldDump = Self.dump(withheld.response)
        #expect(withheldDump.contains("process-private identifiers were withheld"))
        for privateValue in [
            "1_0",
            "private-json-target",
            "private-plain",
            "private-target",
            "targetId",
            "uid",
        ] {
            #expect(!withheldDump.contains(privateValue))
        }
    }

    private static func namespaceID(_ suffix: UInt8) -> BrowserMCPScopedNamespaceID {
        BrowserMCPScopedNamespaceID(rawValue: UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, suffix)))
    }

    private static func pageReference(
        from result: BrowserMCPScopedNamespaceExecutionResult) throws -> String
    {
        let root = try #require(result.response.structuredContent?.objectValue)
        let pages = try #require(root["pages"]?.arrayValue)
        return try #require(pages.first?.objectValue?["id"]?.stringValue)
    }

    private static func text(from response: ToolResponse) -> String {
        guard case let .text(text, _, _)? = response.content.first else { return "" }
        return text
    }

    private static func dump(_ response: ToolResponse) -> String {
        let content = response.content.flatMap { item -> [String] in
            switch item {
            case let .text(text, _, metadata):
                return [text] + self.dump(metadata.map { .object($0.fields) })
            case let .image(_, _, _, metadata),
                 let .audio(_, _, _, metadata),
                 let .resource(_, _, metadata):
                return self.dump(metadata.map { .object($0.fields) })
            case let .resourceLink(uri, name, title, description, mimeType, _):
                return [uri, name, title, description, mimeType].compactMap(\.self)
            }
        }
        return (content + self.dump(response.meta) + self.dump(response.structuredContent))
            .joined(separator: "\n")
    }

    private static func dump(_ value: Value?) -> [String] {
        guard let value else { return [] }
        switch value {
        case let .object(fields):
            return fields.flatMap { key, value in [key] + self.dump(value) }
        case let .array(values):
            return values.flatMap(self.dump)
        case let .string(string):
            return [string]
        case let .int(value):
            return [String(value)]
        case let .double(value):
            return [String(value)]
        case let .bool(value):
            return [String(value)]
        case .null:
            return ["null"]
        case let .data(mimeType, data):
            return [mimeType, data.base64EncodedString()].compactMap(\.self)
        }
    }
}

@MainActor
private final class NamespaceRuntimeFixture {
    private(set) var sessions: [BrowserMCPScopedNamespaceID: NamespaceRuntimeSession] = [:]
    lazy var runtime = BrowserMCPScopedNamespaceRuntime { [unowned self] namespaceID in
        let session = NamespaceRuntimeSession(namespaceID: namespaceID)
        self.sessions[namespaceID] = session
        return session
    }
}

@MainActor
private final class NamespaceRuntimeSession: BrowserMCPScopedNamespaceSession {
    struct Execution {
        let arguments: ToolArguments
        let policy: BrowserMCPScopedNamespaceExecutionPolicy
    }

    let closeStarted = NamespaceRuntimeSignal()
    private(set) var executions: [Execution] = []
    private(set) var providerDispatchCount = 0
    private(set) var activeExecutionCount = 0
    private(set) var closeCount = 0
    var executionBarrier: NamespaceRuntimeBarrier?
    var response: ToolResponse?

    private let pageReference: String
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasNativeBinding = false

    init(namespaceID: BrowserMCPScopedNamespaceID) {
        let token = namespaceID.rawValue.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        self.pageReference = "bp1_\(token)"
    }

    func execute(
        arguments: ToolArguments,
        policy: BrowserMCPScopedNamespaceExecutionPolicy) async throws -> ToolResponse
    {
        self.executions.append(.init(arguments: arguments, policy: policy))
        self.activeExecutionCount += 1
        defer {
            self.activeExecutionCount -= 1
            if self.activeExecutionCount == 0 {
                self.drainWaiters.forEach { $0.resume() }
                self.drainWaiters.removeAll()
            }
        }
        if let executionBarrier {
            await executionBarrier.block()
        }
        if let response {
            self.providerDispatchCount += 1
            return response
        }

        let action = arguments.getString("action")
        if let requestedPage = arguments.getString("page_id"), requestedPage != self.pageReference {
            return ToolResponse.error(
                "The browser page reference belongs to another or expired provider session. Refresh list_pages.")
        }
        self.providerDispatchCount += 1
        if action == "list_pages" {
            return ToolResponse(
                content: [.text(
                    text: "\(self.pageReference): Example",
                    annotations: nil,
                    _meta: nil)],
                structuredContent: .object([
                    "pages": .array([.object([
                        "id": .string(self.pageReference),
                        "title": .string("Example"),
                    ])]),
                ]))
        }
        if action == BrowserProcessLocalAction.bindWindow {
            self.hasNativeBinding = true
            var fields = self.nativeWindowReceiptFields
            fields["page_id"] = .string(self.pageReference)
            return ToolResponse.text(
                "bound",
                meta: .object(["browser_window_binding": .object(fields)]))
        }
        if self.hasNativeBinding, action == "navigate" {
            return ToolResponse.text(
                "navigated",
                meta: .object([
                    BrowserMCPExecutionEvidence.metadataKey: .object([
                        "native_window_receipt": .object(self.nativeWindowReceiptFields),
                    ]),
                ]))
        }
        return ToolResponse.text("ok")
    }

    private var nativeWindowReceiptFields: [String: Value] {
        [
            "pid": .int(42),
            "process_start_identity_decimal": .string("1001"),
            "window_id": .int(313),
            "bounds": .object([
                "x": .double(10),
                "y": .double(20),
                "width": .double(900),
                "height": .double(700),
            ]),
            "quality": .string("exact"),
        ]
    }

    func close() async {
        self.closeCount += 1
        await self.closeStarted.signal()
        guard self.activeExecutionCount > 0 else { return }
        await withCheckedContinuation { continuation in
            self.drainWaiters.append(continuation)
        }
    }
}

private actor NamespaceRuntimeBarrier {
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

private actor NamespaceRuntimeSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        self.signalled = true
        self.waiters.forEach { $0.resume() }
        self.waiters.removeAll()
    }

    func waitUntilSignalled() async {
        guard !self.signalled else { return }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

private actor NamespaceRuntimeFlag {
    private(set) var value = false

    func mark() {
        self.value = true
    }
}
