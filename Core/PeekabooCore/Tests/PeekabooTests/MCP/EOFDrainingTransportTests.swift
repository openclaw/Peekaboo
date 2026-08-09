import Foundation
import Logging
import MCP
import Testing
@testable import PeekabooAgentRuntime

struct EOFDrainingTransportTests {
    @Test(.timeLimit(.minutes(1)))
    func `input EOF waits for the final response`() async throws {
        let upstream = TestMCPTransport()
        let transport = EOFDrainingTransport(wrapping: upstream)
        try await transport.connect()

        let requestProbe = CompletionProbe()
        let completionProbe = CompletionProbe()
        let stream = await transport.receive()
        let collectionTask = Task {
            var messages: [Data] = []
            for try await message in stream {
                messages.append(message)
                await requestProbe.markCompleted()
            }
            await completionProbe.markCompleted()
            return messages
        }
        let request = Data(#"{"jsonrpc":"2.0","method":"tools/list","id":1}"#.utf8)
        await upstream.deliver(request)
        await upstream.finishInput()

        #expect(await waitUntilCompleted(requestProbe))
        #expect(await completionProbe.isCompleted == false)

        let response = Data(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[]}}"#.utf8)
        try await transport.send(response)

        #expect(try await collectionTask.value == [request])
        #expect(await upstream.sentMessages == [response])
    }

    @Test(.timeLimit(.minutes(1)))
    func `cancelled request does not hold EOF open`() async throws {
        let upstream = TestMCPTransport()
        let transport = EOFDrainingTransport(wrapping: upstream)
        try await transport.connect()

        let stream = await transport.receive()
        let collectionTask = Task {
            var messages: [Data] = []
            for try await message in stream {
                messages.append(message)
            }
            return messages
        }
        let request = Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{},"id":"work"}"#.utf8)
        let cancellation = Data(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"work"}}"#.utf8)
        await upstream.deliver(request)
        await upstream.deliver(cancellation)
        await upstream.finishInput()

        #expect(try await collectionTask.value == [request, cancellation])
    }

    @Test(.timeLimit(.minutes(1)))
    func `ID-bearing invalid request holds EOF until its error response`() async throws {
        let upstream = TestMCPTransport()
        let transport = EOFDrainingTransport(wrapping: upstream)
        try await transport.connect()

        let completionProbe = CompletionProbe()
        let stream = await transport.receive()
        let collectionTask = Task {
            var messages: [Data] = []
            for try await message in stream {
                messages.append(message)
            }
            await completionProbe.markCompleted()
            return messages
        }
        let request = Data(#"{"jsonrpc":"2.0","id":7}"#.utf8)
        await upstream.deliver(request)
        await upstream.finishInput()

        try await Task.sleep(for: .milliseconds(20))
        #expect(await completionProbe.isCompleted == false)

        let response = Data(
            #"{"jsonrpc":"2.0","id":7,"error":{"code":-32600,"message":"Invalid Request"}}"#.utf8)
        try await transport.send(response)

        #expect(try await collectionTask.value == [request])
        #expect(await upstream.sentMessages == [response])
    }

    @Test(.timeLimit(.minutes(1)))
    func `drain deadline ends an unanswered request instead of hanging forever`() async throws {
        let upstream = TestMCPTransport()
        let transport = EOFDrainingTransport(wrapping: upstream, drainTimeout: .milliseconds(25))
        try await transport.connect()

        let completionProbe = CompletionProbe()
        let stream = await transport.receive()
        let collectionTask = Task {
            var messages: [Data] = []
            for try await message in stream {
                messages.append(message)
            }
            await completionProbe.markCompleted()
            return messages
        }
        let request = Data(#"{"jsonrpc":"2.0","method":"tools/call","params":{},"id":"stuck"}"#.utf8)
        await upstream.deliver(request)
        await upstream.finishInput()

        #expect(await waitUntilCompleted(completionProbe))
        if await completionProbe.isCompleted == false {
            await transport.disconnect()
        }
        #expect(try await collectionTask.value == [request])
    }
}

private actor TestMCPTransport: Transport {
    nonisolated let logger = Logger(label: "boo.peekaboo.tests.mcp-transport")

    private let stream: AsyncThrowingStream<Data, any Error>
    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private(set) var sentMessages: [Data] = []

    init() {
        var continuation: AsyncThrowingStream<Data, any Error>.Continuation!
        self.stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async throws {}

    func disconnect() async {
        self.continuation.finish()
    }

    func send(_ data: Data) async throws {
        self.sentMessages.append(data)
    }

    func receive() -> AsyncThrowingStream<Data, any Error> {
        self.stream
    }

    func deliver(_ data: Data) {
        self.continuation.yield(data)
    }

    func finishInput() {
        self.continuation.finish()
    }
}

private actor CompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        self.isCompleted = true
    }
}

private func waitUntilCompleted(_ probe: CompletionProbe) async -> Bool {
    for _ in 0..<200 {
        if await probe.isCompleted {
            return true
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return false
}
