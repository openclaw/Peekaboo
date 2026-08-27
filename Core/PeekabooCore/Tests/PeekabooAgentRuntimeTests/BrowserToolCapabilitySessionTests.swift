import Foundation
import MCP
import PeekabooAutomationKit
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

    @Test
    func `native window binding stays private and caller scoped until control death`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.nativeReceipt()
        let sessionBinding = Self.binding(receipt)
        let listed = try await session.project(
            Self.pageResponse(id: 23, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: sessionBinding)
        let pageReference = try Self.pageReference(from: listed)
        let windowIdentity = WindowMutationIdentity(
            windowID: 900,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 456,
            capturedBounds: CGRect(x: -1200, y: 80, width: 1000, height: 700))
        let nativeWindowReceipt = try BrowserNativeWindowReceipt(
            target: BrowserNativeWindowTarget(
                processIdentifier: 123,
                processStartIdentity: 456,
                windowID: 900),
            windowIdentity: windowIdentity,
            bounds: #require(windowIdentity.capturedBounds))

        #expect(try await !session.hasNativeWindowBinding(
            pageReference: pageReference,
            sessionBinding: sessionBinding))

        try await session.bindNativeWindow(
            pageReference: pageReference,
            sessionBinding: sessionBinding,
            privateTargetID: "private-target-a",
            privateBrowserWindowID: BrowserMCPDevToolsWindowID(rawValue: 77),
            nativeWindowReceipt: nativeWindowReceipt)

        #expect(try await session.hasNativeWindowBinding(
            pageReference: pageReference,
            sessionBinding: sessionBinding))

        let binding = try await session.nativeWindowBinding(
            pageReference: pageReference,
            sessionBinding: sessionBinding)
        #expect(binding == BrowserToolNativeWindowBinding(
            privateTargetID: "private-target-a",
            privateBrowserWindowID: BrowserMCPDevToolsWindowID(rawValue: 77),
            nativeWindowReceipt: nativeWindowReceipt))
        #expect(!Self.text(from: listed).contains("private-target-a"))
        #expect(listed.structuredContent?.objectValue?["pages"]?.arrayValue?.first?.objectValue?["id"] ==
            .string(pageReference))

        await session.invalidateNativeWindowBindings()
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await session.hasNativeWindowBinding(
                pageReference: pageReference,
                sessionBinding: sessionBinding)
        }
        await #expect(throws: BrowserToolNativeWindowBindingError.stalePageReference) {
            _ = try await session.nativeWindowBinding(
                pageReference: pageReference,
                sessionBinding: sessionBinding)
        }
    }

    @Test
    func `native window binding rejects process or caller session substitution`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.nativeReceipt()
        let sessionBinding = Self.binding(receipt)
        let listed = try await session.project(
            Self.pageResponse(id: 24, url: "https://example.test/"),
            calls: Self.calls("list_pages"),
            resolved: nil,
            sessionBinding: sessionBinding)
        let pageReference = try Self.pageReference(from: listed)
        let wrongProcess = WindowMutationIdentity(
            windowID: 901,
            ownerProcessIdentifier: 124,
            ownerProcessStartIdentity: 456,
            capturedBounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        let wrongProcessReceipt = try BrowserNativeWindowReceipt(
            target: BrowserNativeWindowTarget(
                processIdentifier: 124,
                processStartIdentity: 456,
                windowID: 901),
            windowIdentity: wrongProcess,
            bounds: #require(wrongProcess.capturedBounds))

        await #expect(throws: BrowserToolNativeWindowBindingError.processMismatch) {
            try await session.bindNativeWindow(
                pageReference: pageReference,
                sessionBinding: sessionBinding,
                privateTargetID: "private-target-b",
                privateBrowserWindowID: BrowserMCPDevToolsWindowID(rawValue: 78),
                nativeWindowReceipt: wrongProcessReceipt)
        }
        let otherSession = BrowserMCPExecutionSessionBinding(
            connectionReceipt: receipt,
            providerSessionEpoch: BrowserMCPProviderSessionEpoch())
        await #expect(throws: BrowserToolNativeWindowBindingError.connectionMismatch) {
            try await session.bindNativeWindow(
                pageReference: pageReference,
                sessionBinding: otherSession,
                privateTargetID: "private-target-b",
                privateBrowserWindowID: BrowserMCPDevToolsWindowID(rawValue: 78),
                nativeWindowReceipt: BrowserNativeWindowReceipt(
                    target: BrowserNativeWindowTarget(
                        processIdentifier: 123,
                        processStartIdentity: 456,
                        windowID: 901),
                    windowIdentity: WindowMutationIdentity(
                        windowID: 901,
                        ownerProcessIdentifier: 123,
                        ownerProcessStartIdentity: 456,
                        capturedBounds: CGRect(x: 0, y: 0, width: 800, height: 600)),
                    bounds: CGRect(x: 0, y: 0, width: 800, height: 600)))
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

    private static func nativeReceipt() -> BrowserMCPConnectionReceipt {
        BrowserMCPConnectionReceipt(
            channel: .stable,
            processIdentifier: 123,
            processStartIdentity: 456,
            bundleIdentifier: "com.google.Chrome",
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

    private static func text(from response: ToolResponse) -> String {
        response.content.compactMap { content in
            guard case let .text(text, _, _) = content else { return nil }
            return text
        }.joined(separator: "\n")
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
