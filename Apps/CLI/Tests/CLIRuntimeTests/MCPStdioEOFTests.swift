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

    @Test(.timeLimit(.minutes(1)))
    func `clipboard stdout path refusal preserves JSON-RPC stream and filesystem`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo (or set PEEKABOO_CLI_BINARY) before running CLI runtime tests.")
            return
        }

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-mcp-clipboard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workingDirectory) }

        let callRequest =
            #"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"clipboard","# +
            #""arguments":{"action":"get","outputPath":"-"}},"id":41}"#
        let listRequest = #"{"jsonrpc":"2.0","method":"tools/list","id":42}"#
        let request = "\(callRequest)\n\(listRequest)\n"
        let child = try await TestChildProcess.runPeekaboo(
            ["mcp", "--no-remote"],
            workingDirectory: workingDirectory,
            standardInput: request
        )

        #expect(child.status == .exited(0))
        #expect(child.standardError.isEmpty)
        let lines = child.standardOutput.split(separator: "\n")
        #expect(lines.count == 2)

        var responses: [Int: [String: Any]] = [:]
        for line in lines {
            let data = Data(line.utf8)
            let response = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let id = try #require(response["id"] as? Int)
            responses[id] = response
        }

        let refusal = try #require(responses[41]?["result"] as? [String: Any])
        #expect(refusal["isError"] as? Bool == true)
        let metadata = try #require(refusal["_meta"] as? [String: Any])
        #expect(metadata["effect"] as? String == "refused")
        #expect(metadata["error_code"] as? String == "MCP_CLIPBOARD_STDOUT_UNAVAILABLE")
        #expect(metadata["mutation_dispatched"] as? Bool == false)
        #expect(metadata["retry_safe"] as? Bool == true)
        let content = try #require(refusal["content"] as? [[String: Any]])
        let message = try #require(content.first?["text"] as? String)
        #expect(message.contains("stdout carries JSON-RPC"))
        #expect(responses[42]?["result"] != nil)

        let literalDash = workingDirectory.appendingPathComponent("-")
        #expect(!FileManager.default.fileExists(atPath: literalDash.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path).isEmpty)
    }
}
