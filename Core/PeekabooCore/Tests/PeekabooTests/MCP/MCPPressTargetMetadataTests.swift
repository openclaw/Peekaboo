import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct MCPPressTargetMetadataTests {
    @Test(arguments: [1, 2])
    func `confirmed press leaves preserve lossless target metadata`(count: Int) async throws {
        let identity = try Self.identity()
        let automation = PressMetadataAutomation(replies: Array(
            repeating: .success(Self.result(identity)), count: count))
        let response = try await Self.execute(automation, count: count)

        #expect(!response.isError)
        for metadata in try Self.metadata(response) {
            #expect(try metadata["target_identity"] == Value(identity.projection))
            #expect(try metadata["target_receipt"] == Value(identity.actionTargetReceipt))
            #expect(metadata["target_identity"]?.objectValue?["process_start_identity_decimal"] ==
                .string("9007199254740993"))
            #expect(metadata["dispatched_unit_count"] == .int(count))
        }
        #expect(automation.calls == count)
    }

    @Test(arguments: [false, true])
    func `missing or conflicting leaf identities never borrow a prior target`(conflicting: Bool) async throws {
        let first = try Self.identity()
        let second = conflicting ? try Self.identity(pid: 90) : nil
        let automation = PressMetadataAutomation(replies: [
            .success(Self.result(first)), .success(Self.result(second)),
        ])
        let response = try await Self.execute(automation, count: 2)

        #expect(!response.isError)
        for metadata in try Self.metadata(response) {
            #expect(metadata["target_identity"] == nil)
            #expect(metadata["target_receipt"] == nil)
            #expect(metadata["dispatched_unit_count"] == .int(2))
        }
    }

    @Test
    func `unverified press stays an error with one leaf receipt and no replay`() async throws {
        let identity = try Self.identity()
        let automation = PressMetadataAutomation(replies: [
            .success(Self.result(identity, outcome: Self.unverified)),
            .success(Self.result(identity)),
        ])
        let response = try await Self.execute(automation, count: 2)

        #expect(response.isError)
        #expect(automation.calls == 1)
        #expect(response.meta?.objectValue?["emitted_units"] == .int(1))
        for metadata in try Self.metadata(response) {
            #expect(metadata["state"] == .string("dispatched_unverified"))
            #expect(metadata["dispatched_unit_count"] == .int(1))
            #expect(metadata["retry_safe"] == .bool(false))
            #expect(metadata["target_identity"] == nil)
            #expect(try metadata["target_receipt"] == Value(identity.actionTargetReceipt))
        }
    }

    @Test(arguments: [false, true])
    func `failure composition retains only the targets of dispatched phases`(leafDispatched: Bool) async throws {
        let identity = try Self.identity()
        let failure: DesktopActionFailure = leafDispatched
            ? .indeterminate(
                delivery: Self.delivery,
                evidence: .completionUnknown,
                unitCount: .init(2),
                message: "Accepted leaf")
            : .preDispatchRefusal(reason: .targetUnavailable, message: "Refused leaf")
        let automation = PressMetadataAutomation(replies: [
            .success(Self.result(identity)),
            .failure(leafDispatched ? failure.attributed(to: identity.actionTargetReceipt) : failure),
        ])
        let response = try await Self.execute(automation, count: 2)

        #expect(response.isError)
        #expect(automation.calls == 2)
        #expect(response.meta?.objectValue?["emitted_units"] == .int(leafDispatched ? 3 : 1))
        for metadata in try Self.metadata(response) {
            #expect(metadata["dispatched_unit_count"] == .int(leafDispatched ? 3 : 1))
            #expect(try metadata["target_receipt"] == Value(identity.actionTargetReceipt))
        }
    }

    @Test(arguments: [false, true])
    func `setup focus cannot lend its target to an unattributed legacy or rejected chord`(reported: Bool) async throws {
        let automation = PressMetadataAutomation(replies: [
            .success(Self.result(nil, outcome: reported ? Self.unverified : nil)),
        ])
        let windows = MCPFocusResultWindowService()
        let context = await MCPToolTestHelpers.makeContext(automation: automation, windows: windows)
        let response = try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"], "foreground": true, "app": "Example", "delay": 0,
        ]))

        #expect(response.isError == reported)
        #expect(windows.focusCalls == 1)
        #expect(automation.calls == 1)
        for metadata in try Self.metadata(response) {
            #expect(metadata["target_identity"] == nil)
            #expect(metadata["target_receipt"] == nil)
            #expect(metadata["mutation_dispatched"] == .bool(true))
        }
    }

    private static let delivery = DesktopActionOutcome.Delivery(mechanism: .globalEvents, mode: .foreground)
    private static let unverified = DesktopActionOutcome.dispatchedUnverified(
        delivery: delivery, evidence: .deliveryAccepted, unitCount: .one)

    private static func identity(pid: Int32 = 89) throws -> DesktopTargetIdentity {
        let bounds = CGRect(x: 20, y: 30, width: 640, height: 480)
        return try DesktopTargetIdentity(exactWindow: .init(
            identity: .init(
                windowID: 700,
                ownerProcessIdentifier: pid,
                ownerProcessStartIdentity: 9_007_199_254_740_993,
                capturedBounds: bounds),
            bounds: bounds))
    }

    private static func result(
        _ identity: DesktopTargetIdentity?,
        outcome: DesktopActionOutcome? = .confirmedChange(delivery: delivery, unitCount: .one))
        -> UIAutomationActionResult<Void>
    {
        UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: identity)
    }

    private static func execute(_ automation: PressMetadataAutomation, count: Int) async throws -> ToolResponse {
        let context = await MCPToolTestHelpers.makeContext(automation: automation)
        return try await PressTool(context: context).execute(arguments: ToolArguments(raw: [
            "keys": ["cmd+a"], "foreground": true, "count": count, "delay": 0,
        ]))
    }

    private static func metadata(_ response: ToolResponse) throws -> [[String: Value]] {
        let wire = PeekabooMCPServer.callToolResult(from: response, toolName: "press")
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(wire))
        return try [#require(response.meta?.objectValue), #require(decoded.objectValue?["_meta"]?.objectValue)]
    }
}

@MainActor
private final class PressMetadataAutomation: MockAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()
    var replies: [Result<UIAutomationActionResult<Void>, DesktopActionFailure>]
    private(set) var calls = 0

    init(replies: [Result<UIAutomationActionResult<Void>, DesktopActionFailure>]) {
        self.replies = replies
        super.init(accessibilityGranted: true)
    }

    func hotkeyWithOutcome(keys _: String, holdDuration _: Int) async throws -> UIAutomationActionResult<Void> {
        self.calls += 1
        return try self.replies.removeFirst().get()
    }
}
