import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooCLI
@testable import PeekabooCore

extension PasteCommandTests {
    @Test
    @MainActor
    func `Exact-window background text paste projects its returned target and outcome`() async throws {
        let fixture = ExactBackgroundTextPasteFixture()
        fixture.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: .one
        )

        let result = try await fixture.run(text: "exact text")
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )

        #expect(result.exitStatus == 0)
        #expect(fixture.automation.exactTypeActionsCalls.count == 1)
        #expect(payload.data.targetPID == Int(ExactBackgroundTextPasteFixture.processIdentifier))
        #expect(payload.data.targetWindowID == ExactBackgroundTextPasteFixture.windowID)
        #expect(payload.outcome?.state == .confirmedChange)
        #expect(payload.outcome?.deliveryMechanism == .windowTargetedEvents)
        #expect(payload.outcome?.deliveryMode == .background)
        #expect(payload.target_identity?.kind == .window)
        #expect(payload.target_identity?.windowID == ExactBackgroundTextPasteFixture.windowID)
        #expect(payload.target_receipt?.windowID == ExactBackgroundTextPasteFixture.windowID)
    }

    @Test
    func `Exact-window background text paste missing outcome keeps delivery and receipt`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(
                processIdentifier: ExactBackgroundTextPasteFixture.processIdentifier,
                processStartIdentity: ExactBackgroundTextPasteFixture.processStartIdentity
            ),
            windowID: ExactBackgroundTextPasteFixture.windowID,
            bounds: ExactBackgroundTextPasteFixture.bounds
        )
        let result = UIAutomationActionResult(
            payload: TypeResult(totalCharacters: 15, keyPresses: 0),
            outcome: nil,
            targetIdentity: fixture.windowTargetIdentity
        )

        do {
            _ = try PasteCommand.validateBackgroundTextResult(
                result,
                authorizedTarget: fixture.windowTargetIdentity.target
            )
            Issue.record("Expected missing canonical outcome to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.message.contains("without a canonical outcome"))
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(
                mechanism: .windowTargetedEvents,
                mode: .background
            ))
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == fixture.windowTargetReceipt)
        }
    }

    @Test
    func `Background text paste accepts compatible exact-window provider evidence`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(
                processIdentifier: ExactBackgroundTextPasteFixture.processIdentifier,
                processStartIdentity: ExactBackgroundTextPasteFixture.processStartIdentity
            ),
            windowID: ExactBackgroundTextPasteFixture.windowID,
            bounds: ExactBackgroundTextPasteFixture.bounds
        )
        let result = UIAutomationActionResult(
            payload: TypeResult(totalCharacters: 4, keyPresses: 0),
            outcome: .confirmedChange(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                unitCount: .one
            ),
            targetIdentity: fixture.windowTargetIdentity
        )

        let resolved = try PasteCommand.validateBackgroundTextResult(
            result,
            authorizedTarget: fixture.processTargetIdentity.target
        )

        #expect(resolved == fixture.windowTargetIdentity)
        #expect(resolved.actionTargetReceipt.windowID == ExactBackgroundTextPasteFixture.windowID)
    }

    @Test
    func `Background text paste rejects confirmed foreground delivery with its exact receipt`() throws {
        let fixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(
                processIdentifier: ExactBackgroundTextPasteFixture.processIdentifier,
                processStartIdentity: ExactBackgroundTextPasteFixture.processStartIdentity
            ),
            windowID: ExactBackgroundTextPasteFixture.windowID,
            bounds: ExactBackgroundTextPasteFixture.bounds
        )
        let foregroundDelivery = DesktopActionOutcome.Delivery(
            mechanism: .globalEvents,
            mode: .foreground
        )
        let result = UIAutomationActionResult(
            payload: TypeResult(totalCharacters: 4, keyPresses: 0),
            outcome: .confirmedChange(delivery: foregroundDelivery, unitCount: .one),
            targetIdentity: fixture.windowTargetIdentity
        )

        do {
            _ = try PasteCommand.validateBackgroundTextResult(
                result,
                authorizedTarget: fixture.windowTargetIdentity.target
            )
            Issue.record("Expected foreground delivery to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.message == "Background text paste reported foreground delivery.")
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == foregroundDelivery)
            #expect(failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == fixture.windowTargetReceipt)
        }
    }

    @Test
    @MainActor
    func `Exact-window background text paste fails closed on a mismatched result target`() async throws {
        let fixture = ExactBackgroundTextPasteFixture()
        fixture.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: .one
        )
        fixture.automation.actionOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: ApplicationProcessIdentity(
                processIdentifier: 9753,
                processStartIdentity: 72
            )
        )
        fixture.automation.allowsContradictoryOutcomeTargetIdentityForTesting = true

        let result = try await fixture.run(text: "mismatched")
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(fixture.automation.exactTypeActionsCalls.count == 1)
        #expect(payload.error?.message.contains("target different from its authorization") == true)
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.outcome?.deliveryMechanism == .windowTargetedEvents)
        #expect(payload.outcome?.deliveryMode == .background)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(payload.outcome?.retrySafe == false)
        #expect(payload.target_receipt?.processIdentifier == 2468)
        #expect(payload.target_receipt?.processStartIdentity == 71)
        #expect(payload.target_receipt?.windowID == 901)
    }

    @Test
    @MainActor
    func `Foreground paste sends current clipboard with its hotkey receipt`() async throws {
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("current".utf8),
            textPreview: "current"
        )
        let services = TestServicesFactory.makePeekabooServices(
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--foreground",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )

        #expect(result.exitStatus == 0)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(automation.targetedHotkeyCalls.isEmpty)
        #expect(clipboard.current?.textPreview == "current")
        #expect(clipboard.restoreCallCount == 0)
        #expect(payload.data.deliveryMode == "foreground")
        // Ambient clipboard content must not leak into structured output.
        #expect(payload.data.pastedTextPreview == nil)
        #expect(payload.data.previousClipboardPresent == true)
        #expect(payload.data.restoreSucceeded == true)
        #expect(payload.effect == .confirmed)
        #expect(payload.outcome?.state == .confirmedChange)
        #expect(payload.outcome?.deliveryMechanism == .globalEvents)
        #expect(payload.outcome?.deliveryMode == .foreground)
        #expect(payload.outcome?.dispatchedUnitCount == .one)
    }

    @Test
    @MainActor
    func `Exact window current clipboard paste returns canonical retry unsafe JSON`() async throws {
        let processIdentifier: Int32 = 2468
        let processStartIdentity: UInt64 = 71
        let windowID = 901
        let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)
        let application = ServiceApplicationInfo(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let window = ServiceWindowInfo(
            windowID: windowID,
            title: "Untitled",
            bounds: bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: windowID,
                ownerProcessIdentifier: processIdentifier,
                ownerProcessStartIdentity: processStartIdentity,
                capturedBounds: bounds
            )
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            unitCount: .one
        )
        automation.targetedFocusedElement = UIFocusInfo(
            role: "AXTextArea",
            title: nil,
            value: nil,
            frame: CGRect(x: 40, y: 60, width: 200, height: 100),
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            processId: Int(processIdentifier),
            windowID: windowID,
            identifier: "editor"
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("current".utf8),
            textPreview: "current"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [application]),
            windows: StubWindowService(windowsByApp: ["TextEdit": [window]]),
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--window-id", String(windowID),
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: JSONResponse.self
        )

        #expect(result.exitStatus == 1)
        #expect(automation.exactHotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(payload.outcome?.state == .dispatchedUnverified)
        #expect(payload.outcome?.deliveryMechanism == .windowTargetedEvents)
        #expect(payload.outcome?.deliveryMode == .background)
        #expect(payload.outcome?.dispatchedUnitCount == .one)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(payload.outcome?.retrySafe == false)
        #expect(payload.error?.mutation_dispatched == true)
        #expect(payload.error?.retry_safe == false)
        #expect(payload.target_receipt?.processIdentifier == processIdentifier)
        #expect(payload.target_receipt?.processStartIdentity == processStartIdentity)
        #expect(payload.target_receipt?.windowID == windowID)
    }

    @Test
    @MainActor
    func `Legacy receiptless foreground focus cannot authorize targeted paste`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 2468,
            processStartIdentity: 71,
            bundleIdentifier: "com.example.ReceiptlessFixture",
            name: "ReceiptlessFixture"
        )
        let applications = StubApplicationService(applications: [application])
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            applications: applications,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "ReceiptlessFixture",
                "--text", "legacy focus",
                "--foreground",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(applications.activateCalls == ["PID:2468"])
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.restoreCallCount == 0)
        #expect(payload.effect == .unverifiable)
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.outcome?.mutationDispatched == true)
        #expect(payload.outcome?.retrySafe == false)
    }

    @Test
    @MainActor
    func `Foreground paste composes focus and hotkey receipts without attributing the global leaf`() async throws {
        let windows = PasteFocusWindowService()
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--window-id", String(PasteFocusWindowService.windowID),
                "--text", "composed",
                "--foreground",
                "--focus-timeout", "1ms",
                "--focus-retry-count", "0",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )

        #expect(result.exitStatus == 0)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.restoreCallCount == 1)
        #expect(payload.effect == .confirmed)
        #expect(payload.outcome?.state == .confirmedChange)
        #expect(payload.outcome?.deliveryMechanism == .composite)
        #expect(payload.outcome?.deliveryMode == .foreground)
        #expect(payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(payload.target_identity == nil)
        #expect(payload.target_receipt == nil)
    }

    @Test
    @MainActor
    func `Legacy foreground paste clears setup focus target for its receiptless global leaf`() async throws {
        let windows = PasteFocusWindowService()
        let automation = StubAutomationService()
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--window-id", String(PasteFocusWindowService.windowID),
                "--text", "legacy global leaf",
                "--foreground",
                "--focus-timeout", "1ms",
                "--focus-retry-count", "0",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(
            from: result,
            as: CodableJSONResponse<PasteResult>.self
        )

        #expect(result.exitStatus == 0)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.hotkeyCalls.map(\.keys) == ["cmd,v"])
        #expect(clipboard.restoreCallCount == 1)
        #expect(payload.outcome?.state == .dispatchedUnverified)
        #expect(payload.outcome?.deliveryMechanism == .composite)
        #expect(payload.outcome?.deliveryMode == .foreground)
        #expect(payload.outcome?.dispatchedUnitCount == DesktopActionOutcome.DispatchUnitCount(2))
        #expect(payload.target_identity == nil)
        #expect(payload.target_receipt == nil)
    }

    @Test
    @MainActor
    func `Foreground paste refuses confirmed background focus before clipboard or hotkey mutation`() async throws {
        let windows = PasteFocusWindowService(
            focusOutcome: .confirmedChange(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                unitCount: .one
            )
        )
        let automation = OutcomeStubAutomationService()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            unitCount: .one
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--window-id", String(PasteFocusWindowService.windowID),
                "--text", "must not paste",
                "--foreground",
                "--focus-timeout", "1ms",
                "--focus-retry-count", "0",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let payload = try ExternalCommandRunner.decodeJSONResponse(from: result, as: JSONResponse.self)

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(clipboard.setCallCount == 0)
        #expect(clipboard.restoreCallCount == 0)
        #expect(payload.outcome?.state == .indeterminate)
        #expect(payload.target_receipt?.windowID == PasteFocusWindowService.windowID)
    }

    @Test
    @MainActor
    func `Foreground paste composes a hotkey refusal after focus`() async throws {
        let windows = PasteFocusWindowService()
        let automation = OutcomeStubAutomationService()
        automation.failHotkey(
            DesktopActionFailure.preDispatchRefusal(
                reason: .permissionDenied,
                message: "Paste hotkey permission denied"
            ),
            onCall: 1
        )
        let clipboard = StubClipboardService()
        clipboard.current = ClipboardReadResult(
            utiIdentifier: "public.utf8-plain-text",
            data: Data("prior".utf8),
            textPreview: "prior"
        )
        let services = TestServicesFactory.makePeekabooServices(
            windows: windows,
            clipboard: clipboard,
            automation: automation
        )

        let result = try await InProcessCommandRunner.run(
            [
                "paste",
                "--window-id", String(PasteFocusWindowService.windowID),
                "--text", "refused",
                "--foreground",
                "--focus-timeout", "1ms",
                "--focus-retry-count", "0",
                "--restore-delay", "0",
                "--json",
                "--no-remote",
            ],
            services: services
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let outcome = try #require(object["outcome"] as? [String: Any])
        let error = try #require(object["error"] as? [String: Any])
        let targetReceipt = try #require(object["target_receipt"] as? [String: Any])

        #expect(result.exitStatus == 1)
        #expect(windows.pinnedFocusCalls.count == 1)
        #expect(automation.outcomeHotkeyCallCount == 1)
        #expect(automation.hotkeyCalls.isEmpty)
        #expect(clipboard.current?.textPreview == "prior")
        #expect(clipboard.restoreCallCount == 1)
        #expect(object["effect"] as? String == "unverifiable")
        #expect(outcome["state"] as? String == "indeterminate")
        #expect(outcome["dispatched_unit_count"] as? Int == 1)
        #expect(outcome["mutation_dispatched"] as? Bool == true)
        #expect(outcome["retry_safe"] as? Bool == false)
        #expect(error["mutation_dispatched"] as? Bool == true)
        #expect(error["retry_safe"] as? Bool == false)
        #expect(targetReceipt["window_id"] as? Int == PasteFocusWindowService.windowID)
    }
}

@MainActor
private struct ExactBackgroundTextPasteFixture {
    static let processIdentifier: pid_t = 2468
    static let processStartIdentity: UInt64 = 71
    static let windowID = 901
    static let bounds = CGRect(x: 20, y: 30, width: 500, height: 400)

    let automation: OutcomeStubAutomationService
    let services: PeekabooServices

    init() {
        let application = ServiceApplicationInfo(
            processIdentifier: Self.processIdentifier,
            processStartIdentity: Self.processStartIdentity,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit"
        )
        let window = ServiceWindowInfo(
            windowID: Self.windowID,
            title: "Untitled",
            bounds: Self.bounds,
            mutationIdentity: WindowMutationIdentity(
                windowID: Self.windowID,
                ownerProcessIdentifier: Self.processIdentifier,
                ownerProcessStartIdentity: Self.processStartIdentity,
                capturedBounds: Self.bounds
            )
        )
        let automation = OutcomeStubAutomationService()
        automation.targetedFocusedElement = UIFocusInfo(
            role: "AXTextArea",
            title: nil,
            value: nil,
            frame: CGRect(x: 40, y: 60, width: 200, height: 100),
            applicationName: "TextEdit",
            bundleIdentifier: "com.apple.TextEdit",
            processId: Int(Self.processIdentifier),
            windowID: Self.windowID,
            identifier: "editor"
        )
        self.automation = automation
        self.services = TestServicesFactory.makePeekabooServices(
            applications: StubApplicationService(applications: [application]),
            windows: StubWindowService(windowsByApp: ["TextEdit": [window]]),
            automation: automation
        )
    }

    func run(text: String) async throws -> CommandRunResult {
        try await InProcessCommandRunner.run(
            [
                "paste",
                "--app", "TextEdit",
                "--window-id", String(Self.windowID),
                "--text", text,
                "--json",
                "--no-remote",
            ],
            services: self.services
        )
    }
}

@MainActor
private final class PasteFocusWindowService: StubWindowService, WindowManagementPinnedFocusActionResultProviding {
    static let windowID = 2_000_000_001
    static let processIdentifier: pid_t = 42
    static let processStartIdentity: UInt64 = 7
    static let bounds = CGRect(x: 40, y: 50, width: 640, height: 480)

    private(set) var pinnedFocusCalls: [(target: WindowTarget, identity: WindowMutationIdentity)] = []
    private let focusOutcome: DesktopActionOutcome

    init(focusOutcome: DesktopActionOutcome = .confirmedChange(
        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
        unitCount: .one
    )) {
        self.focusOutcome = focusOutcome
        super.init(windowsByApp: [
            "Fixture": [
                ServiceWindowInfo(
                    windowID: Self.windowID,
                    title: "Paste Fixture",
                    bounds: Self.bounds,
                    mutationIdentity: Self.identity
                ),
            ],
        ])
    }

    @MainActor
    func focusWindowActionResult(target: WindowTarget) async throws -> UIAutomationActionResult<Void> {
        try await self.focusWindowActionResult(target: target, expectedIdentity: Self.identity)
    }

    @MainActor
    func focusWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity
    ) async throws -> UIAutomationActionResult<Void> {
        self.pinnedFocusCalls.append((target, expectedIdentity))
        try await focusWindow(target: target)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: expectedIdentity,
            bounds: Self.bounds
        )
        return UIAutomationActionResult(
            payload: (),
            outcome: self.focusOutcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow)
        )
    }

    private static var identity: WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds
        )
    }
}
