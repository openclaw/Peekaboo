import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct UIAutomationTargetTests {
    private let processIdentity = AutomationTestFixtures.processIdentity()
    private let bounds = CGRect(x: 10, y: 20, width: 640, height: 480)

    @Test
    func `target cases expose only their validated receipt level`() throws {
        let unpinned = try UIAutomationTarget.Process(
            processIdentifier: self.processIdentity.processIdentifier)
        let pinned = try UIAutomationTarget.Process(
            processIdentifier: self.processIdentity.processIdentifier,
            identity: self.processIdentity)
        let exact = try self.exactWindowTarget()

        #expect(UIAutomationTarget.foreground.processIdentifier == nil)
        #expect(UIAutomationTarget.foreground.processIdentity == nil)
        #expect(UIAutomationTarget.foreground.exactWindow == nil)

        #expect(UIAutomationTarget.process(unpinned).processIdentifier == self.processIdentity.processIdentifier)
        #expect(UIAutomationTarget.process(unpinned).processIdentity == nil)
        #expect(UIAutomationTarget.process(unpinned).exactWindow == nil)

        #expect(UIAutomationTarget.process(pinned).processIdentity == self.processIdentity)
        #expect(UIAutomationTarget.exactWindow(exact).processIdentity == self.processIdentity)
        #expect(UIAutomationTarget.exactWindow(exact).exactWindow == exact)
    }

    @Test
    func `process target rejects a receipt for another PID`() {
        let foreignIdentity = AutomationTestFixtures.processIdentity(
            processIdentifier: self.processIdentity.processIdentifier + 1)

        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.Process(
                processIdentifier: self.processIdentity.processIdentifier,
                identity: foreignIdentity)
        }
    }

    @Test
    func `exact window rejects mismatched embedded bounds`() {
        let identity = AutomationTestFixtures.windowIdentity(
            processIdentity: self.processIdentity,
            bounds: self.bounds)

        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: CGRect(x: 10, y: 20, width: 641, height: 480))
        }
    }

    @Test
    func `exact window rejects explicit identifiers that disagree with its receipt`() {
        let identity = AutomationTestFixtures.windowIdentity(
            processIdentity: self.processIdentity,
            bounds: self.bounds)

        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.ExactWindow(
                processIdentifier: self.processIdentity.processIdentifier + 1,
                windowID: identity.windowID,
                identity: identity,
                bounds: self.bounds)
        }
        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.ExactWindow(
                processIdentifier: self.processIdentity.processIdentifier,
                windowID: identity.windowID + 1,
                identity: identity,
                bounds: self.bounds)
        }
    }

    @Test
    func `exact window rejects focused element from another owner or window`() {
        let identity = AutomationTestFixtures.windowIdentity(
            processIdentity: self.processIdentity,
            bounds: self.bounds)
        let validFocus = self.focusedElement()

        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: self.bounds,
                focusedElement: FocusedElementIdentity(
                    processIdentifier: validFocus.processIdentifier + 1,
                    windowID: validFocus.windowID,
                    role: validFocus.role,
                    frame: validFocus.frame))
        }
        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: self.bounds,
                focusedElement: FocusedElementIdentity(
                    processIdentifier: validFocus.processIdentifier,
                    windowID: validFocus.windowID + 1,
                    role: validFocus.role,
                    frame: validFocus.frame))
        }
    }

    @Test
    func `stable receipt comparison ignores minimized state only`() {
        let base = AutomationTestFixtures.windowIdentity(
            processIdentity: self.processIdentity,
            bounds: self.bounds,
            isMinimized: false)
        let minimized = base.withMinimizedState(true)
        let changedWindow = AutomationTestFixtures.windowIdentity(
            windowID: base.windowID + 1,
            processIdentity: self.processIdentity,
            bounds: self.bounds)
        let changedProcess = AutomationTestFixtures.windowIdentity(
            processIdentity: AutomationTestFixtures.processIdentity(
                processIdentifier: self.processIdentity.processIdentifier + 1,
                processStartIdentity: self.processIdentity.processStartIdentity),
            bounds: self.bounds)
        let changedGeneration = AutomationTestFixtures.windowIdentity(
            processIdentity: AutomationTestFixtures.processIdentity(
                processIdentifier: self.processIdentity.processIdentifier,
                processStartIdentity: self.processIdentity.processStartIdentity + 1),
            bounds: self.bounds)
        let changedBounds = AutomationTestFixtures.windowIdentity(
            processIdentity: self.processIdentity,
            bounds: CGRect(x: 11, y: 20, width: 640, height: 480))

        #expect(base.processIdentity == self.processIdentity)
        #expect(base.hasSameStableReceipt(as: minimized))
        #expect(!base.hasSameStableReceipt(as: changedWindow))
        #expect(!base.hasSameStableReceipt(as: changedProcess))
        #expect(!base.hasSameStableReceipt(as: changedGeneration))
        #expect(!base.hasSameStableReceipt(as: changedBounds))
    }

    @Test
    func `target equality uses stable receipt and nested sidecars`() throws {
        let base = try self.exactWindowTarget(isMinimized: false)
        let minimized = try self.exactWindowTarget(isMinimized: true)
        let changedBounds = CGRect(x: 11, y: 20, width: 639, height: 480)
        let changedSidecar = try UIAutomationTarget.ExactWindow(
            identity: AutomationTestFixtures.windowIdentity(
                processIdentity: self.processIdentity,
                bounds: nil),
            bounds: changedBounds,
            focusedElement: self.focusedElement())
        let changedFocus = try UIAutomationTarget.ExactWindow(
            identity: AutomationTestFixtures.windowIdentity(
                processIdentity: self.processIdentity,
                bounds: self.bounds),
            bounds: self.bounds,
            focusedElement: FocusedElementIdentity(
                processIdentifier: self.processIdentity.processIdentifier,
                windowID: AutomationTestFixtures.windowIdentity().windowID,
                role: "AXTextField",
                identifier: "other-field",
                frame: CGRect(x: 30, y: 40, width: 100, height: 20)))

        #expect(UIAutomationTarget.exactWindow(base) == .exactWindow(minimized))
        #expect(UIAutomationTarget.exactWindow(base) != .exactWindow(changedSidecar))
        #expect(UIAutomationTarget.exactWindow(base) != .exactWindow(changedFocus))
        #expect(try UIAutomationTarget.exactWindow(base) != .process(
            UIAutomationTarget.Process(
                processIdentifier: self.processIdentity.processIdentifier,
                identity: self.processIdentity)))
        #expect(try UIAutomationTarget.foreground != .process(
            UIAutomationTarget.Process(processIdentifier: self.processIdentity.processIdentifier)))
    }

    @Test
    func `exact window refinement preserves an existing process generation pin`() throws {
        let pinned = try UIAutomationTarget.process(UIAutomationTarget.Process(
            processIdentifier: self.processIdentity.processIdentifier,
            identity: self.processIdentity))
        let replacementProcess = AutomationTestFixtures.processIdentity(
            processIdentifier: self.processIdentity.processIdentifier,
            processStartIdentity: self.processIdentity.processStartIdentity + 1)
        let replacement = try UIAutomationTarget.ExactWindow(
            identity: AutomationTestFixtures.windowIdentity(
                processIdentity: replacementProcess,
                bounds: self.bounds),
            bounds: self.bounds)

        #expect(throws: (any Error).self) {
            _ = try pinned.refined(to: replacement)
        }

        let unpinned = try UIAutomationTarget.process(UIAutomationTarget.Process(
            processIdentifier: self.processIdentity.processIdentifier))
        #expect(try unpinned.refined(to: replacement) == .exactWindow(replacement))
    }

    @Test
    func `background keyboard upgrades one authoritative window and refuses ambiguity`() throws {
        let process = try UIAutomationTarget.Process(
            processIdentifier: self.processIdentity.processIdentifier,
            identity: self.processIdentity)
        let first = try self.exactWindowTarget()
        let secondBounds = CGRect(x: 700, y: 20, width: 640, height: 480)
        let second = try UIAutomationTarget.ExactWindow(
            identity: AutomationTestFixtures.windowIdentity(
                windowID: first.identity.windowID + 1,
                processIdentity: self.processIdentity,
                bounds: secondBounds),
            bounds: secondBounds)

        #expect(try UIAutomationTarget.backgroundKeyboard(
            process: process,
            eligibleWindows: [first]) == .exactWindow(first))
        #expect(try UIAutomationTarget.backgroundKeyboard(
            process: process,
            eligibleWindows: []) == .process(process))
        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.backgroundKeyboard(
                process: process,
                eligibleWindows: [first, second])
        }
    }

    @Test
    func `raw background press requires explicit exact evidence`() throws {
        let process = try UIAutomationTarget.Process(
            processIdentifier: self.processIdentity.processIdentifier,
            identity: self.processIdentity)
        let exact = try self.exactWindowTarget()

        #expect(throws: (any Error).self) {
            _ = try UIAutomationTarget.backgroundKeyboard(
                process: process,
                eligibleWindows: [exact],
                requiresExplicitExactWindow: true)
        }
        #expect(try UIAutomationTarget.backgroundKeyboard(
            process: process,
            exactWindow: exact) == .exactWindow(exact))
    }

    @Test
    @MainActor
    func `exact keyboard route validator requires the window targeted background receipt`() throws {
        let expectedDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        let confirmed = DesktopActionOutcome.confirmedChange(delivery: expectedDelivery)
        let accepted = try ExactWindowKeyboardRuntime.validateRouteReceipt(
            UIAutomationActionResult(payload: 1, outcome: confirmed),
            operation: "Fixture")
        #expect(accepted.outcome == confirmed)

        #expect(throws: DesktopActionFailure.self) {
            _ = try ExactWindowKeyboardRuntime.validateRouteReceipt(
                UIAutomationActionResult<Int>(payload: 1, outcome: nil),
                operation: "Fixture")
        }
        #expect(throws: DesktopActionFailure.self) {
            _ = try ExactWindowKeyboardRuntime.validateRouteReceipt(
                UIAutomationActionResult(
                    payload: 1,
                    outcome: .confirmedChange(delivery: .init(
                        mechanism: .processTargetedEvents,
                        mode: .background))),
                operation: "Fixture")
        }

        let composite = UIAutomationActionResult(
            payload: 1,
            outcome: DesktopActionOutcome.confirmedChange(delivery: .init(
                mechanism: .composite,
                mode: .background)))
        #expect(throws: DesktopActionFailure.self) {
            _ = try ExactWindowKeyboardRuntime.validateRouteReceipt(composite, operation: "Fixture")
        }
        #expect(try ExactWindowKeyboardRuntime.validateRouteReceipt(
            composite,
            operation: "Fixture",
            allowsCompositeTypeDelivery: true).outcome == composite.outcome)

        let directClear = UIAutomationActionResult(
            payload: 1,
            outcome: DesktopActionOutcome.confirmedChange(delivery: .init(
                mechanism: .accessibilityValue,
                mode: .background)))
        #expect(try ExactWindowKeyboardRuntime.validateRouteReceipt(
            directClear,
            operation: "Fixture",
            allowsCompositeTypeDelivery: true).outcome == directClear.outcome)
    }

    @Test
    func `published automation result converts to and from the shared carrier`() {
        let outcome = DesktopActionOutcome.confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background))
        let published = UIAutomationActionResult(payload: 42, outcome: outcome)

        let shared = published.desktopActionResult
        let roundTripped = UIAutomationActionResult(shared)

        #expect(shared.payload == 42)
        #expect(shared.outcome == outcome)
        #expect(roundTripped.payload == published.payload)
        #expect(roundTripped.outcome == published.outcome)
    }

    private func exactWindowTarget(isMinimized: Bool = false) throws -> UIAutomationTarget.ExactWindow {
        try UIAutomationTarget.ExactWindow(
            identity: AutomationTestFixtures.windowIdentity(
                processIdentity: self.processIdentity,
                bounds: self.bounds,
                isMinimized: isMinimized),
            bounds: self.bounds,
            focusedElement: self.focusedElement())
    }

    private func focusedElement() -> FocusedElementIdentity {
        FocusedElementIdentity(
            processIdentifier: self.processIdentity.processIdentifier,
            windowID: AutomationTestFixtures.windowIdentity().windowID,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 30, y: 40, width: 100, height: 20))
    }
}
