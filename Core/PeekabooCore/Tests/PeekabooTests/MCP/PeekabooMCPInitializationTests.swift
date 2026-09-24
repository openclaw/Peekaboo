import Foundation
import Logging
import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct PeekabooMCPInitializationTests {
    @Test(.timeLimit(.minutes(1)), arguments: [
        #"{"experimental":{"codex/auth-change":{}}}"#,
        #"{"experimental":{"x":{"enabled":true,"values":[1,null,{"nested":"ok"}]}}}"#,
        #"{"experimental":{"null":null,"number":1,"flag":true,"legacy":"s"}}"#,
        #"{"experimental":{},"extensions":{"io.modelcontextprotocol/ui":{"mimeTypes":["text/html"]}}}"#,
        #"{}"#,
    ])
    func `raw initialization accepts experimental JSON and reaches tools list`(capabilities: String) async throws {
        let replies = try await Self.exchange(capabilities: capabilities)
        #expect(replies.count == 2)
        let initialized = try #require(replies.first?.objectValue?["result"]?.objectValue)
        #expect(initialized["protocolVersion"] == .string("2025-06-18"))
        let tools = try #require(replies.last?.objectValue?["result"]?.objectValue?["tools"]?.arrayValue)
        #expect(tools.count == 1)
        #expect(tools.first?.objectValue?["name"] == .string("permissions"))
    }

    @Test(.timeLimit(.minutes(1)), arguments: [
        #"{"experimental":{"x":{}},"roots":{"listChanged":"not-a-boolean"}}"#,
        #"{"experimental":[1,2,3]}"#,
    ])
    func `malformed capability shapes still fail initialization`(capabilities: String) async throws {
        let replies = try await Self.exchange(capabilities: capabilities)
        #expect(replies.count == 1)
        let response = try #require(replies.first?.objectValue)
        #expect(response["result"] == nil)
        #expect(response["error"]?.objectValue?["code"] == .int(-32603))
    }

    private static func exchange(capabilities: String) async throws -> [Value] {
        let context = await MCPToolTestHelpers.makeContext()
        let server = try await PeekabooMCPServer(
            toolContext: context,
            toolFilters: ToolFilters(allow: ["permissions"], deny: [], allowSource: .config, denySources: [:]))
        let transport = InitializationWireTransport(capabilities: capabilities)
        try await server.serve(transport: transport)
        return await transport.replies
    }
}

private actor InitializationWireTransport: Transport {
    nonisolated let logger = Logger(label: "peekaboo.tests.initialize-wire")
    private let request: Data
    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private(set) var replies: [Value] = []

    init(capabilities: String) {
        self.request = Data("""
        {"jsonrpc":"2.0","id":0,"method":"initialize","params":{
        "protocolVersion":"2025-06-18","capabilities":\(capabilities),
        "clientInfo":{"name":"synthetic-initialize-client","version":"1.0"}}}
        """.utf8)
        let (stream, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        self.stream = stream
        self.continuation = continuation
    }

    func connect() async throws {
        self.continuation.yield(self.request)
    }

    func disconnect() async {
        self.continuation.finish()
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        self.stream
    }

    func send(_ data: Data) async throws {
        let response = try JSONDecoder().decode(Value.self, from: data)
        self.replies.append(response)
        if response.objectValue?["id"] == .int(0), response.objectValue?["result"] != nil {
            self.continuation.yield(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8))
            self.continuation.yield(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8))
        } else {
            self.continuation.finish()
        }
    }
}
