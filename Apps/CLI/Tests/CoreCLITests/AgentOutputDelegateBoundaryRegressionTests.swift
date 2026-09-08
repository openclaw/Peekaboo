import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
@MainActor
struct AgentOutputDelegateBoundaryRegressionTests {
    @Test(arguments: [
        #"{"success":false,"error":"Agent execution was cancelled","cancelled":true}"#,
        #"{"error":"Legacy communication failure"}"#,
    ])
    func `Failed communication completion is never rendered as success`(_ result: String) async throws {
        let delegate = AgentOutputDelegate(outputMode: .verbose, jsonOutput: false, task: "test")

        let output = try await captureStandardOutputText {
            delegate.agentDidEmitEvent(.toolCallCompleted(name: "need_info", result: result))
        }

        #expect(output.contains("Error:"))
        #expect(!output.contains("Need Info completed"))
    }

    @Test
    func `Null error communication completion remains successful`() async throws {
        let delegate = AgentOutputDelegate(outputMode: .verbose, jsonOutput: false, task: "test")

        let output = try await captureStandardOutputText {
            delegate.agentDidEmitEvent(.toolCallCompleted(name: "need_info", result: #"{"error":null}"#))
        }

        #expect(output.contains("Need Info completed"))
        #expect(!output.contains("Error:"))
    }
}
