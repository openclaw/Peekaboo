import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

struct WindowManagementServiceProtocolTests {
    @Test
    func `additive carrier preserves canonical outcomes and legacy nil without changing witnesses`() async throws {
        let service = OutcomeWindowManagementService()
        let identity = AutomationTestFixtures.windowIdentity()
        let target = WindowTarget.windowId(identity.windowID)
        let outcomes = DesktopActionOutcomeFixtures.canonicalOutcomes.map(Optional.some) + [nil]

        for (index, outcome) in outcomes.enumerated() {
            await service.setOutcome(outcome)
            let carried = switch index % 7 {
            case 0:
                try await service.closeWindowWithOutcome(target: target, expectedIdentity: identity)
            case 1:
                try await service.minimizeWindowWithOutcome(target: target, expectedIdentity: identity)
            case 2:
                try await service.restoreWindowWithOutcome(target: target, expectedIdentity: identity)
            case 3:
                try await service.maximizeWindowWithOutcome(target: target, expectedIdentity: identity)
            case 4:
                try await service.moveWindowWithOutcome(target: target, expectedIdentity: identity, to: .zero)
            case 5:
                try await service.resizeWindowWithOutcome(target: target, expectedIdentity: identity, to: .zero)
            default:
                try await service.setWindowBoundsWithOutcome(
                    target: target,
                    expectedIdentity: identity,
                    bounds: .zero)
            }
            #expect(carried == outcome)
        }

        let legacy: any WindowManagementServiceProtocol = LegacyOnlyWindowManagementService()
        #expect((legacy as? any WindowManagementActionOutcomeProviding) == nil)
    }

    @Test
    func `window refusal classification preserves permission target request and runtime causes`() {
        #expect(WindowManagementActionOutcome.refusalReason(
            for: PeekabooError.permissionDeniedAccessibility) == .permissionDenied)
        #expect(WindowManagementActionOutcome.refusalReason(
            for: PeekabooError.windowNotFound(criteria: "fixture")) == .targetUnavailable)
        #expect(WindowManagementActionOutcome.refusalReason(
            for: PeekabooError.invalidInput("fixture")) == .invalidRequest)
        #expect(WindowManagementActionOutcome.refusalReason(
            for: PeekabooError.serviceUnavailable("fixture")) == .runtimeIncompatible)
        #expect(WindowManagementActionOutcome.refusalReason(
            for: PeekabooError.operationError(message: "fixture")) == .operationUnsupported)
    }

    @Test
    func `post AX verification failure reports accepted delivery without claiming work is still running`() {
        let failure = WindowManagementActionOutcome.dispatchedUnverified(
            action: "move window",
            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
            dispatchCount: 1,
            cause: PeekabooError.timeout("fixture"))

        #expect(failure.outcome.state == .dispatchedUnverified)
        #expect(failure.outcome.evidence == .deliveryAccepted)
        #expect(failure.outcome.delivery == .init(mechanism: .accessibilityValue, mode: .background))
    }

    @Test(arguments: [
        (positionAccepted: false, sizeAccepted: false, expectedCount: 0),
        (positionAccepted: true, sizeAccepted: false, expectedCount: 1),
        (positionAccepted: false, sizeAccepted: true, expectedCount: 1),
        (positionAccepted: true, sizeAccepted: true, expectedCount: 2),
    ])
    func `geometry dispatch counts zero partial and complete AX acceptance`(
        positionAccepted: Bool,
        sizeAccepted: Bool,
        expectedCount: Int)
    {
        let acceptance = WindowGeometryDispatchAcceptance(
            positionAccepted: positionAccepted,
            sizeAccepted: sizeAccepted)

        #expect(acceptance.dispatchCount == expectedCount)
    }

    @Test
    func `identity defaults fail closed without dispatching legacy numeric overloads`() async {
        let double = LegacyOnlyWindowManagementService()
        let service: any WindowManagementServiceProtocol = double
        let identity = WindowMutationIdentity(
            windowID: 77,
            ownerProcessIdentifier: 420,
            ownerProcessStartIdentity: 9001)
        let operations: [@Sendable () async throws -> Void] = [
            { try await service.closeWindow(
                target: .windowId(77),
                expectedIdentity: identity,
                allowForegroundFallback: false) },
            { try await service.minimizeWindow(target: .windowId(77), expectedIdentity: identity) },
            { try await service.restoreWindow(target: .windowId(77), expectedIdentity: identity) },
            { try await service.maximizeWindow(target: .windowId(77), expectedIdentity: identity) },
            { try await service.moveWindow(target: .windowId(77), expectedIdentity: identity, to: .zero) },
            { try await service.resizeWindow(target: .windowId(77), expectedIdentity: identity, to: .zero) },
            { try await service.setWindowBounds(target: .windowId(77), expectedIdentity: identity, bounds: .zero) },
        ]

        for operation in operations {
            do {
                try await operation()
                Issue.record("Expected an identity-unaware service to reject the pinned mutation")
            } catch let PeekabooError.serviceUnavailable(message) {
                #expect(message.contains("process-generation-pinned"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        #expect(await double.legacyDispatchCount == 0)
    }
}

private actor OutcomeWindowManagementService: WindowManagementActionOutcomeProviding {
    private var outcome: DesktopActionOutcome?

    func setOutcome(_ outcome: DesktopActionOutcome?) {
        self.outcome = outcome
    }

    func closeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func minimizeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func restoreWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func maximizeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func moveWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func resizeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func setWindowBoundsWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws -> DesktopActionOutcome?
    {
        self.outcome
    }

    func closeWindow(target _: WindowTarget) async throws {}
    func minimizeWindow(target _: WindowTarget) async throws {}
    func maximizeWindow(target _: WindowTarget) async throws {}
    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}
    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}
    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}
    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}

private actor LegacyOnlyWindowManagementService: WindowManagementServiceProtocol {
    private(set) var legacyDispatchCount = 0

    func closeWindow(target _: WindowTarget) async throws {
        self.legacyDispatchCount += 1
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        self.legacyDispatchCount += 1
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        self.legacyDispatchCount += 1
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        self.legacyDispatchCount += 1
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        self.legacyDispatchCount += 1
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        self.legacyDispatchCount += 1
    }

    func focusWindow(target _: WindowTarget) async throws {}

    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
