import Foundation
import Testing

struct MCPStdioEOFTests {
    @Test(.timeLimit(.minutes(1)))
    func `one-shot stdio request flushes its response before EOF exit`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo (or set PEEKABOO_CLI_BINARY) before running CLI runtime tests.")
            return
        }

        let request = #"{"jsonrpc":"2.0","method":"tools/list","id":1}"# + "\n"
        let result = try await TestChildProcess.runPeekaboo(
            ["mcp", "--no-remote"],
            standardInput: request
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)

        let responseLine = try #require(result.standardOutput.split(separator: "\n").first)
        let responseData = Data(responseLine.utf8)
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? Int == 1)
        #expect(response["result"] != nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func `one-shot malformed ID request flushes its protocol error before EOF exit`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo (or set PEEKABOO_CLI_BINARY) before running CLI runtime tests.")
            return
        }

        let request = #"{"jsonrpc":"2.0","id":7}"# + "\n"
        let result = try await TestChildProcess.runPeekaboo(
            ["mcp", "--no-remote"],
            standardInput: request
        )

        #expect(result.status == .exited(0))
        let responseLine = try #require(result.standardOutput.split(separator: "\n").last)
        let responseData = Data(responseLine.utf8)
        let response = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        #expect(response["jsonrpc"] as? String == "2.0")
        #expect(response["id"] as? Int == 7)
        let error = try #require(response["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
    }
}
