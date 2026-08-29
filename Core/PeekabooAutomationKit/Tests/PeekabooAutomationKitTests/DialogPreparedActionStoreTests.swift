import ApplicationServices
import AXorcist
import CoreGraphics
import Darwin
import Foundation
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("Prepared dialog action receipts")
struct DialogPreparedActionStoreTests {
    @Test(arguments: InteractionTargetSelectorFixtures.validCases)
    func `dialog adapter accepts the canonical valid selector matrix`(
        _ selectors: InteractionTargetSelectorCase) throws
    {
        _ = try Self.selector(selectors)
    }

    @Test(arguments: InteractionTargetSelectorFixtures.applicationAndProcessIdentifierCases)
    func `dialog adapter refuses canonical app and PID conflicts`(
        _ selectors: InteractionTargetSelectorCase)
    {
        #expect(throws: (any Error).self) {
            _ = try Self.selector(selectors)
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.multipleWindowSelectorCases)
    func `dialog adapter refuses the canonical multiple-window matrix`(
        _ selectors: InteractionTargetSelectorCase)
    {
        #expect(throws: (any Error).self) {
            _ = try Self.selector(selectors)
        }
    }

    @Test(arguments: InteractionTargetSelectorFixtures.windowSelectorRequiresApplicationCases)
    func `dialog adapter refuses ownerless relative-window syntax`(
        _ selectors: InteractionTargetSelectorCase)
    {
        #expect(throws: (any Error).self) {
            _ = try Self.selector(selectors)
        }
    }

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
    func `selector manual coding preserves existing keys and normalized values`() throws {
        let selector = try DialogTargetSelector(
            applicationIdentifier: "  TextEdit  ",
            windowTitle: "  Save  ")
        let data = try JSONEncoder().encode(selector)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["applicationIdentifier", "windowTitle"])
        #expect(object["applicationIdentifier"] as? String == "TextEdit")
        #expect(object["windowTitle"] as? String == "Save")
        #expect(try JSONDecoder().decode(DialogTargetSelector.self, from: data) == selector)
    }

    private static func selector(_ selectors: InteractionTargetSelectorCase) throws -> DialogTargetSelector {
        try DialogTargetSelector(
            applicationIdentifier: selectors.hasApplication ? "TextEdit" : nil,
            processIdentifier: selectors.hasProcessIdentifier ? 42 : nil,
            windowID: selectors.hasWindowID ? 700 : nil,
            windowTitle: selectors.hasWindowTitle ? "Save" : nil,
            windowIndex: selectors.hasWindowIndex ? 2 : nil)
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

        let refusal = DesktopActionOutcome.refused(reason: .targetUnavailable)
        for (kind, action) in [
            (DialogPreparedActionKind.clickButton, DialogActionType.clickButton),
            (.dismiss, .dismiss),
        ] {
            let refused = DialogActionResult(
                success: false,
                action: action,
                outcome: refusal)
            do {
                _ = try refused.requiredPreparedOutcome(kind: kind)
                Issue.record("Expected prepared \(kind.rawValue) target refusal to remain a typed failure")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome == refusal)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.retrySafety == .safe)
            }
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
    func `window server presence falls back to the full catalog`() throws {
        let identity = try self.receipt().target.identity
        var queries: [(CGWindowListOption, CGWindowID)] = []
        let presence = DialogService.windowServerPresence(
            identity,
            windowListProvider: { options, relativeToWindow in
                queries.append((options, relativeToWindow))
                if options.contains(.optionIncludingWindow) {
                    return []
                }
                return [Self.windowDictionary(identity: identity)]
            })

        #expect(presence == .present)
        #expect(queries.count == 2)
        #expect(queries[0].0 == [.optionIncludingWindow])
        #expect(queries[0].1 == CGWindowID(identity.windowID))
        #expect(queries[1].0 == [.optionAll, .excludeDesktopElements])
        #expect(queries[1].1 == kCGNullWindowID)
    }

    @Test
    func `window server absence requires successful misses from both catalogs`() throws {
        let identity = try self.receipt().target.identity
        var queryCount = 0
        let presence = DialogService.windowServerPresence(identity, windowListProvider: { _, _ in
            queryCount += 1
            return []
        })

        #expect(presence == .absent)
        #expect(queryCount == 2)
    }

    @Test
    func `window server failed full catalog fallback remains unreadable`() throws {
        let identity = try self.receipt().target.identity
        var queryCount = 0
        let presence = DialogService.windowServerPresence(identity, windowListProvider: { options, _ in
            queryCount += 1
            return options.contains(.optionIncludingWindow) ? [] : nil
        })

        #expect(presence == .unreadable)
        #expect(queryCount == 2)
    }

    @Test
    func `window server exact ID with the wrong owner is absent`() throws {
        let identity = try self.receipt().target.identity
        let presence = DialogService.windowServerPresence(identity, windowListProvider: { options, _ in
            if options.contains(.optionIncludingWindow) {
                return []
            }
            return [Self.windowDictionary(
                identity: identity,
                ownerProcessIdentifier: identity.ownerProcessIdentifier + 1)]
        })

        #expect(presence == .absent)
    }

    @Test
    func `window server exact row without owner evidence is unreadable`() throws {
        let identity = try self.receipt().target.identity
        let presence = DialogService.windowServerPresence(identity, windowListProvider: { _, _ in
            [[kCGWindowNumber as String: NSNumber(value: identity.windowID)]]
        })

        #expect(presence == .unreadable)
    }

    @Test
    func `dialog postcondition presence remains dispatched and retry unsafe`() {
        let fallback = DesktopActionOutcome.dispatchedUnverified(
            delivery: DialogService.backgroundDialogDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)

        #expect(DialogService.postconditionFailure(presence: .absent, fallbackOutcome: fallback) == nil)

        let present = DialogService.postconditionFailure(presence: .present, fallbackOutcome: fallback)
        #expect(present?.outcome == fallback)
        #expect(present?.outcome.retrySafety == .unsafe)

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

        let input = try DialogInputExecutionRequest(
            target: DialogTargetSelector(processIdentifier: 42),
            text: "hello")
        do {
            _ = try await LegacyDialogService().enterText(input)
            Issue.record("Expected exact input to refuse on a legacy provider")
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

    private static func windowDictionary(
        identity: WindowMutationIdentity,
        ownerProcessIdentifier: pid_t? = nil) -> [String: Any]
    {
        [
            kCGWindowNumber as String: NSNumber(value: identity.windowID),
            kCGWindowOwnerPID as String: NSNumber(
                value: ownerProcessIdentifier ?? identity.ownerProcessIdentifier),
        ]
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
