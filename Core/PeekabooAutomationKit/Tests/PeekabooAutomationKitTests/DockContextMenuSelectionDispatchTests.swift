import CoreGraphics
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct DockContextMenuSelectionDispatchTests {
    @Test
    @MainActor
    func `Dock cancellation before first submission is typed and retry safe`() {
        do {
            try DockService.checkDockDispatchCancellation { throw CancellationError() }
            Issue.record("Expected typed Dock cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private enum FixtureError: Error {
        case generationDrift
        case lookupFailed
        case pressFailed
    }

    @Test
    @MainActor
    func `Generation drift before the first dispatch submits nothing`() throws {
        let captured = Self.processIdentity(generation: 11)
        var current = Self.processIdentity(generation: 12)
        var submissionCount = 0

        #expect(throws: FixtureError.generationDrift) {
            try DockService.dispatchBoundToDockGeneration(
                captured,
                validate: { expected in
                    guard expected == current else { throw FixtureError.generationDrift }
                },
                submit: {
                    submissionCount += 1
                })
        }

        #expect(submissionCount == 0)
        current = captured
        try DockService.dispatchBoundToDockGeneration(
            captured,
            validate: { expected in
                guard expected == current else { throw FixtureError.generationDrift }
            },
            submit: {
                submissionCount += 1
            })
        #expect(submissionCount == 1)
    }

    @Test
    @MainActor
    func `cancellation after final Dock generation validation submits nothing`() {
        let identity = Self.processIdentity(generation: 12)
        var validationCount = 0
        var submissionCount = 0

        do {
            try DockService.dispatchBoundToDockGeneration(
                identity,
                validate: { _ in validationCount += 1 },
                checkCancellation: { throw CancellationError() },
                submit: { submissionCount += 1 })
            Issue.record("Expected typed final Dock cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(validationCount == 1)
        #expect(submissionCount == 0)
    }

    @Test
    @MainActor
    func `Dock launch AXPress error is one-unit foreground indeterminate`() {
        let identity = Self.processIdentity(generation: 12)
        var submissionCount = 0

        do {
            try DockService.dispatchDockLaunchPress(
                identity,
                appName: "Safari",
                validate: { _ in },
                submit: {
                    submissionCount += 1
                    throw FixtureError.pressFailed
                })
            Issue.record("Expected ambiguous Dock launch AXPress failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(
                mechanism: .accessibilityAction,
                mode: .foreground))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 1)
    }

    @Test
    @MainActor
    func `Dock launch result owner attributes ambiguous AXPress failure`() async {
        let identity = Self.processIdentity(generation: 12)

        do {
            try await DockService.withDockFailureAttribution(processIdentity: identity) {
                try DockService.dispatchDockLaunchPress(
                    identity,
                    appName: "Safari",
                    validate: { _ in },
                    submit: { throw FixtureError.pressFailed })
            }
            Issue.record("Expected attributed Dock launch failure")
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
    @MainActor
    func `Dock launch preserves typed generation refusal before AXPress`() {
        let identity = Self.processIdentity(generation: 12)
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Dock generation changed")
        var submissionCount = 0

        do {
            try DockService.dispatchDockLaunchPress(
                identity,
                appName: "Safari",
                validate: { _ in throw refusal },
                submit: { submissionCount += 1 })
            Issue.record("Expected typed Dock generation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure == refusal)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 0)
    }

    @Test
    func `Dock action result distinguishes right-click from menu selection delivery`() {
        let rightClick = DockContextMenuActionSemantics.successfulOutcome(selectingMenuItem: false)
        #expect(rightClick.delivery == DockContextMenuActionSemantics.rightClickDelivery)
        #expect(rightClick.dispatchState == .dispatched(unitCount: .one))

        let selection = DockContextMenuActionSemantics.successfulOutcome(selectingMenuItem: true)
        #expect(selection.delivery == DockContextMenuActionSemantics.selectionDelivery)
        #expect(selection.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(selection.dispatchState == .dispatched(
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
    }

    @Test
    @MainActor
    func `Dock right-click submission error is one-unit foreground indeterminate`() {
        let identity = Self.processIdentity(generation: 12)
        var submissionCount = 0

        do {
            try DockService.dispatchDockRightClick(
                identity,
                appName: "Safari",
                validate: { _ in },
                submit: {
                    submissionCount += 1
                    throw FixtureError.pressFailed
                })
            Issue.record("Expected ambiguous Dock right-click failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == DockContextMenuActionSemantics.rightClickDelivery)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: .one))
            #expect(failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 1)
    }

    @Test
    @MainActor
    func `Dock right-click preserves typed refusal before submission`() {
        let identity = Self.processIdentity(generation: 12)
        let refusal = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Dock generation changed")
        var submissionCount = 0

        do {
            try DockService.dispatchDockRightClick(
                identity,
                appName: "Safari",
                validate: { _ in throw refusal },
                submit: { submissionCount += 1 })
            Issue.record("Expected typed Dock generation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure == refusal)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(submissionCount == 0)
    }

    @Test
    @MainActor
    func `Right-click uses geometry refreshed after feedback`() throws {
        let identity = Self.processIdentity(generation: 12)
        let staleCenter = CGPoint(x: 15, y: 15)
        let refreshedCenter = try DockService.refreshedDockItemCenter(
            expectedIdentity: identity,
            resolvedIdentity: identity,
            position: CGPoint(x: 40, y: 60),
            size: CGSize(width: 20, height: 40),
            appName: "Safari")

        #expect(refreshedCenter == CGPoint(x: 50, y: 80))
        #expect(refreshedCenter != staleCenter)

        #expect(throws: DesktopActionFailure.self) {
            try DockService.refreshedDockItemCenter(
                expectedIdentity: identity,
                resolvedIdentity: Self.processIdentity(generation: 13),
                position: CGPoint(x: 40, y: 60),
                size: CGSize(width: 20, height: 40),
                appName: "Safari")
        }
    }

    @Test
    @MainActor
    func `Lookup failure reports only the known right-click dispatch`() async throws {
        var submissionCount = 0

        do {
            try await DockService.dispatchContextMenuSelection(
                targetMenuItem: "Options",
                prepare: { () async throws -> Int in
                    throw FixtureError.lookupFailed
                },
                submit: { _ in
                    submissionCount += 1
                })
            Issue.record("Expected lookup failure")
        } catch let failure as DesktopActionFailure {
            Self.expectKnownRightClickOnly(failure)
        }

        #expect(submissionCount == 0)
    }

    @Test
    @MainActor
    func `Cancellation before AXPress reports only the known right-click dispatch`() async throws {
        var submissionCount = 0
        let task = Task { @MainActor in
            try await DockService.dispatchContextMenuSelection(
                targetMenuItem: "Options",
                prepare: {
                    withUnsafeCurrentTask { task in
                        task?.cancel()
                    }
                    return 7
                },
                submit: { _ in
                    submissionCount += 1
                })
        }

        do {
            _ = try await task.value
            Issue.record("Expected cancellation to be classified after the known right-click")
        } catch let failure as DesktopActionFailure {
            Self.expectKnownRightClickOnly(failure)
        }

        #expect(submissionCount == 0)
    }

    @Test
    @MainActor
    func `Generation drift between right-click and AXPress reports only the first dispatch`() async throws {
        let captured = Self.processIdentity(generation: 21)
        var current = captured
        var rightClickCount = 0
        var selectionCount = 0

        try DockService.dispatchBoundToDockGeneration(
            captured,
            validate: { expected in
                guard expected == current else { throw FixtureError.generationDrift }
            },
            submit: {
                rightClickCount += 1
                current = Self.processIdentity(generation: 22)
            })

        do {
            try await DockService.dispatchContextMenuSelection(
                targetMenuItem: "Options",
                prepare: { 7 },
                validateBeforeSubmit: {
                    guard captured == current else { throw FixtureError.generationDrift }
                },
                submit: { _ in
                    selectionCount += 1
                })
            Issue.record("Expected successor Dock generation to block AXPress")
        } catch let failure as DesktopActionFailure {
            Self.expectKnownRightClickOnly(failure)
        }

        #expect(rightClickCount == 1)
        #expect(selectionCount == 0)
    }

    @Test
    @MainActor
    func `AXPress error is retry-unsafe indeterminate mixed delivery`() async throws {
        var submissionCount = 0

        do {
            try await DockService.dispatchContextMenuSelection(
                targetMenuItem: "Options",
                prepare: { 7 },
                submit: { _ in
                    submissionCount += 1
                    throw FixtureError.pressFailed
                })
            Issue.record("Expected AXPress failure")
        } catch let failure as DesktopActionFailure {
            Self.expectIndeterminateSelection(failure)
        }

        #expect(submissionCount == 1)
    }

    @Test
    @MainActor
    func `Dock context result owner attributes ambiguous selection failure`() async {
        let identity = Self.processIdentity(generation: 21)

        do {
            _ = try await DockService.withDockFailureAttribution(processIdentity: identity) {
                try await DockService.dispatchContextMenuSelection(
                    targetMenuItem: "Options",
                    prepare: { 7 },
                    submit: { _ in throw FixtureError.pressFailed })
            }
            Issue.record("Expected attributed Dock context failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .foreground))
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
            #expect(failure.targetReceipt?.processIdentifier == identity.processIdentifier)
            #expect(failure.targetReceipt?.processStartIdentity == identity.processStartIdentity)
            #expect(failure.targetReceipt?.windowID == nil)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    @MainActor
    func `Cancellation returned by AXPress is retry-unsafe indeterminate mixed delivery`() async throws {
        var submissionCount = 0

        do {
            try await DockService.dispatchContextMenuSelection(
                targetMenuItem: "Options",
                prepare: { 7 },
                submit: { _ in
                    submissionCount += 1
                    throw CancellationError()
                })
            Issue.record("Expected AXPress cancellation")
        } catch let failure as DesktopActionFailure {
            Self.expectIndeterminateSelection(failure)
        }

        #expect(submissionCount == 1)
    }

    @Test
    @MainActor
    func `Successful selection crosses the dispatch boundary exactly once`() async throws {
        let captured = Self.processIdentity(generation: 31)
        let current = captured
        var validationCount = 0
        var submittedSelection: Int?

        try await DockService.dispatchContextMenuSelection(
            targetMenuItem: "Options",
            prepare: { 7 },
            validateBeforeSubmit: {
                validationCount += 1
                guard captured == current else { throw FixtureError.generationDrift }
            },
            submit: { selection in
                submittedSelection = selection
            })

        #expect(validationCount == 1)
        #expect(submittedSelection == 7)
    }

    private static func processIdentity(generation: UInt64) -> ApplicationProcessIdentity {
        ApplicationProcessIdentity(processIdentifier: 456, processStartIdentity: generation)
    }

    private static func expectKnownRightClickOnly(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.state == .dispatchedUnverified)
        #expect(failure.outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(failure.outcome.evidence == .deliveryAccepted)
        #expect(failure.outcome.dispatchState == .dispatched(unitCount: .one))
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.escalation == .observeBeforeRetry)
    }

    private static func expectIndeterminateSelection(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(failure.outcome.evidence == .completionUnknown)
        #expect(failure.outcome.dispatchState == .mayHaveDispatched(
            unitCount: DesktopActionOutcome.DispatchUnitCount(2)))
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.escalation == .observeBeforeRetry)
    }
}
