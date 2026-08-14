import ApplicationServices
import AXorcist
import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("Prepared dialog action receipts")
struct DialogPreparedActionStoreTests {
    @Test
    func `selector preserves owner and window constraints and rejects conflicts`() throws {
        let selector = try DialogTargetSelector(
            processIdentifier: 42,
            windowID: 700)
        #expect(selector.processIdentifier == 42)
        #expect(selector.windowID == 700)

        #expect(throws: (any Error).self) {
            try DialogTargetSelector(
                applicationIdentifier: "TextEdit",
                processIdentifier: 42)
        }
        #expect(throws: (any Error).self) {
            try DialogTargetSelector(windowTitle: "Save")
        }
        #expect(throws: (any Error).self) {
            try DialogTargetSelector(processIdentifier: 42, windowID: 700, windowIndex: 0)
        }
    }

    @Test
    func `prepared receipt round trips one canonical exact window target`() throws {
        let receipt = try self.receipt()
        let data = try JSONEncoder().encode(receipt)
        let decoded = try JSONDecoder().decode(PreparedDialogActionReceipt.self, from: data)
        #expect(decoded == receipt)
        #expect(decoded.target.identity.windowID == 700)
        #expect(decoded.target.identity.ownerProcessIdentifier == 42)
        #expect(decoded.target.bounds == CGRect(x: 10, y: 20, width: 300, height: 200))
    }

    @Test
    func `prepared receipt is one shot`() throws {
        let receipt = try self.receipt()
        let store = DialogPreparedActionStore()
        try store.insert(self.entry(receipt: receipt))

        _ = try store.consume(receipt)
        do {
            _ = try store.consume(receipt)
            Issue.record("Expected receipt replay refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    func `expired receipt refuses before dispatch`() throws {
        var now = Date(timeIntervalSinceReferenceDate: 100)
        let store = DialogPreparedActionStore(timeToLive: 1, now: { now })
        let receipt = try self.receipt()
        try store.insert(self.entry(receipt: receipt, createdAt: now))
        now.addTimeInterval(2)

        #expect(throws: DesktopActionFailure.self) {
            _ = try store.consume(receipt)
        }
    }

    @Test
    func `prepared result refuses missing unverified and contradictory outcomes`() throws {
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background)
        let missing = DialogActionResult(success: true, action: .clickButton)
        #expect(throws: DesktopActionFailure.self) {
            _ = try missing.requiredPreparedOutcome(kind: .clickButton)
        }

        let unverified = DialogActionResult(
            success: false,
            action: .clickButton,
            outcome: .dispatchedUnverified(
                delivery: delivery,
                evidence: .deliveryAccepted,
                unitCount: .one))
        do {
            _ = try unverified.requiredPreparedOutcome(kind: .clickButton)
            Issue.record("Expected unverified result to remain a typed failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.retrySafety == .unsafe)
        }

        let wrongAction = DialogActionResult(
            success: true,
            action: .dismiss,
            outcome: .confirmedChange(delivery: delivery, unitCount: .one))
        #expect(throws: DesktopActionFailure.self) {
            _ = try wrongAction.requiredPreparedOutcome(kind: .clickButton)
        }
    }

    @Test
    func `raw accessibility identity distinguishes identical looking replacements`() {
        let retained = Element.systemWide()
        let same = retained
        let replacement = Element(AXUIElementCreateApplication(getpid()))

        #expect(DialogService.sameElement(retained, same))
        #expect(!DialogService.sameElement(retained, replacement))
    }

    @Test
    func `unreadable enabled state is not eligible for prepared AXPress`() {
        #expect(!DialogService.isEligiblePreparedButton(Element.systemWide()))
    }

    @Test
    func `window server absence is distinct from unreadable evidence`() throws {
        let identity = try self.receipt().target.identity
        #expect(DialogService.windowServerPresence(identity, windows: nil) == .unreadable)
        #expect(DialogService.windowServerPresence(identity, windows: []) == .absent)
        #expect(DialogService.windowServerPresence(identity, windows: [[
            kCGWindowNumber as String: NSNumber(value: identity.windowID),
        ]]) == .unreadable)
        #expect(DialogService.windowServerPresence(identity, windows: [[
            kCGWindowNumber as String: NSNumber(value: identity.windowID),
            kCGWindowOwnerPID as String: NSNumber(value: identity.ownerProcessIdentifier),
        ]]) == .present)
    }

    @Test
    func `dialog postcondition presence preserves suspected noop and unreadable semantics`() {
        let fallback = DesktopActionOutcome.dispatchedUnverified(
            delivery: DialogService.backgroundDialogDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(DialogService.postconditionFailure(presence: .absent, fallbackOutcome: fallback) == nil)

        let present = DialogService.postconditionFailure(presence: .present, fallbackOutcome: fallback)
        #expect(present?.outcome.state == .suspectedNoop)
        #expect(present?.outcome.retrySafety == .safe)
        #expect(present?.outcome.evidence == .observedNoChange)

        let unreadable = DialogService.postconditionFailure(presence: .unreadable, fallbackOutcome: fallback)
        #expect(unreadable?.outcome == fallback)
        #expect(unreadable?.outcome.retrySafety == .unsafe)
    }

    @Test
    func `legacy dialog service defaults return canonical runtime refusals`() async throws {
        let request = try DialogActionPreparationRequest(
            target: DialogTargetSelector(processIdentifier: 42),
            kind: .clickButton,
            buttonText: "OK")
        do {
            _ = try await LegacyDialogService().prepareDialogAction(request)
            Issue.record("Expected a runtime compatibility refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    private func receipt() throws -> PreparedDialogActionReceipt {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 1234,
            capturedBounds: bounds)
        return try PreparedDialogActionReceipt(
            token: UUID(),
            kind: .clickButton,
            target: UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds))
    }

    private func entry(
        receipt: PreparedDialogActionReceipt,
        createdAt: Date = Date()) throws -> DialogPreparedActionStore.Entry
    {
        let request = try DialogActionPreparationRequest(
            target: DialogTargetSelector(processIdentifier: 42, windowID: 700),
            kind: .clickButton,
            buttonText: "OK")
        let element = Element.systemWide()
        return DialogPreparedActionStore.Entry(
            receipt: receipt,
            request: request,
            window: element,
            dialog: element,
            button: element,
            resolvedButtonTitle: "OK",
            resolvedButtonIdentifier: "OKButton",
            createdAt: createdAt)
    }
}

@MainActor
private struct LegacyDialogService: DialogServiceProtocol {
    func findActiveDialog(windowTitle _: String?, appName _: String?) async throws -> DialogInfo {
        throw DialogError.noActiveDialog
    }

    func clickButton(buttonText _: String, windowTitle _: String?, appName _: String?) async throws
        -> DialogActionResult
    {
        throw DialogError.noActiveDialog
    }

    func enterText(
        text _: String,
        fieldIdentifier _: String?,
        clearExisting _: Bool,
        windowTitle _: String?,
        appName _: String?) async throws -> DialogActionResult
    {
        throw DialogError.noActiveDialog
    }

    func handleFileDialog(
        path _: String?,
        filename _: String?,
        actionButton _: String?,
        ensureExpanded _: Bool,
        appName _: String?) async throws -> DialogActionResult
    {
        throw DialogError.noActiveDialog
    }

    func dismissDialog(force _: Bool, windowTitle _: String?, appName _: String?) async throws -> DialogActionResult {
        throw DialogError.noActiveDialog
    }

    func listDialogElements(windowTitle _: String?, appName _: String?) async throws -> DialogElements {
        throw DialogError.noActiveDialog
    }
}
