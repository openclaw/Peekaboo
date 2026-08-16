import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
@Suite("Menu dispatch binding")
struct MenuDispatchBindingTests {
    @Test
    func `generation-pinned menu validation accepts the selected process generation`() throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 99,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")

        try MenuService.validateResolvedApplication(
            application,
            expectedIdentity: .init(processIdentifier: 42, processStartIdentity: 99),
            operation: "menu item click")
    }

    @Test
    func `generation-pinned menu validation refuses a replacement generation before dispatch`() {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 100,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "Fixture")

        do {
            try MenuService.validateResolvedApplication(
                application,
                expectedIdentity: .init(processIdentifier: 42, processStartIdentity: 99),
                operation: "menu item click")
            Issue.record("Expected generation mismatch refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `menu extra cancellation immediately before show menu is typed and dispatches nothing`() {
        var submissionCount = 0

        do {
            _ = try MenuService.dispatchMenuExtraAccessibilityAction(
                title: "Clock",
                supportsShowMenu: true,
                supportsPress: false,
                checkCancellation: { throw CancellationError() },
                showMenu: {
                    submissionCount += 1
                },
                press: { submissionCount += 1 })
            Issue.record("Expected typed menu-extra cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 0)
    }

    @Test
    func `menu extra cancellation immediately before press is typed and dispatches nothing`() {
        var submissionCount = 0

        do {
            _ = try MenuService.dispatchMenuExtraAccessibilityAction(
                title: "Clock",
                supportsShowMenu: false,
                supportsPress: true,
                checkCancellation: { throw CancellationError() },
                showMenu: {
                    submissionCount += 1
                },
                press: { submissionCount += 1 })
            Issue.record("Expected typed menu-extra cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 0)
    }

    @Test
    func `ambiguous show menu failure never submits press fallback`() {
        var showMenuCount = 0
        var pressCount = 0

        do {
            try MenuService.dispatchMenuExtraAccessibilityAction(
                title: "Clock",
                supportsShowMenu: true,
                supportsPress: true,
                showMenu: {
                    showMenuCount += 1
                    throw TestFailure.injected
                },
                press: { pressCount += 1 })
            Issue.record("Expected ambiguous AXShowMenu failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(showMenuCount == 1)
        #expect(pressCount == 0)
    }

    @Test
    func `menu bar route admits exact normal main-menu and status layers`() throws {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 99)
        let bounds = CGRect(x: 100, y: 10, width: 40, height: 20)
        let mutationIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 99,
            capturedBounds: bounds)
        let extra = MenuExtraInfo(
            title: "Clock",
            position: CGPoint(x: 120, y: 20),
            windowID: 700,
            ownerPID: 42)
        for key in [CGWindowLevelKey.normalWindow, .mainMenuWindow, .statusWindow] {
            let route = try MenuService.menuBarWindowRoute(
                extra: extra,
                expectedProcessIdentity: processIdentity,
                liveWindow: self.window(bounds: bounds, layer: Int(CGWindowLevelForKey(key))),
                mutationIdentity: mutationIdentity)
            #expect(route.identity == mutationIdentity)
            #expect(route.point == CGPoint(x: 120, y: 20))
        }
    }

    @Test
    func `menu bar route refuses popup hidden transparent and drifted windows`() {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 42,
            processStartIdentity: 99)
        let bounds = CGRect(x: 100, y: 10, width: 40, height: 20)
        let mutationIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 99,
            capturedBounds: bounds)
        let extra = MenuExtraInfo(
            title: "Clock",
            position: CGPoint(x: 120, y: 20),
            windowID: 700,
            windowLayer: Int(CGWindowLevelForKey(.statusWindow)),
            ownerPID: 42)
        let refusedWindows = [
            self.window(bounds: bounds, layer: Int(CGWindowLevelForKey(.popUpMenuWindow))),
            self.window(bounds: bounds, layer: Int(CGWindowLevelForKey(.statusWindow)), isOnScreen: false),
            self.window(bounds: bounds, layer: Int(CGWindowLevelForKey(.statusWindow)), alpha: 0),
            self.window(bounds: bounds.offsetBy(dx: 10, dy: 0), layer: Int(CGWindowLevelForKey(.statusWindow))),
        ]

        for window in refusedWindows {
            #expect(throws: DesktopActionFailure.self) {
                try MenuService.menuBarWindowRoute(
                    extra: extra,
                    expectedProcessIdentity: processIdentity,
                    liveWindow: window,
                    mutationIdentity: mutationIdentity)
            }
        }
    }

    private func window(
        bounds: CGRect,
        layer: Int,
        alpha: CGFloat = 1,
        isOnScreen: Bool = true) -> SystemWindowIdentity
    {
        SystemWindowIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 99,
            title: "Clock",
            bounds: bounds,
            layer: layer,
            alpha: alpha,
            isOnScreen: isOnScreen,
            sharingState: nil)
    }

    @Test
    func `menu bar cancellation is typed`() {
        do {
            try MenuService.checkMenuBarDispatchCancellation { throw CancellationError() }
            Issue.record("Expected typed menu bar cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `keyboard shortcut modifiers encode in stable order`() throws {
        let shortcut = KeyboardShortcut(
            modifiers: ["shift", "cmd", "ctrl"],
            key: "k",
            displayString: "⌃⇧⌘K")

        let data = try JSONEncoder().encode(shortcut)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["modifiers"] as? [String] == ["cmd", "ctrl", "shift"])
        #expect(try JSONDecoder().decode(KeyboardShortcut.self, from: data).modifiers == shortcut.modifiers)
    }

    @Test
    func `menu press validates immediately before one submission`() throws {
        var submittedUnitCount = 0
        var events: [String] = []

        try MenuService.dispatchMenuPress(
            submittedUnitCount: &submittedUnitCount,
            action: "click menu item",
            target: "Save",
            checkCancellation: { events.append("cancellation") },
            validateTarget: { events.append("generation") },
            submit: { events.append("press") })

        #expect(events == ["cancellation", "generation", "cancellation", "press"])
        #expect(submittedUnitCount == 1)
    }

    @Test
    func `ambiguous AXPress failure is never retried and counts the possible submission`() {
        var submittedUnitCount = 0
        var submitCount = 0

        do {
            try MenuService.dispatchMenuPress(
                submittedUnitCount: &submittedUnitCount,
                action: "click menu item",
                target: "Save",
                checkCancellation: {},
                validateTarget: {},
                submit: {
                    submitCount += 1
                    throw TestFailure.injected
                })
            Issue.record("Expected ambiguous AXPress failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submitCount == 1)
        #expect(submittedUnitCount == 0)
    }

    @Test
    func `generation-pinned menu result owner attributes ambiguous AXPress failure`() async {
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 99)
        let service = MenuService()

        do {
            try await service.withPinnedMenuFailureAttribution(processIdentity: identity) {
                var submittedUnitCount = 0
                try MenuService.dispatchMenuPress(
                    submittedUnitCount: &submittedUnitCount,
                    action: "click menu item",
                    target: "Save",
                    checkCancellation: {},
                    validateTarget: {},
                    submit: { throw TestFailure.injected })
            }
            Issue.record("Expected attributed menu AXPress failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.targetReceipt?.processIdentifier == identity.processIdentifier)
            #expect(failure.targetReceipt?.processStartIdentity == identity.processStartIdentity)
            #expect(failure.targetReceipt?.windowID == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func `generation drift after a submitted submenu returns an exact partial count`() {
        var submittedUnitCount = 1
        var submitCount = 0

        do {
            try MenuService.dispatchMenuPress(
                submittedUnitCount: &submittedUnitCount,
                action: "click menu item",
                target: "Save",
                checkCancellation: {},
                validateTarget: { throw TestFailure.injected },
                submit: { submitCount += 1 })
            Issue.record("Expected generation drift failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .partial)
            #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submitCount == 0)
        #expect(submittedUnitCount == 1)
    }

    @Test
    func `cancellation distinguishes zero dispatch from an accepted prefix`() {
        var preDispatchCount = 0
        do {
            try MenuService.dispatchMenuPress(
                submittedUnitCount: &preDispatchCount,
                action: "click menu item",
                target: "Save",
                checkCancellation: { throw CancellationError() },
                validateTarget: {},
                submit: {})
            Issue.record("Expected a typed pre-dispatch cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try MenuService.rethrowMenuCancellation(submittedUnitCount: 2, itemPath: "File > Save")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

private enum TestFailure: Error {
    case injected
}
