import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

extension PasteCommandTests {
    @Test(arguments: [false, true], [false, true])
    @MainActor
    func `Background paste keeps reported hotkey failure receipts`(
        exactWindow: Bool,
        temporaryPayload: Bool
    ) async throws {
        let prepared = exactWindow && temporaryPayload
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: prepared ? .composite : (exactWindow ? .windowTargetedEvents : .processTargetedEvents),
            mode: .background
        )
        let unitCount = DesktopActionOutcome.DispatchUnitCount(prepared ? 8 : 4)
        let outcomes: [DesktopActionOutcome] = [
            .dispatchedUnverified(delivery: delivery, evidence: .deliveryAccepted, unitCount: unitCount),
            .indeterminate(delivery: delivery, evidence: .completionUnknown, unitCount: unitCount),
        ]
        for outcome in outcomes {
            let clipboard = StubClipboardService(current: ClipboardReadResult(
                utiIdentifier: "public.utf8-plain-text",
                data: Data("prior".utf8),
                textPreview: "prior"
            ))
            let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
            if !exactWindow {
                fixture.windows.windowsByApp = [:]
            }
            fixture.automation.actionOutcome = outcome
            var arguments = ["paste", "--app", "TextEdit", "--restore-delay", "0", "--json", "--no-remote"]
            if exactWindow {
                arguments += ["--window-id", String(ExactBackgroundTextPasteFixture.windowID)]
            }
            if temporaryPayload {
                arguments += [
                    "--data-base64",
                    Data("{\\rtf1 synthetic}".utf8).base64EncodedString(),
                    "--uti",
                    "public.rtf"
                ]
            }

            let result = try await InProcessCommandRunner.run(arguments, services: fixture.services)
            let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

            #expect(result.exitStatus == 1)
            #expect(response.error?.message == "Paste hotkey did not return a confirmed outcome.")
            #expect(response.outcome?.outcome == outcome)
            #expect(response.error?.retry_safe == false)
            #expect(response.error?.mutation_dispatched == true)
            #expect(response.target_receipt?.processIdentifier == ExactBackgroundTextPasteFixture.processIdentifier)
            #expect(response.target_receipt?.processStartIdentity == ExactBackgroundTextPasteFixture
                .processStartIdentity)
            #expect(response.target_receipt?.windowID == (exactWindow ? ExactBackgroundTextPasteFixture.windowID : nil))
            #expect(fixture.automation.outcomeHotkeyCallCount == 1)
            #expect(fixture.automation.exactHotkeyCalls.count == (exactWindow ? 1 : 0))
            #expect(fixture.automation.guardedHotkeyClaims.map(\.changeCount) ==
                (exactWindow && temporaryPayload ? [1] : []))
            #expect(fixture.automation.backgroundPreparations == (prepared ? [.blankWindowChrome] : []))
            #expect(fixture.automation.targetedHotkeyCalls.count == (exactWindow ? 0 : 1))
            #expect(fixture.automation.hotkeyCalls.isEmpty)
            #expect(clipboard.current?.textPreview == "prior")
            #expect(clipboard.setCallCount == (temporaryPayload ? 1 : 0))
            #expect(clipboard.restoreCallCount == (temporaryPayload ? 1 : 0))
            #expect(response.error?.clipboard_cleanup_status == (temporaryPayload ? "restored" : nil))
        }
    }

    @Test
    @MainActor
    func `Temporary clipboard mutation clears a reported hotkey refusal target`() async throws {
        let clipboard = StubClipboardService(current: ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        ))
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        fixture.automation.actionOutcome = .refused(reason: .permissionDenied)

        let result = try await InProcessCommandRunner.run([
            "paste", "--app", "TextEdit", "--window-id", String(ExactBackgroundTextPasteFixture.windowID),
            "--data-base64", "aGVsbG8=", "--uti", "public.data",
            "--restore-delay", "0", "--json", "--no-remote",
        ], services: fixture.services)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(response.outcome?.state == .indeterminate)
        #expect(response.outcome?.deliveryMechanism == .clipboardTransaction)
        #expect(response.outcome?.dispatchedUnitCount == nil)
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.mutation_dispatched == true)
        #expect(response.target_receipt == nil)
        #expect(response.target_identity == nil)
        #expect(response.error?.clipboard_cleanup_status == "restored")
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.restoreCallCount == 1)
    }

    @Test
    @MainActor
    func `Unconfirmed paste retains its reported receipt when cleanup preserves newer contents`() async throws {
        let clipboard = StubClipboardService(current: ClipboardReadResult(
            utiIdentifier: "public.data", data: Data("prior".utf8), textPreview: nil
        ))
        let fixture = ExactBackgroundTextPasteFixture(clipboard: clipboard)
        fixture.windows.windowsByApp = [:]
        let reportedTarget = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(
                processIdentifier: ExactBackgroundTextPasteFixture.processIdentifier,
                processStartIdentity: ExactBackgroundTextPasteFixture.processStartIdentity
            ),
            windowID: 902,
            bounds: ExactBackgroundTextPasteFixture.bounds
        )
        fixture.automation.actionOutcomeTargetIdentity = reportedTarget.windowTargetIdentity
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .init(4)
        )
        fixture.automation.actionOutcome = outcome
        fixture.automation.afterPinnedHotkey = {
            clipboard.current = ClipboardReadResult(
                utiIdentifier: "public.data", data: Data("newer".utf8), textPreview: nil
            )
        }

        let result = try await InProcessCommandRunner.run([
            "paste", "--app", "TextEdit", "--data-base64", "aGVsbG8=", "--uti", "public.data",
            "--restore-delay", "0", "--json", "--no-remote",
        ], services: fixture.services)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(response.outcome?.outcome == outcome)
        #expect(response.target_receipt == reportedTarget.windowTargetReceipt)
        #expect(response.error?.clipboard_cleanup_status == "preserved_newer_contents")
        #expect(clipboard.current?.data == Data("newer".utf8))
        #expect(clipboard.setCallCount == 1)
        #expect(clipboard.restoreCallCount == 0)
        #expect(clipboard.clearCallCount == 0)
        #expect(fixture.automation.targetedHotkeyCalls.count == 1)
        #expect(fixture.automation.hotkeyCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Global paste failure cannot inherit a reported or setup focus target`(temporaryPayload: Bool) async throws {
        let windows = PasteFocusWindowService()
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted,
            unitCount: .one
        )
        automation.actionOutcomeTargetIdentity = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: PasteFocusWindowService.processIdentifier,
            processStartIdentity: PasteFocusWindowService.processStartIdentity
        ))
        let clipboard = StubClipboardService()
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows, clipboard: clipboard, automation: automation
        )
        var arguments = [
            "paste", "--window-id", String(PasteFocusWindowService.windowID),
            "--foreground", "--focus-timeout", "1ms", "--focus-retry-count", "0",
            "--restore-delay", "0", "--json", "--no-remote",
        ]
        if temporaryPayload {
            arguments += ["--data-base64", "aGVsbG8=", "--uti", "public.data"]
        }

        let result = try await InProcessCommandRunner.run(arguments, services: services)
        let response = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(response.target_receipt == nil)
        #expect(response.target_identity == nil)
        #expect(response.error?.retry_safe == false)
        #expect(response.error?.mutation_dispatched == true)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.outcomeHotkeyCallCount == 1)
    }
}
