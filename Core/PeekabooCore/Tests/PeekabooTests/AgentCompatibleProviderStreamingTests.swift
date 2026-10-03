import Foundation
import PeekabooAutomationKitTestSupport
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@MainActor
struct AgentCompatibleProviderStreamingTests {
    @Test(arguments: CompatibleProviderFixture.Mode.allCases)
    private func `Wire fragments retain Agent dispatch and validation contracts`(mode: CompatibleProviderFixture
        .Mode) async throws
    {
        let fixture = CompatibleProviderFixture(mode: mode)
        let id = UUID().uuidString
        CompatibleProviderURLProtocol.fixtures.withValue { $0[id] = fixture }
        defer { CompatibleProviderURLProtocol.fixtures.withValue { $0.removeValue(forKey: id) } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompatibleProviderURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = try OpenAICompatibleProvider(
            modelId: "compatible-agent-fixture",
            baseURL: "https://peekaboo-stream-fixture.invalid/\(id)/v1",
            configuration: TachikomaConfiguration(apiKeys: ["openai_compatible": "fixture-key"]),
            session: session)
        let model = LanguageModel.custom(provider: provider)
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try PeekabooAgentService(
            services: PeekabooServices(), defaultModel: model, sessionManager: store.manager)
        let executions = AutomationTestLockedValue<[Int]>([])
        let tool = AgentTool(
            name: "wire_probe",
            description: "Synthetic tool with no native or external effects",
            parameters: .init(properties: [
                "value": .init(name: "value", type: .integer, description: "Synthetic integer"),
            ], required: ["value"])) { arguments in
                let value = try arguments.integerValue("value")
                executions.withValue { $0.append(value) }
                return AnyAgentToolValue(int: value)
            }
        let loop = PeekabooAgentService.StreamingLoopConfiguration(
            model: model,
            provider: provider,
            tools: [tool],
            sessionId: "synthetic-wire-fixture",
            eventHandler: nil,
            enhancementOptions: nil,
            executionAuthority: .init(basePolicy: .unrestricted))

        if mode == .incomplete || mode == .malformed {
            await #expect(throws: (any Error).self) {
                _ = try await service.runStreamingLoop(
                    configuration: loop, maxSteps: 2, initialMessages: [.user("Use the synthetic tool once.")])
            }
            #expect(executions.value.isEmpty)
            #expect(fixture.requests.value.count == 1)
            return
        }

        let outcome = try await service.runStreamingLoop(
            configuration: loop, maxSteps: 2, initialMessages: [.user("Use the synthetic tool once.")])
        #expect(outcome.content == "Finished.")
        #expect(!outcome.reachedStepLimit)
        #expect(executions.value == (mode == .valid ? [7] : []))
        let step = try #require(outcome.steps.first)
        let result = try #require(step.toolResults.first)
        #expect(result.isError == (mode == .schemaInvalid))
        #expect(step.toolCalls.map(\.id) == ["wire-call"])
        #expect(step.toolCalls.first?.arguments["value"] == (
            mode == .valid ? AnyAgentToolValue(int: 7) : AnyAgentToolValue(string: "wrong")))

        let requests = fixture.requests.value
        #expect(requests.count == 2)
        let request = try #require(JSONSerialization.jsonObject(with: requests[1]) as? [String: Any])
        let messages = try #require(request["messages"] as? [[String: Any]])
        let assistant = try #require(messages.first { $0["role"] as? String == "assistant" })
        let calls = try #require(assistant["tool_calls"] as? [[String: Any]])
        #expect(calls.count == 1)
        #expect(calls.first?["id"] as? String == "wire-call")
        let results = messages.filter { $0["role"] as? String == "tool" }
        #expect(results.count == 1)
        #expect(results.first?["tool_call_id"] as? String == "wire-call")
        if mode == .valid {
            #expect(results.first?["content"] as? String == "7")
        }
    }
}

private final class CompatibleProviderFixture: Sendable {
    enum Mode: CaseIterable, Sendable {
        case valid, schemaInvalid, incomplete, malformed
    }

    let mode: Mode
    let requests = AutomationTestLockedValue<[Data]>([])

    init(mode: Mode) {
        self.mode = mode
    }

    func response(to request: URLRequest) throws -> Data {
        let body = try Self.body(of: request)
        let index = self.requests.withValue { requests in
            let index = requests.count
            requests.append(body)
            return index
        }
        if index > 0 {
            return Data((
                #"data: {"id":"reply","choices":[{"index":0,"delta":{"content":"Finished."},"# +
                    #""finish_reason":"stop"}]}"# +
                    "\n\ndata: [DONE]\n\n").utf8)
        }
        let value = self.mode == .schemaInvalid ? #"\"wrong\"}"# : self.mode == .incomplete ? "7" : "7}"
        var frames = [
            #"data: {"id":"start","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"wire-call","# +
                #""function":{"name":"wire_probe","arguments":""}}]}}]}"#,
            #"data: {"id":"args","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"# +
                #""function":{"arguments":"{\"value\":"}}]}}]}"#,
        ]
        if self.mode == .malformed {
            frames.append("data: {malformed}")
        }
        frames += [
            #"data: {"id":"tail","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":""# +
                value + #""}}]}}]}"#,
            #"data: {"id":"end","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "data: [DONE]", "",
        ]
        return Data(frames.joined(separator: "\n\n").utf8)
    }

    private static func body(of request: URLRequest) throws -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 {
                return data
            }
            guard count > 0 else { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
            data.append(buffer, count: count)
        }
    }
}

private final class CompatibleProviderURLProtocol: URLProtocol {
    static let fixtures = AutomationTestLockedValue<[String: CompatibleProviderFixture]>([:])

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "peekaboo-stream-fixture.invalid"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let url = self.request.url,
                  let id = url.pathComponents.dropFirst().first,
                  let fixture = Self.fixtures.value[id],
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: 200,
                      httpVersion: nil,
                      headerFields: ["Content-Type": "text/event-stream"])
            else { throw URLError(.badServerResponse) }
            let data = try fixture.response(to: self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch {
            self.client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
