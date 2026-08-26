import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct BrowserToolCapabilitySessionTests {
    @Test
    func `page and element capabilities are rejected outside their caller session`() async throws {
        let first = BrowserToolCapabilitySession()
        let second = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await first.project(
            Self.pageResponse(id: 7, url: "https://example.test/"),
            action: .listPages,
            resolved: nil,
            connectionReceipt: receipt)
        let pageReference = try Self.pageReference(from: listed)

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await second.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                connectionReceipt: receipt)
        }

        let resolved = try await first.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            connectionReceipt: receipt)
        #expect(resolved.providerPageID == 7)
        let snapshot = try await first.project(
            Self.snapshotResponse(uid: "1_0"),
            action: .snapshot,
            resolved: resolved,
            connectionReceipt: receipt)
        let elementReference = try Self.elementReference(from: snapshot)

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await second.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": elementReference,
                ]),
                connectionReceipt: receipt)
        }
    }

    @Test
    func `navigation invalidates the prior snapshot element capability`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 11, url: "https://example.test/before"),
            action: .listPages,
            resolved: nil,
            connectionReceipt: receipt)
        let pageReference = try Self.pageReference(from: listed)
        let snapshotArguments = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            connectionReceipt: receipt)
        let snapshot = try await session.project(
            Self.snapshotResponse(uid: "4_9"),
            action: .snapshot,
            resolved: snapshotArguments,
            connectionReceipt: receipt)
        let elementReference = try Self.elementReference(from: snapshot)

        let navigate = try await session.resolve(
            action: .navigate,
            arguments: ToolArguments(raw: [
                "page_id": pageReference,
                "url": "https://example.test/after",
            ]),
            connectionReceipt: receipt)
        _ = try await session.project(
            .text("ok"),
            action: .navigate,
            resolved: navigate,
            connectionReceipt: receipt)

        await #expect(throws: BrowserToolCapabilityError.staleElementReference) {
            _ = try await session.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": elementReference,
                ]),
                connectionReceipt: receipt)
        }
    }

    @Test
    func `snapshot capability retains provider identity fields when available`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 13, url: "https://example.test/app"),
            action: .listPages,
            resolved: nil,
            connectionReceipt: receipt)
        let pageReference = try Self.pageReference(from: listed)
        let resolved = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            connectionReceipt: receipt)
        let response = try await session.project(
            Self.snapshotResponse(uid: "8_2"),
            action: .snapshot,
            resolved: resolved,
            connectionReceipt: receipt)
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
            action: .listPages,
            resolved: nil,
            connectionReceipt: receipt)
        let pageReference = try Self.pageReference(from: listed)
        let resolved = try await session.resolve(
            action: .snapshot,
            arguments: ToolArguments(raw: ["page_id": pageReference]),
            connectionReceipt: receipt)
        let first = try await session.project(
            Self.snapshotResponse(uid: "9_1"),
            action: .snapshot,
            resolved: resolved,
            connectionReceipt: receipt)
        let firstElement = try Self.elementReference(from: first)
        let second = try await session.project(
            Self.snapshotResponse(uid: "10_1"),
            action: .snapshot,
            resolved: resolved,
            connectionReceipt: receipt)
        let secondElement = try Self.elementReference(from: second)

        await #expect(throws: BrowserToolCapabilityError.staleElementReference) {
            _ = try await session.resolve(
                action: .click,
                arguments: ToolArguments(raw: [
                    "page_id": pageReference,
                    "uid": firstElement,
                ]),
                connectionReceipt: receipt)
        }
        let current = try await session.resolve(
            action: .click,
            arguments: ToolArguments(raw: [
                "page_id": pageReference,
                "uid": secondElement,
            ]),
            connectionReceipt: receipt)
        #expect(current.arguments.getString("uid") == "10_1")
    }

    @Test
    func `disconnect invalidates every page capability in the session`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 16, url: "https://example.test/"),
            action: .listPages,
            resolved: nil,
            connectionReceipt: receipt)
        let pageReference = try Self.pageReference(from: listed)
        await session.disconnect()

        await #expect(throws: BrowserToolCapabilityError.stalePageReference) {
            _ = try await session.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                connectionReceipt: receipt)
        }
    }

    @Test
    func `ending a browser capability session drops its complete namespace`() async throws {
        let session = BrowserToolCapabilitySession()
        let receipt = Self.receipt()
        let listed = try await session.project(
            Self.pageResponse(id: 17, url: "https://example.test/"),
            action: .listPages,
            resolved: nil,
            connectionReceipt: receipt)
        let pageReference = try Self.pageReference(from: listed)
        await session.end()

        await #expect(throws: BrowserToolCapabilityError.sessionEnded) {
            _ = try await session.resolve(
                action: .snapshot,
                arguments: ToolArguments(raw: ["page_id": pageReference]),
                connectionReceipt: receipt)
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
