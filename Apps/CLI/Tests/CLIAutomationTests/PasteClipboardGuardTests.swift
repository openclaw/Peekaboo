import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe), .serialized)
@MainActor
struct PasteClipboardGuardTests {
    @Test(arguments: 0..<8)
    func `temporary exact paste requires prepared host and retained claim before writing`(flags: Int) async throws {
        let hostSupportsGuard = flags & 1 != 0
        let hostSupportsPreparation = flags & 2 != 0
        let transactionRetainsClaim = flags & 4 != 0
        let clipboard = StubClipboardService(current: Self.prior)
        clipboard.retainsTemporaryWriteClaims = transactionRetainsClaim
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        fixture.automation.supportsClipboardGuardedExactWindowHotkeys = hostSupportsGuard
        fixture.automation.supportsPreparedClipboardGuardedExactWindowHotkeys = hostSupportsPreparation
        fixture.automation.supportsExactWindowTargetedKeyboard = !hostSupportsGuard
        fixture.automation.actionOutcome = Self.dispatched

        let result = try await self.run(fixture)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        let hostSupportsPaste = hostSupportsGuard && hostSupportsPreparation
        let dispatched = hostSupportsPaste && transactionRetainsClaim
        #expect(result.exitStatus == 1)
        #expect(response.error?.mutation_dispatched == dispatched)
        #expect(response.error?.retry_safe == !dispatched)
        if !hostSupportsPaste {
            let hint = try #require(response.error?.hint)
            #expect(hint.contains("peekaboo bridge status --bridge-socket <path>"))
            #expect(hint.contains("custom-socket trust policy can cap negotiation at protocol 1.28"))
            #expect(!hint.contains("Update the Peekaboo host"))
        }
        #expect(clipboard.setCallCount == (dispatched ? 1 : 0))
        #expect(clipboard.getCallCount == (hostSupportsPaste ? 1 : 0))
        #expect(clipboard.restoreCallCount == (dispatched ? 1 : 0))
        #expect(clipboard.current?.data == Self.prior.data)
        #expect(fixture.automation.guardedHotkeyClaims.map(\.changeCount) == (dispatched ? [1] : []))
        #expect(fixture.automation.backgroundPreparations == (dispatched ? [.blankWindowChrome] : []))
        #expect(fixture.automation.exactHotkeyCalls.count == (dispatched ? 1 : 0))
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
        #expect(fixture.automation.hotkeyCalls.isEmpty)
    }

    @Test
    func `late guard refusal preserves newer contents and the original declaration claim`() async throws {
        let clipboard = StubClipboardService(current: Self.prior)
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        fixture.automation.beforeGuardedHotkey = {
            clipboard.current = Self.newer
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Synthetic clipboard claim was superseded"
            )
        }

        let result = try await self.run(fixture)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(fixture.automation.guardedHotkeyClaims.map(\.changeCount) == [1])
        #expect(fixture.automation.exactHotkeyCalls.isEmpty)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
        #expect(response.outcome?.state == .indeterminate)
        #expect(response.outcome?.deliveryMechanism == .clipboardTransaction)
        #expect(response.outcome?.dispatchedUnitCount == nil)
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.clipboard_cleanup_status == "preserved_newer_contents")
        #expect(clipboard.current?.data == Self.newer.data)
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
    }

    @Test(arguments: [false, true])
    func `failed claim write never dispatches and retains partial write cleanup`(partialWrite: Bool) async throws {
        let clipboard = StubClipboardService(current: Self.prior)
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        clipboard.setError = ClipboardServiceError.writeFailed("Synthetic write failure")
        clipboard.setMutatesBeforeThrow = partialWrite
        clipboard.afterPartialSet = { clipboard.current = Self.newer }

        let result = try await self.run(fixture)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(fixture.automation.guardedHotkeyClaims.isEmpty)
        #expect(fixture.automation.exactHotkeyCalls.isEmpty)
        #expect(response.error?.clipboard_cleanup_status == (partialWrite ? "preserved_newer_contents" : "not_needed"))
        #expect(clipboard.current?.data == (partialWrite ? Self.newer.data : Self.prior.data))
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
    }

    @Test
    func `cancellation after the claimed write cleans once without sending a hotkey`() async throws {
        let clipboard = StubClipboardService(current: Self.prior)
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        clipboard.afterSet = { withUnsafeCurrentTask { $0?.cancel() } }
        let command = Task { @MainActor in try await self.run(fixture) }
        let result = try await command.value
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.clipboard_cleanup_status == "restored")
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.restoreCallCount == 1)
        #expect(clipboard.clearCallCount == 0)
        #expect(clipboard.current?.data == Self.prior.data)
        #expect(fixture.automation.guardedHotkeyClaims.isEmpty)
        #expect(fixture.automation.exactHotkeyCalls.isEmpty)
    }

    private func run(_ fixture: ExactBackgroundTextPasteFixture) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run([
            "paste", "--app", "TextEdit", "--window-id", String(ExactBackgroundTextPasteFixture.windowID),
            "--data-base64", "aGVsbG8=", "--uti", "public.data",
            "--restore-delay", "0", "--json", "--no-remote",
        ], services: fixture.services)
    }

    @Test(arguments: [false, true])
    func `foreground temporary and current clipboard routes do not require claims`(foreground: Bool) async throws {
        let clipboard = StubClipboardService(current: Self.prior)
        clipboard.retainsTemporaryWriteClaims = false
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        fixture.automation.supportsClipboardGuardedExactWindowHotkeys = false
        fixture.automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(
                mechanism: foreground ? .globalEvents : .windowTargetedEvents,
                mode: foreground ? .foreground : .background
            ),
            evidence: .deliveryAccepted,
            unitCount: .init(4)
        )
        var arguments = ["paste", "--restore-delay", "0", "--json", "--no-remote"]
        arguments += foreground
            ? ["--foreground", "--data-base64", "aGVsbG8=", "--uti", "public.data"]
            : ["--app", "TextEdit", "--window-id", String(ExactBackgroundTextPasteFixture.windowID)]
        _ = try await InProcessCommandRunner.run(arguments, services: fixture.services)
        #expect(fixture.automation.guardedHotkeyClaims.isEmpty)
        #expect(clipboard.setCallCount == (foreground ? 1 : 0))
        #expect(clipboard.restoreCallCount == (foreground ? 1 : 0))
        #expect(fixture.automation.outcomeHotkeyCallCount == 1)
        #expect(clipboard.current?.data == Self.prior.data)
    }

    private static let prior = ClipboardReadResult(
        utiIdentifier: "public.utf8-plain-text", data: Data("prior".utf8), textPreview: "prior"
    )
    private static let newer = ClipboardReadResult(
        utiIdentifier: "public.utf8-plain-text", data: Data("newer".utf8), textPreview: "newer"
    )
    private static let dispatched = DesktopActionOutcome.dispatchedUnverified(
        delivery: .init(mechanism: .composite, mode: .background),
        evidence: .deliveryAccepted,
        unitCount: .init(8)
    )
}
