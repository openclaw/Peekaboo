import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct MenuBarNamedClickFallbackTests {
    @Test
    @MainActor
    func `Non-actionable named AX extra falls back to an exact routed click`() async throws {
        let bounds = CGRect(x: 100, y: 10, width: 40, height: 20)
        let identity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 42,
            ownerProcessStartIdentity: 99,
            capturedBounds: bounds)
        let exactTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
        let fallbackResult = UIAutomationActionResult(
            payload: ClickResult(elementDescription: "Clock", location: CGPoint(x: 120, y: 20)),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: exactTarget)
        var primarySubmissions = 0
        var fallbackDispatches = 0

        let result: UIAutomationActionResult<ClickResult> = try await MenuService.withNamedMenuExtraLookupFallback {
            try MenuService.dispatchMenuExtraAccessibilityAction(
                title: "Clock",
                supportsShowMenu: false,
                supportsPress: false,
                showMenu: { primarySubmissions += 1 },
                press: { primarySubmissions += 1 })
            return fallbackResult
        } fallback: {
            fallbackDispatches += 1
            return fallbackResult
        }

        #expect(primarySubmissions == 0)
        #expect(fallbackDispatches == 1)
        #expect(result.outcome?.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(result.targetIdentity == exactTarget)
    }

    @Test
    @MainActor
    func `Indeterminate primary click never dispatches index fallback`() async throws {
        var primaryDispatches = 0
        var fallbackDispatches = 0
        let failure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "The primary click may have been dispatched")

        do {
            let _: Void = try await MenuService.withNamedMenuExtraLookupFallback {
                primaryDispatches += 1
                throw failure
            } fallback: {
                fallbackDispatches += 1
            }
            Issue.record("Expected the indeterminate failure to propagate")
        } catch let caught as DesktopActionFailure {
            #expect(caught == failure)
        }

        #expect(primaryDispatches == 1)
        #expect(fallbackDispatches == 0)
    }

    @Test
    @MainActor
    func `Pre-dispatch menu lookup failure retains index fallback`() async throws {
        var primaryDispatches = 0
        var fallbackDispatches = 0
        let primary: @MainActor () async throws -> String = {
            primaryDispatches += 1
            throw NotFoundError(
                code: .menuNotFound,
                userMessage: "Menu extra not found",
                context: [:])
        }

        let result = try await MenuService.withNamedMenuExtraLookupFallback(primary) {
            fallbackDispatches += 1
            return "fallback-result"
        }

        #expect(result == "fallback-result")
        #expect(primaryDispatches == 1)
        #expect(fallbackDispatches == 1)
    }

    @Test
    @MainActor
    func `Partial primary click never dispatches index fallback`() async throws {
        var fallbackDispatches = 0
        let failure = DesktopActionFailure.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
            unitCount: .one,
            message: "The primary click partially completed")

        do {
            let _: Void = try await MenuService.withNamedMenuExtraLookupFallback {
                throw failure
            } fallback: {
                fallbackDispatches += 1
            }
            Issue.record("Expected the partial failure to propagate")
        } catch let caught as DesktopActionFailure {
            #expect(caught == failure)
        }

        #expect(fallbackDispatches == 0)
    }

    @Test
    @MainActor
    func `Named fallback revalidates the second inventory before dispatch`() throws {
        let service = MenuService(partialMatchEnabled: false)
        try service.validateNamedFallbackTitle("Clock", requestedName: "Clock")

        do {
            try service.validateNamedFallbackTitle("Wi-Fi", requestedName: "Clock")
            Issue.record("Expected a reordered fallback item to be refused")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }
    }
}
