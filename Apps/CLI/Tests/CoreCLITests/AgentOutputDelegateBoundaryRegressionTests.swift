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

        let output = try await self.captureStandardOutput {
            delegate.agentDidEmitEvent(.toolCallCompleted(name: "need_info", result: result))
        }

        #expect(output.contains("Error:"))
        #expect(!output.contains("Need Info completed"))
    }

    @Test
    func `Null error communication completion remains successful`() async throws {
        let delegate = AgentOutputDelegate(outputMode: .verbose, jsonOutput: false, task: "test")

        let output = try await self.captureStandardOutput {
            delegate.agentDidEmitEvent(.toolCallCompleted(name: "need_info", result: #"{"error":null}"#))
        }

        #expect(output.contains("Need Info completed"))
        #expect(!output.contains("Error:"))
    }

    private func captureStandardOutput(_ body: () async throws -> Void) async throws -> String {
        let pipe = Pipe()
        let originalStandardOutput = dup(STDOUT_FILENO)
        guard originalStandardOutput >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            close(originalStandardOutput)
            throw CocoaError(.fileWriteUnknown)
        }
        pipe.fileHandleForWriting.closeFile()

        do {
            try await body()
            fflush(nil)
            _ = dup2(originalStandardOutput, STDOUT_FILENO)
            close(originalStandardOutput)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            pipe.fileHandleForReading.closeFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            fflush(nil)
            _ = dup2(originalStandardOutput, STDOUT_FILENO)
            close(originalStandardOutput)
            pipe.fileHandleForReading.closeFile()
            throw error
        }
    }
}
