import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolCapabilitySessionTests {
    private static let providerSessionEpoch = BrowserMCPProviderSessionEpoch()

    @Test
    func `page and element capabilities are rejected outside their caller session`() async throws {
        let first = BrowserToolCapabilitySession()
        let second = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await first.project(
            Self.pageResponse(id: 7, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await second.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                sessionBinding: Self.binding(receipt))
        }

        let resolved = try await first.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: Self.binding(receipt))
        #expect(resolved.providerPageID == 7)
        let snapshot = try await first.project(
            Self.snapshotResponse(uid: "1_0"),
            calls: Self.calls("take_snapshot"),
            resolved: resolved,
            sessionBinding: Self.binding(receipt))
        let elementReference = try Self.elementReference(from: snapshot)

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await second.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": elementReference,
                ]),
                sessionBinding: Self.binding(receipt))
        }
    }

    @Test
    func `navigation invalidates the prior snapshot element capability`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 11, url: "https://example.test/before"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)
        let snapshotArguments = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: Self.binding(receipt))
        let snapshot = try await session.project(
            Self.snapshotResponse(uid: "4_9"),
            calls: Self.calls("take_snapshot"),
            resolved: snapshotArguments,
            sessionBinding: Self.binding(receipt))
        let elementReference = try Self.elementReference(from: snapshot)

        let navigate = try await session.resolve(
            action: .navigate,
            arguments: ToolArguments(raw: [
                "page_id": pageReference,
                "url": "https://example.test/after",
            ]),
            sessionBinding: Self.binding(receipt))
        _ = try await session.project(
            .text("ok"),
            calls: Self.calls("navigate_page"),
            resolved: navigate,
            sessionBinding: Self.binding(receipt))

        await #expect(throws: BrowserToolCapabilityError.staleElementReference) {
            _ = try await session.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": elementReference,
                ]),
                sessionBinding: Self.binding(receipt))
        }
    }

    @Test
    func `snapshot capability retains provider identity fields when available`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 13, url: "https://example.test/app"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)
        let resolved = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: Self.binding(receipt))
        let response = try await session.project(
            Self.snapshotResponse(uid: "8_2"),
            calls: Self.calls("take_snapshot"),
            resolved: resolved,
            sessionBinding: Self.binding(receipt))
        let elementReference = try Self.elementReference(from: response)

        let binding = await session.elementBinding(for: elementReference)
        #expect(binding == .init(
            backendNodeID: 991,
            frameID: "frame-main",
            loaderID: "loader-3",
            navigationID: "navigation-4"))
    }

    @Test
    func `newer snapshot invalidates the prior snapshot namespace`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 15, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)
        let resolved = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: Self.binding(receipt))
        let first = try await session.project(
            Self.snapshotResponse(uid: "9_1"),
            calls: Self.calls("take_snapshot"),
            resolved: resolved,
            sessionBinding: Self.binding(receipt))
        let firstElement = try Self.elementReference(from: first)
        let second = try await session.project(
            Self.snapshotResponse(uid: "10_1"),
            calls: Self.calls("take_snapshot"),
            resolved: resolved,
            sessionBinding: Self.binding(receipt))
        let secondElement = try Self.elementReference(from: second)

        await #expect(throws: BrowserToolCapabilityError.staleElementReference) {
            _ = try await session.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": firstElement,
                ]),
                sessionBinding: Self.binding(receipt))
        }
        let current = try await session.resolve(
            action: .click,
            arguments: ToolArguments(raw: [
                "page_id": pageReference,
                "uid": secondElement,
            ]),
            sessionBinding: Self.binding(receipt))
        #expect(current.arguments.getString("uid") == "10_1")
    }

    @Test
    func `disconnect invalidates every page capability in the session`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 16, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)
        await session.disconnect()

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await session.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                sessionBinding: Self.binding(receipt))
        }
    }

    @Test
    func `indeterminate status invalidates refs when exact binding is missing or changed`() async throws {
        let receipt = Self.receipt()
        let statuses = [
            BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: [],
                observation: .indeterminate),
            BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: [],
                connectionReceipt: receipt,
                providerSessionEpoch: BrowserMCPProviderSessionEpoch(),
                observation: .indeterminate),
        ]

        for status in statuses {
            let session = BrowserToolCapabilitySession()
            let listed = try await session.project(
                Self.pageResponse(id: 17, url: "https://example.test/"),
                calls: Self.calls("list_pages"),
                resolved: nil,
                sessionBinding: Self.binding(receipt))
            let pageReference = try Self.pageReference(from: listed)

            await session.observeStatus(status)

            await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
                _ = try await session.resolve(
                    action: .snapshot,
                    arguments: ToolArguments(raw: ["page_id": pageReference]),
                    sessionBinding: Self.binding(receipt))
            }
        }
    }

    @Test
    func `hover invalidates the snapshot namespace after provider entry`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 18, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)
        let snapshotArguments = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            sessionBinding: Self.binding(receipt))
        let snapshot = try await session.project(
            Self.snapshotResponse(uid: "12_1"),
            calls: Self.calls("take_snapshot"),
            resolved: snapshotArguments,
            sessionBinding: Self.binding(receipt))
        let elementReference = try Self.elementReference(from: snapshot)
        let hover = try await session.resolve(
            action: .hover,
            arguments: ToolArguments(raw: [
                "page_id": pageReference,
                "uid": elementReference,
            ]),
            sessionBinding: Self.binding(receipt))
        _ = try await session.project(
            .text("hovered"),
            calls: [BrowserMCPMappedCall(
                toolName: "hover",
                arguments: ["pageId": 18, "uid": "12_1"])],
            resolved: hover,
            sessionBinding: Self.binding(receipt))

        await #expect(throws: BrowserToolCapabilityError.staleElementReference) {
            _ = try await session.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": elementReference,
                ]),
                sessionBinding: Self.binding(receipt))
        }
    }

    @Test
    func `ending a browser capability session drops its complete namespace`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 17, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: Self.binding(receipt))
        let pageReference = try Self.pageReference(from: listed)
        await session.end()

        await #expect(throws: BrowserToolCapabilityError.sessionEnded) {
            _ = try await session.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                sessionBinding: Self.binding(receipt))
        }
    }

    @Test
    func `ending a browser capability session waits for in flight projection`() async throws {
        let session = BrowserToolCapabilitySession()
        let barrier = CapabilityOperationBarrier()
        let completion = CapabilityEndCompletion()
        let operation = Task { @MainActor in
            try await session.withExclusiveOperation {
                await barrier.block()
                return 1
            }
        }
        await barrier.waitUntilBlocked()
        let teardown = Task {
            await session.end()
            await completion.markFinished()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await !(completion.finished))

        await barrier.release()
        #expect(try await operation.value == 1)
        await teardown.value
        #expect(await completion.finished)
        await #expect(throws: BrowserToolCapabilityError.sessionEnded) {
            _ = try await session.withExclusiveOperation { 2 }
        }
    }

    @Test
    func `same browser target with a restarted provider child invalidates page refs`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let firstBinding = BrowserMCPExecutionSessionBinding(
            connectionReceipt: receipt,
            providerSessionEpoch: BrowserMCPProviderSessionEpoch())
        let listed = try await session.project(
            Self.pageResponse(id: 19, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: firstBinding)
        let pageReference = try Self.pageReference(from: listed)
        let restartedBinding = BrowserMCPExecutionSessionBinding(
            connectionReceipt: receipt,
            providerSessionEpoch: BrowserMCPProviderSessionEpoch())

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await session.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                sessionBinding: restartedBinding)
        }
    }

    private static func receipt() -> BrowserMCPConnectionReceipt {
        BrowserMCPConnectionReceipt(
            browserURL: "http://127.0.0.1:9222/",
            webSocketDebuggerURL: "ws://127.0.0.1:9222/devtools/browser/browser-a",
            devToolsBrowserID: "browser-a",
            browserVersion: "Chrome/151.0",
            protocolVersion: "1.3")
    }

    private static func binding(_ receipt: BrowserMCPConnectionReceipt) -> BrowserMCPExecutionSessionBinding {
        .init(
            connectionReceipt: receipt,
            providerSessionEpoch: self.providerSessionEpoch)
    }

    private static func calls(_ toolName: String) -> [BrowserMCPMappedCall] {
        [BrowserMCPMappedCall(toolName: toolName, arguments: [:])]
    }

    private static func pageResponse(id: Int, url: String) -> ToolResponse {
        ToolResponse(
            content: [.text(text: "## Pages\n\(id): Example (\(url)) [selected]", annotations: nil, _meta: nil)],
            structuredContent: .object([
                "pages": .array([.object([
                    "id": .int(id),
                    "url": .string(url),
                    "title": .string("Example"),
                    "selected": .bool(true),
                ])]),
            ]))
    }

    private static func snapshotResponse(uid: String) -> ToolResponse {
        ToolResponse(
            content: [.text(text: "uid=\(uid) button \"Continue\"", annotations: nil, _meta: nil)],
            structuredContent: .object([
                "snapshot": .object([
                    "id": .string(uid),
                    "role": .string("button"),
                    "name": .string("Continue"),
                    "backendNodeId": .int(991),
                    "frameId": .string("frame-main"),
                    "loaderId": .string("loader-3"),
                    "navigationId": .string("navigation-4"),
                ]),
            ]))
    }

    private static func pageReference(from response: ToolResponse) throws -> String {
        let root = try #require(response.structuredContent?.objectValue)
        let pages = try #require(root["pages"]?.arrayValue)
        let page = try #require(pages.first?.objectValue)
        return try #require(page["id"]?.stringValue)
    }

    private static func elementReference(from response: ToolResponse) throws -> String {
        let root = try #require(response.structuredContent?.objectValue)
        let snapshot = try #require(root["snapshot"]?.objectValue)
        return try #require(snapshot["id"]?.stringValue)
    }
}

private actor CapabilityOperationBarrier {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        self.blocked = true
        self.blockedWaiters.forEach { $0.resume() }
        self.blockedWaiters.removeAll()
        guard !self.released else { return }
        await withCheckedContinuation { self.releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !self.blocked else { return }
        await withCheckedContinuation { self.blockedWaiters.append($0) }
    }

    func release() {
        self.released = true
        self.releaseWaiters.forEach { $0.resume() }
        self.releaseWaiters.removeAll()
    }
}

private actor CapabilityEndCompletion {
    private(set) var finished = false

    func markFinished() {
        self.finished = true
    }
}
