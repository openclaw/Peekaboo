import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
import UniformTypeIdentifiers
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.tags(.safe), .serialized)
@MainActor
struct PasteClipboardOwnershipTests {
    @Test(arguments: [false, true], [false, true])
    func `Background paste preserves a newer clipboard write before cleanup`(
        hadPriorContents: Bool,
        identicalBytes: Bool
    ) async throws {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "synthetic.clipboard.target",
            name: "SyntheticClipboardTarget"
        )
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        if hadPriorContents {
            clipboard.current = ClipboardReadResult(
                utiIdentifier: "public.utf8-plain-text",
                data: Data("synthetic-before".utf8),
                textPreview: "synthetic-before"
            )
        }
        let newer = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data((identicalBytes ? "hello" : "synthetic-newer-copy").utf8),
            textPreview: "synthetic-newer-copy"
        )
        var injectedNewerWrite = false
        automation.afterPinnedHotkey = {
            clipboard.current = newer
            injectedNewerWrite = true
        }
        let applications = StubApplicationService(applications: [app])
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run([
            "paste", "--app", "SyntheticClipboardTarget",
            "--data-base64", "aGVsbG8=", "--uti", "public.data",
            "--restore-delay", "0", "--json", "--no-remote",
        ], services: services)

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("may have pasted; do not retry"))
        #expect(automation.targetedHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(applications.activateCalls.isEmpty)
        #expect(clipboard.setCallCount == 1)
        #expect(injectedNewerWrite)
        #expect(clipboard.current?.data == newer.data)
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.error?.clipboard_cleanup_status == "preserved_newer_contents")
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.mutation_dispatched == true)
        #expect(!result.stdout.contains("prior clipboard state was restored"))
    }

    @Test(arguments: [false, true])
    func `Cancellation and delivery failure preserve newer contents without replay`(cancel: Bool) async throws {
        let fixture = OwnershipFixture()
        let cancellation = OwnershipCancellation()
        fixture.automation.afterDelivery = {
            fixture.clipboard.current = Self.newer
            if cancel {
                cancellation.task?.cancel()
            } else {
                throw OwnershipFailure.afterDispatch
            }
        }
        let command = Task { @MainActor in try await fixture.run() }
        cancellation.task = command
        let result = try await command.value
        cancellation.task = nil
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus != 0)
        #expect(response.error?.clipboard_cleanup_status == "preserved_newer_contents")
        #expect(response.error?.retry_safe == false)
        #expect(response.outcome?.state == .indeterminate)
        #expect(fixture.clipboard.current?.data == Self.newer.data)
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.clipboard.clearCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.count == 1)
    }

    @Test(arguments: [false, true])
    func `A refused hotkey retains the earlier clipboard claim without inventing input`(newerCopy: Bool) async throws {
        let fixture = OwnershipFixture()
        fixture.automation.beforeDelivery = {
            if newerCopy {
                fixture.clipboard.current = Self.newer
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Synthetic hotkey refused before dispatch",
                standardErrorCode: .timeout
            )
        }

        let result = try await fixture.run()
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(response.error?.code == "TIMEOUT")
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.outcome?.state == .indeterminate)
        #expect(response.outcome?.route == .local)
        #expect(response.outcome?.deliveryMechanism == .clipboardTransaction)
        #expect(response.outcome?.dispatchedUnitCount == nil)
        #expect(response.target_receipt == nil)
        #expect(response.error?.clipboard_cleanup_status == (newerCopy ? "preserved_newer_contents" : "restored"))
        #expect(fixture.clipboard.current?.data == (newerCopy ? Self.newer.data : Data("prior".utf8)))
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func `Write failure cleanup only acts on an owned claim`(partialWrite: Bool) async throws {
        let fixture = OwnershipFixture()
        fixture.clipboard.setError = ClipboardServiceError.writeFailed("synthetic payload write failed")
        fixture.clipboard.setMutatesBeforeThrow = partialWrite
        fixture.clipboard.afterPartialSet = { fixture.clipboard.current = Self.newer }

        let result = try await fixture.run()
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(result.exitStatus != 0)
        #expect(response.error?.clipboard_cleanup_status == (partialWrite ? "preserved_newer_contents" : "not_needed"))
        #expect(fixture.clipboard.current?.data == (partialWrite ? Self.newer.data : Data("prior".utf8)))
        #expect(fixture.clipboard.restoreCallCount == 0)
        #expect(fixture.clipboard.clearCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    func `Silent clipboard permission refusal retains its reason without mutation`() async throws {
        let fixture = OwnershipFixture()
        fixture.clipboard.getError = DesktopActionFailure.preDispatchRefusal(
            reason: .permissionDenied,
            message: "Synthetic silent clipboard permission is missing"
        )

        let result = try await fixture.run()
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)
        #expect(result.exitStatus != 0)
        #expect(response.outcome?.refusalReason == .permissionDenied)
        #expect(response.error?.retry_safe == true)
        #expect(response.error?.mutation_dispatched == false)
        #expect(fixture.clipboard.setCallCount == 0)
        #expect(fixture.clipboard.saveCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
    }

    @Test
    func `Legacy clipboard provider refuses before reads focus or input`() async throws {
        let fixture = OwnershipFixture()
        let legacy = LegacyClipboardService()
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: legacy,
            automation: fixture.automation
        )

        let result = try await InProcessCommandRunner.run([
            "paste", "--foreground", "--no-auto-focus",
            "--data-base64", "aGVsbG8=", "--uti", "public.data", "--json", "--no-remote",
        ], services: services)

        #expect(result.exitStatus != 0)
        #expect(result.stdout.contains("ownership-aware temporary writes"))
        #expect(legacy.backing.getCallCount == 0)
        #expect(legacy.backing.setCallCount == 0)
        #expect(legacy.backing.saveCallCount == 0)
        #expect(fixture.automation.hotkeyCalls.isEmpty)
        #expect(fixture.automation.targetedHotkeyCalls.isEmpty)
    }

    private static var newer: ClipboardReadResult {
        ClipboardReadResult(utiIdentifier: "public.data", data: Data("newer".utf8), textPreview: nil)
    }
}

@MainActor
private final class OwnershipFixture {
    let clipboard = StubClipboardService(current: ClipboardReadResult(
        utiIdentifier: "public.data", data: Data("prior".utf8), textPreview: nil
    ))
    let automation = OwnershipAutomation()

    func run() async throws -> CommandRunResult {
        let app = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "synthetic.clipboard.target",
            name: "SyntheticClipboardTarget"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [app]),
            clipboard: self.clipboard,
            automation: self.automation
        )
        return try await InProcessCommandRunner.run([
            "paste", "--app", "SyntheticClipboardTarget",
            "--data-base64", "aGVsbG8=", "--uti", "public.data",
            "--restore-delay", "0", "--json", "--no-remote",
        ], services: services)
    }
}

private enum OwnershipFailure: Error {
    case afterDispatch
}

@MainActor
private final class OwnershipAutomation: StubAutomationService {
    var beforeDelivery: (() throws -> Void)?
    var afterDelivery: (() throws -> Void)?

    override func hotkey(
        keys: String,
        holdDuration: Int,
        expectedProcessIdentity: ApplicationProcessIdentity
    ) async throws {
        try self.beforeDelivery?()
        try await super.hotkey(keys: keys, holdDuration: holdDuration, expectedProcessIdentity: expectedProcessIdentity)
        try self.afterDelivery?()
    }
}

@MainActor
private final class OwnershipCancellation {
    var task: Task<CommandRunResult, any Error>?
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
