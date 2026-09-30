import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct PasteToolClipboardOwnershipTests {
    @Test(arguments: [false, true], [false, true])
    func `MCP process clipboard paste retains the reported hotkey target and dispatch count`(
        explicitPayload: Bool,
        indeterminate: Bool) async throws
    {
        let fixture = Fixture(prior: Self.payload("prior"))
        let bounds = CGRect(x: 20, y: 30, width: 600, height: 400)
        let reportedIdentity = try DesktopTargetIdentity(exactWindow: .init(
            identity: .init(
                windowID: 864,
                ownerProcessIdentifier: 2468,
                ownerProcessStartIdentity: 71,
                capturedBounds: bounds),
            bounds: bounds))
        let delivery = DesktopActionOutcome.Delivery(mechanism: .processTargetedEvents, mode: .background)
        let outcome: DesktopActionOutcome = indeterminate
            ? .indeterminate(route: .bridge, delivery: delivery, evidence: .completionUnknown, unitCount: .init(3))
            : .dispatchedUnverified(
                route: .bridge,
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .init(4))
        let automation = OutcomeOwnershipAutomation(outcome: outcome, targetIdentity: reportedIdentity)

        let response = try await fixture.run(automation: automation, explicitPayload: explicitPayload)

        #expect(response.isError)
        try MCPToolTestHelpers.expectCanonicalOutcomeMetadata(outcome, in: response)
        let metadata = try #require(response.meta?.objectValue)
        #expect(try metadata["target_receipt"] == Value(reportedIdentity.actionTargetReceipt))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["clipboard_cleanup_status"] == (explicitPayload ? .string("restored") : nil))
        #expect(automation.targetedHotkeyCalls.count == 1)
        #expect(automation.lastHotkeyKeys == nil)
        #expect(fixture.clipboard.setCallCount == (explicitPayload ? 1 : 0))
        #expect(fixture.clipboard.restoreCallCount == (explicitPayload ? 1 : 0))
        #expect(fixture.clipboard.current?.data == Data("prior".utf8))
    }

    @Test(arguments: [false, true], [false, true])
    func `MCP preserves a newer clipboard generation including identical bytes`(
        hadPriorContents: Bool,
        identicalBytes: Bool) async throws
    {
        let fixture = Fixture(prior: hadPriorContents ? Self.payload("prior") : nil)
        let newer = Self.payload(identicalBytes ? "hello" : "newer")
        fixture.automation.afterPinnedHotkey = { fixture.clipboard.current = newer }

        let response = try await fixture.run()
        let metadata = try #require(response.meta?.objectValue)
        #expect(response.isError)
        #expect(metadata["clipboard_cleanup_status"] == .string("preserved_newer_contents"))
        #expect(metadata["clipboard_restore_succeeded"] == .bool(false))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["may_have_pasted"] == .bool(true))
        #expect(fixture.clipboard.current?.data == newer.data)
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.clipboard.clearCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.count == 1)
    }

    @Test(arguments: [false, true])
    func `MCP cancellation and dispatch failure retain newer clipboard contents`(cancel: Bool) async throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.automation.afterPinnedHotkey = {
            fixture.clipboard.current = Self.payload("newer")
            if cancel {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        if !cancel {
            fixture.automation.pinnedHotkeyError = { _ in OwnershipFailure.afterDispatch }
        }
        let command = Task { @MainActor in try await fixture.run() }
        let response = try await command.value
        let metadata = try #require(response.meta?.objectValue)

        #expect(response.isError)
        #expect(metadata["clipboard_cleanup_status"] == .string("preserved_newer_contents"))
        #expect(metadata["paste_outcome"] == .string("indeterminate"))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(fixture.clipboard.current?.data == Data("newer".utf8))
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.clipboard.clearCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.count == 1)
    }

    @Test(arguments: [false, true])
    func `MCP attributed input refusal retains only the global clipboard effect`(
        newerCopy: Bool) async throws
    {
        let fixture = Fixture(prior: Self.payload("prior"))
        let automation = RefusingOwnershipAutomation(accessibilityGranted: true)
        automation.beforeRefusal = {
            if newerCopy {
                fixture.clipboard.current = Self.payload("newer")
            }
        }

        let response = try await fixture.run(automation: automation)
        let metadata = try #require(response.meta?.objectValue)
        #expect(response.isError)
        #expect(metadata["error_code"] == .string("TIMEOUT"))
        #expect(metadata["retry_safe"] == .bool(false))
        #expect(metadata["mutation_dispatched"] == .bool(true))
        #expect(metadata["state"] == .string("indeterminate"))
        #expect(metadata["route"] == .string("local"))
        #expect(metadata["delivery_mechanism"] == .string("clipboard_transaction"))
        #expect(metadata["dispatched_unit_count"] == nil || metadata["dispatched_unit_count"] == .null)
        #expect(metadata["target_receipt"] == nil || metadata["target_receipt"] == .null)
        #expect(metadata["clipboard_cleanup_status"] == .string(newerCopy ? "preserved_newer_contents" : "restored"))
        #expect(fixture.clipboard.current?.data == Data((newerCopy ? "newer" : "prior").utf8))
        #expect(automation.refusalCalls == 1)
        #expect(automation.targetedHotkeyCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func `MCP write failure does not overwrite an external update or restore without a claim`(
        partialWrite: Bool) async throws
    {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.clipboard.setError = ClipboardServiceError.writeFailed("synthetic payload write failed")
        fixture.clipboard.setMutatesBeforeThrow = partialWrite
        fixture.clipboard.afterPartialSet = { fixture.clipboard.current = Self.payload("newer") }

        let response = try await fixture.run()
        let metadata = try #require(response.meta?.objectValue)
        #expect(response.isError)
        #expect(metadata["clipboard_cleanup_status"] ==
            .string(partialWrite ? "preserved_newer_contents" : "not_needed"))
        #expect(metadata["retry_safe"] == .bool(!partialWrite))
        #expect(fixture.clipboard.current?.data == Data((partialWrite ? "newer" : "prior").utf8))
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.clipboard.clearCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    func `MCP silent clipboard permission refusal retains its reason without mutation`() async throws {
        let fixture = Fixture(prior: Self.payload("prior"))
        fixture.clipboard.getError = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Synthetic silent clipboard permission is missing")

        let response = try await fixture.run()
        let metadata = try #require(response.meta?.objectValue)
        #expect(response.isError)
        #expect(metadata["refusal_reason"] == .string("permission_denied"))
        #expect(metadata["retry_safe"] == .bool(true))
        #expect(metadata["mutation_dispatched"] == .bool(false))
        #expect(fixture.clipboard.setCallCount == 0)
        #expect(fixture.clipboard.saveCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    func `MCP legacy provider refuses before clipboard reads or input`() async throws {
        let fixture = Fixture(prior: nil)
        let legacy = LegacyClipboardService()
        let response = try await fixture.run(clipboard: legacy, foreground: true)

        #expect(response.isError)
        #expect(response.meta?.objectValue?["mutation_dispatched"] == .bool(false))
        #expect(legacy.backing.getCallCount == 0)
        #expect(legacy.backing.setCallCount == 0)
        #expect(legacy.backing.saveCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
        #expect(fixture.automation.lastHotkeyKeys == nil)
    }

    private static func payload(_ text: String) -> ClipboardReadResult {
        ClipboardReadResult(utiIdentifier: "public.data", data: Data(text.utf8), textPreview: nil)
    }

    @MainActor
    private final class Fixture {
        let clipboard: ScriptedClipboardService
        let automation = MockAutomationService(accessibilityGranted: true)

        init(prior: ClipboardReadResult?) {
            self.clipboard = ScriptedClipboardService(current: prior)
        }

        func run(
            clipboard: (any ClipboardServiceProtocol)? = nil,
            foreground: Bool = false,
            automation: (any UIAutomationServiceProtocol)? = nil,
            explicitPayload: Bool = true) async throws -> ToolResponse
        {
            let app = AutomationTestFixtures.application(
                processIdentifier: 2468,
                processStartIdentity: 71,
                bundleIdentifier: "synthetic.clipboard.target",
                name: "SyntheticClipboardTarget")
            let context = await MCPToolTestHelpers.makeContext(
                automation: automation ?? self.automation,
                applications: MockApplicationService(applications: [app]),
                clipboard: clipboard ?? self.clipboard,
                executionPolicy: .unrestricted)
            var arguments: [String: Any] = [
                "app": "SyntheticClipboardTarget", "foreground": foreground,
                "restore_delay_ms": 0,
            ]
            if explicitPayload {
                arguments["dataBase64"] = "aGVsbG8="
                arguments["uti"] = "public.data"
            }
            return try await PasteTool(context: context).execute(arguments: ToolArguments(raw: arguments))
        }
    }
}

private enum OwnershipFailure: Error {
    case afterDispatch
}

@MainActor
private final class OutcomeOwnershipAutomation: MockAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript: UIAutomationOutcomeScript
    let uiAutomationOutcomeTargetIdentity: DesktopTargetIdentity?

    init(outcome: DesktopActionOutcome, targetIdentity: DesktopTargetIdentity) {
        self.uiAutomationOutcomeScript = UIAutomationOutcomeScript(defaultResponse: .outcome(outcome))
        self.uiAutomationOutcomeTargetIdentity = targetIdentity
        super.init(accessibilityGranted: true)
    }
}

@MainActor
private final class RefusingOwnershipAutomation: MockAutomationService, ScriptedUIAutomationActionOutcomeProviding {
    let uiAutomationOutcomeScript = UIAutomationOutcomeScript()
    let uiAutomationOutcomeTargetIdentity: DesktopTargetIdentity? = nil
    var beforeRefusal: (() -> Void)?
    private(set) var refusalCalls = 0

    func hotkeyWithOutcome(
        keys _: String,
        holdDuration _: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) async throws -> UIAutomationActionResult<Void>
    {
        self.refusalCalls += 1
        self.beforeRefusal?()
        let identity = try DesktopTargetIdentity(processIdentity: expectedProcessIdentity)
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Synthetic hotkey refused before dispatch",
            standardErrorCode: .timeout)
            .attributed(to: identity.actionTargetReceipt)
    }
}

@MainActor
private final class LegacyClipboardService: ClipboardServiceProtocol {
    let backing = ScriptedClipboardService()
    func get(prefer uti: UTType?) throws -> ClipboardReadResult? {
        try self.backing.get(prefer: uti)
    }

    func set(_ request: ClipboardWriteRequest) throws -> ClipboardReadResult {
        try self.backing.set(request)
    }

    func clear() {
        self.backing.clear()
    }

    func save(slot: String) throws {
        try self.backing.save(slot: slot)
    }

    func restore(slot: String) throws -> ClipboardReadResult {
        try self.backing.restore(slot: slot)
    }
}
