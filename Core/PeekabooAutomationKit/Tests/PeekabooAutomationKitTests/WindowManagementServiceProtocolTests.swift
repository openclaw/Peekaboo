import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

struct WindowManagementServiceProtocolTests {
    @Test
    func `result adapters prefer explicit carrier witnesses over outcome and legacy tiers`() async throws {
        let provider = WindowActionResultProbe()
        let service: any WindowManagementServiceProtocol = provider
        let outcomes = try await self.invokeResultAdapters(on: service)

        #expect(outcomes == Array(repeating: provider.resultOutcome, count: WindowAdapterOperation.allCases.count))
        #expect(await provider.actionCalls == WindowAdapterOperation.allCases)
        #expect(await provider.outcomeCalls.isEmpty)
        #expect(await provider.legacyCalls.isEmpty)
    }

    @Test
    func `result adapters use legacy pinned requirements only as the final fallback`() async throws {
        let legacy = PinnedLegacyWindowManagementService()
        let service: any WindowManagementServiceProtocol = legacy
        let outcomes = try await self.invokeResultAdapters(on: service)

        #expect(outcomes == Array(repeating: nil, count: WindowAdapterOperation.allCases.count))
        #expect(await legacy.pinnedCalls == WindowAdapterOperation.allCases)
        #expect((service as? any WindowManagementActionOutcomeProviding) == nil)
        #expect((service as? any WindowManagementActionResultProviding) == nil)
    }

    @Test
    func `additive carrier adapts the published outcome provider without changing its witnesses`() async throws {
        let service = OutcomeWindowManagementService()
        let resultService: any WindowManagementServiceProtocol = service
        let identity = AutomationTestFixtures.windowIdentity()
        let target = WindowTarget.windowId(identity.windowID)
        let outcomes = DesktopActionOutcomeFixtures.canonicalOutcomes.map(Optional.some) + [nil]

        for (index, outcome) in outcomes.enumerated() {
            await service.setOutcome(outcome)
            let compatibilityOutcome: DesktopActionOutcome? = switch index % 7 {
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
            #expect(compatibilityOutcome == outcome)

            let carried = switch index % 7 {
            case 0:
                try await resultService.closeWindowResult(
                    target: target,
                    expectedIdentity: identity,
                    allowForegroundFallback: false)
            case 1:
                try await resultService.minimizeWindowResult(target: target, expectedIdentity: identity)
            case 2:
                try await resultService.restoreWindowResult(target: target, expectedIdentity: identity)
            case 3:
                try await resultService.maximizeWindowResult(target: target, expectedIdentity: identity)
            case 4:
                try await resultService.moveWindowResult(target: target, expectedIdentity: identity, to: .zero)
            case 5:
                try await resultService.resizeWindowResult(target: target, expectedIdentity: identity, to: .zero)
            default:
                try await resultService.setWindowBoundsResult(
                    target: target,
                    expectedIdentity: identity,
                    bounds: .zero)
            }
            #expect(carried.outcome == outcome)
        }

        let legacy: any WindowManagementServiceProtocol = LegacyOnlyWindowManagementService()
        #expect((legacy as? any WindowManagementActionOutcomeProviding) == nil)
        #expect((legacy as? any WindowManagementActionResultProviding) == nil)
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

    private func invokeResultAdapters(
        on service: any WindowManagementServiceProtocol) async throws -> [DesktopActionOutcome?]
    {
        let identity = AutomationTestFixtures.windowIdentity()
        let target = WindowTarget.windowId(identity.windowID)
        let close = try await service.closeWindowResult(
            target: target,
            expectedIdentity: identity,
            allowForegroundFallback: false)
        let minimize = try await service.minimizeWindowResult(target: target, expectedIdentity: identity)
        let restore = try await service.restoreWindowResult(target: target, expectedIdentity: identity)
        let maximize = try await service.maximizeWindowResult(target: target, expectedIdentity: identity)
        let move = try await service.moveWindowResult(target: target, expectedIdentity: identity, to: .zero)
        let resize = try await service.resizeWindowResult(target: target, expectedIdentity: identity, to: .zero)
        let setBounds = try await service.setWindowBoundsResult(
            target: target,
            expectedIdentity: identity,
            bounds: .zero)
        return [
            close.outcome,
            minimize.outcome,
            restore.outcome,
            maximize.outcome,
            move.outcome,
            resize.outcome,
            setBounds.outcome,
        ]
    }
}

private enum WindowAdapterOperation: CaseIterable, Sendable {
    case close
    case minimize
    case restore
    case maximize
    case move
    case resize
    case setBounds
}

private actor WindowActionResultProbe: WindowManagementActionResultProviding,
    WindowManagementActionOutcomeProviding
{
    nonisolated let resultOutcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .accessibilityValue, mode: .background),
        unitCount: .one)
    private(set) var actionCalls: [WindowAdapterOperation] = []
    private(set) var outcomeCalls: [WindowAdapterOperation] = []
    private(set) var legacyCalls: [WindowAdapterOperation] = []

    func closeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.close)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func minimizeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.minimize)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func restoreWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.restore)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func maximizeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.maximize)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func moveWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.move)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func resizeWindowActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.resize)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func setWindowBoundsActionResult(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws -> DesktopActionResult<Void>
    {
        self.actionCalls.append(.setBounds)
        return DesktopActionResult(outcome: self.resultOutcome)
    }

    func closeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.close)
        return .confirmedNoChange()
    }

    func minimizeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.minimize)
        return .confirmedNoChange()
    }

    func restoreWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.restore)
        return .confirmedNoChange()
    }

    func maximizeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.maximize)
        return .confirmedNoChange()
    }

    func moveWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.move)
        return .confirmedNoChange()
    }

    func resizeWindowWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.resize)
        return .confirmedNoChange()
    }

    func setWindowBoundsWithOutcome(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws -> DesktopActionOutcome?
    {
        self.outcomeCalls.append(.setBounds)
        return .confirmedNoChange()
    }

    func closeWindow(target _: WindowTarget) async throws {
        self.legacyCalls.append(.close)
    }

    func minimizeWindow(target _: WindowTarget) async throws {
        self.legacyCalls.append(.minimize)
    }

    func maximizeWindow(target _: WindowTarget) async throws {
        self.legacyCalls.append(.maximize)
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {
        self.legacyCalls.append(.move)
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {
        self.legacyCalls.append(.resize)
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {
        self.legacyCalls.append(.setBounds)
    }

    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
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

private actor PinnedLegacyWindowManagementService: WindowManagementServiceProtocol {
    private(set) var pinnedCalls: [WindowAdapterOperation] = []

    func closeWindow(target _: WindowTarget) async throws {}

    func closeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        allowForegroundFallback _: Bool) async throws
    {
        self.pinnedCalls.append(.close)
    }

    func minimizeWindow(target _: WindowTarget) async throws {}

    func minimizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        self.pinnedCalls.append(.minimize)
    }

    func restoreWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        self.pinnedCalls.append(.restore)
    }

    func maximizeWindow(target _: WindowTarget) async throws {}

    func maximizeWindow(target _: WindowTarget, expectedIdentity _: WindowMutationIdentity) async throws {
        self.pinnedCalls.append(.maximize)
    }

    func moveWindow(target _: WindowTarget, to _: CGPoint) async throws {}

    func moveWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGPoint) async throws
    {
        self.pinnedCalls.append(.move)
    }

    func resizeWindow(target _: WindowTarget, to _: CGSize) async throws {}

    func resizeWindow(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        to _: CGSize) async throws
    {
        self.pinnedCalls.append(.resize)
    }

    func setWindowBounds(target _: WindowTarget, bounds _: CGRect) async throws {}

    func setWindowBounds(
        target _: WindowTarget,
        expectedIdentity _: WindowMutationIdentity,
        bounds _: CGRect) async throws
    {
        self.pinnedCalls.append(.setBounds)
    }

    func focusWindow(target _: WindowTarget) async throws {}
    func listWindows(target _: WindowTarget) async throws -> [ServiceWindowInfo] {
        []
    }

    func getFocusedWindow() async throws -> ServiceWindowInfo? {
        nil
    }
}
