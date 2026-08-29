import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime

@MainActor
@Suite(.serialized)
struct MCPClipboardOutcomeTests {
    @Test
    func `clipboard mutations publish their canonical foreground transaction outcomes`() async throws {
        let clipboard = ResultClipboardService()
        let expected = DesktopActionOutcome.confirmedChange(
            delivery: ClipboardMutationResultSemantics.delivery)
        clipboard.outcome = expected
        clipboard.slots["fixture"] = Self.result("restored")
        let context = await MCPToolTestHelpers.makeContext(clipboard: clipboard)
        let tool = ClipboardTool(context: context)

        let set = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "set",
            "text": "updated",
        ]))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: set)

        let clear = try await tool.execute(arguments: ToolArguments(raw: ["action": "clear"]))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: clear)

        let restore = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "restore",
            "slot": "fixture",
        ]))
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: restore)

        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.clearCallCount == 1)
        #expect(clipboard.restoreCallCount == 1)
    }

    @Test
    func `clipboard set validation refusal is canonical and does not dispatch`() async throws {
        let clipboard = ResultClipboardService()
        let context = await MCPToolTestHelpers.makeContext(clipboard: clipboard)

        let response = try await ClipboardTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "set",
        ]))

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalRefusalMetadata(reason: .invalidRequest, in: response)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
    }

    @Test
    func `clipboard post-write failure remains indeterminate and retry unsafe`() async throws {
        let clipboard = ResultClipboardService()
        clipboard.postWriteError = ClipboardOutcomeTestError.processing
        let context = await MCPToolTestHelpers.makeContext(clipboard: clipboard)

        let response = try await ClipboardTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "set",
            "text": "updated",
        ]))

        let expected = DesktopActionOutcome.indeterminate(
            delivery: ClipboardMutationResultSemantics.delivery,
            evidence: .completionUnknown)
        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(expected, in: response)
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.current?.textPreview == "updated")
    }

    @Test
    func `background-only clipboard mutations stop at schema or policy before the leaf`() async throws {
        let clipboard = ResultClipboardService()
        clipboard.slots["fixture"] = Self.result("restored")
        let context = await MCPToolTestHelpers.makeContext(
            clipboard: clipboard,
            executionPolicy: .backgroundOnly)
        let tool = ClipboardTool(context: context)
        let cases: [(arguments: [String: Any], reason: DesktopActionOutcome.RefusalReason, errorCode: String)] = [
            // The background catalog omits text, so schema validation precedes the policy gate.
            (["action": "set", "text": "updated"], .invalidRequest, "VALIDATION_ERROR"),
            (["action": "set"], .foregroundConsentRequired, MCPToolExecutionPolicy.refusalErrorCode),
            (["action": "clear"], .foregroundConsentRequired, MCPToolExecutionPolicy.refusalErrorCode),
            (
                ["action": "restore", "slot": "fixture"],
                .foregroundConsentRequired,
                MCPToolExecutionPolicy.refusalErrorCode),
        ]

        for testCase in cases {
            let response = try await context.execute(tool: tool, arguments: ToolArguments(raw: testCase.arguments))
            #expect(response.isError)
            try MCPToolTestHelpers.expectCanonicalRefusalMetadata(
                reason: testCase.reason,
                in: response)
            #expect(response.meta?.objectValue?["error_code"] == .string(testCase.errorCode))
        }
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
    }

    @Test
    func `clipboard get and save remain read-only without action metadata`() async throws {
        let clipboard = ResultClipboardService()
        clipboard.current = Self.result("current")
        let context = await MCPToolTestHelpers.makeContext(clipboard: clipboard)
        let tool = ClipboardTool(context: context)

        let get = try await tool.execute(arguments: ToolArguments(raw: ["action": "get"]))
        let save = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "save",
            "slot": "fixture",
        ]))

        for response in [get, save] {
            let meta = try #require(response.meta?.objectValue)
            #expect(meta["effect"] == nil)
            #expect(meta["state"] == nil)
            #expect(meta["dispatch_state"] == nil)
        }
        #expect(clipboard.saveCallCount == 1)
    }

    private static func result(_ text: String) -> ClipboardReadResult {
        ClipboardReadResult(
            utiIdentifier: UTType.utf8PlainText.identifier,
            data: Data(text.utf8),
            textPreview: text)
    }
}

@MainActor
private final class ResultClipboardService: ClipboardServiceActionResultProviding {
    var current: ClipboardReadResult?
    var slots: [String: ClipboardReadResult] = [:]
    var outcome: DesktopActionOutcome = .dispatchedUnverified(
        delivery: ClipboardMutationResultSemantics.delivery,
        evidence: .deliveryAccepted)
    var postWriteError: (any Error)?
    private(set) var setCallCount = 0
    private(set) var clearCallCount = 0
    private(set) var saveCallCount = 0
    private(set) var restoreCallCount = 0

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        self.current
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        let representation = try self.primaryRepresentation(in: request)
        let text = request.alsoText ?? String(data: representation.data, encoding: .utf8)
        let result = ClipboardReadResult(
            utiIdentifier: representation.utiIdentifier,
            data: representation.data,
            textPreview: text)
        self.setCallCount += 1
        self.current = result
        return result
    }

    func clear() {
        self.clearCallCount += 1
        self.current = nil
    }

    func save(slot: String) throws {
        guard let current else { throw ClipboardServiceError.empty }
        self.saveCallCount += 1
        self.slots[slot] = current
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        self.restoreCallCount += 1
        guard let result = self.slots[slot] else {
            throw ClipboardServiceError.slotNotFound(slot)
        }
        self.current = result
        return result
    }

    func setActionResult(_ request: ClipboardWriteRequest) throws -> DesktopActionResult<ClipboardReadResult> {
        let payload = try self.set(request)
        try self.throwPostWriteErrorIfNeeded()
        return DesktopActionResult(payload: payload, outcome: self.outcome)
    }

    func clearActionResult() throws -> DesktopActionResult<Void> {
        self.clear()
        try self.throwPostWriteErrorIfNeeded()
        return DesktopActionResult(outcome: self.outcome)
    }

    func restoreActionResult(slot: String) throws -> DesktopActionResult<ClipboardReadResult> {
        let payload = try self.restore(slot: slot)
        try self.throwPostWriteErrorIfNeeded()
        return DesktopActionResult(payload: payload, outcome: self.outcome)
    }

    private func primaryRepresentation(in request: ClipboardWriteRequest) throws -> ClipboardRepresentation {
        guard let representation = request.representations.first else {
            throw ClipboardServiceError.writeFailed("No representations provided.")
        }
        return representation
    }

    private func throwPostWriteErrorIfNeeded() throws {
        if let postWriteError {
            throw ClipboardMutationResultSemantics.postWriteFailure(
                postWriteError,
                operation: "Clipboard mutation")
        }
    }
}

private enum ClipboardOutcomeTestError: Error {
    case processing
}
