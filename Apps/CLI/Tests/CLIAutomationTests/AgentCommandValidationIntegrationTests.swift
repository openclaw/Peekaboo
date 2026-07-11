import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
struct AgentCommandValidationIntegrationTests {
    @Test(arguments: [0, 101])
    func `Invalid max steps returns one JSON error`(_ maxSteps: Int) async throws {
        let result = try await InProcessCommandRunner.runShared(
            ["agent", "test task", "--max-steps", String(maxSteps), "--json"],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)

        let data = try #require(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload.count == 2)
        #expect(payload["success"] as? Bool == false)
        let message = try #require(payload["error"] as? String)
        #expect(message.contains("between 1 and 100"))
        #expect(message.contains("received \(maxSteps)"))
    }

    @Test
    func `Missing resume session returns one JSON error`() async throws {
        let result = try await InProcessCommandRunner.runShared(
            [
                "agent",
                "--resume-session",
                "missing-session-\(UUID().uuidString)",
                "--jsonOutput",
            ],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)

        let data = try #require(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload.count == 2)
        #expect(payload["success"] as? Bool == false)
        #expect((payload["error"] as? String)?.contains("Failed to resume session") == true)
    }
}
