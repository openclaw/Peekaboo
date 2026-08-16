import Foundation
import Subprocess
import Testing

struct BridgeReceiptCLITests {
    @Test
    func `receipt validation reports bundle file errors before contacting the exact socket`() async throws {
        guard TestChildProcess.canLocatePeekabooBinary() else {
            Issue.record("Build peekaboo before running CLI runtime tests.")
            return
        }
        let missingBundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-receipt-\(UUID().uuidString).json").path
        let missingSocket = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-bridge-\(UUID().uuidString).sock").path

        let result = try await TestChildProcess.runPeekaboo(
            [
                "bridge", "receipt", "validate",
                "--bundle", missingBundle,
                "--bridge-socket", missingSocket,
                "--json",
            ],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        let object = try JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8))
        let json = try #require(object as? [String: Any])
        let error = try #require(json["error"] as? [String: Any])
        #expect(json["success"] as? Bool == false)
        #expect(error["code"] as? String == "FILE_IO_ERROR")
        #expect((error["message"] as? String)?.contains("file does not exist") == true)
        #expect(!result.standardOutput.contains(missingSocket))
    }
}
