import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct AgentChatEventDelegateTests {
    @Test
    func `TUI tool completion renders error-only results as failures`() {
        let failurePayloads = [
            #"{"error":"Legacy tool failure"}"#,
            #"{"error":"Tool 'missing_tool' is not available in this context"}"#,
            #"{"error":"The tool threw while executing"}"#,
        ]

        for payload in failurePayloads {
            #expect(!AgentChatEventDelegate.successFlag(from: payload))
        }
    }

    @Test
    func `TUI tool completion preserves implicit success`() {
        #expect(AgentChatEventDelegate.successFlag(from: #"{"result":"ok"}"#))
        #expect(AgentChatEventDelegate.successFlag(from: #"{"error":null}"#))
    }
}
