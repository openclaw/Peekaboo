import Foundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PressToolPrimaryKeyValidationTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `Press tool reports non-string primary keys without dispatch`() async throws {
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: Self.uiSnapshots.owner)
        let cases: [[String: Any]] = [
            ["key": 7],
            ["key": true],
            ["key": ["c"]],
            ["key": ["value": "c"]],
            ["key": NSNull()],
        ]

        for arguments in cases {
            var foregroundArguments = arguments
            foregroundArguments["foreground"] = true
            let response = try await PressTool(context: context).execute(
                arguments: ToolArguments(raw: foregroundArguments))
            #expect(response.isError)
            guard case let .text(message, _, _)? = response.content.first else {
                Issue.record("Expected press validation text")
                continue
            }
            #expect(message.contains("key must be a primary key string"))
            #expect(await MainActor.run { automation.lastHotkeyKeys } == nil)
            #expect(await MainActor.run { automation.targetedHotkeyCalls.isEmpty })
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected press validation metadata")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["refusal_reason"] == .string("invalid_request"))
        }
    }

    @Test
    func `Press tool rejects non-string primary keys while parsing`() {
        let cases: [[String: Any]] = [
            ["key": 7],
            ["key": true],
            ["key": ["c"]],
            ["key": ["value": "c"]],
            ["key": NSNull()],
        ]

        for arguments in cases {
            let error = #expect(throws: PressToolValidationError.self) {
                _ = try PressTool.parseChords(arguments: ToolArguments(raw: arguments))
            }
            #expect(error?.message == "key must be a primary key string")
        }
    }
}
